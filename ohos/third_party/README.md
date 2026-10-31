# Third-party libraries (shared by native modules)

`ohos/third_party/` 为两个 native 模块共用的第三方库根目录：

| 使用方 | 模块 | 取自本目录 |
|---|---|---|
| `libentry.so` | `ohos/entry/src/main/cpp/` | `cjson/`、`curl/include/`（配预编译 `libcurl.so`） |
| `libmybooks_core.so` | `ohos/mybooks_core/src/main/cpp/` | `sqlite/`、`curl/curl-8.23.0/`、`mbedtls/`、`miniz/` |

两处 CMake 均以 `${NATIVERENDER_ROOT_PATH}/../../../../third_party` 指向本目录。

## cjson (MIT)

- Version: v1.7.19
- Files: `cjson/cJSON.c`, `cjson/cJSON.h`
- License: MIT (https://github.com/DaveGamble/cJSON/blob/master/LICENSE)
- Usage: `entry` 模块的 JSON 读写（preferences / secure storage / `talebook_api.cpp` / `sonovel_api.cpp`）
- 更新：

```bash
curl -o cjson/cJSON.c https://raw.githubusercontent.com/DaveGamble/cJSON/master/cJSON.c
curl -o cjson/cJSON.h https://raw.githubusercontent.com/DaveGamble/cJSON/master/cJSON.h
```

## curl headers for entry (curl license)

- Version: 8.23.0（`curl/include/curl/curlver.h`，随源码版同步）
- Path: `curl/include/`
- Usage: `libentry.so` 的编译期头文件，链接 `ohos/entry/libs/arm64-v8a/libcurl.so`
- ⚠️ 既有不一致：头文件自报 8.23.0，而预编译 `.so` 自报 `libcurl/8.5.0-DEV`（OpenSSL 后端）。
  `entry` 用到的 `CURLOPT_*` 全部 ≤ 7.85（`CURLOPT_PROTOCOLS_STR`），在该 `.so` 中均存在；
  替换预编译 `.so` 前仍需回归 HTTPS 请求 / 下载 / Cookie 会话。

## sqlite (public domain)

- Version: amalgamation 3.54.1 (`sqlite-amalgamation-3540100`)
- Files: `sqlite/sqlite3.c`, `sqlite/sqlite3.h`
- License: Public Domain (https://www.sqlite.org/copyright.html)
- Usage: primary persistence for download records, history, bookmarks, KV/secure store
- 升级记录：3.46.1 → 3.54.1（2026-10-16），修 CVE-2025-6965 / CVE-2025-29087 / CVE-2025-70873

## curl source (MIT/curl license)

- Version: 8.23.0（2026-10-14 发布，最新稳定版）
- Path: `curl/curl-8.23.0/`（全量源码；`curl/curl.tar.gz` 为上游归档，构建不使用）
- License: https://curl.se/docs/copyright.html
- Build: static `libcurl` via CMake（**mbedTLS SSL backend**）
- Usage: HTTP/HTTPS client, cookies, streaming download, SoNovel SSE
- 升级记录：8.5.0 → 8.23.0（2026-10-31）。8.5.0 命中 55 条 curl 安全公告
  （14 Medium / 41 Low），本次一并清除（含 CVE-2024-0853 OCSP 绕过、CVE-2024-2398
  HTTP/2 push 泄漏、CVE-2025-0725 gzip 整数溢出、CVE-2026-92392 HTTP/2 上传 UAF）。
- ⚠️ 构建层变更（升级时同步改过）：
  1. curl ≥ 8.18.0 要求 mbedTLS ≥ 3.2.0（`CMakeLists.txt` 有 `FATAL_ERROR`），故本次与
     mbedTLS 3.6.7 捆绑升级，二者不可再单独升。
  2. 8.23 移除 `HTTP_ONLY` 选项，改为逐协议 `CURL_DISABLE_*`；本工程显式关掉
     FILE/FTP/DICT/GOPHER/TELNET/TFTP/IMAP/POP3/SMTP/MQTT/RTSP/WEBSOCKETS，保持原有 HTTP(S) 协议面。
  3. `CMake/FindMbedTLS.cmake` 由 `MBEDTLS_INCLUDE_DIRS` 改为单数 `MBEDTLS_INCLUDE_DIR`，
     两处 CMakeLists 均已补预置，否则报 `Could NOT find MbedTLS (missing: MBEDTLS_INCLUDE_DIR)`。
- 注：curl 的 mbedTLS 后端自 8.7 起无条件调用 `mbedtls_ssl_set_hostname()`
  （`lib/vtls/mbedtls.c:995`，sni 为空时回退 `peer.hostname`），CVE-2024-2466 已在上游修复，
  本地补丁随之移除。

## mbedtls (Apache-2.0)

- Version: 3.6.7 LTS (self-contained; curl mbedtls backend)
- Path: `mbedtls/`
- License: Apache-2.0
- Build: static `mbedtls` / `mbedx509` / `mbedcrypto`
- Usage: TLS backend for curl HTTPS
- Note: `http_client.cpp` 不再硬编码 `CURLOPT_SSL_VERIFYPEER=0`；证书校验默认开启，仅在用户显式开启
  「跳过 SSL 验证」（偏好键 `allow_insecure_ssl`）时才关闭。校验开关见 `include/http_client.h`
  的 `setSslVerify()`。

### 已处理的历史安全项

1. **CVE-2025-27809 / CVE-2025-27810（HIGH）— 客户端可能静默跳过服务器身份校验**
   - mbedtls 在客户端未调用 `mbedtls_ssl_set_hostname()` 时会跳过证书 CN/SAN 校验
     （影响所有 ≤ 2.28.9 版本）。
   - curl 的 mbedtls 后端**仅在 `peer.sni` 非空时**调用该函数
     （`curl-8.5.0/lib/vtls/mbedtls.c:642`），而 `curl-8.5.0/lib/vtls/vtls.c:1600-1602`
     对 IP 形式主机名**不设置 `sni`**。因此以 `https://<IP>:端口` 连接时（本项目自建服务端
     的常见形态），签发链会被校验但**证书主体不会被校验**。
   - **状态：已修复（2026-10-29）**。mbedtls 升至 2.28.10；同时把 curl 的
     `set_hostname` 调用改为无条件（sni 为空时回退 `peer.hostname`），即上游
     CVE-2024-2466 修复。
   - 注：`entry` 模块使用预编译 `libcurl.so`（OpenSSL 系后端，见下），**不受此条影响**。

2. **缺少 CA 信任库 — 默认开启校验时 HTTPS 无法握手**（**未处理，仍待办**）
   - 本模块未设置 `CURLOPT_CAINFO` / `CURLOPT_CAPATH`，mbedtls 亦无内置信任库，
     故签发链校验必然失败（`MBEDTLS_X509_BADCERT_NOT_TRUSTED`），
     即 `sslVerify=true`（默认）下 HTTPS 不可用，用户只能通过关闭校验使用 HTTPS。
   - 修复：随包提供 CA bundle，并设置 `CURLOPT_CAINFO`（或 `CURLOPT_CAINFO_BLOB`）。
   - ✅ **iPAddress SAN 限制已解除**：mbedTLS 3.6.7 的 `x509_crt_check_san()` 已匹配
     `MBEDTLS_X509_SAN_IP_ADDRESS`（`library/x509_crt.c:2924`），`https://<IP>` + 仅 IP SAN
     的证书可正常通过主体校验（2.28.x 会以 `BADCERT_CN_MISMATCH` 失败）。

## 关联：`entry` 模块的 libcurl

`ohos/entry/libs/arm64-v8a/libcurl.so` 为预编译产物（`libcurl/8.5.0-DEV`，OpenSSL 系 TLS 后端，
由 `libentry.so` 链接，头文件见上文 `curl/include/`）。

⚠️ 本目录虽已共用，但两套 native 模块仍**各自持有独立的 curl 与 TLS 栈**
（`entry` 用预编译 `.so` + OpenSSL 后端；`mybooks_core` 用 8.23.0 源码静态编译 + mbedTLS 3.6.7 后端），
安全策略与版本需**分别评估**，不可只看其中一处。

## miniz (MIT)

- Version: 3.1.2（`miniz.h` 的 `MZ_VERSION` 宏；README 旧记录 3.0.2 为笔误，实际文件头即 3.1.2）
- Path: `miniz/`
- License: MIT
- Usage: raw deflate inflate for EPUB ZIP method 8 entries (`epub_parser.cpp`)

## tinyxml2 (zlib license)

- Version: 11.0.0
- Path: `tinyxml2/tinyxml2.{h,cpp}`
- License: zlib
- Status: vendored for optional EPUB OPF XML parsing; current parser uses lightweight string tags
- 升级记录：10.0.0 → 11.0.0（2025-03-15），修 CVE-2024-50615（字符编码解析越界）；
  含 10.1.0 起 `int` → `size_t` 的内部字段变更（对象大小变化，API 不变）
- 注：当前未接入 CMake 编译（`grep tinyxml2 --include=CMakeLists.txt` 无匹配），仅作可选依赖保留

## EPUB parsing

- Implemented in `src/main/cpp/epub_parser.cpp`
- Supports ZIP stored (method 0) and deflated (method 8) entries via miniz tinfl
- Extracts OPF metadata (title, creator, language, identifier)
- Display/reading remains HarmonyOS `@kit.ReaderKit`
