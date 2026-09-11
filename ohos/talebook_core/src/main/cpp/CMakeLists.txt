cmake_minimum_required(VERSION 3.16)
project(talebook_core)

set(CMAKE_CXX_STANDARD 17)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
# cpp -> main -> src -> talebook_core
set(THIRD_PARTY ${NATIVERENDER_ROOT_PATH}/../../../third_party)

include_directories(
    ${NATIVERENDER_ROOT_PATH}/include
    ${THIRD_PARTY}/sqlite
    ${THIRD_PARTY}/curl/curl-8.5.0/include
    ${THIRD_PARTY}/miniz
)

# Prefer our FindMbedTLS that binds to vendored targets
list(PREPEND CMAKE_MODULE_PATH ${NATIVERENDER_ROOT_PATH}/cmake)

# --- sqlite3 amalgamation ---
add_library(sqlite3 STATIC ${THIRD_PARTY}/sqlite/sqlite3.c)
target_compile_definitions(sqlite3 PRIVATE
    SQLITE_OMIT_LOAD_EXTENSION
    SQLITE_THREADSAFE=1
)
target_include_directories(sqlite3 PUBLIC ${THIRD_PARTY}/sqlite)

# --- mbedtls (HTTPS backend for curl) ---
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
set(GEN_FILES OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
add_subdirectory(${THIRD_PARTY}/mbedtls ${CMAKE_BINARY_DIR}/mbedtls_build EXCLUDE_FROM_ALL)
set(MBEDTLS_SOURCE_DIR ${THIRD_PARTY}/mbedtls)

# Pre-seed FindMbedTLS for curl (targets exist after add_subdirectory)
set(MBEDTLS_INCLUDE_DIRS ${THIRD_PARTY}/mbedtls/include CACHE PATH "" FORCE)
set(MBEDTLS_LIBRARY mbedtls CACHE STRING "" FORCE)
set(MBEDX509_LIBRARY mbedx509 CACHE STRING "" FORCE)
set(MBEDCRYPTO_LIBRARY mbedcrypto CACHE STRING "" FORCE)
set(MBEDTLS_LIBRARIES mbedtls mbedx509 mbedcrypto CACHE STRING "" FORCE)

# --- libcurl with mbedtls HTTPS ---
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
add_subdirectory(${THIRD_PARTY}/curl/curl-8.5.0 ${CMAKE_BINARY_DIR}/curl_build EXCLUDE_FROM_ALL)

# --- miniz (deflate/inflate for EPUB ZIP) ---
add_library(miniz STATIC
    ${THIRD_PARTY}/miniz/miniz.c
    ${THIRD_PARTY}/miniz/miniz_tinfl.c
)
target_include_directories(miniz PUBLIC ${THIRD_PARTY}/miniz)
target_compile_definitions(miniz PRIVATE
    MINIZ_NO_STDIO
    MINIZ_NO_ARCHIVE_APIS
    MINIZ_NO_DEFLATE_APIS
)

# --- talebook_core shared NAPI module ---
add_library(talebook_core SHARED
    napi_init.cpp
    http_client.cpp
    database.cpp
    download_engine.cpp
    api_service.cpp
    json_util.cpp
    epub_parser.cpp
)

target_compile_definitions(talebook_core PRIVATE
    TALEBOOK_HAS_CURL=1
    TALEBOOK_HAS_MBEDTLS=1
    TALEBOOK_HAS_MINIZ=1
)

target_link_libraries(talebook_core PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    sqlite3
    libcurl
    mbedtls
    mbedx509
    mbedcrypto
    miniz
)
