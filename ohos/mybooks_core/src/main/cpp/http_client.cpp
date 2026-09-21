#include "http_client.h"
#include <hilog/log.h>

#include <curl/curl.h>
#include <atomic>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <sstream>
#include <algorithm>
#include <sys/stat.h>

namespace mybooks {

// DNS / TLS session 缓存跨线程共享。连接本身不跨线程共享：curl 官方明确不支持
// 在并发线程之间共享连接，改为每线程各自持有连接（见 acquireEasyHandle）。
static std::once_flag gCurlInitFlag;
static std::mutex gShareMutex;
static CURLSH *gCurlShare = nullptr;

// 每个 worker 线程一个长期存活的 easy handle。curl_easy_reset 只清选项，会保留
// live connections / DNS 缓存 / TLS session / cookies，因此同线程的后续请求可直接
// 复用已建立的 TCP+TLS 连接（HTTP keep-alive），不再每请求重新解析 DNS 与握手。
static thread_local CURL *tEasy = nullptr;

// Cookie 落盘串行化：只在内容变化时写，且写临时文件后 rename 原子替换。
static std::mutex gCookieMutex;
static std::string gPersistedCookieLines;

// 连接层性能日志开关：默认关（避免每请求一行日志），由 pref `http_perf_log` 打开。
static std::atomic<bool> gMetricsEnabled{false};

static void ensureCurlInit() {
    std::call_once(gCurlInitFlag, []() {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        gCurlShare = curl_share_init();
        if (gCurlShare != nullptr) {
            curl_share_setopt(gCurlShare, CURLSHOPT_LOCKFUNC,
                              +[](CURL *, curl_lock_data, curl_lock_access, void *) {
                                  gShareMutex.lock();
                              });
            curl_share_setopt(gCurlShare, CURLSHOPT_UNLOCKFUNC,
                              +[](CURL *, curl_lock_data, void *) { gShareMutex.unlock(); });
            curl_share_setopt(gCurlShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
            curl_share_setopt(gCurlShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
        }
    });
}

static CURL *acquireEasyHandle() {
    ensureCurlInit();
    if (tEasy == nullptr) {
        tEasy = curl_easy_init();
    } else {
        // 只重置选项：live connections / DNS / TLS session / cookies 均保留。
        curl_easy_reset(tEasy);
    }
    return tEasy;
}

/** 连接层通用选项：线程内连接复用、TCP 调优、超时实现方式。 */
static void applyConnectionOptions(CURL *curl) {
    if (gCurlShare != nullptr) {
        curl_easy_setopt(curl, CURLOPT_SHARE, gCurlShare);
    }
    // 复用本线程已建立的连接：客户端↔nginx 这一跳是 keep-alive（nginx 的
    // Connection: close 只作用于 nginx→tornado 上游跳）。
    curl_easy_setopt(curl, CURLOPT_FORBID_REUSE, 0L);
    curl_easy_setopt(curl, CURLOPT_FRESH_CONNECT, 0L);
    curl_easy_setopt(curl, CURLOPT_MAXCONNECTS, 4L);
    // 多线程下必须禁用信号式超时（libcurl 默认会用 SIGALRM 实现 DNS/连接超时）。
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_NODELAY, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_FASTOPEN, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPIDLE, 30L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPINTVL, 15L);
    curl_easy_setopt(curl, CURLOPT_DNS_CACHE_TIMEOUT, 600L);
    curl_easy_setopt(curl, CURLOPT_HAPPY_EYEBALLS_TIMEOUT_MS, 50L);
    curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 1L);
    // 关闭 Expect: 100-continue，避免经反向代理的 POST 多等一轮 RTT。
    curl_easy_setopt(curl, CURLOPT_EXPECT_100_TIMEOUT_MS, 0L);
    // 当前 libcurl 构建无 nghttp2，HTTP/1.1 是唯一可用版本；显式指定避免协商。
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
}

static size_t writeCallback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    auto *buffer = static_cast<std::string *>(userdata);
    buffer->append(ptr, size * nmemb);
    return size * nmemb;
}

static size_t writeFileCallback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    auto *file = static_cast<std::FILE *>(userdata);
    return std::fwrite(ptr, size, nmemb, file);
}

