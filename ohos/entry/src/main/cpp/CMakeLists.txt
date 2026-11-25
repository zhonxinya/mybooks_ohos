cmake_minimum_required(VERSION 3.5)
project(talebook)

# 与 mybooks_core 同理：预置 FindThreads 结果避免 -pthread 泄漏；
# 关掉 curl 8.23 的 pkg-config 探测通道，避免 host .pc（如 runner 上的
# libbrotli-dev/libzstd-dev，Cflags -I/usr/include）注入编译行击穿 musl 头。
set(CMAKE_HAVE_LIBC_PTHREAD ON CACHE INTERNAL "" FORCE)
set(CURL_USE_PKGCONFIG OFF CACHE BOOL "" FORCE)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
# cpp -> main -> src -> entry -> ohos（与 mybooks_core 模块共用的第三方库根目录）
set(SHARED_THIRD_PARTY ${NATIVERENDER_ROOT_PATH}/../../../../third_party)

if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()

# --- 平台分支 ---
# 鸿蒙：NAPI/hilog 用系统库；非 x86_64 的 ABI 用预编译 libcurl.so（鸿蒙 musl）。
# Android（ArkUI-X）：NAPI/hilog 由引擎库 libarkui_android.so 提供（导出 napi_* 与 HiLogPrint）；
#                    且必须走源码构建的 curl + mbedTLS（鸿蒙预编译 .so 为 musl，Android bionic 装不上）。
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    if(NOT DEFINED ARKUIX_ANDROID_ENGINE_LIB)
        message(FATAL_ERROR
            "Android 构建需指定 -DARKUIX_ANDROID_ENGINE_LIB=<arkui-x engine/lib/arkui/<abi>/libarkui_android.so>")
    endif()
    get_filename_component(_arkuix_abi_dir ${ARKUIX_ANDROID_ENGINE_LIB} DIRECTORY)
    get_filename_component(_arkuix_arkui_dir ${_arkuix_abi_dir} DIRECTORY)
    get_filename_component(_arkuix_lib_dir ${_arkuix_arkui_dir} DIRECTORY)
    include_directories(
        ${_arkuix_lib_dir}/include
        ${SHARED_THIRD_PARTY}/arkuix_android/include
    )
    add_library(arkui_android SHARED IMPORTED GLOBAL)
    set_target_properties(arkui_android PROPERTIES IMPORTED_LOCATION ${ARKUIX_ANDROID_ENGINE_LIB})
    set(ENTRY_NAPI_LIBS arkui_android)
    set(ENTRY_BUILD_DEPS_FROM_SOURCE ON)
else()
    set(ENTRY_NAPI_LIBS libace_napi.z.so libhilog_ndk.z.so)
    set(ENTRY_BUILD_DEPS_FROM_SOURCE OFF)
endif()

# arm64-v8a 链接预编译 libcurl.so；x86_64（模拟器）与 Android 没有对应预编译产物，
# 改用 third_party 源码静态构建 curl + mbedTLS。
# 开关清单收敛到共享 include（建议 #1227），与 mybooks_core 同源；背景见该文件头注释。
if(ENTRY_BUILD_DEPS_FROM_SOURCE OR OHOS_ARCH STREQUAL "x86_64")
    set(ENTRY_CURL_INCLUDE ${SHARED_THIRD_PARTY}/curl/curl-8.23.0/include)
    set(CURL_DEPS_TP_ROOT ${SHARED_THIRD_PARTY})
    include(${NATIVERENDER_ROOT_PATH}/../../../../cmake/BuildCurlMbedTLS.cmake)
else()
    set(ENTRY_CURL_INCLUDE ${SHARED_THIRD_PARTY}/curl/include)
endif()

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${SHARED_THIRD_PARTY}
    ${ENTRY_CURL_INCLUDE}
    ${SHARED_THIRD_PARTY}/reader3/include
)

add_library(entry SHARED
    napi_init.cpp
    talebook_core.cpp
    http_client.cpp
    json_store.cpp
    reading_history.cpp
    bookmarks.cpp
    download_store.cpp
    talebook_api.cpp
    sonovel_api.cpp
    reader3_meta.cpp
    apk_installer.cpp
    ${SHARED_THIRD_PARTY}/cjson/cJSON.c
)

target_compile_options(entry PRIVATE -fvisibility=hidden -Os)

target_link_libraries(entry PUBLIC
    ${ENTRY_NAPI_LIBS}
)

# Android 侧 apk_installer.cpp 用 dlopen/dlsym 取 JNI 虚拟机
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    target_link_libraries(entry PUBLIC dl)
endif()

if(ENTRY_BUILD_DEPS_FROM_SOURCE OR OHOS_ARCH STREQUAL "x86_64")
    target_link_libraries(entry PUBLIC libcurl mbedtls mbedx509 mbedcrypto)
else()
    target_link_libraries(entry PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libcurl.so
    )
endif()

# reader_core 书源引擎（book_info 详情元数据）：仿 libcurl 预编译模式，
# libs/${OHOS_ARCH}/libreader3_native.so 存在才链接（arm64-v8a/x86_64 均为鸿蒙 musl 产物）。
# Android 装不上 musl 产物，不链接；reader3_meta.cpp 在宏未定义时退化为空实现，
# ArkTS 侧经 reader3Available() 探测后走现有 parse 兜底路径。
set(ENTRY_READER3_PREBUILT ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libreader3_native.so)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Android" AND EXISTS ${ENTRY_READER3_PREBUILT})
    target_link_libraries(entry PUBLIC ${ENTRY_READER3_PREBUILT})
    target_compile_definitions(entry PRIVATE READER3_META_ENABLED=1)
endif()
