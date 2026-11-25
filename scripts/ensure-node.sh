#!/usr/bin/env bash
#
# 确保 node 可用（批O，建议 #1854；批P 判据分级）。
#
# 默认判据=「node 在位」：门禁 .mjs 是纯 ESM，CI 的 setup-node 18 就能跑。
# 严格判据=支持 `--experimental-strip-types`：harness 会把 .ets 转 .ts 夹具
# import，系统 node18「在位」但跑不了（实测 ERR_UNKNOWN_FILE_EXTENSION）。
# 调用方 source 前 export MYBOOKS_NODE_NEED_TS=1 选严格判据；两种判据不满足
# 时都回落 ~/.nvm/versions/node 下版本号最高的一份。
#
# 用法：source scripts/ensure-node.sh（失败返回 127，调用方 set -e 即止）

mybooks_node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  if [ "${MYBOOKS_NODE_NEED_TS:-0}" = "1" ]; then
    node --experimental-strip-types -e '1' >/dev/null 2>&1
  fi
}
if ! mybooks_node_ok; then
  _MYBOOKS_NODE="$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)" || true
  if [ -n "${_MYBOOKS_NODE:-}" ]; then
    export PATH="$(dirname "$_MYBOOKS_NODE"):$PATH"
  fi
fi
if ! mybooks_node_ok; then
  if [ "${MYBOOKS_NODE_NEED_TS:-0}" = "1" ]; then
    echo "错误：未找到支持 --experimental-strip-types 的 node（harness 夹具需要）。请安装 Node 或配置 nvm。" >&2
  else
    echo "错误：未找到 node（门禁脚本需要）。请安装 Node 或配置 nvm。" >&2
  fi
  return 127 2>/dev/null || exit 127
fi