struct ProgressData {
    std::function<void(double)> callback;
    double lastProgress = -1;
};

static int progressCallback(void *clientp, curl_off_t dltotal, curl_off_t dlnow,
                            curl_off_t /*ultotal*/, curl_off_t /*ulnow*/) {
    auto *data = static_cast<ProgressData *>(clientp);
    if (!data || !data->callback) return 0;
    double progress = 0;
    if (dltotal > 0) {
        progress = static_cast<double>(dlnow) / static_cast<double>(dltotal);
    } else if (dlnow > 0) {
        progress = static_cast<double>(dlnow) / (static_cast<double>(dlnow) + 1024 * 1024);
    }
    if (progress - data->lastProgress >= 0.01 || data->lastProgress < 0) {
        data->lastProgress = progress;
        data->callback(progress);
    }
    return 0;
}

static int uploadProgressCallback(void *clientp, curl_off_t /*dltotal*/, curl_off_t /*dlnow*/,
                                  curl_off_t ultotal, curl_off_t ulnow) {
    auto *data = static_cast<ProgressData *>(clientp);
    if (!data || !data->callback) return 0;
    double progress = 0;
    if (ultotal > 0) {
        progress = static_cast<double>(ulnow) / static_cast<double>(ultotal);
    }
    if (progress - data->lastProgress >= 0.01 || data->lastProgress < 0) {
        data->lastProgress = progress;
        data->callback(progress);
    }
    return 0;
}

HttpClient &HttpClient::instance() {
    static HttpClient client;
    // curl_global_init 只在首次调用时执行；用 call_once 而不是裸 static bool，
    // 避免多个 worker 线程同时首次请求时的数据竞态。
    ensureCurlInit();
    return client;
}

/** URL 是否已具备可请求的绝对形式；缺协议头说明服务器地址未配置。 */
static bool hasUsableBaseUrl(const std::string &url) {
    return url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0;
}

/** 服务器地址未配置时的提示（取代 curl 晦涩的 malformed URL 报错）。 */
static const char *kMissingBaseUrlError = "未配置服务器地址，请在「账号与服务器」中填写";

/** 取 libcurl 的某段时间统计（秒 → 毫秒），取不到返回 -1。 */
static long curlTimeMs(CURL *curl, CURLINFO info) {
    double seconds = 0;
    if (curl_easy_getinfo(curl, info, &seconds) != CURLE_OK) {
        return -1;
    }
    return static_cast<long>(seconds * 1000.0);
}

/**
 * 连接层性能日志（hilog -T MyBooksHttp 可看）：newconn 为本次请求新建的 TCP
 * 连接数，0 表示复用了已有连接，dnsMs/connMs/tlsMs/ttfbMs 对应各阶段耗时。
 */
static void logRequestMetrics(const char *kind, const char *method, const std::string &url,
                              CURL *curl, CURLcode code, long statusCode) {
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
static void persistCookiesIfChanged(CURL *curl, const std::string &cookieDir) {
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
    if (std::rename(tmpPath.c_str(), path.c_str()) == 0) {
        gPersistedCookieLines = lines;
        // 只记条数，不记 cookie 内容（会话凭据不外泄）
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp", "cookie persist lines=%{public}ld",
                     static_cast<long>(std::count(lines.begin(), lines.end(), '\n')));
    } else {
        std::remove(tmpPath.c_str());
    }
}

void HttpClient::setBaseUrl(const std::string &url) {
    baseUrl_ = url;
    while (!baseUrl_.empty() && baseUrl_.back() == '/') baseUrl_.pop_back();
    // 允许用户只填 host:port；curl 需要协议头，缺失时补 http://
    if (!baseUrl_.empty() && baseUrl_.find("://") == std::string::npos) {
        baseUrl_ = "http://" + baseUrl_;
    }
}

