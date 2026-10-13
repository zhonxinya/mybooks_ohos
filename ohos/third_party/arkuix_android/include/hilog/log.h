#ifndef MYBOOKS_ARKUIX_ANDROID_HILOG_SHIM_H
#define MYBOOKS_ARKUIX_ANDROID_HILOG_SHIM_H

/*
 * ArkUI-X Android 端 hilog 兼容头。
 *
 * ArkUI-X SDK 的 engine/lib/include 不提供 hilog 头文件（只有 napi/uv 等），
 * 但引擎库 libarkui_android.so 导出了 C 符号 `HiLogPrint`（与 OHOS
 * libhilog_ndk.z.so 的 OH_LOG_Print 同签名：type, level, domain, tag, fmt, ...）。
 * 这里按 OHOS 官方 hilog/log.h 的定义补齐枚举与宏，仅供 Android 目标编译使用
 * （见各模块 CMakeLists 的 Android 分支）。
 */

#ifdef __cplusplus
extern "C" {
#endif

/** 日志类型：第三方应用固定用 LOG_APP（与 OHOS hilog/log.h 一致）。 */
typedef enum {
  LOG_APP = 0,
} LogType;

/** 日志级别（取值与 OHOS hilog/log.h 一致）。 */
typedef enum {
  LOG_DEBUG = 3,
  LOG_INFO = 4,
  LOG_WARN = 5,
  LOG_ERROR = 6,
  LOG_FATAL = 7,
} LogLevel;

int HiLogPrint(LogType type, LogLevel level, unsigned int domain, const char* tag, const char* fmt, ...);

#ifdef __cplusplus
}
#endif

#define OH_LOG_Print(type, level, domain, tag, ...) \
  HiLogPrint((type), (level), (domain), (tag), __VA_ARGS__)

#endif /* MYBOOKS_ARKUIX_ANDROID_HILOG_SHIM_H */
