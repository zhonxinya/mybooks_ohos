#include "talebook_core.h"

#include "napi/native_api.h"

#include <functional>
#include <string>
#include <vector>

namespace {

struct AsyncStringContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::function<std::string()> task;
    std::string result;
};

void AsyncStringExecute(napi_env env, void *data)
{
    (void)env;
    auto *ctx = static_cast<AsyncStringContext *>(data);
    if (ctx->task) {
        ctx->result = ctx->task();
    }
}

void AsyncStringComplete(napi_env env, napi_status status, void *data)
{
    auto *ctx = static_cast<AsyncStringContext *>(data);
    if (status == napi_ok) {
        napi_value result = nullptr;
        napi_create_string_utf8(env, ctx->result.c_str(), ctx->result.size(), &result);
        napi_resolve_deferred(env, ctx->deferred, result);
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, "async api failed", NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, ctx->deferred, message);
    }
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

napi_value RunAsyncStringTask(napi_env env, std::function<std::string()> task)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);

    auto *ctx = new AsyncStringContext();
    ctx->deferred = deferred;
    ctx->task = std::move(task);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "TalebookAsyncApi", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, AsyncStringExecute, AsyncStringComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

std::string GetStringArg(napi_env env, napi_value value)
{
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::vector<char> buffer(len + 1);
    napi_get_value_string_utf8(env, value, buffer.data(), len + 1, &len);
    return std::string(buffer.data(), len);
}

int32_t GetIntArg(napi_env env, napi_value value, int32_t defaultValue)
{
    int32_t result = defaultValue;
    napi_get_value_int32(env, value, &result);
    return result;
}

bool GetBoolArg(napi_env env, napi_value value, bool defaultValue)
{
    bool result = defaultValue;
    napi_get_value_bool(env, value, &result);
    return result;
}

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value Init(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "dataDir required");
        return nullptr;
    }
    talebook::TalebookCore::instance().init(GetStringArg(env, args[0]));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value SetBaseUrl(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto &core = talebook::TalebookCore::instance();
    core.http().setBaseUrl(GetStringArg(env, args[0]), GetStringArg(env, args[1]));
    core.store().writeSecure(GetStringArg(env, args[0]) + "_url", GetStringArg(env, args[1]));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value SetIdentityDir(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "identityDir required");
        return nullptr;
    }
    talebook::TalebookCore::instance().setIdentityDir(GetStringArg(env, args[0]));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value SecureGet(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().store().readSecure(GetStringArg(env, args[0]), ""));
}

/** 全局凭据读取（不随账号身份根变化），用于 SoNovel 等全局服务配置。 */
napi_value SecureGetGlobal(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().store().readSecureGlobal(GetStringArg(env, args[0]), ""));
}

