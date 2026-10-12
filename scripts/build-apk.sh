#!/usr/bin/env bash
#
# 构建 Android APK（ArkUI-X / ACE Tools）。
#
# 依赖：ArkUI-X SDK（内含 ACE Tools）+ Android SDK/NDK + JDK 11+
# 获取 ArkUI-X SDK：DevEco Studio → Settings → ArkUI-X，或从 ArkUI-X Release Notes 下载。
#
# 用法：
#   scripts/build-apk.sh              # debug APK
#   scripts/build-apk.sh release      # release APK
#
# 环境变量：
#   ARKUI_X_SDK    ArkUI-X SDK 根目录（含 arkui-x.json 的上一级）
#   ANDROID_HOME   Android SDK 根目录
#
set -euo pipefail

MODE="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/ohos"

# shellcheck source=/dev/null
[ -f "$ROOT/scripts/android-env.sh" ] && source "$ROOT/scripts/android-env.sh"

command -v ace >/dev/null 2>&1 || {
  echo "错误：未找到 ace 命令（ACE Tools）。" >&2
  echo "请先安装 ArkUI-X SDK 并将其 toolchains 加入 PATH，或在 scripts/android-env.sh 中配置。" >&2
  exit 1
}

cd "$APP_DIR"

if [ "$MODE" = "release" ]; then
  echo "==> 构建 release APK"
  ace build apk --mode release
else
  echo "==> 构建 debug APK"
  ace build apk
fi

APK_DIR="$APP_DIR/build/default/outputs/arkui-x"
echo
echo "构建完成，产物目录：$APK_DIR"
find "$APK_DIR" -name '*.apk' -print 2>/dev/null || echo "（未找到 APK，请检查上方构建日志）"
