#include "database.h"

#include "sqlite3.h"

#include <fstream>
#include <sstream>

namespace mybooks {

Database &Database::instance() {
    static Database db;
    return db;
}

bool Database::open(const std::string &filesDir) {
    filesDir_ = filesDir;
    if (db_) return true;
    const std::string dbPath = filesDir + "/talebook.db";
    sqlite3 *handle = nullptr;
    if (sqlite3_open(dbPath.c_str(), &handle) != SQLITE_OK) {
        return false;
    }
    db_ = handle;
    initSchema();
    return true;
}

void Database::close() {
    if (db_) {
        sqlite3_close(static_cast<sqlite3 *>(db_));
        db_ = nullptr;
    }
}

bool Database::switchTo(const std::string &filesDir) {
    if (filesDir.empty()) {
        return false;
    }
    if (db_ != nullptr && filesDir == filesDir_) {
        return true;
    }
    // open() 在 db_ 非空时会短路，因此必须先关闭再重开
    close();
    filesDir_.clear();
    return open(filesDir);
}

bool Database::execSql(const std::string &sql) {
    if (!db_) return false;
    char *err = nullptr;
    int rc = sqlite3_exec(static_cast<sqlite3 *>(db_), sql.c_str(), nullptr, nullptr, &err);
    if (err) sqlite3_free(err);
    return rc == SQLITE_OK;
}

void Database::initSchema() {
    execSql("CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT NOT NULL);");
    execSql("CREATE TABLE IF NOT EXISTS secure_store (key TEXT PRIMARY KEY, value TEXT NOT NULL);");
    execSql("CREATE TABLE IF NOT EXISTS json_blobs (key TEXT PRIMARY KEY, value TEXT NOT NULL);");
    execSql("CREATE TABLE IF NOT EXISTS reading_stats (book_id TEXT PRIMARY KEY, value TEXT NOT NULL);");
    execSql("INSERT OR IGNORE INTO kv_store(key,value) VALUES('migration_done','false');");
}

static std::optional<std::string> querySingle(sqlite3 *db, const std::string &sql,
                                              const std::string &bindKey = "") {
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        return std::nullopt;
    }
    if (!bindKey.empty()) {
        sqlite3_bind_text(stmt, 1, bindKey.c_str(), -1, SQLITE_TRANSIENT);
    }
    std::optional<std::string> result;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(stmt, 0);
        if (text) {
            result = reinterpret_cast<const char *>(text);
        }
    }
    sqlite3_finalize(stmt);
    return result;
}

std::optional<std::string> Database::kvGet(const std::string &key) {
    if (!db_) return std::nullopt;
    return querySingle(static_cast<sqlite3 *>(db_), "SELECT value FROM kv_store WHERE key=?1;", key);
}

