#pragma once

#include "json_store.h"

#include <string>

namespace talebook {

class ReadingHistoryStore {
public:
    explicit ReadingHistoryStore(JsonStore &store);

    std::string getAllJson() const;
    bool saveAllJson(const std::string &json) const;
    bool upsertRecord(const std::string &recordJson) const;
    bool removeRecord(const std::string &bookId) const;
    bool clearAll() const;

private:
    JsonStore &store_;
};

} // namespace talebook
