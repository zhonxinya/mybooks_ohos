#include "reading_history.h"

namespace talebook {

ReadingHistoryStore::ReadingHistoryStore(JsonStore &store) : store_(store) {}

std::string ReadingHistoryStore::getAllJson() const
{
    return store_.read("reading_history", "[]");
}

bool ReadingHistoryStore::saveAllJson(const std::string &json) const
{
    return store_.write("reading_history", json);
}

bool ReadingHistoryStore::upsertRecord(const std::string &recordJson) const
{
    return store_.write("reading_history_pending", recordJson);
}

bool ReadingHistoryStore::removeRecord(const std::string &bookId) const
{
    std::string all = getAllJson();
    const std::string marker = "\"bookId\":\"" + bookId + "\"";
    auto pos = all.find(marker);
    if (pos == std::string::npos) {
        return true;
    }
    auto objStart = all.rfind('{', pos);
    auto objEnd = all.find('}', pos);
    if (objStart == std::string::npos || objEnd == std::string::npos) {
        return false;
    }
    std::string next = all.substr(0, objStart);
    if (!next.empty() && next.back() == ',') {
        next.pop_back();
    }
    next += all.substr(objEnd + 1);
    return saveAllJson(next);
}

bool ReadingHistoryStore::clearAll() const
{
    return saveAllJson("[]");
}

} // namespace talebook
