// reader_core 书源引擎桥：book_info（详情页元数据）单命令。
// 引擎在 native async work 线程同步跑 book_info；http_fetch 回调经
// threadsafe_function 投递到 ArkTS 主线程用 rcp 执行（charset→UTF-8 解码
// 归 ArkTS：native 无可靠 GBK 转换，见 reader_core/src/reader3_http_charset.cpp:15-19），
// 结果经 reader3Deliver 回填、条件变量唤醒引擎线程。
// 协议（reader3_ctx.h）：request {"kind":"http","method","url","headers":{},"body","charset","timeout_ms"}
//   response {"status_code","headers":{小写:[..]},"url","body_b64"(UTF-8 字节 base64),"transport_error"?}
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#include "napi/native_api.h"
#ifdef READER3_META_ENABLED
#include "reader3_ctx.h"
#endif

namespace {

#ifdef READER3_META_ENABLED

// ---- http host 桥 ----

struct HttpTask {
    std::string requestJson;
    std::mutex mu;
    std::condition_variable cv;
    bool delivered = false;
    std::string responseJson;
};

// #1668：task 用引用计数管理生命周期。此前 HttpFetch 超时即 delete，
// 而晚到的 deliver/CallJs 仍持有裸指针 → use-after-free；任何访问方
// 只要拿着一份 HttpTaskPtr，对象就多活一份时间，最后持有者释放。
using HttpTaskPtr = std::shared_ptr<HttpTask>;

napi_threadsafe_function g_tsfn = nullptr;

// 单挂起任务槽：book_info 串行使用；持有者=引用计数（HttpFetch/CallJs/deliver 各取副本）
HttpTaskPtr g_pending;
std::mutex g_pendingMu;

void DeliverPendingResponse(const std::string &resp)
{
    HttpTaskPtr task;
    {
        std::lock_guard<std::mutex> lk(g_pendingMu);
        task = g_pending;
        g_pending = nullptr;
    }
    if (task == nullptr) {
        return;
    }
    {
        std::lock_guard<std::mutex> lk(task->mu);
        task->responseJson = resp;
        task->delivered = true;
    }
    task->cv.notify_all();
}

void CallJsHttp(napi_env env, napi_value jsCb, void *, void *)
{
    // #1668：队列项不再携带 task 裸指针（HttpFetch 超时释放后就是悬垂指针）；
    // 从 g_pending 取引用计数副本——取到 null 说明任务已超时清理，静默跳过
    HttpTaskPtr task;
    {
        std::lock_guard<std::mutex> lk(g_pendingMu);
        task = g_pending;
    }
    if (task == nullptr) {
        return;
    }
    if (env == nullptr || jsCb == nullptr) {
        std::lock_guard<std::mutex> lk(task->mu);
        if (!task->delivered) {
            task->responseJson = "{\"status_code\":0,\"transport_error\":\"bridge unavailable\",\"headers\":{},\"body_b64\":\"\"}";
            task->delivered = true;
            task->cv.notify_all();
        }
        return;
    }
    // requestJson 写入先于 g_pending 赋值（g_pendingMu 建立 happens-before），读无需再加锁
    napi_value arg = nullptr;
    napi_create_string_utf8(env, task->requestJson.c_str(), task->requestJson.size(), &arg);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value ignore = nullptr;
    napi_status st = napi_call_function(env, undefined, jsCb, 1, &arg, &ignore);
    if (st != napi_ok) {
        std::lock_guard<std::mutex> lk(task->mu);
        if (!task->delivered) {
            task->responseJson = "{\"status_code\":0,\"transport_error\":\"js dispatch failed\",\"headers\":{},\"body_b64\":\"\"}";
            task->delivered = true;
            task->cv.notify_all();
        }
    }
    // 成功路径由 reader3Deliver 完成 delivered/notify
}

int32_t HttpFetch(void *, const uint8_t *req, int64_t reqlen,
                  uint8_t **out_json, int64_t *out_len)
{
    auto task = std::make_shared<HttpTask>();
    task->requestJson.assign((const char *)req, (size_t)reqlen);
    bool dispatched = false;
    if (g_tsfn != nullptr) {
        {
            std::lock_guard<std::mutex> lk(g_pendingMu);
            if (g_pending == nullptr) {
                g_pending = task;
                // #1668：队列项不携带 task 指针，消费端从 g_pending 取引用副本
                if (napi_call_threadsafe_function(g_tsfn, nullptr, napi_tsfn_blocking) == napi_ok) {
                    dispatched = true;
                } else {
                    g_pending = nullptr;
                }
            }
        }
    }
    std::string resp;
    if (dispatched) {
        std::unique_lock<std::mutex> lk(task->mu);
        // 上限=引擎单请求 timeout + 网络余量；rcp 自身超时更短，正常不会触顶
        if (!task->cv.wait_for(lk, std::chrono::seconds(60), [&task] { return task->delivered; })) {
            lk.unlock();
            {
                std::lock_guard<std::mutex> plk(g_pendingMu);
                if (g_pending == task) {
                    g_pending = nullptr;
                }
            }
            // #1668：超时写入必须持 task->mu 并复核 delivered——若晚到的 deliver
            // 抢先认领并写了真实响应，不得覆盖；对同一 string 并发裸写即堆破坏
            lk.lock();
            if (!task->delivered) {
                task->responseJson = "{\"status_code\":0,\"transport_error\":\"host timeout\",\"headers\":{},\"body_b64\":\"\"}";
                task->delivered = true;
            }
        }
        resp = task->responseJson;
    } else {
        resp = "{\"status_code\":0,\"transport_error\":\"bridge unavailable\",\"headers\":{},\"body_b64\":\"\"}";
    }
    // #1668：不再 delete——本地引用离开作用域自动释放，晚到的持引用方仍安全
    uint8_t *buf = (uint8_t *)malloc(resp.size() + 1);
    if (buf == nullptr) {
        return 1;
    }
    memcpy(buf, resp.data(), resp.size());
    buf[resp.size()] = '\0';
    *out_json = buf;
    *out_len = (int64_t)resp.size();
    return 0;
}

// ---- JSON 小工具（book_info 输入转义用）----

std::string JsonEscape(const std::string &s)
{
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') {
            o.push_back('\\');
        }
        if (c == '\n' || c == '\r' || c == '\t') {
            o.push_back(' ');
            continue;
        }
        o.push_back(c);
    }
    return o;
}

