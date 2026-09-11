#include "http_client.h"

#include "curl/curl.h"

#include <cerrno>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <sys/stat.h>

namespace talebook {
namespace {

std::once_flag gCurlInitFlag;
std::mutex gShareMutex;
CURLSH *gCurlShare = nullptr;

// 每个 worker 线程复用 easy handle，保留本线程 DNS / TLS session 缓存（服务器禁用连接复用）。
thread_local CURL *gTlsEasy = nullptr;

void ensureCurlInit()
{
    std::call_once(gCurlInitFlag, []() {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        gCurlShare = curl_share_init();
        if (gCurlShare != nullptr) {
            curl_share_setopt(gCurlShare, CURLSHOPT_LOCKFUNC,
                              +[](CURL * /*handle*/, curl_lock_data /*data*/, curl_lock_access /*access*/,
                                  void * /*userptr*/) { gShareMutex.lock(); });
            curl_share_setopt(gCurlShare, CURLSHOPT_UNLOCKFUNC,
                              +[](CURL * /*handle*/, curl_lock_data /*data*/, void * /*userptr*/) {
                                  gShareMutex.unlock();
                              });
            // 服务器禁用 Keep-Alive：不共享 CONNECT；跨线程共享 DNS + TLS session 缩短每次新连接握手。
            curl_share_setopt(gCurlShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
            curl_share_setopt(gCurlShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
        }
    });
}

CURL *acquireEasyHandle()
{
    ensureCurlInit();
    if (gTlsEasy == nullptr) {
        gTlsEasy = curl_easy_init();
    } else {
        curl_easy_reset(gTlsEasy);
    }
    return gTlsEasy;
}

void applySharedCurlOptions(CURL *curl)
{
    if (gCurlShare != nullptr) {
        curl_easy_setopt(curl, CURLOPT_SHARE, gCurlShare);
    }
    // 不强制 IP 族：纯 IPv6 主机 DNS 仅 AAAA，无双栈开销；字体等外链仍可走 IPv4。
    curl_easy_setopt(curl, CURLOPT_IPRESOLVE, CURL_IPRESOLVE_WHATEVER);
    curl_easy_setopt(curl, CURLOPT_HAPPY_EYEBALLS_TIMEOUT_MS, 50L);
    curl_easy_setopt(curl, CURLOPT_DNS_CACHE_TIMEOUT, 600L);
    curl_easy_setopt(curl, CURLOPT_TCP_NODELAY, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_FASTOPEN, 1L);
    // 服务器禁用连接复用：每次请求后关闭，避免误复用已关闭连接导致卡住。
    curl_easy_setopt(curl, CURLOPT_FORBID_REUSE, 1L);
    curl_easy_setopt(curl, CURLOPT_FRESH_CONNECT, 0L);
    // TLS session ticket/ID 仍可跨「新 TCP 连接」复用，显著缩短握手。
    curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 1L);
    // 关闭 Expect: 100-continue，避免经反向代理的 POST 多等一轮 RTT。
    curl_easy_setopt(curl, CURLOPT_EXPECT_100_TIMEOUT_MS, 0L);
    // 无 Keep-Alive 时 HTTP/1.1 比每次新建 HTTP/2 更轻。
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "TalebookReader/1.0 (HarmonyOS)");
}

size_t writeCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    auto *buffer = static_cast<std::string *>(userdata);
    const size_t total = size * nmemb;
    buffer->append(ptr, total);
    return total;
}

size_t writeFileCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    auto *file = static_cast<FILE *>(userdata);
    if (file == nullptr) {
        return 0;
    }
    return fwrite(ptr, size, nmemb, file);
}

bool ensureParentDir(const std::string &filePath)
{
    const size_t pos = filePath.find_last_of('/');
    if (pos == std::string::npos) {
        return true;
    }
    const std::string dir = filePath.substr(0, pos);
    return mkdir(dir.c_str(), 0755) == 0 || errno == EEXIST;
}

std::string cookiePath(const std::string &cookieDir)
{
    return cookieDir.empty() ? "" : cookieDir + "/cookies.txt";
}

