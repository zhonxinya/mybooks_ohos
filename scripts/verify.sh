#!/usr/bin/env bash
#
# 一键全验证（批O，建议 #1854）。
#
# 目的：把「七门禁 + 门禁自测 + harness」固化成一个入口，输出逐项
# [OK]/[FAIL] 行与总退出码。此前每轮自动化凭记忆拼命令，出现过把
# harness 入口误记为 scripts/harness/run.mjs（实为 check_ai_assistant.mjs）
# 造成假失败的排查浪费。
#
# 用法：
#   scripts/verify.sh            # 门禁全量 + harness
#   scripts/verify.sh --build    # 追加完整构建链（build-hap.sh，提交 PR 前用）

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# harness 跑 .ts 夹具需 strip-types（批P 分级判据：run-gates.sh 不加此标记）
export MYBOOKS_NODE_NEED_TS=1
# shellcheck source=/dev/null
source "$ROOT/scripts/ensure-node.sh"

FAILS=0
step() {
  local name="$1"; shift
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "[OK] $name"
  else
    FAILS=$((FAILS + 1))
    echo "[FAIL] $name (exit $rc)"
  fi
}

step "门禁+自测" "$ROOT/scripts/run-gates.sh"
step "harness(check_ai_assistant.mjs)" node "$ROOT/scripts/check_ai_assistant.mjs"
if [ "${1:-}" = "--build" ]; then
  step "构建 build-hap.sh" bash "$ROOT/scripts/build-hap.sh"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "验证未通过：$FAILS 项失败"
  exit 1
fi
echo "verify.sh 全部通过"
