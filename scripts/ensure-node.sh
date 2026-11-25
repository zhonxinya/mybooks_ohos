#!/usr/bin/env bash
#
# 确保 node 可用且能直跑 harness 的 .ts 夹具（批O，建议 #1854）。
#
# 门禁/harness 都是 .mjs，且 harness 会把 .ets 转成 .ts 夹具 import——要求
# node ≥ 有 --experimental-strip-types。系统 PATH 里可能有 node 18（无此
# 特性，实测 ERR_UNKNOWN_FILE_EXTENSION ".ts"），故合格性以特性探测为准，
# 不合格时回落 ~/.nvm/versions/node 下版本号最高的一份。
#
# 用法：source scripts/ensure-node.sh（失败返回 127，调用方 set -e 即止）

mybooks_node_ok() {
  command -v node >/dev/null 2>&1 && node --experimental-strip-types -e '1' >/dev/null 2>&1
}
if ! mybooks_node_ok; then
  _MYBOOKS_NODE="$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)" || true
  if [ -n "${_MYBOOKS_NODE:-}" ]; then
    export PATH="$(dirname "$_MYBOOKS_NODE"):$PATH"
  fi
fi
if ! mybooks_node_ok; then
  echo "错误：未找到支持 --experimental-strip-types 的 node（harness 需要）。请安装 Node 或配置 nvm。" >&2
  return 127 2>/dev/null || exit 127
fi
