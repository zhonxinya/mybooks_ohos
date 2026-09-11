#pragma once

#include "json_store.h"

#include <string>

namespace talebook {

class BookmarkStore {
public:
    explicit BookmarkStore(JsonStore &store);

    std::string getAllJson() const;
    bool saveAllJson(const std::string &json) const;
    bool clearAll() const;

private:
    JsonStore &store_;
};

} // namespace talebook
