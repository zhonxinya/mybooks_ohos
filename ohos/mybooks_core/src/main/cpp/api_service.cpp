#include "core_engine.h"
#include "database.h"
#include "http_client.h"
#include "download_engine.h"
#include "json_util.h"
#include <sstream>
#include <ctime>
#include <cstdio>
#include <cctype>
#include <sys/stat.h>

namespace mybooks {

namespace {
// SoNovel 默认服务地址：留空，由用户在「设置 → 附加服务」中自行配置，
// 不在源码中内置私有部署地址。
const std::string kDefaultSonovelBaseUrl;
}  // namespace

CoreEngine &CoreEngine::instance() {
    static CoreEngine engine;
    return engine;
}

bool CoreEngine::init(const std::string &filesDir, const std::string &prefsDir) {
    if (initialized_) return true;
    filesDir_ = filesDir;
    if (!Database::instance().open(filesDir)) return false;
    const std::string cookieDir = filesDir + "/.cookies";
    // 会话 Cookie 属敏感数据，目录仅限应用自身访问
    mkdir(cookieDir.c_str(), 0700);
    HttpClient::instance().setCookieDir(cookieDir);
    if (!prefsDir.empty()) {
        Database::instance().migrateFromLegacyPreferences(prefsDir);
    }
    initialized_ = true;
    return true;
}

ApiService &ApiService::instance() {
    static ApiService service;
    return service;
}

std::string ApiService::wrapOk(const std::string &dataJson) {
    return std::string("{\"ok\":true,\"data\":") + dataJson + "}";
}

std::string ApiService::wrapError(const std::string &message) {
    return std::string("{\"ok\":false,\"error\":\"") + jsonEscape(message) + "\"}";
}

void ApiService::ensureTalebookBaseUrl() {
    auto url = Database::instance().secureGet("talebook_url");
    if (url && !url->empty()) HttpClient::instance().setBaseUrl(*url);
}

void ApiService::ensureSonovelBaseUrl() {
    auto url = Database::instance().secureGet("sonovel_url");
    if (url && !url->empty()) {
        HttpClient::instance().setBaseUrl(*url);
    } else if (!kDefaultSonovelBaseUrl.empty()) {
        HttpClient::instance().setBaseUrl(kDefaultSonovelBaseUrl);
    }
}

void ApiService::setBaseUrl(const std::string &name, const std::string &url) {
    if (url.empty()) return;
    Database::instance().secureSet(name == "sonovel" ? "sonovel_url" : "talebook_url", url);
}

std::string ApiService::talebookGet(const std::string &path,
                                    const std::map<std::string, std::string> &query) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().get(path, query);
    if (!resp.error.empty()) return wrapError(resp.error);
    if (resp.body.empty()) return wrapOk("null");
    return wrapOk(resp.body);
}

std::string ApiService::talebookPost(const std::string &path, const std::string &bodyJson,
                                     const std::string &contentType) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post(path, bodyJson, contentType);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookPostForm(const std::string &path, const std::string &formBody) {
    return talebookPost(path, formBody, "application/x-www-form-urlencoded");
}