void HttpClient::setBearerToken(const std::string &token) { bearerToken_ = token; }
void HttpClient::setBasicAuth(const std::string &username, const std::string &password) {
    basicAuthHeader_ = username + ":" + password;
}
void HttpClient::clearAuth() {
    bearerToken_.clear();
    basicAuthHeader_.clear();
}
void HttpClient::setCookieDir(const std::string &dir) { cookieDir_ = dir; }
void HttpClient::setSslVerify(bool verify) { sslVerify_ = verify; }
void HttpClient::setMetricsEnabled(bool enabled) { gMetricsEnabled.store(enabled); }

std::string HttpClient::resolveUrl(const std::string &pathOrUrl) const {
    if (pathOrUrl.rfind("http://", 0) == 0 || pathOrUrl.rfind("https://", 0) == 0) {
        return pathOrUrl;
    }
    if (baseUrl_.empty()) return pathOrUrl;
    if (!pathOrUrl.empty() && pathOrUrl[0] == '/') return baseUrl_ + pathOrUrl;
    return baseUrl_ + "/" + pathOrUrl;
}

HttpResponse HttpClient::request(const HttpRequestOptions &options) {
    HttpResponse response;
    CURL *curl = acquireEasyHandle();
    if (!curl) {
        response.error = "curl init failed";
        return response;
    }

    std::string url = resolveUrl(options.url);
    if (!hasUsableBaseUrl(url)) {
        response.error = kMissingBaseUrlError;
        return response;
    }
    std::string responseBody;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, options.method.c_str());
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, options.connectTimeoutMs);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, options.readTimeoutMs);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, options.followRedirects ? 1L : 0L);

    // 默认校验证书链与主机名；仅当用户在设置中显式开启「跳过 SSL 验证」时才关闭。
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, sslVerify_ ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, sslVerify_ ? 2L : 0L);
    // 仅允许 http/https（含重定向），阻断 file:// 等本地协议被利用
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    applyConnectionOptions(curl);

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Accept: application/json, text/plain, */*");
    if (!options.contentType.empty()) {
        std::string ct = "Content-Type: " + options.contentType;
        headers = curl_slist_append(headers, ct.c_str());
    }
    for (const auto &h : options.headers) {
        std::string line = h.first + ": " + h.second;
        headers = curl_slist_append(headers, line.c_str());
    }
    if (!bearerToken_.empty()) {
        std::string auth = "Authorization: Bearer " + bearerToken_;
        headers = curl_slist_append(headers, auth.c_str());
    } else if (!basicAuthHeader_.empty()) {
        curl_easy_setopt(curl, CURLOPT_USERPWD, basicAuthHeader_.c_str());
    }
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    if (!options.body.empty()) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, options.body.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(options.body.size()));
    }

    std::string cookieFile = cookieDir_.empty() ? "" : cookieDir_ + "/cookies.txt";
    if (!cookieFile.empty()) {
        curl_easy_setopt(curl, CURLOPT_COOKIEFILE, cookieFile.c_str());
        curl_easy_setopt(curl, CURLOPT_COOKIEJAR, cookieFile.c_str());
    }

    std::function<bool(const char *, size_t)> streamCb = options.streamCallback;
    if (streamCb) {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION,
                         +[](char *ptr, size_t size, size_t nmemb, void *userdata) -> size_t {
                             auto *cb = static_cast<std::function<bool(const char *, size_t)> *>(userdata);
                             return (*cb)(ptr, size * nmemb) ? size * nmemb : 0;
                         });
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &streamCb);
    } else {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);
    }

    CURLcode code = curl_easy_perform(curl);
    long status = 0;
    if (code != CURLE_OK) {
        response.error = curl_easy_strerror(code);
    } else {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        response.statusCode = static_cast<int>(status);
        response.body = responseBody;
        if (status >= 400) {
            response.error = status == 413
                ? "请求体过大，超过服务器大小限制 (HTTP 413)"
                : "服务器错误 (HTTP " + std::to_string(status) + ")";
        }
    }

    logRequestMetrics("core-api", options.method.c_str(), url, curl, code, status);
    // handle 留在本线程复用连接，cookie 改为「有变化才原子落盘」
    persistCookiesIfChanged(curl, cookieDir_);
    curl_slist_free_all(headers);
    return response;
}

HttpResponse HttpClient::get(const std::string &pathOrUrl,
                             const std::map<std::string, std::string> &query) {
    std::string url = pathOrUrl;
    if (!query.empty()) {
        std::ostringstream oss;
        oss << url << (url.find('?') == std::string::npos ? '?' : '&');
        bool first = true;
        for (const auto &kv : query) {
            if (!first) oss << '&';
            first = false;
            char *ek = curl_easy_escape(nullptr, kv.first.c_str(), static_cast<int>(kv.first.size()));
            char *ev = curl_easy_escape(nullptr, kv.second.c_str(), static_cast<int>(kv.second.size()));
            oss << ek << '=' << ev;
            curl_free(ek);
            curl_free(ev);
        }
        url = oss.str();
    }
    HttpRequestOptions opts;
    opts.method = "GET";
    opts.url = url;
    return request(opts);
}

HttpResponse HttpClient::post(const std::string &pathOrUrl, const std::string &body,
                              const std::string &contentType) {
    HttpRequestOptions opts;
    opts.method = "POST";
    opts.url = pathOrUrl;
    opts.body = body;
    opts.contentType = contentType;
    return request(opts);
}

HttpResponse HttpClient::uploadFiles(const std::string &pathOrUrl,
                                     const std::vector<UploadFilePart> &files,
                                     const std::string &fileFieldName,
                                     const std::vector<std::pair<std::string, std::string>> &fields,
                                     std::function<void(double)> onProgress) {
    HttpResponse response;
    if (files.empty()) {
        response.error = "no files to upload";
        return response;
    }

    CURL *curl = acquireEasyHandle();
    if (!curl) {
        response.error = "curl init failed";
        return response;
    }

    std::string url = resolveUrl(pathOrUrl);
    if (!hasUsableBaseUrl(url)) {
        response.error = kMissingBaseUrlError;
        return response;
    }
    std::string responseBody;
    curl_mime *mime = curl_mime_init(curl);
    for (const auto &file : files) {
        curl_mimepart *part = curl_mime_addpart(mime);
        const std::string &partField = file.fieldName.empty() ? fileFieldName : file.fieldName;
        // 上传诊断：确认 multipart 字段名、文件名与宿主文件是否真实存在（hilog -T MyBooksHttp）
        struct stat st{};
        int statRc = stat(file.filePath.c_str(), &st);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp",
                     "upload part field=%{public}s name=%{public}s path=%{public}s "
                     "stat=%{public}d size=%{public}lld",
                     partField.c_str(), file.fileName.c_str(), file.filePath.c_str(), statRc,
                     static_cast<long long>(st.st_size));
        curl_mime_name(part, partField.c_str());
        curl_mime_filedata(part, file.filePath.c_str());
        curl_mime_filename(part, file.fileName.c_str());
    }
    for (const auto &kv : fields) {
        curl_mimepart *field = curl_mime_addpart(mime);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp",
                     "upload field name=%{public}s value=%{public}s",
                     kv.first.c_str(), kv.second.c_str());
        curl_mime_name(field, kv.first.c_str());
        curl_mime_data(field, kv.second.c_str(), CURL_ZERO_TERMINATED);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp", "upload POST %{public}s (files=%{public}zu)",
                 url.c_str(), files.size());
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    // 不要在这里再设 CURLOPT_POST：MIMEPOST 已把 method 置为 HTTPREQ_POST_MIME，
    // 覆盖成 HTTPREQ_POST 会让 curl 改用 application/x-www-form-urlencoded 且空 body，
    // 服务端 multipart 解析拿不到文件字段（表现为「文件不存在或未选择文件」）。
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 15000);
    // 批量图书上传可能更大，读超时放宽到 20 分钟
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 1200000L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, sslVerify_ ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, sslVerify_ ? 2L : 0L);
    // 仅允许 http/https（含重定向），阻断本地协议被利用
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    applyConnectionOptions(curl);

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Accept: application/json, text/plain, */*");
    if (!bearerToken_.empty()) {
        std::string auth = "Authorization: Bearer " + bearerToken_;
        headers = curl_slist_append(headers, auth.c_str());
    } else if (!basicAuthHeader_.empty()) {
        curl_easy_setopt(curl, CURLOPT_USERPWD, basicAuthHeader_.c_str());
    }
    std::string cookieFile = cookieDir_.empty() ? "" : cookieDir_ + "/cookies.txt";
    if (!cookieFile.empty()) {
        curl_easy_setopt(curl, CURLOPT_COOKIEFILE, cookieFile.c_str());
        curl_easy_setopt(curl, CURLOPT_COOKIEJAR, cookieFile.c_str());
    }
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);

    ProgressData progressData{onProgress, -1};
    if (onProgress) {
        curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, uploadProgressCallback);
        curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &progressData);
        curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    }

    CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        response.error = curl_easy_strerror(code);
    } else {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        response.statusCode = static_cast<int>(status);
        response.body = responseBody;
    }
    // 上传诊断：curl 结果 + HTTP 状态 + 响应体前 800 字节（hilog -T MyBooksHttp）
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MyBooksHttp",
                 "upload resp curl=%{public}d http=%{public}d body=%{public}s",
                 static_cast<int>(code), response.statusCode, responseBody.substr(0, 800).c_str());

    logRequestMetrics("core-upload", "POST", url, curl, code, response.statusCode);
    persistCookiesIfChanged(curl, cookieDir_);
    curl_mime_free(mime);
    curl_slist_free_all(headers);
    // handle 留在本线程复用连接
    return response;
}

