#pragma once

#include "http_client.h"
#include "json_store.h"

#include <string>

namespace talebook {

class TalebookApi {
public:
    TalebookApi(HttpClient &http, JsonStore &store);

    std::string wrapResponse(const HttpResponse &resp) const;
    std::string signIn(const std::string &username, const std::string &password) const;
    std::string signOut() const;
    std::string getUserInfo() const;
    std::string getIndex(int random, int recent) const;
    std::string search(const std::string &name, int page, int limit) const;
    std::string getRecent(int page, int limit) const;
    std::string getHot(int page, int limit) const;
    std::string getAllBooks(int page, int limit) const;
    std::string getBookDetail(int bookId) const;
    std::string deleteBook(int bookId) const;
    std::string setFavorite(int bookId, bool favorite) const;
    std::string getBookNav() const;
    std::string getReadingList(int page, int limit) const;
    std::string getFavorites(int page, int limit) const;
    std::string getMessages(int page, int limit) const;
    std::string getMetaList(const std::string &type, int page, int limit) const;
    std::string getMetaBooks(const std::string &type, const std::string &name, int page,
                             int limit) const;
    std::string getAdminBooks(int page, int limit) const;
    std::string getAdminUsers(int page, int limit) const;
    std::string downloadBook(int bookId, const std::string &format, const std::string &destPath) const;
    std::string downloadAudioFile(int bookId, const std::string &filename,
                                  const std::string &destPath) const;
    std::string editBook(int bookId, const std::string &jsonBody) const;
    std::string getBookRefer(int bookId) const;
    std::string getAudioFiles(int bookId) const;
    std::string markMessageRead(int messageId) const;
    std::string fetchImageCache(const std::string &url, const std::string &destPath) const;
    std::string warmConnection() const;

private:
    HttpClient &http_;
    JsonStore &store_;
    void ensureBaseUrl() const;
    std::string buildPageQuery(int page, int limit) const;
};

} // namespace talebook
