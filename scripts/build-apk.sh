#!/usr/bin/env bash
#
# 构建 Android APK（ArkUI-X / ACE Tools 工具链）。
#
# 与 build-hap.sh 共用同一套 ACE Tools，只是 target 不同（apk=Android，hap=HarmonyOS）。
#
# 依赖：ArkUI-X SDK（内含 ACE Tools）+ Android SDK/NDK + JDK 17（Gradle 7.5 不支持 JDK 21），
#       均见 scripts/android-env.sh。
#
# 用法：
#   scripts/build-apk.sh              # release APK（ace 默认 release）
#   scripts/build-apk.sh debug        # debug APK
#
set -euo pipefail

MODE="${1:-release}"
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

if [ "$MODE" = "debug" ]; then
  echo "==> 构建 debug APK（target: Android）"
  ace build apk --debug
else
  echo "==> 构建 release APK（target: Android）"
  ace build apk --release
fi

# ace 把 gradle 产物放在 .arkui-x/android/app/build/outputs/apk/<buildType>/
OUT="$APP_DIR/.arkui-x/android/app/build/outputs/apk"
echo
echo "构建完成，产物目录：$OUT"
find "$OUT" -name '*.apk' -print 2>/dev/null || echo "（未找到 APK，请检查上方构建日志）"
