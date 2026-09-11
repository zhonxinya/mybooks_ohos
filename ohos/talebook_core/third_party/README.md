# Third-party libraries for talebook_core

This directory vendors open-source libraries used by the C++ NAPI module.

## sqlite (public domain)

- Version: amalgamation 3.46.1 (`sqlite-amalgamation-3460100`)
- Files: `sqlite/sqlite3.c`, `sqlite/sqlite3.h`
- License: Public Domain (https://www.sqlite.org/copyright.html)
- Usage: primary persistence for download records, history, bookmarks, KV/secure store

## curl (MIT/curl license)

- Version: 8.5.0
- Path: `curl/curl-8.5.0/`
- License: https://curl.se/docs/copyright.html
- Build: static `libcurl` via CMake (`HTTP_ONLY`, **mbedTLS SSL backend**)
- Usage: HTTP/HTTPS client, cookies, streaming download, SoNovel SSE

## mbedtls (Apache-2.0)

- Version: 2.28.9 LTS (self-contained; curl mbedtls backend)
- Path: `mbedtls/`
- License: Apache-2.0
- Build: static `mbedtls` / `mbedx509` / `mbedcrypto`
- Usage: TLS backend for curl HTTPS
- Note: `http_client.cpp` currently sets `CURLOPT_SSL_VERIFYPEER=0` for private/self-signed servers; set CA via `CURLOPT_CAINFO` for production verify.

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
