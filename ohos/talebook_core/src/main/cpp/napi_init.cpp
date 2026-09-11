#include "core_engine.h"
#include "database.h"
#include "http_client.h"

#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdlib>
#include <string>
#include <memory>
#include <map>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "TalebookCore"

namespace {

using ProgressCallback = std::function<void(double)>;
std::map<int64_t, ProgressCallback> g_progressCallbacks;
int64_t g_nextCallbackId = 1;

napi_value CreateString(napi_env env, const std::string &value) {
    napi_value result;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

std::string GetString(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string result(len, '\0');
    napi_get_value_string_utf8(env, value, result.data(), len + 1, &len);
    result.resize(len);
    return result;
}

napi_value InitCore(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string filesDir = argc >= 1 ? GetString(env, args[0]) : "";
    std::string prefsDir = argc >= 2 ? GetString(env, args[1]) : "";

    bool ok = talebook::CoreEngine::instance().init(filesDir, prefsDir);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

struct AsyncContext {
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    std::string input;
    std::string output;
    std::function<std::string(const std::string &)> task;
    ProgressCallback progress;
    int64_t callbackId = 0;
};

static void AsyncExecute(napi_env env, void *data) {
    auto *ctx = static_cast<AsyncContext *>(data);
    if (ctx->task) {
        ctx->output = ctx->task(ctx->input);
    }
}

static void AsyncComplete(napi_env env, napi_status status, void *data) {
    auto *ctx = static_cast<AsyncContext *>(data);
    napi_value result = CreateString(env, ctx->output);
    napi_resolve_deferred(env, ctx->deferred, result);
    napi_delete_async_work(env, ctx->work);
    if (ctx->callbackId > 0) g_progressCallbacks.erase(ctx->callbackId);
    delete ctx;
}

napi_value RunAsyncStringTask(napi_env env, napi_callback_info info,
                              const std::function<std::string(const std::string &)> &task,
                              size_t inputArgIndex = 0) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value promise;
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);

    auto *ctx = new AsyncContext();
    ctx->env = env;
    ctx->deferred = deferred;
    ctx->task = task;
    if (argc > inputArgIndex) ctx->input = GetString(env, args[inputArgIndex]);

    napi_value resourceName = CreateString(env, "TalebookCoreAsync");
    napi_create_async_work(env, nullptr, resourceName, AsyncExecute, AsyncComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

#define ASYNC_API(name, lambda) \
    static napi_value name(napi_env env, napi_callback_info info) { \
        return RunAsyncStringTask(env, info, lambda); \
    }

ASYNC_API(TalebookGet, [](const std::string &input) {
    // input format: path|queryJson
    size_t sep = input.find('|');
    std::string path = sep == std::string::npos ? input : input.substr(0, sep);
    return talebook::ApiService::instance().talebookGet(path);
})

ASYNC_API(TalebookPost, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    std::string path = input.substr(0, sep);
    std::string body = input.substr(sep + 1);
    return talebook::ApiService::instance().talebookPost(path, body);
})

ASYNC_API(TalebookPostForm, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    std::string path = input.substr(0, sep);
    std::string body = input.substr(sep + 1);
    return talebook::ApiService::instance().talebookPostForm(path, body);
})

ASYNC_API(TalebookDelete, [](const std::string &input) {
    return talebook::ApiService::instance().talebookDelete(input);
})

ASYNC_API(TalebookDeleteWithBody, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    std::string path = input.substr(0, sep);
    std::string body = input.substr(sep + 1);
    return talebook::ApiService::instance().talebookDeleteWithBody(path, body);
})

ASYNC_API(TalebookUploadFile, [](const std::string &input) {
    // input format: path|filePath|field|fileName[|fieldsJson]
    size_t first = input.find('|');
    size_t second = first == std::string::npos ? std::string::npos : input.find('|', first + 1);
    size_t third = second == std::string::npos ? std::string::npos : input.find('|', second + 1);
    size_t fourth = third == std::string::npos ? std::string::npos : input.find('|', third + 1);
    if (first == std::string::npos || second == std::string::npos || third == std::string::npos) {
        return talebook::ApiService::instance().wrapError("invalid input");
    }
    std::string fileName = fourth == std::string::npos ?
        input.substr(third + 1) : input.substr(third + 1, fourth - third - 1);
    std::string fieldsJson = fourth == std::string::npos ? "" : input.substr(fourth + 1);
    return talebook::ApiService::instance().talebookUploadFile(
        input.substr(0, first),
        input.substr(first + 1, second - first - 1),
        input.substr(second + 1, third - second - 1),
        fileName, fieldsJson);
})

