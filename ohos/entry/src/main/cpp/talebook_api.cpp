#include "talebook_api.h"

#include "third_party/cjson/cJSON.h"

#include <cctype>
#include <iomanip>
#include <sstream>
#include <sys/stat.h>

namespace talebook {
namespace {

std::string escapeJsonString(const std::string &value)
{
    std::ostringstream ss;
    for (const char ch : value) {
        switch (ch) {
            case '\\':
                ss << "\\\\";
                break;
            case '"':
                ss << "\\\"";
                break;
            case '\n':
                ss << "\\n";
                break;
            case '\r':
                ss << "\\r";
                break;
            case '\t':
                ss << "\\t";
                break;
            default:
                ss << ch;
                break;
        }
    }
    return ss.str();
}

std::string urlEncodeFormValue(const std::string &value)
{
    std::ostringstream ss;
    for (const unsigned char ch : value) {
        if (std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
            ss << static_cast<char>(ch);
        } else if (ch == ' ') {
            ss << '+';
        } else {
            ss << '%' << std::uppercase << std::hex << std::setw(2) << std::setfill('0')
               << static_cast<int>(ch) << std::nouppercase << std::dec;
        }
    }
    return ss.str();
}

std::string urlEncodePathSegment(const std::string &value)
{
    std::ostringstream ss;
    for (const unsigned char ch : value) {
        if (std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
            ss << static_cast<char>(ch);
        } else {
            ss << '%' << std::uppercase << std::hex << std::setw(2) << std::setfill('0')
               << static_cast<int>(ch) << std::nouppercase << std::dec;
        }
    }
    return ss.str();
}

void applyApiBusinessError(HttpResponse &resp)
{
    if (!resp.error.empty() || resp.body.empty() || resp.body.front() != '{') {
        return;
    }
    cJSON *json = cJSON_Parse(resp.body.c_str());
    if (json == nullptr) {
        return;
    }
    const cJSON *errItem = cJSON_GetObjectItemCaseSensitive(json, "err");
    if (cJSON_IsString(errItem) && errItem->valuestring != nullptr) {
        const std::string err = errItem->valuestring;
        if (err != "ok") {
            resp.error = err;
        }
    }
    if (resp.error.empty()) {
        const cJSON *msgItem = cJSON_GetObjectItemCaseSensitive(json, "msg");
        if (cJSON_IsString(msgItem) && msgItem->valuestring != nullptr) {
            const std::string msg = msgItem->valuestring;
            if (msg != "ok") {
                resp.error = msg;
            }
        }
    }
    cJSON_Delete(json);
}

} // namespace

TalebookApi::TalebookApi(HttpClient &http, JsonStore &store) : http_(http), store_(store) {}

void TalebookApi::ensureBaseUrl() const
{
    const std::string url = store_.readSecure("talebook_url", "");
    if (!url.empty()) {
        const_cast<HttpClient &>(http_).setBaseUrl("talebook", url);
    }
}

std::string TalebookApi::buildPageQuery(int page, int limit) const
{
    std::ostringstream query;
    if (page >= 0) {
        query << "page=" << page;
    }
    if (limit >= 0) {
        if (!query.str().empty()) {
            query << "&";
        }
        query << "num=" << limit;
    }
    return query.str();
}

std::string TalebookApi::wrapResponse(const HttpResponse &resp) const
{
    std::ostringstream ss;
    ss << "{\"status\":" << resp.statusCode << ",\"body\":";
    if (resp.body.empty()) {
        ss << "null";
    } else if (resp.body.front() == '{' || resp.body.front() == '[') {
        ss << resp.body;
    } else {
        ss << "{\"filePath\":\"" << escapeJsonString(resp.body) << "\"}";
    }
    ss << ",\"error\":\"" << escapeJsonString(resp.error) << "\"}";
    return ss.str();
}

std::string TalebookApi::signIn(const std::string &username, const std::string &password) const
{
    ensureBaseUrl();
    const std::string form = "username=" + urlEncodeFormValue(username) +
                             "&password=" + urlEncodeFormValue(password);
    HttpResponse resp = http_.postForm("talebook", "/api/user/sign_in", form);
    if (!resp.ok()) {
        resp = http_.post("talebook", "/api/user/signin",
                          "{\"username\":\"" + escapeJsonString(username) + "\",\"password\":\"" +
                              escapeJsonString(password) + "\"}");
    }
    applyApiBusinessError(resp);
    if (resp.error.empty() && resp.statusCode >= 200 && resp.statusCode < 300) {
        store_.writeSecure("talebook_username", username);
        store_.writeSecure("talebook_password", password);
    }
    return wrapResponse(resp);
}

std::string TalebookApi::signOut() const
{
    ensureBaseUrl();
    HttpResponse resp = http_.post("talebook", "/api/user/sign_out", "");
    if (!resp.ok()) {
        resp = http_.post("talebook", "/api/user/signout", "");
    }
    const_cast<HttpClient &>(http_).clearCookies();
    store_.writeSecure("talebook_user_profile", "");
    return wrapResponse(resp);
}

std::string TalebookApi::getUserInfo() const
{
    ensureBaseUrl();
    auto resp = http_.get("talebook", "/api/user/info", "");
    if (!resp.ok()) {
        resp = http_.get("talebook", "/api/user", "");
    }
    return wrapResponse(resp);
}

std::string TalebookApi::getIndex(int random, int recent) const
{
    ensureBaseUrl();
    std::ostringstream query;
    if (random >= 0) {
        query << "random=" << random;
    }
    if (recent >= 0) {
        if (!query.str().empty()) {
            query << "&";
        }
        query << "recent=" << recent;
    }
    return wrapResponse(http_.get("talebook", "/api/index", query.str()));
}

std::string TalebookApi::search(const std::string &name, int page, int limit) const
{
    ensureBaseUrl();
    std::ostringstream query;
    query << "name=" << urlEncodeFormValue(name);
    if (page >= 0) {
        query << "&page=" << page;
    }
    if (limit >= 0) {
        query << "&num=" << limit;
    }
    return wrapResponse(http_.get("talebook", "/api/search", query.str()));
}

std::string TalebookApi::getRecent(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/recent", buildPageQuery(page, limit)));
}

std::string TalebookApi::getHot(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/hot", buildPageQuery(page, limit)));
}

std::string TalebookApi::getAllBooks(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/all", buildPageQuery(page, limit)));
}

std::string TalebookApi::getBookDetail(int bookId) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/book/" + std::to_string(bookId), ""));
}

