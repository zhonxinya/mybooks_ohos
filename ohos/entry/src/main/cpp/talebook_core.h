#pragma once

#include "bookmarks.h"
#include "download_store.h"
#include "http_client.h"
#include "json_store.h"
#include "reading_history.h"
#include "sonovel_api.h"
#include "talebook_api.h"

#include <memory>
#include <mutex>
#include <string>

namespace talebook {

class TalebookCore {
public:
    static TalebookCore &instance();

    void init(const std::string &dataDir);
    /**
     * 切换账号身份根目录：secure 凭据、下载记录、阅读历史、书签与会话 Cookie 一并切换。
     * 全局偏好（preferences.json）仍留在 dataDir，不随账号变。
     */
    void setIdentityDir(const std::string &dir);
    bool isInitialized() const { return initialized_; }

    HttpClient &http();
    JsonStore &store();
    TalebookApi &api();
    SoNovelApi &sonovel();
    ReadingHistoryStore &history();
    BookmarkStore &bookmarks();
    DownloadStore &downloads();

private:
    TalebookCore() = default;

    bool initialized_ = false;
    std::unique_ptr<JsonStore> store_;
    std::unique_ptr<ReadingHistoryStore> history_;
    std::unique_ptr<BookmarkStore> bookmarks_;
    std::unique_ptr<DownloadStore> downloads_;
    std::unique_ptr<TalebookApi> api_;
    std::unique_ptr<SoNovelApi> sonovel_;
};

} // namespace talebook
