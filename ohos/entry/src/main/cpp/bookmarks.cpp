#include "bookmarks.h"

namespace talebook {

BookmarkStore::BookmarkStore(JsonStore &store) : store_(store) {}

std::string BookmarkStore::getAllJson() const
{
    return store_.read("reading_bookmarks", "[]");
}

bool BookmarkStore::saveAllJson(const std::string &json) const
{
    return store_.write("reading_bookmarks", json);
}

bool BookmarkStore::clearAll() const
{
    return saveAllJson("[]");
}

} // namespace talebook
