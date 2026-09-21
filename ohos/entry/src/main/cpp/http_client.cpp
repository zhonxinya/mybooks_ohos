#include "http_client.h"

#include "curl/curl.h"
#include "path_util.h"

#include <hilog/log.h>

#include <algorithm>
#include <atomic>
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

// 每个 worker 线程一个长期存活的 easy handle：curl_easy_reset 只清选项，会保留
// live connections / DNS 缓存 / TLS session / cookies，因此同线程的后续请求可以直接
// 复用已建立的 TCP+TLS 连接（HTTP keep-alive），不必每次请求重新握手。
thread_local CURL *gTlsEasy = nullptr;

// Cookie 落盘串行化：只在内容变化时写，且写临时文件后 rename 原子替换。
std::mutex gCookieMutex;
std::string gPersistedCookieLines;

// 连接层性能日志开关：默认关（避免每请求一行日志），由 pref `http_perf_log` 打开。
std::atomic<bool> gMetricsEnabled{false};

/** 线程退出时释放本线程 handle，避免 fd 泄漏（worker 线程长期存活，正常不会触发）。 */
struct EasyHandleGuard {
    ~EasyHandleGuard()
    {
        if (gTlsEasy != nullptr) {
            curl_easy_cleanup(gTlsEasy);
            gTlsEasy = nullptr;
        }
    }
};
thread_local EasyHandleGuard gEasyHandleGuard;

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
            // 跨线程共享 DNS 与 TLS session 缓存。连接（CURL_LOCK_DATA_CONNECT）不共享：
            // curl 官方明确「不支持在多个并发线程之间共享连接」，改为每线程各自持有连接
            // （见 acquireEasyHandle），这才是多线程下可安全 keep-alive 的方式。
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
        // 只重置选项：live connections / DNS 缓存 / TLS session / cookies 都保留，
        // 于是同线程的下一请求会复用上一条已建立的连接。
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
    // 允许复用本线程已建立的连接：客户端↔nginx 这一跳本身是 keep-alive。
    // 服务端 nginx 只对「nginx→tornado」上游跳发 Connection: close
    // （conf/nginx 中 map $http_upgrade $connection_upgrade + proxy_set_header），
    // 不影响客户端这一侧；因此客户端可以且应当复用连接。
    curl_easy_setopt(curl, CURLOPT_FORBID_REUSE, 0L);
    curl_easy_setopt(curl, CURLOPT_FRESH_CONNECT, 0L);
    // 连接缓存上限：每个 worker 线程最多留几条连接，避免批量封面时堆连接。
    curl_easy_setopt(curl, CURLOPT_MAXCONNECTS, 4L);
    // TCP 层保活：让内核探测空闲连接，尽早发现被网络中断的半开连接。
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPIDLE, 30L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPINTVL, 15L);
    // TLS session ticket/ID 可跨「新 TCP 连接」复用，显著缩短握手。
    curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 1L);
    // 关闭 Expect: 100-continue，避免经反向代理的 POST 多等一轮 RTT。
    curl_easy_setopt(curl, CURLOPT_EXPECT_100_TIMEOUT_MS, 0L);
    // 当前 libcurl 构建无 nghttp2，HTTP/1.1 是唯一可用版本；显式指定避免协商。
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    // 本构建未编译 zlib/brotli，此行当前为空操作；保留以便将来换带压缩的 libcurl 后自动生效。
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
    // 目标目录可能是多层（如账号书籍目录），单层 mkdir 会失败
    return makeDirs(filePath.substr(0, pos));
}

std::string cookiePath(const std::string &cookieDir)
{
    return cookieDir.empty() ? "" : cookieDir + "/cookies.txt";
}

/** URL 是否已具备可请求的绝对形式；缺协议头说明服务器地址未配置。 */
bool hasUsableBaseUrl(const std::string &url)
{
    return url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0;
}

/** 服务器地址未配置时的提示（取代 curl 晦涩的 malformed URL 报错）。 */
const char *kMissingBaseUrlError = "未配置服务器地址，请在「账号与服务器」中填写";

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

/** 取 libcurl 的某段时间统计（秒 → 毫秒），取不到返回 -1。 */
long curlTimeMs(CURL *curl, CURLINFO info)
{
    double seconds = 0;
    if (curl_easy_getinfo(curl, info, &seconds) != CURLE_OK) {
        return -1;
    }
    return static_cast<long>(seconds * 1000.0);
}

/**
 * 连接层性能日志（hilog -T MyBooksHttp 可看）：
 * newconn 是本次请求新建的 TCP 连接数，0 表示复用了已有连接（keep-alive 生效），
 * dnsMs/connMs/tlsMs/ttfbMs 分别对应 DNS、TCP、TLS 握手、首字节耗时。
 */
void logRequestMetrics(const char *kind, const char *method, const std::string &url, CURL *curl,
                       CURLcode code, long statusCode)
{
    if (!gMetricsEnabled.load()) {
        return;
    }
    long connects = 0;
    curl_easy_getinfo(curl, CURLINFO_NUM_CONNECTS, &connects);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp",
                 "perf kind=%{public}s method=%{public}s http=%{public}ld curl=%{public}d "
                 "newconn=%{public}ld dnsMs=%{public}ld connMs=%{public}ld tlsMs=%{public}ld "
                 "ttfbMs=%{public}ld totalMs=%{public}ld url=%{public}s",
                 kind, method, statusCode, static_cast<int>(code), connects,
                 curlTimeMs(curl, CURLINFO_NAMELOOKUP_TIME), curlTimeMs(curl, CURLINFO_CONNECT_TIME),
                 curlTimeMs(curl, CURLINFO_APPCONNECT_TIME),
                 curlTimeMs(curl, CURLINFO_STARTTRANSFER_TIME), curlTimeMs(curl, CURLINFO_TOTAL_TIME),
                 url.c_str());
}

