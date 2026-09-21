#include "talebook_core.h"

#include "path_util.h"

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
    // 连接层性能日志默认关闭，排查网络问题时置 pref http_perf_log=true 打开
    HttpClient::instance().setMetricsEnabled(store_->readPref("http_perf_log", "false") == "true");
    initialized_ = true;
}

void TalebookCore::setIdentityDir(const std::string &dir)
{
    if (store_ == nullptr || dir.empty()) {
        return;
    }
    store_->setIdentityDir(dir);
    const std::string cookieDir = dir + "/.cookies";
    // 会话 Cookie 属敏感数据，目录仅限应用自身访问
    // 账号目录是多层路径，必须递归创建，否则 Cookie 无法落盘（重启后又要手动登录）
    makeDirs(cookieDir, 0700);
    HttpClient::instance().setCookieDir(cookieDir);
    // 切换身份根后立刻用新目录里的地址刷新 HttpClient，避免仍指向上一个账号
    const std::string talebookUrl = store_->readSecure("talebook_url");
    if (!talebookUrl.empty()) {
        HttpClient::instance().setBaseUrl("talebook", talebookUrl);
    }
    // SoNovel 为全局服务，固定在全局根
    const std::string sonovelUrl = store_->readSecureGlobal("sonovel_url");
    if (!sonovelUrl.empty()) {
        HttpClient::instance().setBaseUrl("sonovel", sonovelUrl);
    }
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