HttpResponse HttpClient::uploadFile(const std::string &pathOrUrl, const std::string &filePath,
                                    const std::string &fileFieldName, const std::string &fileName,
                                    const std::map<std::string, std::string> &fields,
                                    std::function<void(double)> onProgress) {
    std::vector<UploadFilePart> files;
    files.push_back(UploadFilePart{filePath, fileName});
    std::vector<std::pair<std::string, std::string>> fieldList;
    fieldList.reserve(fields.size());
    for (const auto &kv : fields) {
        fieldList.emplace_back(kv.first, kv.second);
    }
    return uploadFiles(pathOrUrl, files, fileFieldName, fieldList, onProgress);
}

HttpResponse HttpClient::downloadToFile(const std::string &pathOrUrl, const std::string &savePath,
                                        std::function<void(double)> onProgress) {
    HttpResponse response;
    CURL *curl = acquireEasyHandle();
    if (!curl) {
        response.error = "curl init failed";
        return response;
    }

    std::string url = resolveUrl(pathOrUrl);
    if (!hasUsableBaseUrl(url)) {
        response.error = kMissingBaseUrlError;
        return response;
    }
    FILE *file = std::fopen(savePath.c_str(), "wb");
    if (!file) {
        response.error = "cannot open save path";
        return response;
    }

    ProgressData progressData{onProgress, -1};
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeFileCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, file);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, sslVerify_ ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, sslVerify_ ? 2L : 0L);
    // 仅允许 http/https（含重定向），阻断本地协议被利用
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    applyConnectionOptions(curl);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progressCallback);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &progressData);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Accept: */*");
    if (!bearerToken_.empty()) {
        std::string auth = "Authorization: Bearer " + bearerToken_;
        headers = curl_slist_append(headers, auth.c_str());
    } else if (!basicAuthHeader_.empty()) {
        curl_easy_setopt(curl, CURLOPT_USERPWD, basicAuthHeader_.c_str());
    }
    std::string cookieFile = cookieDir_.empty() ? "" : cookieDir_ + "/cookies.txt";
    if (!cookieFile.empty()) {
        curl_easy_setopt(curl, CURLOPT_COOKIEFILE, cookieFile.c_str());
        curl_easy_setopt(curl, CURLOPT_COOKIEJAR, cookieFile.c_str());
    }
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    CURLcode code = curl_easy_perform(curl);
    long status = 0;
    std::fclose(file);
    if (code != CURLE_OK) {
        response.error = curl_easy_strerror(code);
        std::remove(savePath.c_str());
    } else {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        response.statusCode = static_cast<int>(status);
    }
    logRequestMetrics("core-download", "GET", url, curl, code, status);
    persistCookiesIfChanged(curl, cookieDir_);
    curl_slist_free_all(headers);
    // handle 留在本线程复用连接
    return response;
}

} // namespace mybooks