// ---- NAPI ----

napi_value Reader3Available(napi_env env, napi_callback_info)
{
    napi_value b = nullptr;
    napi_get_boolean(env, true, &b);
    return b;
}

napi_value Reader3SetHttpCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value r = nullptr;
    if (argc < 1) {
        napi_get_boolean(env, false, &r);
        return r;
    }
    if (g_tsfn != nullptr) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_abort);
        g_tsfn = nullptr;
    }
    napi_value resource = nullptr;
    napi_create_string_utf8(env, "reader3_http", NAPI_AUTO_LENGTH, &resource);
    napi_status st = napi_create_threadsafe_function(
        env, argv[0], nullptr, resource, 4, 1, nullptr, nullptr, nullptr, CallJsHttp, &g_tsfn);
    napi_get_boolean(env, st == napi_ok, &r);
    return r;
}

napi_value Reader3Deliver(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value r = nullptr;
    // #1668：2MB 大缓冲移出调用栈（napi 线程栈宽有限，压栈即溢出）；
    // deliver 仅在 JS 主线程被调，无并发写，static 复用安全
    static char buf[2 * 1024 * 1024];
    size_t len = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, argv[0], buf, sizeof(buf), &len) != napi_ok) {
        napi_get_boolean(env, false, &r);
        return r;
    }
    // deliver 由 ArkTS 在收到 dispatch 后调用；当前挂起任务唯一（book_info 串行）
    DeliverPendingResponse(std::string(buf, len));
    napi_get_boolean(env, true, &r);
    return r;
}

struct BookInfoCall {
    std::string sourceJson;
    std::string bookUrl;
    napi_deferred deferred;
    napi_async_work work = nullptr;
    std::string payload;
};

