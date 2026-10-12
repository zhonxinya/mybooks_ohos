#!/usr/bin/env bash
# 无头构建 HAP（Linux / Command Line Tools，无需 DevEco Studio）
#
# 为什么要这个脚本：
#   1. `command-line-tools/bin/hvigorw` 只有执行位、没有读位（-r-x--x--x），
#      shell 无法读取脚本内容，直接跑会 `Permission denied`；改为用内置 node 直调 hvigor.js。
#   2. hvigor 启动时按 Node 规则解析 `@ohos/hvigor-ohos-plugin`，
#      该包在 SDK 的 `command-line-tools/hvigor/` 下、不在任何 node_modules 里，
#      需要造一个 NODE_PATH 垫片目录。
#   3. 构建中间产物（entry/build/**、.hvigor/cache）在不同账号下会互相不可写，
#      出现 `Failed to delete ... Permission denied`；脚本在构建前清理这些目录。
#
# 用法：
#   scripts/build-hap.sh                    # debug 构建
#   scripts/build-hap.sh release            # release 构建
#   HARMONY_SDK_ROOT=/path/to/harmony-sdk scripts/build-hap.sh
#
# 产物：ohos/entry/build/default/outputs/default/entry-default-unsigned.hap
# 注意：未签名 HAP 无法安装，签名见 README「签名」章节。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OHOS_DIR="$REPO_ROOT/ohos"
BUILD_MODE="${1:-debug}"

# 定位 harmony-sdk：显式指定 > DEVECO_SDK_HOME 上推 > 常见位置（$HOME、仓库同级）
find_sdk_root() {
  local candidates=() c
  [ -n "${HARMONY_SDK_ROOT:-}" ] && candidates+=("$HARMONY_SDK_ROOT")
  if [ -n "${DEVECO_SDK_HOME:-}" ]; then
    candidates+=("$(cd "$DEVECO_SDK_HOME/../.." 2>/dev/null && pwd || true)")
  fi
  candidates+=("$HOME/workspace/harmony-sdk" "$(dirname "$REPO_ROOT")/harmony-sdk")
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -d "$c/command-line-tools/sdk" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

if ! SDK_ROOT="$(find_sdk_root)"; then
  echo "[错误] 未找到 harmony-sdk（需含 command-line-tools/sdk）" >&2
  echo "       请用 HARMONY_SDK_ROOT=/path/to/harmony-sdk 指定。" >&2
  exit 1
fi
CLT="$SDK_ROOT/command-line-tools"

NODE="$CLT/tool/node/bin/node"
HVIGOR_JS="$CLT/hvigor/hvigor/bin/hvigor.js"
PLUGIN_DIR="$CLT/hvigor/hvigor-ohos-plugin"

for f in "$NODE" "$HVIGOR_JS" "$PLUGIN_DIR/index.js"; do
  if ! head -c 1 "$f" >/dev/null 2>&1; then
    echo "[错误] 不可读：$f" >&2
    echo "       请让 SDK 目录对当前账号可读：chmod -R a+rX \"$CLT\"" >&2
    exit 1
  fi
done

# Node 模块垫片：@ohos/hvigor-ohos-plugin 与 @ohos/hvigor
SHIM="$(mktemp -d)"
trap 'rm -rf "$SHIM"' EXIT
mkdir -p "$SHIM/@ohos"
ln -sfn "$PLUGIN_DIR" "$SHIM/@ohos/hvigor-ohos-plugin"
ln -sfn "$CLT/hvigor/hvigor" "$SHIM/@ohos/hvigor"

# 清理中间产物（构建产物，删掉会自动重建）。
# 注意：若这些目录由**另一个账号**构建过，文件属主不是你、chmod 也改不了，
# rm 会部分失败；此时最好的办法是让属主执行：
#     chmod -R a+rwX <repo>/ohos/entry/build <repo>/ohos/.hvigor
force_clean() {
  local target="$1"
  [ -e "$target" ] || return 0
  if rm -rf "$target" 2>/dev/null && [ ! -e "$target" ]; then
    return 0
  fi
  chmod -R u+rwX "$target" 2>/dev/null || true
  if rm -rf "$target" 2>/dev/null && [ ! -e "$target" ]; then
    return 0
  fi
  echo "[提示] 无法完全清除 $target（属主是其他账号）。" >&2
  echo "       请在该账号下执行：chmod -R a+rwX \"$target\"" >&2
  return 1
}

clean_ok=1
for d in "$OHOS_DIR/entry/build" "$OHOS_DIR/mybooks_core/build" \
         "$OHOS_DIR/feature/reader/build" "$OHOS_DIR/.hvigor/cache"; do
  force_clean "$d" || clean_ok=0
done
if [ "$clean_ok" -eq 0 ]; then
  echo "[错误] 中间产物不干净，构建会因权限失败。请先按上面的提示放开权限。" >&2
  exit 1
fi

export DEVECO_SDK_HOME="$CLT/sdk"
export NODE_PATH="$SHIM"

cd "$OHOS_DIR"
"$NODE" "$HVIGOR_JS" assembleHap -p product=default -p buildMode="$BUILD_MODE" --no-daemon

OUT="$OHOS_DIR/entry/build/default/outputs/default"
echo
echo "产物目录：$OUT"
ls -la "$OUT" 2>/dev/null || true
