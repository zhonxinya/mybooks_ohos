cmake_minimum_required(VERSION 3.5)
project(talebook)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
# cpp -> main -> src -> entry -> ohos（与 mybooks_core 模块共用的第三方库根目录）
set(SHARED_THIRD_PARTY ${NATIVERENDER_ROOT_PATH}/../../../../third_party)

if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()

# arm64-v8a 链接预编译 libcurl.so；x86_64（模拟器）没有对应预编译产物，
# 改用 third_party 源码静态构建 curl + mbedTLS（与 mybooks_core 同一套构建参数）。
if(OHOS_ARCH STREQUAL "x86_64")
    set(ENTRY_CURL_INCLUDE ${SHARED_THIRD_PARTY}/curl/curl-8.5.0/include)

    set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
    set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
    set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
    set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
    set(GEN_FILES OFF CACHE BOOL "" FORCE)
    set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
    set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
    add_subdirectory(${SHARED_THIRD_PARTY}/mbedtls ${CMAKE_BINARY_DIR}/mbedtls_build EXCLUDE_FROM_ALL)
    set(MBEDTLS_SOURCE_DIR ${SHARED_THIRD_PARTY}/mbedtls)

    # curl 自带的 CMake/FindMbedTLS.cmake 会遮蔽 CMAKE_MODULE_PATH（curl CMakeLists 第 65 行），
    # 故按 mybooks_core 的做法预置缓存变量，让它直接绑定 vendored 的 mbedtls 目标。
    set(MBEDTLS_INCLUDE_DIRS ${SHARED_THIRD_PARTY}/mbedtls/include CACHE PATH "" FORCE)
    set(MBEDTLS_LIBRARY mbedtls CACHE STRING "" FORCE)
    set(MBEDX509_LIBRARY mbedx509 CACHE STRING "" FORCE)
    set(MBEDCRYPTO_LIBRARY mbedcrypto CACHE STRING "" FORCE)
    set(MBEDTLS_LIBRARIES mbedtls mbedx509 mbedcrypto CACHE STRING "" FORCE)

    set(BUILD_CURL_EXE OFF CACHE BOOL "" FORCE)
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
    set(CURL_DISABLE_LDAP ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_LDAPS ON CACHE BOOL "" FORCE)
    set(CURL_USE_LIBPSL OFF CACHE BOOL "" FORCE)
    set(CURL_USE_LIBSSH2 OFF CACHE BOOL "" FORCE)
    set(CURL_ENABLE_SSL ON CACHE BOOL "" FORCE)
    set(CURL_USE_OPENSSL OFF CACHE BOOL "" FORCE)
    set(CURL_USE_MBEDTLS ON CACHE BOOL "" FORCE)
    set(CURL_USE_SCHANNEL OFF CACHE BOOL "" FORCE)
    set(CURL_USE_WOLFSSL OFF CACHE BOOL "" FORCE)
    set(CURL_DISABLE_INSTALL ON CACHE BOOL "" FORCE)
    set(CURL_ENABLE_EXPORT_TARGET OFF CACHE BOOL "" FORCE)
    set(HTTP_ONLY ON CACHE BOOL "" FORCE)
    set(ENABLE_MANUAL OFF CACHE BOOL "" FORCE)
    set(CURL_ZLIB OFF CACHE BOOL "" FORCE)
    set(USE_NGHTTP2 OFF CACHE BOOL "" FORCE)
    set(USE_LIBIDN2 OFF CACHE BOOL "" FORCE)
    add_subdirectory(${SHARED_THIRD_PARTY}/curl/curl-8.5.0 ${CMAKE_BINARY_DIR}/curl_build EXCLUDE_FROM_ALL)
else()
    set(ENTRY_CURL_INCLUDE ${SHARED_THIRD_PARTY}/curl/include)
endif()

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${SHARED_THIRD_PARTY}
    ${ENTRY_CURL_INCLUDE}
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
)

if(OHOS_ARCH STREQUAL "x86_64")
    target_link_libraries(entry PUBLIC libcurl mbedtls mbedx509 mbedcrypto)
else()
    target_link_libraries(entry PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libcurl.so
    )
endif()