void ExecuteBookInfo(napi_env, void *data)
{
    auto *call = static_cast<BookInfoCall *>(data);
    reader3_ctx_host_callbacks cb{};
    cb.http_fetch = HttpFetch;
    reader3_ctx_t *ctx = reader3_ctx_create(
        (const uint8_t *)call->sourceJson.data(), (int64_t)call->sourceJson.size(), &cb, nullptr);
    if (ctx == nullptr) {
        call->payload = "{\"status\":\"error\",\"message\":\"书源规则无效\"}";
        return;
    }
    const std::string input = "{\"book_url\":\"" + JsonEscape(call->bookUrl) + "\",\"timeout_ms\":30000}";
    std::string out;
    int64_t cap = 64 * 1024;
    int64_t written = -2;
    for (int retry = 0; retry < 6; retry++) {
        out.resize((size_t)cap);
        written = reader3_ctx_book_info(
            ctx, (const uint8_t *)input.data(), (int64_t)input.size(),
            (uint8_t *)out.data(), cap);
        if (written >= 0) {
            out.resize((size_t)written);
            break;
        }
        if (written != -2) {
            break;
        }
        cap *= 2;
    }
    call->payload = written > 0 ? out
                                : "{\"status\":\"error\",\"message\":\"引擎错误 " +
                                      std::to_string((long long)written) + "\"}";
    reader3_ctx_destroy(ctx);
}

void CompleteBookInfo(napi_env env, napi_status, void *data)
{
    auto *call = static_cast<BookInfoCall *>(data);
    napi_value result = nullptr;
    napi_create_string_utf8(env, call->payload.c_str(), call->payload.size(), &result);
    napi_resolve_deferred(env, call->deferred, result);
    napi_delete_async_work(env, call->work);
    delete call;
}

napi_value Reader3BookInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    auto *call = new BookInfoCall();
    call->deferred = deferred;
    size_t len = 0;
    char urlBuf[4096] = {0};
    napi_get_value_string_utf8(env, argv[1], urlBuf, sizeof(urlBuf), &len);
    call->bookUrl.assign(urlBuf, len);
    // 书源 JSON 可能较大：先取长度再分配
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len) == napi_ok) {
        std::string src(len + 1, '\0');
        if (napi_get_value_string_utf8(env, argv[0], src.data(), len + 1, &len) == napi_ok) {
            call->sourceJson.assign(src.data(), len);
        }
    }
    napi_value resource = nullptr;
    napi_create_string_utf8(env, "reader3_book_info", NAPI_AUTO_LENGTH, &resource);
    napi_create_async_work(env, nullptr, resource, ExecuteBookInfo, CompleteBookInfo, call, &call->work);
    napi_queue_async_work(env, call->work);
    return promise;
}

#else // !READER3_META_ENABLED

// 本构建没有可用的 libreader3_native.so（Android bionic 装不上鸿蒙 musl 预编译产物）。
// 导出同签名空实现：reader3Available 恒为 false，ArkTS 据此走原有 parse 兜底路径，
// 桥接 API 形状保持一致，调用方无需分平台判空。
napi_value Reader3Available(napi_env env, napi_callback_info)
{
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
}

napi_value Reader3SetHttpCallback(napi_env env, napi_callback_info)
{
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
}

napi_value Reader3Deliver(napi_env env, napi_callback_info)
{
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
}

napi_value Reader3BookInfo(napi_env env, napi_callback_info info)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    napi_value r = nullptr;
    napi_create_string_utf8(env, "{\"status\":\"error\",\"message\":\"reader3 引擎不可用（本 ABI 无预编译产物）\"}", NAPI_AUTO_LENGTH, &r);
    napi_resolve_deferred(env, deferred, r);
    return promise;
}

#endif // READER3_META_ENABLED

} // namespace

namespace reader3_meta {

napi_value RegisterModule(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"reader3Available", nullptr, Reader3Available, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reader3SetHttpCallback", nullptr, Reader3SetHttpCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reader3Deliver", nullptr, Reader3Deliver, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reader3BookInfo", nullptr, Reader3BookInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace reader3_meta