/** 全局凭据写入（不随账号身份根变化）。 */
napi_value SecureSetGlobal(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    talebook::TalebookCore::instance().store().writeSecureGlobal(GetStringArg(env, args[0]),
                                                                 GetStringArg(env, args[1]));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value SecureSet(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    talebook::TalebookCore::instance().store().writeSecure(GetStringArg(env, args[0]), GetStringArg(env, args[1]));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value PrefGet(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().store().readPref(GetStringArg(env, args[0]), ""));
}

napi_value PrefSet(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string key = GetStringArg(env, args[0]);
    const std::string value = GetStringArg(env, args[1]);
    auto &core = talebook::TalebookCore::instance();
    core.store().writePref(key, value);
    if (key == "allow_insecure_ssl") {
        core.http().setSslVerify(value != "true");
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value PrefSetBatch(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string jsonObject = GetStringArg(env, args[0]);
    auto &core = talebook::TalebookCore::instance();
    core.store().writePrefsBatch(jsonObject);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value GetReadingHistory(napi_env env, napi_callback_info info)
{
    return MakeString(env, talebook::TalebookCore::instance().history().getAllJson());
}

napi_value SaveReadingHistory(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const bool ok = talebook::TalebookCore::instance().history().saveAllJson(GetStringArg(env, args[0]));
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value GetBookmarks(napi_env env, napi_callback_info info)
{
    return MakeString(env, talebook::TalebookCore::instance().bookmarks().getAllJson());
}

napi_value SaveBookmarks(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const bool ok = talebook::TalebookCore::instance().bookmarks().saveAllJson(GetStringArg(env, args[0]));
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value GetDownloads(napi_env env, napi_callback_info info)
{
    return MakeString(env, talebook::TalebookCore::instance().downloads().getAllJson());
}

napi_value SaveDownloads(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const bool ok = talebook::TalebookCore::instance().downloads().saveAllJson(GetStringArg(env, args[0]));
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value ApiSignIn(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().signIn(GetStringArg(env, args[0]),
                                                                              GetStringArg(env, args[1])));
}

napi_value ApiSignOut(napi_env env, napi_callback_info info)
{
    return MakeString(env, talebook::TalebookCore::instance().api().signOut());
}

napi_value ApiGetUserInfo(napi_env env, napi_callback_info info)
{
    return MakeString(env, talebook::TalebookCore::instance().api().getUserInfo());
}

napi_value ApiGetIndex(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getIndex(
        GetIntArg(env, args[0], -1), GetIntArg(env, args[1], -1)));
}

napi_value ApiSearch(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().search(
        GetStringArg(env, args[0]), GetIntArg(env, args[1], 1), GetIntArg(env, args[2], 20)));
}

napi_value ApiGetRecent(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getRecent(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetHot(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getHot(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetAllBooks(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getAllBooks(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetBookDetail(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getBookDetail(GetIntArg(env, args[0], 0)));
}

napi_value ApiDeleteBook(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().deleteBook(GetIntArg(env, args[0], 0)));
}

napi_value ApiSetFavorite(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().setFavorite(
        GetIntArg(env, args[0], 0), GetBoolArg(env, args[1], true)));
}

napi_value ApiGetBookNav(napi_env env, napi_callback_info info)
{
    return MakeString(env, talebook::TalebookCore::instance().api().getBookNav());
}

napi_value ApiGetReadingList(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getReadingList(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetFavorites(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getFavorites(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetMessages(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getMessages(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetMetaList(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getMetaList(
        GetStringArg(env, args[0]), GetIntArg(env, args[1], 1), GetIntArg(env, args[2], 20)));
}

napi_value ApiGetMetaBooks(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getMetaBooks(
        GetStringArg(env, args[0]), GetStringArg(env, args[1]),
        GetIntArg(env, args[2], 1), GetIntArg(env, args[3], 20)));
}

napi_value ApiGetAdminBooks(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getAdminBooks(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiGetAdminUsers(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getAdminUsers(
        GetIntArg(env, args[0], 1), GetIntArg(env, args[1], 20)));
}

napi_value ApiSoNovelSearch(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().sonovel().searchAggregated(GetStringArg(env, args[0])));
}

napi_value ApiSoNovelFetchBook(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().sonovel().fetchBook(
        GetStringArg(env, args[0]), GetStringArg(env, args[1])));
}

napi_value ApiDownloadBook(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().downloadBook(
        GetIntArg(env, args[0], 0), GetStringArg(env, args[1]), GetStringArg(env, args[2])));
}

napi_value ApiEditBook(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().editBook(
        GetIntArg(env, args[0], 0), GetStringArg(env, args[1])));
}

napi_value ApiGetBookRefer(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getBookRefer(GetIntArg(env, args[0], 0)));
}

napi_value ApiGetAudioFiles(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().getAudioFiles(GetIntArg(env, args[0], 0)));
}

napi_value ApiMarkMessageRead(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().markMessageRead(GetIntArg(env, args[0], 0)));
}

napi_value ApiMarkMessageReadAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t messageId = GetIntArg(env, args[0], 0);
    return RunAsyncStringTask(env, [messageId]() {
        return talebook::TalebookCore::instance().api().markMessageRead(messageId);
    });
}

napi_value FetchImageCache(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeString(env, talebook::TalebookCore::instance().api().fetchImageCache(
        GetStringArg(env, args[0]), GetStringArg(env, args[1])));
}

napi_value ApiSignInAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string username = GetStringArg(env, args[0]);
    const std::string password = GetStringArg(env, args[1]);
    return RunAsyncStringTask(env, [username, password]() {
        return talebook::TalebookCore::instance().api().signIn(username, password);
    });
}

napi_value ApiGetUserInfoAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return RunAsyncStringTask(env, []() { return talebook::TalebookCore::instance().api().getUserInfo(); });
}

napi_value ApiWarmConnectionAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return RunAsyncStringTask(env, []() { return talebook::TalebookCore::instance().api().warmConnection(); });
}

napi_value ApiGetBookNavAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return RunAsyncStringTask(env, []() { return talebook::TalebookCore::instance().api().getBookNav(); });
}