/**
 * Cookie 落盘：只在内容真正变化时写，且先写临时文件再 rename 原子替换。
 *
 * 原实现靠「curl_easy_cleanup 时由 COOKIEJAR 落盘」；现在 handle 长期存活于线程内，
 * cleanup 不再发生，而每请求无条件重写 cookies.txt 既有写放大，又可能让别的线程在
 * COOKIEFILE 读取时看到半截文件（表现为登录态莫名丢失）。
 */
void persistCookiesIfChanged(CURL *curl, const std::string &cookieDir)
{
    if (cookieDir.empty()) {
        return;
    }
    struct curl_slist *cookies = nullptr;
    if (curl_easy_getinfo(curl, CURLINFO_COOKIELIST, &cookies) != CURLE_OK) {
        return;
    }
    std::string lines;
    for (struct curl_slist *node = cookies; node != nullptr; node = node->next) {
        if (node->data != nullptr) {
            lines += node->data;
            lines += '\n';
        }
    }
    curl_slist_free_all(cookies);

    std::lock_guard<std::mutex> lock(gCookieMutex);
    if (lines == gPersistedCookieLines) {
        return;
    }
    const std::string path = cookieDir + "/cookies.txt";
    const std::string tmpPath = path + ".tmp";
    // 交给 libcurl 按标准 Netscape 格式写临时文件（FLUSH 写到 COOKIEJAR 指定的文件）
    curl_easy_setopt(curl, CURLOPT_COOKIEJAR, tmpPath.c_str());
    const CURLcode flushCode = curl_easy_setopt(curl, CURLOPT_COOKIELIST, "FLUSH");
    curl_easy_setopt(curl, CURLOPT_COOKIEJAR, static_cast<const char *>(nullptr));
    if (flushCode != CURLE_OK) {
        return;
    }
    if (rename(tmpPath.c_str(), path.c_str()) == 0) {
        gPersistedCookieLines = lines;
        // 只记条数，不记 cookie 内容（会话凭据不外泄）
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp",
                     "cookie persist lines=%{public}zu", std::count(lines.begin(), lines.end(), '\n'));
    } else {
        remove(tmpPath.c_str());
    }
}

HttpResponse performCurlRequest(const std::string &url, const std::string &method,
                                const std::string &contentType, const std::string &body,
                                const std::string &cookieDir, bool sslVerify,
                                long connectTimeoutSec = 5, long timeoutSec = 10)
{
    HttpResponse result;
    if (!hasUsableBaseUrl(url)) {
        result.error = kMissingBaseUrlError;
        return result;
    }
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
    long status = 0;
    if (code != CURLE_OK) {
        result.error = formatCurlError(code, curl_easy_strerror(code));
    } else {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        result.statusCode = static_cast<int>(status);
        result.body = std::move(responseBody);
    }

    logRequestMetrics("api", method.c_str(), url, curl, code, status);
    // handle 留在本线程复用连接，cookie 改为「有变化才原子落盘」，
    // 跨线程 / 跨模块（mybooks_core）请求依旧能读到最新会话。
    persistCookiesIfChanged(curl, cookieDir);
    curl_slist_free_all(headers);
    return result;
}

HttpResponse performCurlDownload(const std::string &url, const std::string &destPath,
                                 const std::string &cookieDir, bool sslVerify,
                                 long connectTimeoutSec, long timeoutSec)
{
    HttpResponse result;
    if (!hasUsableBaseUrl(url)) {
        result.error = kMissingBaseUrlError;
        return result;
    }
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
            // 下载诊断：确认实际请求的 URL 与服务端状态码（404 说明文件路径拼错）
            std::string head;
            std::ifstream failed(destPath, std::ios::binary);
            if (failed) {
                char buf[161] = {0};
                failed.read(buf, 160);
                head.assign(buf, static_cast<size_t>(failed.gcount()));
                failed.close();
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp",
                         "download FAILED http=%{public}d url=%{public}s dest=%{public}s body=%{public}s",
                         result.statusCode, url.c_str(), destPath.c_str(), head.c_str());
            remove(destPath.c_str());
            result.error = "下载失败，HTTP " + std::to_string(result.statusCode);
        } else {
            result.body = destPath;
        }
    }

    logRequestMetrics("download", "GET", url, curl, code, result.statusCode);
    persistCookiesIfChanged(curl, cookieDir);
    curl_slist_free_all(headers);
    // handle 留在本线程复用（连接 keep-alive），cookie 已按变化原子落盘。
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
    // 允许用户只填 host:port；curl 需要协议头，缺失时补 http://
    if (!normalized.empty() && normalized.find("://") == std::string::npos) {
        normalized = "http://" + normalized;
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
        makeDirs(cookieDir_, 0700);
    }
    loadCookies();
}

void HttpClient::setSslVerify(bool verify)
{
    sslVerify_ = verify;
}

void HttpClient::setMetricsEnabled(bool enabled)
{
    gMetricsEnabled.store(enabled);
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
