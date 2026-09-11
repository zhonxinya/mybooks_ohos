#pragma once

#include <string>

namespace talebook {

struct HttpResponse {
    int statusCode = 0;
    std::string body;
    std::string error;
    bool ok() const { return statusCode >= 200 && statusCode < 300 && error.empty(); }
};

class HttpClient {
public:
    static HttpClient &instance();

    void setBaseUrl(const std::string &service, const std::string &url);
    std::string getBaseUrl(const std::string &service) const;
    void setCookieDir(const std::string &dir);
    void setSslVerify(bool verify);
    bool sslVerify() const { return sslVerify_; }
    void loadCookies();
    void saveCookies();
    void clearCookies();

    HttpResponse get(const std::string &service, const std::string &path,
                     const std::string &query = "", long connectTimeoutSec = 5,
                     long timeoutSec = 30);
    HttpResponse post(const std::string &service, const std::string &path,
                      const std::string &body, const std::string &contentType = "application/json");
    HttpResponse postForm(const std::string &service, const std::string &path,
                          const std::string &formBody);
    HttpResponse downloadToFile(const std::string &service, const std::string &path,
                                const std::string &destPath, const std::string &query = "");
    HttpResponse downloadUrlToFile(const std::string &url, const std::string &destPath);
    /** 预热 DNS / TLS session（服务器禁用连接复用时仍有用） */
    HttpResponse warmConnection(const std::string &service);

private:
    HttpClient() = default;
    HttpResponse request(const std::string &method, const std::string &service,
                         const std::string &path, const std::string &body,
                         const std::string &contentType);
    std::string buildUrl(const std::string &service, const std::string &path,
                         const std::string &query) const;

    std::string talebookBase_;
    std::string sonovelBase_;
    std::string cookieDir_;
    std::string cookieData_;
    bool sslVerify_ = true;
};

} // namespace talebook
