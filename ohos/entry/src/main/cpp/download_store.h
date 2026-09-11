#pragma once

#include "json_store.h"

#include <string>

namespace talebook {

class DownloadStore {
public:
    explicit DownloadStore(JsonStore &store);

    std::string getAllJson() const;
    bool saveAllJson(const std::string &json) const;
    bool clearAll() const;

private:
    JsonStore &store_;
};

} // namespace talebook
