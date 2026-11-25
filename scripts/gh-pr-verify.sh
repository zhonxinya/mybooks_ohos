#!/usr/bin/env bash
#
# PR 合并结果核验（批T，任务 #1722 advice）
#
# 自动化 PR 闭环的手拼核验序列（merge → pr view → ls-remote）已两次踩坑：
# merge exit 0 但核验命令 GraphQL EOF（#182）、merge 报错但实际成功（#1816）。
# 本脚本把「以远端真实状态为准」的核验合一，供每轮 merge 后直接调用：
#   1) gh pr view 重试 3 次拿 state/mergeCommit（EOF 假失败不等于未合并）；
#   2) main 的 ls-remote SHA 必须等于 mergeCommit；
#   3) 传了 head 分支则要求远端该分支已删（--delete-branch 生效证明）。
#
# 用法：scripts/gh-pr-verify.sh <PR号> [head分支]
#   exit 0=已合并且远端一致；1=未合并/不一致/查询失败；2=参数错误

set -uo pipefail
REPO="zhonxinya/mybooks_ohos"
WWW="https://www.github.com/$REPO"

PR="${1:-}"
HEAD_BRANCH="${2:-}"
case "$PR" in
  '' | *[!0-9]*) echo "用法：$0 <PR号> [head分支]" >&2; exit 2 ;;
esac

VIEW=""
for i in 1 2 3; do
  VIEW="$(gh pr view "$PR" --repo "$REPO" --json state,mergeCommit 2>/dev/null)" && break
  echo "第 $i 次 pr view 失败（EOF 类假失败常见），${i}0s 后重试…" >&2
  sleep "$((i * 10))"
done
[ -n "$VIEW" ] || { echo "错误：gh pr view $PR 三次均失败" >&2; exit 1; }

STATE="$(printf '%s' "$VIEW" | sed -n 's/.*"state":"\([A-Z_]*\)".*/\1/p')"
MC="$(printf '%s' "$VIEW" | sed -n 's/.*"mergeCommit":{"oid":"\([a-f0-9]*\)".*/\1/p')"
if [ "$STATE" != "MERGED" ]; then
  echo "未合并：PR #$PR state=$STATE" >&2
  exit 1
fi
echo "PR #$PR MERGED，mergeCommit=$MC"

MAIN_SHA="$(git ls-remote "$WWW" refs/heads/main 2>/dev/null | awk '{print $1}')"
if [ -z "$MAIN_SHA" ]; then
  echo "错误：ls-remote main 查询失败" >&2
  exit 1
fi
if [ "$MAIN_SHA" != "$MC" ]; then
  echo "错误：main SHA 与 mergeCommit 不符 main=$MAIN_SHA merge=$MC" >&2
  exit 1
fi
echo "main 已指向合并提交：$MAIN_SHA"

if [ -n "$HEAD_BRANCH" ]; then
  HEAD_SHA="$(git ls-remote "$WWW" "refs/heads/$HEAD_BRANCH" 2>/dev/null | awk '{print $1}')"
  if [ -n "$HEAD_SHA" ]; then
    echo "警告：远端分支 $HEAD_BRANCH 仍存在（$HEAD_SHA）——delete-branch 未生效" >&2
    exit 1
  fi
  echo "远端分支 $HEAD_BRANCH 已删除"
fi
echo "核验通过：PR #$PR"
