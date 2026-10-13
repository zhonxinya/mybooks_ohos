# ArkUI-X Android 环境配置示例
#
# 用法：复制为 android-env.sh 后按本机实际情况填写，然后 build-apk.sh 会自动加载。
#       该文件可能含本机绝对路径，建议加入 .gitignore（默认已忽略 scripts/android-env.sh）。
#
# 注意：本文件在 Bash 侧加载，只能用 POSIX 语法，不要写 PowerShell。

# ---- ArkUI-X SDK ----
# 目录结构要求（ACE Tools 的默认布局）：
#   $ARKUI_X_SDK/<versioncode>/arkui-x/{engine,plugins,toolchains,arkui-x.json}
# 例：$HOME/Library/ArkUI-X/Sdk/60/arkui-x/...
export ARKUI_X_SDK="${ARKUI_X_SDK:-$HOME/ArkUI-X/Sdk}"

# ACE Tools 可执行文件在 SDK 的 toolchains 下
if [ -d "$ARKUI_X_SDK" ]; then
  ACE_BIN="$(find "$ARKUI_X_SDK" -type d -name toolchains -maxdepth 4 2>/dev/null | head -1)"
  [ -n "$ACE_BIN" ] && export PATH="$ACE_BIN:$PATH"
fi

# ---- Android SDK ----
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# NDK：编译 mybooks_core 的 C++（curl/cJSON/mbedTLS/SQLite/miniz）需要
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/26.1.10909125}"

# ---- JDK ----
# ArkTS 工具链要求 JDK 11+；若本机有多个版本，在此指定
# export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# ---- 产物 ----
export ARKUI_X_OUT="$ARKUI_X_SDK"