std::string formatCurlError(CURLcode code, const char *message)
{
    if (code == CURLE_PEER_FAILED_VERIFICATION) {
        return "SSL 证书验证失败，请为服务器配置受信任证书；仅自签名/局域网环境可开启「跳过 SSL 验证」";
    }
    if (code == CURLE_SSL_CONNECT_ERROR) {
        return "SSL 连接失败，请检查服务器地址与证书";
    }
    if (code == CURLE_SSL_CACERT) {
        return "无法验证 SSL 证书，请使用受信任证书；仅自签名/局域网环境可开启「跳过 SSL 验证」";
    }
    return message != nullptr ? std::string(message) : "网络请求失败";
}

HttpResponse performCurlRequest(const std::string &url, const std::string &method,
                                const std::string &contentType, const std::string &body,
                                const std::string &cookieDir, bool sslVerify,
                                long connectTimeoutSec = 5, long timeoutSec = 10)
{
    HttpResponse result;
    CURL *curl = acquireEasyHandle();
    if (curl == nullptr) {
        result.error = "curl_easy_init failed";
        return result;
    }

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Accept: application/json");
    if (!contentType.empty()) {
        headers = curl_slist_append(headers, ("Content-Type: " + contentType).c_str());
    }

    std::string responseBody;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, connectTimeoutSec);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeoutSec);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, sslVerify ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, sslVerify ? 2L : 0L);
    // 仅允许 http/https：阻断 file:// 等本地协议被恶意服务端数据或
    // 重定向到本地协议所利用（curl 支持 file://，可读出本地文件）。
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    applySharedCurlOptions(curl);

    const std::string cookieFile = cookiePath(cookieDir);
    if (!cookieFile.empty()) {
        curl_easy_setopt(curl, CURLOPT_COOKIEJAR, cookieFile.c_str());
        curl_easy_setopt(curl, CURLOPT_COOKIEFILE, cookieFile.c_str());
    }

    if (method == "GET") {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    } else if (method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
    } else {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
        if (!body.empty()) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
        }
    }

    const CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        result.error = formatCurlError(code, curl_easy_strerror(code));
    } else {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        result.statusCode = static_cast<int>(status);
        result.body = std::move(responseBody);
    }

    curl_slist_free_all(headers);
    // 必须 cleanup：COOKIEJAR 仅在 cleanup 时落盘到 cookies.txt，
    // 否则登录 cookie 只留在本线程 handle 内存，跨线程/跨模块（mybooks_core）请求拿不到会话。
    // DNS/TLS 缓存已通过 curl_share 共享，且已 FORBID_REUSE，cleanup 无性能损失。
    curl_easy_cleanup(curl);
    gTlsEasy = nullptr;
    return result;
}