std::string TalebookApi::deleteBook(int bookId) const
{
    ensureBaseUrl();
    return wrapResponse(http_.post("talebook", "/api/book/" + std::to_string(bookId) + "/delete", ""));
}

std::string TalebookApi::setFavorite(int bookId, bool favorite) const
{
    ensureBaseUrl();
    const std::string body = favorite ? "{\"favorite\":true}" : "{\"favorite\":false}";
    auto resp = http_.post("talebook", "/api/book/" + std::to_string(bookId) + "/favorite", body);
    if (!resp.ok()) {
        const std::string path = favorite ? "/api/favorites/add" : "/api/favorites/remove";
        resp = http_.post("talebook", path, "{\"book_id\":" + std::to_string(bookId) + "}");
    }
    return wrapResponse(resp);
}

std::string TalebookApi::getBookNav() const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/book/nav", ""));
}

std::string TalebookApi::getReadingList(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/reading", buildPageQuery(page, limit)));
}

std::string TalebookApi::getFavorites(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/favorites", buildPageQuery(page, limit)));
}

std::string TalebookApi::getMessages(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/user/messages", buildPageQuery(page, limit)));
}

std::string TalebookApi::getMetaList(const std::string &type, int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/" + type, buildPageQuery(page, limit)));
}

std::string TalebookApi::getMetaBooks(const std::string &type, const std::string &name, int page,
                                      int limit) const
{
    ensureBaseUrl();
    const std::string path = "/api/" + type + "/" + urlEncodePathSegment(name);
    return wrapResponse(http_.get("talebook", path, buildPageQuery(page, limit)));
}

std::string TalebookApi::getAdminBooks(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/admin/books", buildPageQuery(page, limit)));
}

std::string TalebookApi::getAdminUsers(int page, int limit) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/admin/users", buildPageQuery(page, limit)));
}

std::string TalebookApi::downloadBook(int bookId, const std::string &format,
                                      const std::string &destPath) const
{
    ensureBaseUrl();
    const std::string path = "/api/book/" + std::to_string(bookId) + "." + format;
    return wrapResponse(http_.downloadToFile("talebook", path, destPath));
}

std::string TalebookApi::downloadAudioFile(int bookId, const std::string &filename,
                                           const std::string &destPath) const
{
    ensureBaseUrl();
    const std::string path = "/api/audio/" + std::to_string(bookId) + "/" +
                             urlEncodePathSegment(filename);
    return wrapResponse(http_.downloadToFile("talebook", path, destPath));
}

std::string TalebookApi::editBook(int bookId, const std::string &jsonBody) const
{
    ensureBaseUrl();
    return wrapResponse(http_.post("talebook", "/api/book/" + std::to_string(bookId) + "/edit", jsonBody));
}

std::string TalebookApi::getBookRefer(int bookId) const
{
    ensureBaseUrl();
    return wrapResponse(http_.get("talebook", "/api/book/" + std::to_string(bookId) + "/refer", ""));
}

std::string TalebookApi::getAudioFiles(int bookId) const
{
    ensureBaseUrl();
    auto resp = http_.get("talebook", "/api/audios/" + std::to_string(bookId) + "/collection", "");
    if (!resp.ok()) {
        resp = http_.get("talebook", "/api/audio/" + std::to_string(bookId), "");
    }
    return wrapResponse(resp);
}

std::string TalebookApi::markMessageRead(int messageId) const
{
    ensureBaseUrl();
    return wrapResponse(http_.post("talebook", "/api/user/messages",
                                    "{\"id\":" + std::to_string(messageId) + "}"));
}

std::string TalebookApi::fetchImageCache(const std::string &url, const std::string &destPath) const
{
    struct stat fileStat {};
    if (!destPath.empty() && stat(destPath.c_str(), &fileStat) == 0 && fileStat.st_size > 0) {
        HttpResponse cached;
        cached.statusCode = 200;
        cached.body = destPath;
        return wrapResponse(cached);
    }
    ensureBaseUrl();
    std::string fullUrl = url;
    if (!url.empty() && url[0] == '/') {
        fullUrl = http_.getBaseUrl("talebook") + url;
    }
    return wrapResponse(http_.downloadUrlToFile(fullUrl, destPath));
}

std::string TalebookApi::warmConnection() const
{
    ensureBaseUrl();
    return wrapResponse(http_.warmConnection("talebook"));
}

} // namespace talebook
