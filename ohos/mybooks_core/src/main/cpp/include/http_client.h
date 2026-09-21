#pragma once

#include <string>
#include <map>
#include <functional>
#include <optional>
#include <vector>
#include <utility>

namespace mybooks {

struct HttpResponse {
    int statusCode = 0;
    std::string body;
    std::string error;
    bool ok() const { return statusCode >= 200 && statusCode < 300 && error.empty(); }
};

struct HttpRequestOptions {
    std::string method = "GET";
    std::string url;
    std::map<std::string, std::string> headers;
    std::string body;
    std::string contentType;
    int connectTimeoutMs = 15000;
    int readTimeoutMs = 60000;
    bool followRedirects = true;
    std::function<bool(const char *data, size_t len)> streamCallback;
};

struct UploadFilePart {
    std::string filePath;
    std::string fileName;
    // empty => use uploadFiles() shared fileFieldName
    std::string fieldName;
};

class HttpClient {
public:
    static HttpClient &instance();

    void setBaseUrl(const std::string &url);
    void setBearerToken(const std::string &token);
    void setBasicAuth(const std::string &username, const std::string &password);
    void clearAuth();
    void setCookieDir(const std::string &dir);
    /** 是否校验 HTTPS 服务器证书：默认开启；仅当用户在设置中显式允许时才关闭。 */
    void setSslVerify(bool verify);
    bool sslVerify() const { return sslVerify_; }
    /** 连接层性能日志开关（默认关；pref `http_perf_log=true` 时开启）。 */
    void setMetricsEnabled(bool enabled);

    HttpResponse request(const HttpRequestOptions &options);
    HttpResponse get(const std::string &pathOrUrl,
                     const std::map<std::string, std::string> &query = {});
    HttpResponse post(const std::string &pathOrUrl, const std::string &body,
                      const std::string &contentType = "application/json");
    HttpResponse uploadFile(const std::string &pathOrUrl, const std::string &filePath,
                            const std::string &fileFieldName, const std::string &fileName,
                            const std::map<std::string, std::string> &fields = {},
                            std::function<void(double)> onProgress = nullptr);
    HttpResponse uploadFiles(const std::string &pathOrUrl,
                             const std::vector<UploadFilePart> &files,
                             const std::string &fileFieldName,
                             const std::vector<std::pair<std::string, std::string>> &fields = {},
                             std::function<void(double)> onProgress = nullptr);
    HttpResponse downloadToFile(const std::string &pathOrUrl, const std::string &savePath,
                                std::function<void(double)> onProgress = nullptr);

    std::string resolveUrl(const std::string &pathOrUrl) const;

private:
    HttpClient() = default;
    std::string baseUrl_;
    std::string bearerToken_;
    std::string basicAuthHeader_;
    std::string cookieDir_;
    bool sslVerify_ = true;
};

} // namespace mybooks
