cmake_minimum_required(VERSION 3.5)
project(talebook)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
# cpp -> main -> src -> entry -> ohos（与 mybooks_core 模块共用的第三方库根目录）
set(SHARED_THIRD_PARTY ${NATIVERENDER_ROOT_PATH}/../../../../third_party)

if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${SHARED_THIRD_PARTY}
    ${SHARED_THIRD_PARTY}/curl/include
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
    ${SHARED_THIRD_PARTY}/cjson/cJSON.c
)

target_compile_options(entry PRIVATE -fvisibility=hidden -Os)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libcurl.so
)
