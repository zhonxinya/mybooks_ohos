#pragma once

#include <string>
#include <vector>
#include <optional>
#include <functional>

namespace mybooks {

class Database {
public:
    static Database &instance();

    bool open(const std::string &filesDir);
    void close();
    /**
     * 切换数据所在目录（关闭当前连接后重新打开），用于多账号身份数据隔离：
     * KV / 凭据 / 下载记录 / 阅读历史 / 书签 / 阅读统计 均位于该目录下的 talebook.db。
     */
    bool switchTo(const std::string &filesDir);

    // KV store
    std::optional<std::string> kvGet(const std::string &key);
    void kvSet(const std::string &key, const std::string &value);
    void kvRemove(const std::string &key);
    bool kvHas(const std::string &key);

    // Secure store (credentials)
    std::optional<std::string> secureGet(const std::string &key);
    void secureSet(const std::string &key, const std::string &value);
    void secureRemove(const std::string &key);

    // JSON blob tables
    std::string getDownloadRecordsJson();
    void saveDownloadRecordsJson(const std::string &json);
    std::string getReadingHistoryJson();
    void saveReadingHistoryJson(const std::string &json);
    std::string getBookmarksJson();
    void saveBookmarksJson(const std::string &json);
    std::string getReaderConfigJson();
    void saveReaderConfigJson(const std::string &json);
    std::string getReadingStatsJson(const std::string &bookId);
    void saveReadingStatsJson(const std::string &bookId, const std::string &json);

    bool migrateFromLegacyPreferences(const std::string &prefsDir);

private:
    Database() = default;
    void *db_ = nullptr;
    std::string filesDir_;
    bool execSql(const std::string &sql);
    void initSchema();
};

} // namespace mybooks