void Database::kvSet(const std::string &key, const std::string &value) {
    if (!db_) return;
    sqlite3_stmt *stmt = nullptr;
    sqlite3_prepare_v2(static_cast<sqlite3 *>(db_),
                       "INSERT OR REPLACE INTO kv_store(key,value) VALUES(?1,?2);", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, value.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void Database::kvRemove(const std::string &key) {
    if (!db_) return;
    sqlite3_stmt *stmt = nullptr;
    sqlite3_prepare_v2(static_cast<sqlite3 *>(db_), "DELETE FROM kv_store WHERE key=?1;", -1, &stmt,
                       nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

bool Database::kvHas(const std::string &key) { return kvGet(key).has_value(); }

std::optional<std::string> Database::secureGet(const std::string &key) {
    if (!db_) return std::nullopt;
    return querySingle(static_cast<sqlite3 *>(db_), "SELECT value FROM secure_store WHERE key=?1;", key);
}

void Database::secureSet(const std::string &key, const std::string &value) {
    if (!db_) return;
    sqlite3_stmt *stmt = nullptr;
    sqlite3_prepare_v2(static_cast<sqlite3 *>(db_),
                       "INSERT OR REPLACE INTO secure_store(key,value) VALUES(?1,?2);", -1, &stmt,
                       nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, value.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void Database::secureRemove(const std::string &key) {
    if (!db_) return;
    sqlite3_stmt *stmt = nullptr;
    sqlite3_prepare_v2(static_cast<sqlite3 *>(db_), "DELETE FROM secure_store WHERE key=?1;", -1,
                       &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

static std::string blobGet(sqlite3 *db, const std::string &key, const std::string &defaultVal) {
    auto val = querySingle(db, "SELECT value FROM json_blobs WHERE key=?1;", key);
    return val.value_or(defaultVal);
}

static void blobSet(sqlite3 *db, const std::string &key, const std::string &value) {
    sqlite3_stmt *stmt = nullptr;
    sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO json_blobs(key,value) VALUES(?1,?2);", -1, &stmt,
                       nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, value.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::string Database::getDownloadRecordsJson() {
    return blobGet(static_cast<sqlite3 *>(db_), "download_records", "[]");
}
void Database::saveDownloadRecordsJson(const std::string &json) {
    blobSet(static_cast<sqlite3 *>(db_), "download_records", json);
}
std::string Database::getReadingHistoryJson() {
    return blobGet(static_cast<sqlite3 *>(db_), "reading_history", "[]");
}
void Database::saveReadingHistoryJson(const std::string &json) {
    blobSet(static_cast<sqlite3 *>(db_), "reading_history", json);
}
std::string Database::getBookmarksJson() {
    return blobGet(static_cast<sqlite3 *>(db_), "reading_bookmarks", "{}");
}
void Database::saveBookmarksJson(const std::string &json) {
    blobSet(static_cast<sqlite3 *>(db_), "reading_bookmarks", json);
}
std::string Database::getReaderConfigJson() {
    return blobGet(static_cast<sqlite3 *>(db_), "reader_config", "{}");
}
void Database::saveReaderConfigJson(const std::string &json) {
    blobSet(static_cast<sqlite3 *>(db_), "reader_config", json);
}
std::string Database::getReadingStatsJson(const std::string &bookId) {
    return querySingle(static_cast<sqlite3 *>(db_),
                       "SELECT value FROM reading_stats WHERE book_id=?1;", bookId)
        .value_or("{}");
}
void Database::saveReadingStatsJson(const std::string &bookId, const std::string &json) {
    sqlite3_stmt *stmt = nullptr;
    sqlite3_prepare_v2(static_cast<sqlite3 *>(db_),
                       "INSERT OR REPLACE INTO reading_stats(book_id,value) VALUES(?1,?2);", -1,
                       &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, bookId.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, json.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

static std::string readFileIfExists(const std::string &path) {
    std::ifstream ifs(path);
    if (!ifs) return "";
    std::ostringstream oss;
    oss << ifs.rdbuf();
    return oss.str();
}

bool Database::migrateFromLegacyPreferences(const std::string &prefsDir) {
    auto done = kvGet("migration_done");
    if (done && *done == "true") return true;

    const std::string spJson = readFileIfExists(prefsDir + "/shared_preferences.xml");
    if (!spJson.empty()) {
        auto migrateKey = [&](const std::string &legacyKey, const std::string &current) {
            if (current != "[]" && current != "{}") return;
            size_t pos = spJson.find("\"" + legacyKey + "\"");
            if (pos == std::string::npos) return;
            size_t start = spJson.find('[', pos);
            if (start == std::string::npos) return;
            size_t end = spJson.find(']', start);
            if (end == std::string::npos) return;
            if (legacyKey == "download_records") {
                saveDownloadRecordsJson(spJson.substr(start, end - start + 1));
            } else if (legacyKey == "reading_history") {
                saveReadingHistoryJson(spJson.substr(start, end - start + 1));
            }
        };
        migrateKey("download_records", getDownloadRecordsJson());
        migrateKey("reading_history", getReadingHistoryJson());
    }

    kvSet("migration_done", "true");
    return true;
}

} // namespace mybooks
