#include "http_client.h"

#include <curl/curl.h>
#include <fstream>
#include <sstream>
#include <algorithm>

namespace talebook {

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
    static bool curlInited = false;
    if (!curlInited) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        curlInited = true;
    }
    return client;
}

void HttpClient::setBaseUrl(const std::string &url) {
    baseUrl_ = url;
    while (!baseUrl_.empty() && baseUrl_.back() == '/') baseUrl_.pop_back();
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
    CURL *curl = curl_easy_init();
    if (!curl) {
        response.error = "curl init failed";
        return response;
    }

    std::string url = resolveUrl(options.url);
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
    if (code != CURLE_OK) {
        response.error = curl_easy_strerror(code);
    } else {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        response.statusCode = static_cast<int>(status);
        response.body = responseBody;
        if (status >= 400) {
            response.error = status == 413
                ? "请求体过大，超过服务器大小限制 (HTTP 413)"
                : "服务器错误 (HTTP " + std::to_string(status) + ")";
        }
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
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

    CURL *curl = curl_easy_init();
    if (!curl) {
        response.error = "curl init failed";
        return response;
    }

    std::string url = resolveUrl(pathOrUrl);
    std::string responseBody;
    curl_mime *mime = curl_mime_init(curl);
    for (const auto &file : files) {
        curl_mimepart *part = curl_mime_addpart(mime);
        const std::string &partField = file.fieldName.empty() ? fileFieldName : file.fieldName;
        curl_mime_name(part, partField.c_str());
        curl_mime_filedata(part, file.filePath.c_str());
        curl_mime_filename(part, file.fileName.c_str());
    }
    for (const auto &kv : fields) {
        curl_mimepart *field = curl_mime_addpart(mime);
        curl_mime_name(field, kv.first.c_str());
        curl_mime_data(field, kv.second.c_str(), CURL_ZERO_TERMINATED);
    }
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 15000);
    // 批量图书上传可能更大，读超时放宽到 20 分钟
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 1200000L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, sslVerify_ ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, sslVerify_ ? 2L : 0L);
    // 仅允许 http/https（含重定向），阻断本地协议被利用
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");

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

    curl_mime_free(mime);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
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
    CURL *curl = curl_easy_init();
    if (!curl) {
        response.error = "curl init failed";
        return response;
    }

    std::string url = resolveUrl(pathOrUrl);
    FILE *file = std::fopen(savePath.c_str(), "wb");
    if (!file) {
        response.error = "cannot open save path";
        curl_easy_cleanup(curl);
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
    std::fclose(file);
    if (code != CURLE_OK) {
        response.error = curl_easy_strerror(code);
        std::remove(savePath.c_str());
    } else {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        response.statusCode = static_cast<int>(status);
    }
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return response;
}

} // namespace talebook
