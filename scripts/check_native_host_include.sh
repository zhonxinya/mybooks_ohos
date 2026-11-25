#!/usr/bin/env bash
#
# host 头守卫（建议 #1287）：交叉编译产物里出现 -I/usr/include 即 fail fast。
# 根因链：curl 依赖探测走 pkg-config 命中 host .pc（brotli/zstd）→
# -I/usr/include 注入编译行 → host glibc 头击穿 musl sysroot，报错形态
# （features-time64.h / bits/wordsize.h not found）完全不指向依赖开关，
# 每次都要人肉分析 FLAGS 传播链（curl 8.23 CI 排障实录）。
# 显式开关清单见 ohos/cmake/BuildCurlMbedTLS.cmake。
#
# 用法：scripts/check_native_host_include.sh [仓库根]   # 违规 exit 1
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
bad=0
while IFS= read -r ninja; do
  if grep -q -- '-I/usr/include' "$ninja"; then
    echo "错误：${ninja#"$ROOT/"} 出现 -I/usr/include（host 头污染）。" >&2
    echo "      检查 ohos/cmake/BuildCurlMbedTLS.cmake 的显式依赖开关是否被绕过" >&2
    echo "      （CURL_USE_PKGCONFIG OFF + CURL_BROTLI/CURL_ZSTD 显式 OFF）。" >&2
    bad=1
  fi
done < <(find "$ROOT/ohos" \( -path "*/.cxx/*" -o -path "*/build-android/*" \) \
  -name build.ninja 2>/dev/null)
if [ "$bad" = 0 ]; then
  echo "host 头守卫通过：无 -I/usr/include 泄漏"
fi
exit "$bad"
