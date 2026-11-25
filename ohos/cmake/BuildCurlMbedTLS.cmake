# curl + mbedTLS 源码构建共享配置（建议 #1227：收敛 mybooks_core / entry 两份手工同步的开关列表）
#
# 用法：调用方先设置 CURL_DEPS_TP_ROOT（third_party 绝对路径），再 include() 本文件。
# 会 add_subdirectory mbedtls 与 curl，暴露目标 libcurl/mbedtls/mbedx509/mbedcrypto。
#
# 背景（curl 8.23 升级 CI 排障，记忆 curl-pkgconfig-host-include）：
#  - 8.23 默认启用 pkg-config 依赖探测，绕过 OHOS toolchain 的 find-root-ONLY 直接查
#    host .pc；GitHub runner 的 libbrotli-dev/libzstd-dev 把 -I/usr/include 注入编译行，
#    host glibc 头击穿 musl sysroot（features-time64.h → bits/wordsize.h not found）。
#  - 8.23 起 brotli/zstd 变三态选项（默认 AUTO 探测）、HTTP_ONLY 移除改逐协议开关、
#    FindMbedTLS 改用单数 MBEDTLS_INCLUDE_DIR——升级 curl 必须核对这份显式清单。
# 防线：构建后 scripts/check_native_host_include.sh 扫 build.ninja 拦截 -I/usr/include 泄漏。

# --- mbedtls (HTTPS backend for curl) ---
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
set(GEN_FILES OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
add_subdirectory(${CURL_DEPS_TP_ROOT}/mbedtls ${CMAKE_BINARY_DIR}/mbedtls_build EXCLUDE_FROM_ALL)
set(MBEDTLS_SOURCE_DIR ${CURL_DEPS_TP_ROOT}/mbedtls)

# curl 自带的 CMake/FindMbedTLS.cmake 会遮蔽 CMAKE_MODULE_PATH（curl CMakeLists 内部），
# 预置缓存变量让它直接绑定 vendored 的 mbedtls 目标。
set(MBEDTLS_INCLUDE_DIRS ${CURL_DEPS_TP_ROOT}/mbedtls/include CACHE PATH "" FORCE)
# curl 8.23 的 FindMbedTLS 改用单数 MBEDTLS_INCLUDE_DIR
set(MBEDTLS_INCLUDE_DIR ${CURL_DEPS_TP_ROOT}/mbedtls/include CACHE PATH "" FORCE)
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
# curl 8.23 移除 HTTP_ONLY，改为逐协议开关；这里只留 HTTP(S)，与旧版协议面一致
set(CURL_DISABLE_FILE ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_FTP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_DICT ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_GOPHER ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_TELNET ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_TFTP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_IMAP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_POP3 ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_SMTP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_MQTT ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_RTSP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_WEBSOCKETS ON CACHE BOOL "" FORCE)
set(ENABLE_MANUAL OFF CACHE BOOL "" FORCE)
set(CURL_ZLIB OFF CACHE BOOL "" FORCE)
# curl 8.23 把 brotli/zstd 改为三态选项（默认 AUTO 探测），与 CURL_ZLIB 一样需显式关闭
set(CURL_BROTLI OFF CACHE STRING "" FORCE)
set(CURL_ZSTD OFF CACHE STRING "" FORCE)
set(USE_NGHTTP2 OFF CACHE BOOL "" FORCE)
set(USE_LIBIDN2 OFF CACHE BOOL "" FORCE)
add_subdirectory(${CURL_DEPS_TP_ROOT}/curl/curl-8.23.0 ${CMAKE_BINARY_DIR}/curl_build EXCLUDE_FROM_ALL)