napi_value ApiGetAllBooksAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getAllBooks(page, limit);
    });
}

napi_value ApiGetMetaBooksAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string type = GetStringArg(env, args[0]);
    const std::string name = GetStringArg(env, args[1]);
    const int32_t page = GetIntArg(env, args[2], 1);
    const int32_t limit = GetIntArg(env, args[3], 20);
    return RunAsyncStringTask(env, [type, name, page, limit]() {
        return talebook::TalebookCore::instance().api().getMetaBooks(type, name, page, limit);
    });
}

napi_value ApiSearchAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string name = GetStringArg(env, args[0]);
    const int32_t page = GetIntArg(env, args[1], 1);
    const int32_t limit = GetIntArg(env, args[2], 20);
    return RunAsyncStringTask(env, [name, page, limit]() {
        return talebook::TalebookCore::instance().api().search(name, page, limit);
    });
}

napi_value ApiGetRecentAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getRecent(page, limit);
    });
}

napi_value ApiGetHotAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getHot(page, limit);
    });
}

napi_value FetchImageCacheAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string url = GetStringArg(env, args[0]);
    const std::string destPath = GetStringArg(env, args[1]);
    return RunAsyncStringTask(env, [url, destPath]() {
        return talebook::TalebookCore::instance().api().fetchImageCache(url, destPath);
    });
}

napi_value ApiGetBookDetailAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t bookId = GetIntArg(env, args[0], 0);
    return RunAsyncStringTask(env, [bookId]() {
        return talebook::TalebookCore::instance().api().getBookDetail(bookId);
    });
}

napi_value ApiDownloadBookAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t bookId = GetIntArg(env, args[0], 0);
    const std::string format = GetStringArg(env, args[1]);
    const std::string destPath = GetStringArg(env, args[2]);
    return RunAsyncStringTask(env, [bookId, format, destPath]() {
        return talebook::TalebookCore::instance().api().downloadBook(bookId, format, destPath);
    });
}

napi_value ApiDownloadAudioFileAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t bookId = GetIntArg(env, args[0], 0);
    const std::string filename = GetStringArg(env, args[1]);
    const std::string destPath = GetStringArg(env, args[2]);
    return RunAsyncStringTask(env, [bookId, filename, destPath]() {
        return talebook::TalebookCore::instance().api().downloadAudioFile(bookId, filename, destPath);
    });
}

napi_value ApiGetReadingListAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getReadingList(page, limit);
    });
}

napi_value ApiGetFavoritesAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getFavorites(page, limit);
    });
}

napi_value ApiGetMessagesAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getMessages(page, limit);
    });
}

napi_value ApiGetMetaListAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string type = GetStringArg(env, args[0]);
    const int32_t page = GetIntArg(env, args[1], 1);
    const int32_t limit = GetIntArg(env, args[2], 20);
    return RunAsyncStringTask(env, [type, page, limit]() {
        return talebook::TalebookCore::instance().api().getMetaList(type, page, limit);
    });
}

napi_value ApiGetAdminBooksAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t page = GetIntArg(env, args[0], 1);
    const int32_t limit = GetIntArg(env, args[1], 20);
    return RunAsyncStringTask(env, [page, limit]() {
        return talebook::TalebookCore::instance().api().getAdminBooks(page, limit);
    });
}

napi_value ApiSetFavoriteAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t bookId = GetIntArg(env, args[0], 0);
    const bool favorite = GetBoolArg(env, args[1], true);
    return RunAsyncStringTask(env, [bookId, favorite]() {
        return talebook::TalebookCore::instance().api().setFavorite(bookId, favorite);
    });
}

