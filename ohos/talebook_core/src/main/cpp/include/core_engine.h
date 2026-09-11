#pragma once

#include <string>
#include <map>
#include <functional>
#include <vector>

namespace talebook {

class ApiService {
public:
    static ApiService &instance();

    void ensureTalebookBaseUrl();
    void ensureSonovelBaseUrl();
    void setBaseUrl(const std::string &name, const std::string &url);

    std::string talebookGet(const std::string &path,
                            const std::map<std::string, std::string> &query = {});
    std::string talebookPost(const std::string &path, const std::string &bodyJson,
                             const std::string &contentType = "application/json");
    std::string talebookPostForm(const std::string &path, const std::string &formBody);
    std::string talebookDelete(const std::string &path);
    std::string talebookDeleteWithBody(const std::string &path, const std::string &bodyJson);
    std::string talebookUploadBook(const std::string &filePath, const std::string &fileName,
                                   const std::string &bookId);
    std::string talebookUploadFile(const std::string &path, const std::string &filePath,
                                   const std::string &fieldName, const std::string &fileName,
                                   const std::string &fieldsJson = "");
    std::string talebookUploadBookBatch(const std::string &filesJson);
    std::string talebookUploadFiles(const std::string &path,
                                   const std::string &filesJson,
                                   const std::string &fieldsJson = "");
    std::string sonovelGet(const std::string &path,
                           const std::map<std::string, std::string> &query = {});
    std::string sonovelFetchBook(const std::string &paramsJson,
                                 std::function<void(const std::string &eventJson)> onSseEvent);

    std::string adminTrashBooks();
    std::string adminTrashSize();
    std::string adminTrashRestore(const std::string &bookIdsJson);
    std::string adminTrashPurge(const std::string &bookIdsJson);
    std::string adminTrashClear();
    std::string adminBookReviews(const std::string &status, int page, int pageSize);
    std::string adminBookReviewAction(const std::string &reviewId, const std::string &action);
    std::string adminImportList(int page, int num, const std::string &filter);
    std::string adminImportRun(const std::string &filelistJson, bool force);
    std::string adminImportCancel();
    std::string adminImportDelete(const std::string &hashlistJson);
    std::string adminSyslog();
    std::string adminResources();
    std::string adminToolList();
    std::string adminToolAction(const std::string &toolId, const std::string &action);
    std::string adminMemoList(int page, int pageSize);
    std::string adminMemoAction(const std::string &memoId, const std::string &action,
                                const std::string &reply);
    std::string adminMemoDelete(const std::string &memoId);

    std::string getDownloadRecords();
    std::string addDownloadRecord(const std::string &recordJson);
    std::string updateDownloadProgress(const std::string &bookId, const std::string &progressJson);
    std::string removeDownloadRecord(const std::string &bookId);
    std::string deleteDownloadRecord(const std::string &bookId);

    std::string getReadingHistory();
    std::string recordReadingHistory(const std::string &itemJson);
    std::string removeReadingHistory(const std::string &bookId);
    std::string clearReadingHistory();

    std::string getBookmarks(const std::string &bookId);
    std::string addBookmark(const std::string &bookId, const std::string &bookmarkJson);
    std::string removeBookmark(const std::string &bookId, const std::string &bookmarkId);

    std::string getReaderConfig();
    std::string saveReaderConfig(const std::string &configJson);

    std::string downloadBookLocal(const std::string &optionsJson,
                                  std::function<void(double)> onProgress);

    std::string wrapOk(const std::string &dataJson);
    std::string wrapError(const std::string &message);

private:
    ApiService() = default;
};

class CoreEngine {
public:
    static CoreEngine &instance();
    bool init(const std::string &filesDir, const std::string &prefsDir = "");
    bool isInitialized() const { return initialized_; }
    const std::string &filesDir() const { return filesDir_; }

private:
    CoreEngine() = default;
    bool initialized_ = false;
    std::string filesDir_;
};

} // namespace talebook