ASYNC_API(TalebookUploadBook, [](const std::string &input) {
    size_t first = input.find('|');
    if (first == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    size_t second = input.find('|', first + 1);
    if (second == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().talebookUploadBook(
        input.substr(0, first), input.substr(first + 1, second - first - 1), input.substr(second + 1));
})


ASYNC_API(TalebookUploadBookBatch, [](const std::string &input) {
    return talebook::ApiService::instance().talebookUploadBookBatch(input);
})
ASYNC_API(TalebookUploadFiles, [](const std::string &input) {
    // input: path|filesJson[|fieldsJson]
    size_t first = input.find('|');
    if (first == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    size_t second = input.find('|', first + 1);
    std::string path = input.substr(0, first);
    if (second == std::string::npos) {
        return talebook::ApiService::instance().talebookUploadFiles(path, input.substr(first + 1), "");
    }
    return talebook::ApiService::instance().talebookUploadFiles(
        path,
        input.substr(first + 1, second - first - 1),
        input.substr(second + 1));
})
ASYNC_API(GetDownloadRecords, [](const std::string &) {
    return talebook::ApiService::instance().getDownloadRecords();
})

ASYNC_API(AddDownloadRecord, [](const std::string &input) {
    return talebook::ApiService::instance().addDownloadRecord(input);
})

ASYNC_API(DeleteDownloadRecord, [](const std::string &input) {
    return talebook::ApiService::instance().deleteDownloadRecord(input);
})

ASYNC_API(GetReadingHistory, [](const std::string &) {
    return talebook::ApiService::instance().getReadingHistory();
})

ASYNC_API(RecordReadingHistory, [](const std::string &input) {
    return talebook::ApiService::instance().recordReadingHistory(input);
})

ASYNC_API(GetReaderConfig, [](const std::string &) {
    return talebook::ApiService::instance().getReaderConfig();
})

ASYNC_API(SaveReaderConfig, [](const std::string &input) {
    return talebook::ApiService::instance().saveReaderConfig(input);
})

ASYNC_API(DownloadBookLocal, [](const std::string &input) {
    return talebook::ApiService::instance().downloadBookLocal(input, nullptr);
})

ASYNC_API(SecureSet, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid");
    talebook::Database::instance().secureSet(input.substr(0, sep), input.substr(sep + 1));
    return talebook::ApiService::instance().wrapOk("true");
})

ASYNC_API(SecureGet, [](const std::string &input) {
    auto val = talebook::Database::instance().secureGet(input);
    return talebook::ApiService::instance().wrapOk(val ? ("\"" + *val + "\"") : "null");
})

ASYNC_API(KvSet, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid");
    talebook::Database::instance().kvSet(input.substr(0, sep), input.substr(sep + 1));
    return talebook::ApiService::instance().wrapOk("true");
})

ASYNC_API(KvGet, [](const std::string &input) {
    auto val = talebook::Database::instance().kvGet(input);
    return talebook::ApiService::instance().wrapOk(val ? ("\"" + *val + "\"") : "null");
})

ASYNC_API(SonovelGet, [](const std::string &input) {
    return talebook::ApiService::instance().sonovelGet(input);
})

ASYNC_API(AdminTrashBooks, [](const std::string &) {
    return talebook::ApiService::instance().adminTrashBooks();
})

ASYNC_API(AdminTrashSize, [](const std::string &) {
    return talebook::ApiService::instance().adminTrashSize();
})

ASYNC_API(AdminTrashRestore, [](const std::string &input) {
    return talebook::ApiService::instance().adminTrashRestore(input);
})

ASYNC_API(AdminTrashPurge, [](const std::string &input) {
    return talebook::ApiService::instance().adminTrashPurge(input);
})

ASYNC_API(AdminTrashClear, [](const std::string &) {
    return talebook::ApiService::instance().adminTrashClear();
})

ASYNC_API(AdminBookReviews, [](const std::string &input) {
    size_t first = input.find('|');
    if (first == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    size_t second = input.find('|', first + 1);
    if (second == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminBookReviews(
        input.substr(0, first),
        std::atoi(input.substr(first + 1, second - first - 1).c_str()),
        std::atoi(input.substr(second + 1).c_str()));
})

ASYNC_API(AdminBookReviewAction, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminBookReviewAction(input.substr(0, sep),
                                                                  input.substr(sep + 1));
})

ASYNC_API(AdminImportList, [](const std::string &input) {
    size_t first = input.find('|');
    if (first == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    size_t second = input.find('|', first + 1);
    if (second == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminImportList(
        std::atoi(input.substr(0, first).c_str()),
        std::atoi(input.substr(first + 1, second - first - 1).c_str()),
        input.substr(second + 1));
})

ASYNC_API(AdminImportRun, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminImportRun(input.substr(0, sep),
                                                           input.substr(sep + 1) == "1");
})

ASYNC_API(AdminImportCancel, [](const std::string &) {
    return talebook::ApiService::instance().adminImportCancel();
})

ASYNC_API(AdminImportDelete, [](const std::string &input) {
    return talebook::ApiService::instance().adminImportDelete(input);
})

ASYNC_API(AdminSyslog, [](const std::string &) {
    return talebook::ApiService::instance().adminSyslog();
})

ASYNC_API(AdminResources, [](const std::string &) {
    return talebook::ApiService::instance().adminResources();
})

ASYNC_API(AdminToolList, [](const std::string &) {
    return talebook::ApiService::instance().adminToolList();
})

ASYNC_API(AdminToolAction, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminToolAction(input.substr(0, sep),
                                                             input.substr(sep + 1));
})

ASYNC_API(AdminMemoList, [](const std::string &input) {
    size_t sep = input.find('|');
    if (sep == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminMemoList(
        std::atoi(input.substr(0, sep).c_str()),
        std::atoi(input.substr(sep + 1).c_str()));
})

ASYNC_API(AdminMemoAction, [](const std::string &input) {
    size_t first = input.find('|');
    if (first == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    size_t second = input.find('|', first + 1);
    if (second == std::string::npos) return talebook::ApiService::instance().wrapError("invalid input");
    return talebook::ApiService::instance().adminMemoAction(input.substr(0, first),
                                                             input.substr(first + 1, second - first - 1),
                                                             input.substr(second + 1));
})

ASYNC_API(AdminMemoDelete, [](const std::string &input) {
    return talebook::ApiService::instance().adminMemoDelete(input);
})

static napi_value SetBaseUrl(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string input = GetString(env, args[0]);
    size_t sep = input.find('|');
    if (sep == std::string::npos) return CreateString(env, "false");
    talebook::ApiService::instance().setBaseUrl(input.substr(0, sep), input.substr(sep + 1));
    return CreateString(env, "true");
}

static napi_value SetSslVerify(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool verify = true;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &verify);
    }
    talebook::HttpClient::instance().setSslVerify(verify);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value RegisterCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t id = g_nextCallbackId++;
    napi_value result;
    napi_create_int64(env, id, &result);
    return result;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"initCore", nullptr, InitCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"talebookGet", nullptr, TalebookGet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"talebookPost", nullptr, TalebookPost, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"talebookPostForm", nullptr, TalebookPostForm, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"talebookUploadBook", nullptr, TalebookUploadBook, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"talebookUploadFile", nullptr, TalebookUploadFile, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"talebookUploadBookBatch", nullptr, TalebookUploadBookBatch, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"talebookUploadFiles", nullptr, TalebookUploadFiles, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getDownloadRecords", nullptr, GetDownloadRecords, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"addDownloadRecord", nullptr, AddDownloadRecord, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"deleteDownloadRecord", nullptr, DeleteDownloadRecord, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getReadingHistory", nullptr, GetReadingHistory, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"recordReadingHistory", nullptr, RecordReadingHistory, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getReaderConfig", nullptr, GetReaderConfig, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"saveReaderConfig", nullptr, SaveReaderConfig, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"downloadBookLocal", nullptr, DownloadBookLocal, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"secureSet", nullptr, SecureSet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"secureGet", nullptr, SecureGet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"kvSet", nullptr, KvSet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"kvGet", nullptr, KvGet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sonovelGet", nullptr, SonovelGet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adminTrashBooks", nullptr, AdminTrashBooks, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminTrashSize", nullptr, AdminTrashSize, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminTrashRestore", nullptr, AdminTrashRestore, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminTrashPurge", nullptr, AdminTrashPurge, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminTrashClear", nullptr, AdminTrashClear, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminBookReviews", nullptr, AdminBookReviews, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminBookReviewAction", nullptr, AdminBookReviewAction, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"adminImportList", nullptr, AdminImportList, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminImportRun", nullptr, AdminImportRun, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminImportCancel", nullptr, AdminImportCancel, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminImportDelete", nullptr, AdminImportDelete, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminSyslog", nullptr, AdminSyslog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adminResources", nullptr, AdminResources, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminToolList", nullptr, AdminToolList, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminToolAction", nullptr, AdminToolAction, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminMemoList", nullptr, AdminMemoList, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminMemoAction", nullptr, AdminMemoAction, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminMemoDelete", nullptr, AdminMemoDelete, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setBaseUrl", nullptr, SetBaseUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSslVerify", nullptr, SetSslVerify, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerProgressCallback", nullptr, RegisterCallback, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module talebookModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "talebook_core",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTalebookModule(void) {
    napi_module_register(&talebookModule);
}

} // namespace
