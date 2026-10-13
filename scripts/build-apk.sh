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
#   scripts/build-apk.sh                    # release APK（arm64）
#   scripts/build-apk.sh release x86_64     # 模拟器用（x86_64）
#   scripts/build-apk.sh debug
#
# 为什么要在本脚本里单独交叉编译原生模块：
#   ace 的 APK 流程会用**鸿蒙工具链**编我们的 C++（.cxx 缓存 CMAKE_SYSTEM_NAME=OHOS），
#   产出的 libentry.so 链的是 libace_napi.z.so / libhilog_ndk.z.so——Android 上 dlopen 必失败
#   （页面空白）。故这里用 NDK 重新交叉编译各模块（CMakeLists 的 Android 分支改为链接
#   引擎库 libarkui_android.so），并把 .so 直接放进 gradle 的 jniLibs（app/libs/<abi>/）。
set -euo pipefail

MODE="${1:-release}"
TARGET_ARCH="${2:-}"

case "$MODE" in
  debug | release | "") ;;
  *)
    TARGET_ARCH="$MODE"
    MODE="release"
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/ohos"
ANDROID_DIR="$APP_DIR/.arkui-x/android"

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

# ---- ace 的 target-platform ↔ NDK ABI ↔ 引擎库目录 ----
case "$TARGET_ARCH" in
  "" | arm64)
    ACE_PLATFORM=""
    ABI="arm64-v8a"
    ENGINE_SUBDIR="android-arm64-release"
    ;;
  arm)
    ACE_PLATFORM="arm"
    ABI="armeabi-v7a"
    ENGINE_SUBDIR="android-arm-release"
    ;;
  x86_64)
    ACE_PLATFORM="x86_64"
    ABI="x86_64"
    ENGINE_SUBDIR="android-x86_64"
    ;;
  *)
    echo "错误：不支持的 target-platform：$TARGET_ARCH（可选 arm / arm64 / x86_64）" >&2
    exit 1
    ;;
esac

: "${ANDROID_NDK_HOME:?需要在 scripts/android-env.sh 中设置 ANDROID_NDK_HOME}"
NDK_TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
ENGINE_LIB="$ARKUI_X_SDK/24/arkui-x/engine/lib/arkui/$ENGINE_SUBDIR/libarkui_android.so"
[ -f "$NDK_TOOLCHAIN" ] || { echo "错误：找不到 NDK 工具链 $NDK_TOOLCHAIN" >&2; exit 1; }
[ -f "$ENGINE_LIB" ] || { echo "错误：找不到引擎库 $ENGINE_LIB" >&2; exit 1; }

# ---- 1) NDK 交叉编译原生模块（Android 目标），产物进 gradle jniLibs ----
JNI_ABI_DIR="$ANDROID_DIR/app/libs/$ABI"
mkdir -p "$JNI_ABI_DIR"

build_native_module() {
  local MOD="$1"
  local NAME="$2"
  local SRC="$3"
  local BUILD="$ROOT/ohos/build-android/$MOD/$ABI"
  echo "==> [$ABI] 编译原生模块 $NAME"
  # Android 用 c++_static：ArkUI-X 引擎自带 libc++ 的命名空间是 std::__n1（OHOS 风格），
  # 而 NDK 编出的是 std::__ndk1，二者不兼容（同一进程无法共用一个 libc++_shared.so）。
  # 静态链接后我们的模块自包含，引擎照旧用它的 libc++_shared。
  if [ -f "$BUILD/CMakeCache.txt" ] && ! grep -q '^ANDROID_STL:.*=c++_static$' "$BUILD/CMakeCache.txt"; then
    rm -rf "$BUILD"
  fi
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM=android-26 \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DARKUIX_ANDROID_ENGINE_LIB="$ENGINE_LIB" >/dev/null
  cmake --build "$BUILD" -j "$(nproc)" >/dev/null
  local SO
  SO="$(find "$BUILD" -name "$NAME" -type f | head -n 1)"
  [ -n "$SO" ] || { echo "错误：未找到产物 $NAME" >&2; exit 1; }
  cp -f "$SO" "$JNI_ABI_DIR/"
  echo "    -> $JNI_ABI_DIR/$NAME"
}

build_native_module mybooks_core libmybooks_core.so "$APP_DIR/mybooks_core/src/main/cpp"
build_native_module entry libentry.so "$APP_DIR/entry/src/main/cpp"

# ---- 1b) 补拷 ArkUI-X 插件库 ----
# ace 只拷贝「它识别到」的插件 .so；经实测（日志 `moduleName:X ... libX.so not found`），
# Kit 形式导入的模块会漏拷，其中 promptaction（toast）在 SDK 里存在，补进 jniLibs 即生效。
# 注：batteryinfo / displaysync / wantagent / avsession / backgroundtaskmanager 在
# ArkUI-X 6.1.1 SDK 中**不存在**（非打包问题），需在 ArkTS 侧做运行期降级。
PLUGIN_LIBS=(
  "promptaction/libpromptaction.so"
)
for rel in "${PLUGIN_LIBS[@]}"; do
  src="$ARKUI_X_SDK/24/arkui-x/plugins/api/lib/$rel"
  # 插件目录名与引擎库目录名一致（android-arm64-release / android-arm-release / android-x86_64）
  src_abi="$(dirname "$src")/$ENGINE_SUBDIR/$(basename "$src")"
  if [ -f "$src_abi" ]; then
    cp -f "$src_abi" "$JNI_ABI_DIR/"
    echo "    -> 插件 $JNI_ABI_DIR/$(basename "$src")"
  else
    echo "    警告：SDK 中未找到插件库 $src_abi（跳过）" >&2
  fi
done

# ---- 2) ace 打包（编译 ArkTS + gradle 组装 APK，jniLibs 取上一步的产物）----
cd "$APP_DIR"
ACE_ARGS=(build apk)
if [ "$MODE" = "debug" ]; then
  echo "==> 构建 debug APK（target: Android / $ABI）"
  ACE_ARGS+=(--debug)
else
  echo "==> 构建 release APK（target: Android / $ABI）"
  ACE_ARGS+=(--release)
fi
if [ -n "$ACE_PLATFORM" ]; then
  ACE_ARGS+=(--target-platform "$ACE_PLATFORM")
fi

ace "${ACE_ARGS[@]}"

OUT="$ANDROID_DIR/app/build/outputs/apk/$MODE"
echo
echo "构建完成，产物目录：$OUT"
find "$OUT" -name '*.apk' -print 2>/dev/null || echo "（未找到 APK，请检查上方构建日志）"