napi_value ApiEditBookAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int32_t bookId = GetIntArg(env, args[0], 0);
    const std::string payloadJson = GetStringArg(env, args[1]);
    return RunAsyncStringTask(env, [bookId, payloadJson]() {
        return talebook::TalebookCore::instance().api().editBook(bookId, payloadJson);
    });
}

napi_value RegisterFn(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setBaseUrl", nullptr, SetBaseUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setIdentityDir", nullptr, SetIdentityDir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"secureGet", nullptr, SecureGet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"secureGetGlobal", nullptr, SecureGetGlobal, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"secureSetGlobal", nullptr, SecureSetGlobal, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"secureSet", nullptr, SecureSet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prefGet", nullptr, PrefGet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prefSet", nullptr, PrefSet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prefSetBatch", nullptr, PrefSetBatch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getReadingHistory", nullptr, GetReadingHistory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveReadingHistory", nullptr, SaveReadingHistory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getBookmarks", nullptr, GetBookmarks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveBookmarks", nullptr, SaveBookmarks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDownloads", nullptr, GetDownloads, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveDownloads", nullptr, SaveDownloads, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSignIn", nullptr, ApiSignIn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSignInAsync", nullptr, ApiSignInAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSignOut", nullptr, ApiSignOut, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetUserInfo", nullptr, ApiGetUserInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetUserInfoAsync", nullptr, ApiGetUserInfoAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiWarmConnectionAsync", nullptr, ApiWarmConnectionAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetIndex", nullptr, ApiGetIndex, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSearch", nullptr, ApiSearch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSearchAsync", nullptr, ApiSearchAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetRecent", nullptr, ApiGetRecent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetRecentAsync", nullptr, ApiGetRecentAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetHot", nullptr, ApiGetHot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetHotAsync", nullptr, ApiGetHotAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetAllBooks", nullptr, ApiGetAllBooks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetAllBooksAsync", nullptr, ApiGetAllBooksAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetBookDetail", nullptr, ApiGetBookDetail, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetBookDetailAsync", nullptr, ApiGetBookDetailAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiDeleteBook", nullptr, ApiDeleteBook, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSetFavorite", nullptr, ApiSetFavorite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSetFavoriteAsync", nullptr, ApiSetFavoriteAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetBookNav", nullptr, ApiGetBookNav, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetBookNavAsync", nullptr, ApiGetBookNavAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetReadingList", nullptr, ApiGetReadingList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetReadingListAsync", nullptr, ApiGetReadingListAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetFavorites", nullptr, ApiGetFavorites, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetFavoritesAsync", nullptr, ApiGetFavoritesAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetMessages", nullptr, ApiGetMessages, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetMessagesAsync", nullptr, ApiGetMessagesAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetMetaList", nullptr, ApiGetMetaList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetMetaListAsync", nullptr, ApiGetMetaListAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetMetaBooks", nullptr, ApiGetMetaBooks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetMetaBooksAsync", nullptr, ApiGetMetaBooksAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetAdminBooks", nullptr, ApiGetAdminBooks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetAdminBooksAsync", nullptr, ApiGetAdminBooksAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetAdminUsers", nullptr, ApiGetAdminUsers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSoNovelSearch", nullptr, ApiSoNovelSearch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiSoNovelFetchBook", nullptr, ApiSoNovelFetchBook, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiDownloadBook", nullptr, ApiDownloadBook, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiDownloadBookAsync", nullptr, ApiDownloadBookAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiDownloadAudioFileAsync", nullptr, ApiDownloadAudioFileAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiEditBook", nullptr, ApiEditBook, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiEditBookAsync", nullptr, ApiEditBookAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetBookRefer", nullptr, ApiGetBookRefer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiGetAudioFiles", nullptr, ApiGetAudioFiles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiMarkMessageRead", nullptr, ApiMarkMessageRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiMarkMessageReadAsync", nullptr, ApiMarkMessageReadAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fetchImageCache", nullptr, FetchImageCache, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fetchImageCacheAsync", nullptr, FetchImageCacheAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

extern "C" __attribute__((constructor)) void RegisterTalebookModule(void)
{
    napi_module module = {
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = nullptr,
        .nm_register_func = RegisterFn,
        .nm_modname = "entry",
        .nm_priv = nullptr,
        .reserved = {0},
    };
    napi_module_register(&module);
}
