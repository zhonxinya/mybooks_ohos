#!/usr/bin/env bash
#
# 构建 HarmonyOS HAP（ArkUI-X / ACE Tools 工具链）。
#
# 与 build-apk.sh 共用同一套 ACE Tools，只是 target 不同（hap=HarmonyOS，apk=Android）。
# 说明：`ace modify` 已把本工程切为 ArkUI-X 工程结构（hvigorfile.ts 使用 ArkUI-X 任务类），
#       因此 HAP 同样走 ace；直接用裸 hvigorw 会因缺少跨端配置而失败。
#
# 依赖：ArkUI-X SDK + 鸿蒙工具链 + JDK 11+（均见 scripts/android-env.sh）
#
# 用法：
#   scripts/build-hap.sh              # debug HAP
#   scripts/build-hap.sh release      # release HAP
#
# 产物：ohos/entry/build/default/outputs/default/entry-default-unsigned.hap
set -euo pipefail

MODE="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/ohos"

# shellcheck source=/dev/null
if [ -f "$ROOT/scripts/android-env.sh" ]; then
  source "$ROOT/scripts/android-env.sh"
else
  echo "错误：缺少 scripts/android-env.sh（可从 android-env.example.sh 复制并填写路径）。" >&2
  exit 1
fi

command -v ace >/dev/null 2>&1 || {
  echo "错误：未找到 ace 命令（ACE Tools）。请检查 scripts/android-env.sh 中的 ARKUI_X_SDK。" >&2
  exit 1
}

cd "$APP_DIR"

if [ "$MODE" = "release" ]; then
  echo "==> 构建 release HAP（target: HarmonyOS）"
  ace build hap --release
else
  echo "==> 构建 debug HAP（target: HarmonyOS）"
  ace build hap --debug
fi

OUT="$APP_DIR/entry/build/default/outputs/default"
echo
echo "构建完成，产物目录：$OUT"
find "$OUT" -name '*.hap' -print 2>/dev/null || echo "（未找到 HAP，请检查上方构建日志）"
