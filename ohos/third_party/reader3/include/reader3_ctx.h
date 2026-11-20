// reader3_ctx.h -- 书源上下文（ctx）公共 API。
//
// 这是 reader3_native 唯一对外导出的书源接口面。设计目标：
//   * 一个 ctx 实例 = 一个书源。书源 JSON 只在创建时传入一次，后续每步调用
//     不再重复传 source_json。
//   * 只暴露「书籍级」书源函数：search / bookInfo / toc / content / explore。
//     规则解析、CSS/XPath/JSONPath/正则、扫描计划、聚合、HTML 工具等中间能力
//     全部为内部实现，不导出，可自由重构与优化而不影响外部调用方。
//   * 输入输出均为 UTF-8 字符串（JSON），字段名与内部 Core 命令协议一致。
//   * 宿主能力（HTTP / JS 求值 / WebView）通过 C 回调注入，不依赖任何 C++
//     符号，便于 Dart FFI / OHOS NAPI 直接绑定。
//
// 调用约定：
//   1. reader3_ctx_create(source_json, host_callbacks, user) 创建 ctx；
//   2. 依次调用 reader3_ctx_search / _book_info / _toc / _content / _explore，
//      每次传入该步的输入 JSON，输出该步结果 JSON；
//   3. reader3_ctx_destroy(ctx) 释放。
//
// 每一步内部会自动完成 host 回调往返（HTTP 抓页、rule_eval 等），调用方无需
// 关心中间状态机。单次调用是同步阻塞的；需要中止时从其它线程调用
// reader3_ctx_cancel。
//
// 返回值约定：>0 为写入 out 的字节数（不含结尾 '\0'）；<0 为错误码
// （READER3_NATIVE_ERROR_*）。

#ifndef READER3_CTX_H_
#define READER3_CTX_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 导出/导入宏。构建 reader3_native 共享库时由目标定义 READER3_NATIVE_BUILD。
#if defined(_WIN32)
#if defined(READER3_NATIVE_BUILD)
#define READER3_CTX_EXPORT __declspec(dllexport)
#else
#define READER3_CTX_EXPORT __declspec(dllimport)
#endif
#else
#define READER3_CTX_EXPORT __attribute__((visibility("default")))
#endif

// C ABI 版本。调用方在使用前应校验。与 reader3_native.h 的
// READER3_NATIVE_ABI_VERSION 同源（均反映同一动态库的导出面版本）。
// 导出面只覆盖「取书籍数据」的书源五步。reader_core 对调用方是黑盒：
// 规则解析、CSS/XPath/JSONPath/正则、扫描计划、聚合、HTML 工具、JS 求值、
// 字段提取、书源校验全是内部实现，调用方只描述「要哪一步、参数是什么」。
#define READER3_CTX_ABI_VERSION 4

// 能力位（只增不改，不复用既有位）。完整能力位集合由
// reader3_native_capabilities() 返回；此处列出 ctx 面直接相关的能力。
#define READER3_CTX_CAPABILITY_CTX_HANDLE (UINT64_C(1) << 21)
#define READER3_CTX_CAPABILITY_HOST_CALLBACKS (UINT64_C(1) << 22)

// 错误码（与内部 C ABI 一致）。
#define READER3_CTX_ERROR_INVALID_ARGUMENT (-1)
#define READER3_CTX_ERROR_OUTPUT_TOO_SMALL (-2)
#define READER3_CTX_ERROR_OVERFLOW (-3)
#define READER3_CTX_ERROR_BUSY (-4)
#define READER3_CTX_ERROR_STATE (-6)

// 宿主回调：把一次平台操作委托给调用方。
//
// request_json 为 UTF-8 JSON（不以 NUL 结尾时以 request_length 为准），
// kind 字段区分操作类型：
//   "http"          网络请求；响应须与 reader3_host.h 的 HttpResponse 一致
//                   （status_code / body_b64 / headers / url / transport_error）
//   "rule_eval"     JS 规则求值；响应须与 RuleEvalResponse 一致
//   "browser_probe" WebView 渲染；响应须与 BrowserProbeResponse 一致
//
// 回调实现须把响应 JSON 写入 *out_json（UTF-8，可为非 NUL 结尾），长度写入
// *out_length，并返回 0 表示成功；返回非 0 视为该次操作失败。
// 内存由回调分配，reader3 调用完 free_response（若非 NULL）或 free() 释放。
typedef int32_t (*reader3_ctx_host_fn)(void* user,
                                       const uint8_t* request_json,
                                       int64_t request_length,
                                       uint8_t** out_json,
                                       int64_t* out_length);

typedef struct reader3_ctx_host_callbacks {
  // 必填：网络抓取。单条 http、并发 http_batch 与 JS 侧 java.ajaxAll 的批量
  // 抓取都走这个回调（http_batch 的请求体为
  // {"kind":"http_batch","entries":[...]}，宿主按 entries 逐条请求后返回
  // {"entries":[...]}）。批量抓取会**并发**调用本回调（有界工作线程），
  // 实现须线程安全。
  reader3_ctx_host_fn http_fetch;
  // 可选：JS 规则求值（@js: / <js> / java.* 桥）。为 NULL 时由库内自带的
  // QuickJS 运行时求值（与桌面宿主一致），宿主无需自行实现 JS 引擎。
  reader3_ctx_host_fn rule_eval;
  // 可选：WebView 渲染（webView / webJs 书源）。
  reader3_ctx_host_fn browser_probe;
  // 可选：释放回调返回的 JSON。为 NULL 时使用 free()。
  void (*free_response)(void* user, uint8_t* json);
} reader3_ctx_host_callbacks;

