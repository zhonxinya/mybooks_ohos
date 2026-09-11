# Third-party libraries for talebook_core

This directory vendors open-source libraries used by the C++ NAPI module.

## sqlite (public domain)

- Version: amalgamation 3.46.1 (`sqlite-amalgamation-3460100`)
- Files: `sqlite/sqlite3.c`, `sqlite/sqlite3.h`
- License: Public Domain (https://www.sqlite.org/copyright.html)
- Usage: primary persistence for download records, history, bookmarks, KV/secure store

## curl (MIT/curl license)

- Version: 8.5.0（2023-12 发布）
- Path: `curl/curl-8.5.0/`
- License: https://curl.se/docs/copyright.html
- Build: static `libcurl` via CMake (`HTTP_ONLY`, **mbedTLS SSL backend**)
- Usage: HTTP/HTTPS client, cookies, streaming download, SoNovel SSE
- Note: 上游后续版本修复了多项低/中危问题（8.21.0 单版即修复 18 项）。建议按发布节奏
  定期评估升级，升级后需回归 HTTPS 请求 / 下载 / Cookie 会话。

## mbedtls (Apache-2.0)

- Version: 2.28.9 LTS (self-contained; curl mbedtls backend)
- Path: `mbedtls/`
- License: Apache-2.0
- Build: static `mbedtls` / `mbedx509` / `mbedcrypto`
- Usage: TLS backend for curl HTTPS
- Note: `http_client.cpp` 不再硬编码 `CURLOPT_SSL_VERIFYPEER=0`；证书校验默认开启，仅在用户显式开启
  「跳过 SSL 验证」（偏好键 `allow_insecure_ssl`）时才关闭。校验开关见 `include/http_client.h`
  的 `setSslVerify()`。

### ⚠️ 待处理项（2026-09-11 安全审计发现，均需真机 TLS 回归后处理）

1. **CVE-2025-27809（HIGH）— 客户端可能静默跳过服务器身份校验**
   - mbedtls 在客户端未调用 `mbedtls_ssl_set_hostname()` 时会跳过证书 CN/SAN 校验
     （影响所有 ≤ 2.28.9 版本）。
   - curl 的 mbedtls 后端**仅在 `peer.sni` 非空时**调用该函数
     （`curl-8.5.0/lib/vtls/mbedtls.c:642`），而 `curl-8.5.0/lib/vtls/vtls.c:1600-1602`
     对 IP 形式主机名**不设置 `sni`**。因此以 `https://<IP>:端口` 连接时（本项目自建服务端
     的常见形态），签发链会被校验但**证书主体不会被校验**。
   - 修复：升级至 **mbedtls ≥ 2.28.10**。公告：
     https://mbed-tls.readthedocs.io/en/latest/security-advisories/mbedtls-security-advisory-2025-03-1/
   - 注：`entry` 模块使用预编译 `libcurl.so`（OpenSSL 系后端，见下），**不受此条影响**。

2. **缺少 CA 信任库 — 默认开启校验时 HTTPS 无法握手**
   - 本模块未设置 `CURLOPT_CAINFO` / `CURLOPT_CAPATH`，mbedtls 亦无内置信任库，
     故签发链校验必然失败（`MBEDTLS_X509_BADCERT_NOT_TRUSTED`），
     即 `sslVerify=true`（默认）下 HTTPS 不可用，用户只能通过关闭校验使用 HTTPS。
   - 修复：随包提供 CA bundle，并设置 `CURLOPT_CAINFO`（或 `CURLOPT_CAINFO_BLOB`）。
   - ⚠️ **必须与第 1 项同时处理**：只补 CA 而不升级 mbedtls，会在 IP 场景下形成
     "看着在验签、实际不校验主体"的假安全。

## 关联：`entry` 模块的 libcurl

`ohos/entry/libs/arm64-v8a/libcurl.so` 为预编译产物（`libcurl/8.5.0-DEV`，OpenSSL 系 TLS 后端，
由 `libentry.so` 链接）。两套 native 模块**各自持有独立的 curl 与 TLS 栈**，安全策略与版本
需分别评估，不可只看其中一处。

## miniz (MIT)

- Version: 3.0.2 (headers + `miniz.c` / `miniz_tinfl.c`)
- Path: `miniz/`
- License: MIT
- Usage: raw deflate inflate for EPUB ZIP method 8 entries (`epub_parser.cpp`)

## tinyxml2 (zlib license)

- Version: 10.0.0
- Path: `tinyxml2/tinyxml2.{h,cpp}`
- License: zlib
- Status: vendored for optional EPUB OPF XML parsing; current parser uses lightweight string tags

## EPUB parsing

- Implemented in `src/main/cpp/epub_parser.cpp`
- Supports ZIP stored (method 0) and deflated (method 8) entries via miniz tinfl
- Extracts OPF metadata (title, creator, language, identifier)
- Display/reading remains HarmonyOS `@kit.ReaderKit`
