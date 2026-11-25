#!/usr/bin/env bash
#
# 缺陷类扫描探针（批R，建议 #1899）
#
# 把小时自动化轮次的「定向摸排」从一次性 grep 固化成可重跑探针：
# 每类输出命中数，与上次快照 diff，**新增即提示立项**。提示型工具——
# 永远 exit 0，不阻断构建（与门禁的拦截语义区分开）。
# 排除清单吸收已确认的假阳性（轮7 摸排结论）：
#   - http:// 的 startsWith 校验形态（协议判断，不是明文端点）
#   - Map/Set 的同步 .clear()（不是 preferences 异步 API）
#   - 局域网/示例地址
#
# 用法：scripts/probe_defect_classes.sh             # 扫描 + 对比上次快照
#       scripts/probe_defect_classes.sh --update    # 扫描并覆盖快照（确立基线）

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETS="$ROOT/ohos/entry/src/main/ets"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mybooks_ohos"
SNAP="$STATE_DIR/defect_probe_snapshot.txt"

# count <grep -E 模式> [反过滤 egrep -v 模式]
count() {
  local hits
  hits=$(grep -rEn "$1" --include='*.ets' "$ETS" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:\s*(//|\*)')
  [ $# -ge 2 ] && hits=$(printf '%s\n' "$hits" | grep -vE "$2" | grep -v '^\s*$')
  printf '%s\n' "$hits" | grep -c '[^[:space:]]'
}

RESULTS="dropped_promise=$(count '\.(startAbility|terminateSelf)\(' 'await|\.then|\.catch')
empty_catch=$(count 'catch\s*\([^)]*\)\s*\{\s*\}')
cleartext_url=$(count "['\"]http://" "startsWith|indexOf\('http://'\)|192\.168|127\.0|localhost|example|schemas|w3\.org")
raw_decodeuri=$(count 'decodeURIComponent\(')"

echo "$RESULTS"
if [ -f "$SNAP" ]; then
  while IFS='=' read -r name new; do
    old=$(grep -m1 "^${name}=" "$SNAP" | cut -d= -f2)
    old=${old:-0}
    if [ "$new" -gt "$old" ]; then
      echo "⚠ 新增 $name: $old → $new（建议立项排查）"
    fi
  done <<< "$RESULTS"
else
  echo "（首次运行：无历史快照，本次结果未对比）"
fi

if [ "${1:-}" = "--update" ]; then
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$RESULTS" > "$SNAP"
  echo "快照已更新：$SNAP"
fi
exit 0
