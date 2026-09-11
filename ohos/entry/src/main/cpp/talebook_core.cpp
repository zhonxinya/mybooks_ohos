#include "talebook_core.h"

namespace talebook {

TalebookCore &TalebookCore::instance()
{
    static TalebookCore core;
    return core;
}

void TalebookCore::init(const std::string &dataDir)
{
    if (initialized_) {
        return;
    }
    store_ = std::make_unique<JsonStore>(dataDir);
    history_ = std::make_unique<ReadingHistoryStore>(*store_);
    bookmarks_ = std::make_unique<BookmarkStore>(*store_);
    downloads_ = std::make_unique<DownloadStore>(*store_);
    api_ = std::make_unique<TalebookApi>(HttpClient::instance(), *store_);
    sonovel_ = std::make_unique<SoNovelApi>(HttpClient::instance(), *store_);
    HttpClient::instance().setCookieDir(dataDir + "/.cookies");
    const std::string allowInsecure = store_->readPref("allow_insecure_ssl", "false");
    HttpClient::instance().setSslVerify(allowInsecure != "true");
    initialized_ = true;
}

HttpClient &TalebookCore::http()
{
    return HttpClient::instance();
}

JsonStore &TalebookCore::store()
{
    return *store_;
}

TalebookApi &TalebookCore::api()
{
    return *api_;
}

SoNovelApi &TalebookCore::sonovel()
{
    return *sonovel_;
}

ReadingHistoryStore &TalebookCore::history()
{
    return *history_;
}

BookmarkStore &TalebookCore::bookmarks()
{
    return *bookmarks_;
}

DownloadStore &TalebookCore::downloads()
{
    return *downloads_;
}

} // namespace talebook