HttpResponse performCurlDownload(const std::string &url, const std::string &destPath,
                                 const std::string &cookieDir, bool sslVerify,
                                 long connectTimeoutSec, long timeoutSec)
{
    HttpResponse result;
    if (!ensureParentDir(destPath)) {
        result.error = "无法创建下载目录";
        return result;
    }

    FILE *file = fopen(destPath.c_str(), "wb");
    if (file == nullptr) {
        result.error = "无法创建下载文件";
        return result;
    }

    CURL *curl = acquireEasyHandle();
    if (curl == nullptr) {
        fclose(file);
        result.error = "curl_easy_init failed";
        return result;
    }

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Accept: */*");
    headers = curl_slist_append(headers, "User-Agent: Mozilla/5.0 (compatible; TalebookReader/1.0)");

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeFileCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, file);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, connectTimeoutSec);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeoutSec);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, sslVerify ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, sslVerify ? 2L : 0L);
    // 仅允许 http/https（含重定向），避免本地协议被利用
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    applySharedCurlOptions(curl);

    const std::string cookieFile = cookiePath(cookieDir);
    if (!cookieFile.empty()) {
        curl_easy_setopt(curl, CURLOPT_COOKIEJAR, cookieFile.c_str());
        curl_easy_setopt(curl, CURLOPT_COOKIEFILE, cookieFile.c_str());
    }

    const CURLcode code = curl_easy_perform(curl);
    fclose(file);

    if (code != CURLE_OK) {
        remove(destPath.c_str());
        result.error = formatCurlError(code, curl_easy_strerror(code));
    } else {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        result.statusCode = static_cast<int>(status);
        if (result.statusCode < 200 || result.statusCode >= 300) {
            remove(destPath.c_str());
            result.error = "下载失败，HTTP " + std::to_string(result.statusCode);
        } else {
            result.body = destPath;
        }
    }

    curl_slist_free_all(headers);
    // 同 performCurlRequest：cleanup 触发 COOKIEJAR 落盘，保证登录态跨请求可用
    curl_easy_cleanup(curl);
    gTlsEasy = nullptr;
    return result;
}

} // namespace

HttpClient &HttpClient::instance()
{
    static HttpClient client;
    return client;
}

void HttpClient::setBaseUrl(const std::string &service, const std::string &url)
{
    std::string normalized = url;
    while (!normalized.empty() && normalized.back() == '/') {
        normalized.pop_back();
    }
    if (service == "sonovel") {
        sonovelBase_ = normalized;
    } else {
        talebookBase_ = normalized;
    }
}

std::string HttpClient::getBaseUrl(const std::string &service) const
{
    return service == "sonovel" ? sonovelBase_ : talebookBase_;
}

void HttpClient::setCookieDir(const std::string &dir)
{
    cookieDir_ = dir;
    if (!cookieDir_.empty()) {
        // 会话 Cookie 属敏感数据，目录仅限应用自身访问
        mkdir(cookieDir_.c_str(), 0700);
    }
    loadCookies();
}

void HttpClient::setSslVerify(bool verify)
{
    sslVerify_ = verify;
}

void HttpClient::loadCookies()
{
    cookieData_.clear();
    if (cookieDir_.empty()) {
        return;
    }
    std::ifstream in(cookieDir_ + "/cookies.txt");
    if (in.is_open()) {
        std::ostringstream ss;
        ss << in.rdbuf();
        cookieData_ = ss.str();
    }
}

void HttpClient::saveCookies()
{
    // libcurl 通过 COOKIEJAR 自动持久化
}

void HttpClient::clearCookies()
{
    cookieData_.clear();
    if (cookieDir_.empty()) {
        return;
    }
    remove((cookieDir_ + "/cookies.txt").c_str());
}

std::string HttpClient::buildUrl(const std::string &service, const std::string &path,
                                 const std::string &query) const
{
    std::string base = getBaseUrl(service);
    std::string fullPath = path.empty() ? "/" : path;
    if (!fullPath.empty() && fullPath[0] != '/') {
        fullPath = "/" + fullPath;
    }
    std::string url = base + fullPath;
    if (!query.empty()) {
        url += (query[0] == '?' ? "" : "?") + query;
    }
    return url;
}

HttpResponse HttpClient::request(const std::string &method, const std::string &service,
                                 const std::string &path, const std::string &body,
                                 const std::string &contentType)
{
    const std::string url = buildUrl(service, path, "");
    return performCurlRequest(url, method, contentType, body, cookieDir_, sslVerify_);
}

HttpResponse HttpClient::get(const std::string &service, const std::string &path,
                             const std::string &query, long connectTimeoutSec, long timeoutSec)
{
    const std::string url = buildUrl(service, path, query);
    return performCurlRequest(url, "GET", "", "", cookieDir_, sslVerify_, connectTimeoutSec,
                              timeoutSec);
}

HttpResponse HttpClient::post(const std::string &service, const std::string &path,
                              const std::string &body, const std::string &contentType)
{
    return request("POST", service, path, body, contentType);
}

HttpResponse HttpClient::postForm(const std::string &service, const std::string &path,
                                  const std::string &formBody)
{
    return post(service, path, formBody, "application/x-www-form-urlencoded");
}

HttpResponse HttpClient::downloadToFile(const std::string &service, const std::string &path,
                                        const std::string &destPath, const std::string &query)
{
    const std::string url = buildUrl(service, path, query);
    return performCurlDownload(url, destPath, cookieDir_, sslVerify_, 30L, 300L);
}

HttpResponse HttpClient::downloadUrlToFile(const std::string &url, const std::string &destPath)
{
    // 封面图较小；字体等大文件也走此接口，放宽超时避免中途失败
    return performCurlDownload(url, destPath, cookieDir_, sslVerify_, 15L, 180L);
}

HttpResponse HttpClient::warmConnection(const std::string &service)
{
    const std::string base = getBaseUrl(service);
    if (base.empty()) {
        HttpResponse empty;
        empty.error = "base url empty";
        return empty;
    }
    // 走轻量 API：预热 DNS + TLS session（服务器禁用连接复用时仍能加速后续握手）。
    if (service == "talebook") {
        return get(service, "/api/user/info", "", 5L, 8L);
    }
    return performCurlRequest(base + "/", "GET", "", "", cookieDir_, sslVerify_, 5L, 8L);
}

} // namespace talebook