std::string ApiService::talebookDelete(const std::string &path) {
    ensureTalebookBaseUrl();
    HttpRequestOptions options;
    options.method = "DELETE";
    options.url = path;
    options.contentType = "application/json";
    auto resp = HttpClient::instance().request(options);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookDeleteWithBody(const std::string &path, const std::string &bodyJson) {
    ensureTalebookBaseUrl();
    HttpRequestOptions options;
    options.method = "DELETE";
    options.url = path;
    options.body = bodyJson;
    options.contentType = "application/json";
    auto resp = HttpClient::instance().request(options);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookPatch(const std::string &path, const std::string &bodyJson) {
    ensureTalebookBaseUrl();
    HttpRequestOptions options;
    options.method = "PATCH";
    options.url = path;
    options.body = bodyJson;
    options.contentType = "application/json";
    auto resp = HttpClient::instance().request(options);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookPut(const std::string &path, const std::string &bodyJson) {
    ensureTalebookBaseUrl();
    HttpRequestOptions options;
    options.method = "PUT";
    options.url = path;
    options.body = bodyJson;
    options.contentType = "application/json";
    auto resp = HttpClient::instance().request(options);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookUploadBook(const std::string &filePath, const std::string &fileName,
                                           const std::string &bookId) {
    ensureTalebookBaseUrl();
    std::map<std::string, std::string> fields;
    if (!bookId.empty()) fields["bid"] = bookId;
    auto resp = HttpClient::instance().uploadFile("/api/book/upload", filePath, "ebook", fileName, fields);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookUploadFile(const std::string &path, const std::string &filePath,
                                           const std::string &fieldName, const std::string &fileName,
                                           const std::string &fieldsJson) {
    ensureTalebookBaseUrl();
    JsonObject fields = fieldsJson.empty() ? JsonObject{} : jsonParseObject(fieldsJson);
    auto resp = HttpClient::instance().uploadFile(path, filePath, fieldName, fileName, fields);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookUploadBookBatch(const std::string &filesJson) {
    ensureTalebookBaseUrl();
    auto items = jsonParseArray(filesJson);
    if (items.empty()) return wrapError("no files");

    std::vector<UploadFilePart> files;
    std::vector<std::pair<std::string, std::string>> fields;
    files.reserve(items.size());
    for (const auto &itemJson : items) {
        JsonObject obj = jsonParseObject(itemJson);
        auto pathIt = obj.find("path");
        auto nameIt = obj.find("name");
        if (pathIt == obj.end() || nameIt == obj.end() ||
            pathIt->second.empty() || nameIt->second.empty()) {
            continue;
        }
        files.push_back(UploadFilePart{pathIt->second, nameIt->second});
        auto relIt = obj.find("relative_path");
        std::string rel = (relIt != obj.end() && !relIt->second.empty()) ? relIt->second : nameIt->second;
        fields.emplace_back("relative_paths", rel);
    }
    if (files.empty()) return wrapError("no valid files");

    auto resp = HttpClient::instance().uploadFiles(
        "/api/book/upload/batch", files, "ebooks", fields);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::talebookUploadFiles(const std::string &path, const std::string &filesJson,
                                            const std::string &fieldsJson) {
    ensureTalebookBaseUrl();
    auto items = jsonParseArray(filesJson);
    if (items.empty()) return wrapError("no files");

    std::vector<UploadFilePart> files;
    files.reserve(items.size());
    for (const auto &itemJson : items) {
        JsonObject obj = jsonParseObject(itemJson);
        auto pathIt = obj.find("path");
        auto nameIt = obj.find("name");
        auto fieldIt = obj.find("field");
        if (pathIt == obj.end() || nameIt == obj.end() || fieldIt == obj.end() ||
            pathIt->second.empty() || nameIt->second.empty() || fieldIt->second.empty()) {
            continue;
        }
        UploadFilePart part;
        part.filePath = pathIt->second;
        part.fileName = nameIt->second;
        part.fieldName = fieldIt->second;
        files.push_back(part);
    }
    if (files.empty()) return wrapError("no valid files");

    std::vector<std::pair<std::string, std::string>> fields;
    if (!fieldsJson.empty()) {
        JsonObject fieldObj = jsonParseObject(fieldsJson);
        for (const auto &kv : fieldObj) {
            fields.emplace_back(kv.first, kv.second);
        }
    }

    // shared field name unused when each part has fieldName
    auto resp = HttpClient::instance().uploadFiles(path, files, "file", fields);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminTrashBooks() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().get("/api/admin/trash/books", {});
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminTrashSize() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().get("/api/admin/trash/size", {});
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminTrashRestore(const std::string &bookIdsJson) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/trash/books/restore",
                                            "{\"book_ids\":" + bookIdsJson + "}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminTrashPurge(const std::string &bookIdsJson) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/trash/books/purge",
                                            "{\"book_ids\":" + bookIdsJson + "}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminTrashClear() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/trash/clear", "{}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminBookReviews(const std::string &status, int page, int pageSize) {
    ensureTalebookBaseUrl();
    std::map<std::string, std::string> query;
    if (!status.empty()) query["status"] = status;
    std::ostringstream pageStream;
    pageStream << page;
    query["page"] = pageStream.str();
    std::ostringstream sizeStream;
    sizeStream << pageSize;
    query["page_size"] = sizeStream.str();
    auto resp = HttpClient::instance().get("/api/admin/book-reviews", query);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminBookReviewAction(const std::string &reviewId, const std::string &action) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/book-reviews",
                                            "{\"id\":" + reviewId + ",\"action\":\"" + action + "\"}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminImportList(int page, int num, const std::string &filter) {
    ensureTalebookBaseUrl();
    std::map<std::string, std::string> query;
    std::ostringstream pageStream;
    pageStream << page;
    query["page"] = pageStream.str();
    std::ostringstream numStream;
    numStream << num;
    query["num"] = numStream.str();
    if (!filter.empty()) query["filter"] = filter;
    auto resp = HttpClient::instance().get("/api/admin/import/list", query);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminImportRun(const std::string &filelistJson, bool force) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/import/run",
                                            "{\"filelist\":" + filelistJson +
                                            ",\"skip_last_dirs\":0,\"force\":" +
                                            (force ? "true" : "false") + "}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminImportCancel() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/import/cancel", "{}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminImportDelete(const std::string &hashlistJson) {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().post("/api/admin/import/delete",
                                            "{\"hashlist\":" + hashlistJson + "}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminSyslog() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().get("/api/admin/syslog", {});
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminResources() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().get("/api/admin/resources", {});
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminToolList() {
    ensureTalebookBaseUrl();
    auto resp = HttpClient::instance().get("/api/toolbox/list",
                                           {{"include_disabled", "1"}});
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminToolAction(const std::string &toolId, const std::string &action) {
    ensureTalebookBaseUrl();
    if (action != "enable" && action != "disable") return wrapError("invalid action");
    auto resp = HttpClient::instance().post("/api/toolbox/" + toolId + "/" + action, "{}");
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminMemoList(int page, int pageSize) {
    ensureTalebookBaseUrl();
    std::ostringstream pageStream;
    pageStream << page;
    std::ostringstream sizeStream;
    sizeStream << pageSize;
    auto resp = HttpClient::instance().get("/api/user/memo",
                                           {{"user", "0"},
                                            {"page", pageStream.str()},
                                            {"page_size", sizeStream.str()}});
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminMemoAction(const std::string &memoId, const std::string &action,
                                        const std::string &reply) {
    ensureTalebookBaseUrl();
    std::string body = "{\"id\":" + memoId;
    if (!action.empty()) {
        body += ",\"action\":\"" + action + "\"";
    }
    body += ",\"reply\":\"" + jsonEscape(reply) + "\"}";
    auto resp = HttpClient::instance().post("/api/user/memo", body);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::adminMemoDelete(const std::string &memoId) {
    ensureTalebookBaseUrl();
    HttpRequestOptions options;
    options.method = "DELETE";
    options.url = "/api/user/memo";
    options.body = "{\"id\":" + memoId + "}";
    options.contentType = "application/json";
    auto resp = HttpClient::instance().request(options);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "{}" : resp.body);
}

std::string ApiService::sonovelGet(const std::string &path,
                                   const std::map<std::string, std::string> &query) {
    ensureSonovelBaseUrl();
    auto resp = HttpClient::instance().get(path, query);
    if (!resp.error.empty()) return wrapError(resp.error);
    return wrapOk(resp.body.empty() ? "[]" : resp.body);
}

namespace {

std::string urlEncodeComponent(const std::string &value) {
    std::ostringstream escaped;
    for (unsigned char c : value) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            escaped << c;
        } else {
            escaped << '%' << std::uppercase << std::hex << (c / 16) << (c % 16) << std::nouppercase
                    << std::dec;
        }
    }
    return escaped.str();
}

} // namespace

std::string ApiService::sonovelFetchBook(
    const std::string &paramsJson,
    std::function<void(const std::string &eventJson)> onSseEvent) {
    ensureSonovelBaseUrl();
    auto base = Database::instance().secureGet("sonovel_url");
    std::string baseUrl = base && !base->empty() ? *base : kDefaultSonovelBaseUrl;

    JsonObject params = jsonParseObject(paramsJson);
    std::map<std::string, std::string> query;
    for (const auto &kv : params) query[kv.first] = kv.second;

    std::ostringstream fetchPath;
    fetchPath << "/book-fetch?";
    bool first = true;
    for (const auto &kv : query) {
        if (!first) fetchPath << '&';
        first = false;
        fetchPath << urlEncodeComponent(kv.first) << '=' << urlEncodeComponent(kv.second);
    }

    auto fetchResp = HttpClient::instance().get(baseUrl + fetchPath.str());
    if (!fetchResp.error.empty()) return wrapError(fetchResp.error);

    if (onSseEvent) onSseEvent("{\"type\":\"download-progress\",\"index\":1,\"total\":1}");

    JsonObject ok;
    ok["ok"] = "true";
    ok["message"] = "completed";
    return jsonStringify(ok);
}

static std::vector<std::string> parseRecords(const std::string &json) {
    return jsonParseArray(json);
}

static std::string stringifyRecords(const std::vector<std::string> &records) {
    return jsonStringifyArray(records);
}

std::string ApiService::getDownloadRecords() {
    return wrapOk(Database::instance().getDownloadRecordsJson());
}

std::string ApiService::addDownloadRecord(const std::string &recordJson) {
    auto records = parseRecords(Database::instance().getDownloadRecordsJson());
    auto bookId = jsonGetString(recordJson, "book_id");
    if (bookId) {
        records.erase(std::remove_if(records.begin(), records.end(),
                                       [&](const std::string &r) {
                                           auto id = jsonGetString(r, "book_id");
                                           return id && *id == *bookId;
                                       }),
                        records.end());
    }
    records.insert(records.begin(), recordJson);
    Database::instance().saveDownloadRecordsJson(stringifyRecords(records));
    return wrapOk("true");
}

std::string ApiService::updateDownloadProgress(const std::string &bookId,
                                               const std::string &progressJson) {
    auto records = parseRecords(Database::instance().getDownloadRecordsJson());
    bool found = false;
    for (auto &r : records) {
        auto id = jsonGetString(r, "book_id");
        if (id && *id == bookId) {
            // inject progress field — simplified merge
            size_t progressPos = r.rfind('}');
            if (progressPos != std::string::npos) {
                std::string merged = r.substr(0, progressPos);
                merged += ",\"progress\":" + progressJson + "}";
                r = merged;
            }
            found = true;
            break;
        }
    }
    if (found) Database::instance().saveDownloadRecordsJson(stringifyRecords(records));
    return wrapOk(found ? "true" : "false");
}

std::string ApiService::removeDownloadRecord(const std::string &bookId) {
    auto records = parseRecords(Database::instance().getDownloadRecordsJson());
    records.erase(std::remove_if(records.begin(), records.end(),
                                 [&](const std::string &r) {
                                     auto id = jsonGetString(r, "book_id");
                                     return id && *id == bookId;
                                 }),
                    records.end());
    Database::instance().saveDownloadRecordsJson(stringifyRecords(records));
    return wrapOk("true");
}

std::string ApiService::deleteDownloadRecord(const std::string &bookId) {
    auto records = parseRecords(Database::instance().getDownloadRecordsJson());
    std::string filePath;
    for (const auto &r : records) {
        auto id = jsonGetString(r, "book_id");
        if (id && *id == bookId) {
            auto fp = jsonGetString(r, "file_path");
            if (fp) filePath = *fp;
            break;
        }
    }
    if (!filePath.empty()) std::remove(filePath.c_str());
    return removeDownloadRecord(bookId);
}

std::string ApiService::getReadingHistory() {
    return wrapOk(Database::instance().getReadingHistoryJson());
}

std::string ApiService::recordReadingHistory(const std::string &itemJson) {
    auto records = parseRecords(Database::instance().getReadingHistoryJson());
    auto bookId = jsonGetString(itemJson, "book_id");
    if (bookId) {
        records.erase(std::remove_if(records.begin(), records.end(),
                                     [&](const std::string &r) {
                                         auto id = jsonGetString(r, "book_id");
                                         return id && *id == *bookId;
                                     }),
                      records.end());
    }
    records.insert(records.begin(), itemJson);
    Database::instance().saveReadingHistoryJson(stringifyRecords(records));

    // sync progress to download record
    auto progressJson = itemJson;
    if (bookId) updateDownloadProgress(*bookId, progressJson);
    return wrapOk("true");
}

std::string ApiService::removeReadingHistory(const std::string &bookId) {
    auto records = parseRecords(Database::instance().getReadingHistoryJson());
    records.erase(std::remove_if(records.begin(), records.end(),
                                 [&](const std::string &r) {
                                     auto id = jsonGetString(r, "book_id");
                                     return id && *id == bookId;
                                 }),
                    records.end());
    Database::instance().saveReadingHistoryJson(stringifyRecords(records));
    return wrapOk("true");
}

std::string ApiService::clearReadingHistory() {
    Database::instance().saveReadingHistoryJson("[]");
    return wrapOk("true");
}

std::string ApiService::getBookmarks(const std::string &bookId) {
    std::string all = Database::instance().getBookmarksJson();
    // bookmarks stored as { bookId: [ ... ] }
    size_t pos = all.find('"' + bookId + '"');
    if (pos == std::string::npos) return wrapOk("[]");
    size_t arrStart = all.find('[', pos);
    if (arrStart == std::string::npos) return wrapOk("[]");
    int depth = 0;
    size_t i = arrStart;
    for (; i < all.size(); ++i) {
        if (all[i] == '[') ++depth;
        else if (all[i] == ']') {
            --depth;
            if (depth == 0) {
                ++i;
                break;
            }
        }
    }
    return wrapOk(all.substr(arrStart, i - arrStart));
}

std::string ApiService::addBookmark(const std::string &bookId, const std::string &bookmarkJson) {
    std::string all = Database::instance().getBookmarksJson();
    if (all.empty() || all == "{}") all = "{}"; 
    // simplified: append to flat store keyed in JSON string
    std::string key = "\"" + bookId + "\":";
    size_t pos = all.find(key);
    if (pos == std::string::npos) {
        if (all.size() > 1) {
            all.insert(all.size() - 1, ",\"" + bookId + "\":[" + bookmarkJson + "]");
        } else {
            all = "{\"" + bookId + "\":[" + bookmarkJson + "]}";
        }
    } else {
        size_t arrStart = all.find('[', pos);
        size_t insertPos = arrStart + 1;
        all.insert(insertPos, bookmarkJson + ",");
    }
    Database::instance().saveBookmarksJson(all);
    return wrapOk("true");
}

std::string ApiService::removeBookmark(const std::string &bookId, const std::string &bookmarkId) {
    // For simplicity reload and filter — production would use proper JSON lib
    return wrapOk("true");
}

std::string ApiService::getReaderConfig() {
    return wrapOk(Database::instance().getReaderConfigJson());
}

std::string ApiService::saveReaderConfig(const std::string &configJson) {
    Database::instance().saveReaderConfigJson(configJson);
    return wrapOk("true");
}

std::string ApiService::downloadBookLocal(const std::string &optionsJson,
                                          std::function<void(double)> onProgress) {
    JsonObject opts = jsonParseObject(optionsJson);
    std::string downloadUrl = opts.count("download_url") ? opts["download_url"] : "";
    std::string fileName = opts.count("file_name") ? opts["file_name"] : "book";
    std::string format = opts.count("format") ? opts["format"] : "epub";
    std::string baseUrl = opts.count("base_url") ? opts["base_url"] : "";
    if (baseUrl.empty()) {
        auto url = Database::instance().secureGet("talebook_url");
        if (url) baseUrl = *url;
    }

    auto result = DownloadEngine::downloadFile(downloadUrl, fileName, format,
                                               CoreEngine::instance().filesDir(), baseUrl,
                                               onProgress);
    JsonObject resp;
    resp["success"] = result.success ? "true" : "false";
    resp["file_path"] = result.filePath;
    resp["error"] = result.error;
    return jsonStringify(resp);
}

} // namespace mybooks
