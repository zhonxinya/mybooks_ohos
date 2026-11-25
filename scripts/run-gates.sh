#!/usr/bin/env bash
#
# 全部门禁检查的唯一入口（批O，建议 #1854）。
#
# 门禁清单以 gates_selftest.mjs 的 GATES 数组为**唯一来源**（--list 导出），
# 新增门禁只需改那个数组——本脚本与 selftest 自动覆盖，不再逐处抄列表。
#
# 用法：scripts/run-gates.sh              # 逐个 --gate + selftest，任一失败 exit 1
#       scripts/run-gates.sh --only routes  # 只跑名字含 routes 的门禁（--gate+--selftest），
#                                          # 供 CI rerun 快速定位；模式名打错即报错不静默放行

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/ensure-node.sh"

ONLY=""
if [ "${1:-}" = "--only" ]; then
  ONLY="${2:-}"
  [ -n "$ONLY" ] || { echo "错误：--only 需要模式参数（如 --only check_routes.mjs 或 --only routes）" >&2; exit 2; }
fi

FAILS=0
mapfile -t GATES < <(node "$ROOT/scripts/gates_selftest.mjs" --list)

if [ -n "$ONLY" ]; then
  MATCHED=()
  for g in "${GATES[@]}"; do
    [[ "$g" == *"$ONLY"* ]] && MATCHED+=("$g")
  done
  if [ "${#MATCHED[@]}" -eq 0 ]; then
    echo "错误：--only $ONLY 未匹配任何门禁（清单：${GATES[*]}）" >&2
    exit 2
  fi
  for g in "${MATCHED[@]}"; do
    if node "$ROOT/scripts/$g" --gate && node "$ROOT/scripts/$g" --selftest; then
      echo "[OK] $g (gate+selftest)"
    else
      FAILS=$((FAILS + 1))
      echo "[FAIL] $g"
    fi
  done
  if [ "$FAILS" -ne 0 ]; then
    echo "门禁未通过：--only $ONLY 命中 ${#MATCHED[@]} 项，$FAILS 项失败"
    exit 1
  fi
  echo "门禁通过（--only $ONLY：${#MATCHED[@]} 项 gate+selftest）"
  exit 0
fi

for g in "${GATES[@]}"; do
  if node "$ROOT/scripts/$g" --gate; then
    echo "[OK] $g"
  else
    FAILS=$((FAILS + 1))
    echo "[FAIL] $g"
  fi
done
if node "$ROOT/scripts/gates_selftest.mjs"; then
  echo "[OK] gates_selftest.mjs"
else
  FAILS=$((FAILS + 1))
  echo "[FAIL] gates_selftest.mjs"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "门禁未通过：$FAILS 项失败"
  exit 1
fi
echo "门禁全部通过（${#GATES[@]} 项 + selftest）"
