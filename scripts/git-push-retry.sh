#!/usr/bin/env bash
#
# 推送分支并核实（批S，建议 #1286）
#
# 固化 PR 工作流里的 push 重试循环。两个历史上的坑都收在这里：
# 1) 末次失败错误码必须显式收口——`for i in 1..3; do push && break; done`
#    形态若末次 push 失败，循环退出码来自 break 判断（0），看起来像成功；
# 2) push「成功」不等于远端到位（假象 Everything up-to-date / 通道不同步），
#    一律以 `git ls-remote` 回读远端 SHA == 本地 SHA 为准（#1487：推送走
#    www.github.com 直连，origin 被 insteadOf 改写到 gh-proxy 镜像）。
#
# 用法：scripts/git-push-retry.sh <branch>
#   exit 0=远端已核到该 SHA；1=三轮全挂或核实不符；2=参数/分支错误

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BRANCH="${1:-}"
[ -n "$BRANCH" ] || { echo "用法：$0 <branch>" >&2; exit 2; }
LOCAL_SHA="$(git rev-parse --verify "$BRANCH" 2>/dev/null)" || {
  echo "错误：本地分支 $BRANCH 不存在" >&2; exit 2; }

WWW="https://www.github.com/zhonxinya/mybooks_ohos"
PUSH_LOG="$(mktemp -t git-push-retry-XXXXXX.log)"
PUSHED=0
for i in 1 2 3; do
  if git push "$WWW" "$BRANCH" >"$PUSH_LOG" 2>&1; then
    PUSHED=1; echo "第 $i 轮：www 直连推送成功"; break
  fi
  echo "第 $i 轮：www 直连失败，重试 origin …" >&2
  if git push origin "$BRANCH" >>"$PUSH_LOG" 2>&1; then
    PUSHED=1; echo "第 $i 轮：origin 通道推送成功"; break
  fi
  sleep 3
done
if [ "$PUSHED" -ne 1 ]; then
  echo "错误：三通道轮全挂，末次错误输出：" >&2
  tail -5 "$PUSH_LOG" >&2
  rm -f "$PUSH_LOG"
  exit 1
fi
rm -f "$PUSH_LOG"

REMOTE_SHA="$(git ls-remote "$WWW" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')"
if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
  echo "错误：远端核实不符 local=$LOCAL_SHA remote=${REMOTE_SHA:-<空>}" >&2
  exit 1
fi
echo "推送并核实一致：$BRANCH = $LOCAL_SHA"