// 书源上下文句柄：不透明类型。
typedef struct reader3_ctx reader3_ctx_t;

// 创建 ctx。source_json 为单个书源的 UTF-8 JSON（与 legado 书源字段一致）。
// callbacks 可为 NULL（此时任何需要宿主的步骤都会失败），user 原样回传给回调。
// 失败返回 NULL。
READER3_CTX_EXPORT reader3_ctx_t* reader3_ctx_create(
    const uint8_t* source_json, int64_t source_json_length,
    const reader3_ctx_host_callbacks* callbacks, void* user);

// 销毁 ctx 并释放资源；ctx 为 NULL 时无操作。
READER3_CTX_EXPORT void reader3_ctx_destroy(reader3_ctx_t* ctx);

// 搜索。输入 JSON：{"key":"关键字","page":1,"timeout_ms":0}
// 输出：{"status":"ok","result":{"field":"ruleSearch","data":"[ ... ]"}}
READER3_CTX_EXPORT int64_t reader3_ctx_search(
    reader3_ctx_t* ctx,
    const uint8_t* input_json, int64_t input_length,
    uint8_t* out, int64_t out_capacity);

// 书籍详情。输入 JSON：{"book_url":"...","timeout_ms":0}
// 输出：{"status":"ok","result":{"field":"ruleBookInfo","data":"{ ... }"}}
READER3_CTX_EXPORT int64_t reader3_ctx_book_info(
    reader3_ctx_t* ctx,
    const uint8_t* input_json, int64_t input_length,
    uint8_t* out, int64_t out_capacity);

// 目录。输入 JSON：{"toc_url":"...","book_url":"...","max_pages":8,
// "max_parallel":4,"timeout_ms":0}
// max_parallel 为并发分页的批大小（默认 8，上限 32）：书源 nextTocUrl 一次
// 给出多个 URL 时按此并发抓取；书源声明了 concurrentRate 时还会被其收紧。
// 输出：{"status":"ok","result":{"field":"ruleToc","data":"[ ... ]"}}
READER3_CTX_EXPORT int64_t reader3_ctx_toc(
    reader3_ctx_t* ctx,
    const uint8_t* input_json, int64_t input_length,
    uint8_t* out, int64_t out_capacity);

// 正文。输入 JSON：{"chapter_url":"...","next_chapter_url":"","max_pages":4,
// "max_parallel":4,"timeout_ms":0}
// max_parallel 语义同 reader3_ctx_toc（并发分页批大小，默认 8，上限 32）。
// 输出：{"status":"ok","result":{"field":"ruleContent","data":"{ ... }"}}
READER3_CTX_EXPORT int64_t reader3_ctx_content(
    reader3_ctx_t* ctx,
    const uint8_t* input_json, int64_t input_length,
    uint8_t* out, int64_t out_capacity);

// 发现。输入 JSON：{"explore_url":"...","page":1,"timeout_ms":0}
// 输出：{"status":"ok","result":{"field":"ruleExplore","data":"[ ... ]"}}
READER3_CTX_EXPORT int64_t reader3_ctx_explore(
    reader3_ctx_t* ctx,
    const uint8_t* input_json, int64_t input_length,
    uint8_t* out, int64_t out_capacity);

// 取消 ctx 上正在进行的调用（可从其它线程调用）。返回 0。
//
// 语义与线程安全：
//   * 取消是**协作式**的——只置一个原子标志，状态机收尾由正在驱动本次调用的
//     线程完成，因此从任意线程调用都是安全的（不会与驱动线程竞争）；
//   * 进行中的调用会在下一次与 core 交互时中止，并返回负错误码
//     （READER3_CTX_ERROR_STATE）；宿主回调阻塞期间无法打断；
//   * 取消后同一 ctx 可继续使用（状态机已被复位）；空闲态调用取消不影响随后
//     发起的调用；
//   * 同一个 ctx 实例**不可并发调用**（它持有单个命令状态机）；需要并行取多章
//     内容时，每线程各建一个 ctx（同一书源 JSON 可重复创建）——引擎内部缓存
//     （HTML 片段/正则/选择器/jsoup 句柄/QuickJS 运行时）均为线程私有，
//     cookie 罐与变量是 per-ctx 的（不会跨 ctx 共享）。
READER3_CTX_EXPORT int64_t reader3_ctx_cancel(reader3_ctx_t* ctx);

// 元信息：定义在 reader3_native.h（reader3_native 的 ABI 版本与能力位），
// 此处仅为便于只包含 reader3_ctx.h 的调用方而声明，不重复定义。
READER3_CTX_EXPORT int64_t reader3_native_abi_version(void);
READER3_CTX_EXPORT uint64_t reader3_native_capabilities(void);

#ifdef __cplusplus
}
#endif

#endif  // READER3_CTX_H_
