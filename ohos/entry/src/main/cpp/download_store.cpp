#include "download_store.h"

namespace talebook {

DownloadStore::DownloadStore(JsonStore &store) : store_(store) {}

std::string DownloadStore::getAllJson() const
{
    return store_.read("download_records", "[]");
}

bool DownloadStore::saveAllJson(const std::string &json) const
{
    return store_.write("download_records", json);
}

bool DownloadStore::clearAll() const
{
    return saveAllJson("[]");
}

} // namespace talebook
