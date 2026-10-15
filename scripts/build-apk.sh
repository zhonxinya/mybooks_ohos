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
  # 阅读器分页依赖文本测量与字体插件：缺 measure 会抛
  # `Cannot read property measureTextSize of undefined`（正文排版失败）
  "measure/libmeasure.so"
  "font/libfont.so"
  # ArkUI 组件扩展（部分组件/绘制描述符在 Kit 导入路径下漏拷）
  "arkui/libarkui_componentutils.so"
  "arkui/libarkui_drawabledescriptor.so"
  "arkui/liboverlay.so"
)
for rel in "${PLUGIN_LIBS[@]}"; do
  src="$ARKUI_X_SDK/24/arkui-x/plugins/api/lib/$rel"
  # 插件目录名与引擎库目录名一致（android-arm64-release / android-arm-release / android-x86_64）
  src_abi="$(dirname "$src")/$ENGINE_SUBDIR/$(basename "$src")"
  if [ -f "$src_abi" ]; then
    cp -f "$src_abi" "$JNI_ABI_DIR/"
    echo "    -> 插件 $JNI_ABI_DIR/$(basename "$src")"
  else
    # 以前只是警告后跳过，结果换 SDK 后整条能力静默消失（功能还在，只是不再被拷进包）
    echo "错误：SDK 中找不到 PLUGIN_LIBS 中的插件库 $src_abi" >&2
    echo "      该 ABI 为 $ABI；若 SDK 调整了目录布局，请同步修本脚本。" >&2
    exit 1
  fi
done

# ---- 1c) 叠加 Android 壳工程补丁（provider / 权限 / 版本号 / 签名）----
# 应用内升级依赖这些补丁，必须在 gradle 打包前落地
bash "$ROOT/scripts/android-shell-overlay.sh"

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

ACE_LOG="$(mktemp -t ace-apk-XXXXXX.log)"
set +e
ace "${ACE_ARGS[@]}" 2>&1 | tee "$ACE_LOG"
ACE_STATUS="${PIPESTATUS[0]}"
set -e
# ace 在 ArkTS 编译失败时**仍返回 0**（实测：日志里是 `COMPILE RESULT:FAIL`，退出码为 0），
# 于是后续校验会在上一次的旧 APK 上「通过」——等于把坏构建放行，故这里显式判失败。
if [ "$ACE_STATUS" -ne 0 ] || grep -q 'COMPILE RESULT:FAIL' "$ACE_LOG"; then
  echo "错误：APK 构建失败（ace 退出码 $ACE_STATUS），完整日志：$ACE_LOG" >&2
  exit 1
fi
rm -f "$ACE_LOG"

OUT="$ANDROID_DIR/app/build/outputs/apk/$MODE"

# ---- 3) 校验插件库真的进了 APK ----
# 目的：ace 漏拷插件 .so 时功能是「静默失效」——包里没这个库，只有 logcat 里能看到
# `libX.so not found`（历史事故：promptaction / measure / font）。
# 这里做两道核对，任一不满足即失败：
#   a) PLUGIN_LIBS 里每个库都在 APK 内（含拷贝成功但 gradle 没打进去的情况）；
#   b) 源码中以 `import { x } from '@kit.*'` 导入、且 x 恰好与某个插件库同名
#      （如 promptAction→libpromptaction.so）的库也在 APK 内。
#   为什么限定「小写开头 + 精确同名」两个条件：小写开头可排除 `Configuration` 这类
#   ArkTS 类型（它们来自同名系统库、不需要插件）；精确匹配可排除模糊匹配的误伤
#   （`common` → libcommoneventmanager、`media` → libmediaquery 都是假阳性）。
#   代价是覆盖不全：`picker` → libfile_picker 这类改名映射查不到，仍需以 logcat 为准。
SDK_PLUGIN_LIBS="$(find "$ARKUI_X_SDK/24/arkui-x/plugins/api/lib" -path "*${ENGINE_SUBDIR}*" \
  -name '*.so' -printf '%f\n' 2>/dev/null | sort -u)"
APK_FILE="$(find "$OUT" -name '*.apk' -print 2>/dev/null | head -n 1)"
[ -n "$APK_FILE" ] || { echo "错误：未找到 APK 产物（$OUT）" >&2; exit 1; }
APK_LIBS="$(unzip -l "$APK_FILE" | grep -oE "lib/$ABI/lib[^ ]*\.so" | sed 's#.*/##' | sort -u)"

require_in_apk() {
  local lib="$1"
  local why="$2"
  if ! grep -qx "$lib" <<<"$APK_LIBS"; then
    echo "错误：APK 里缺少 native 库 $lib（$why）" >&2
    echo "      若是 Kit 形式导入被 ace 漏拷，把该库加进本脚本的 PLUGIN_LIBS 即可。" >&2
    exit 1
  fi
}

for rel in "${PLUGIN_LIBS[@]}"; do
  require_in_apk "$(basename "$rel")" "PLUGIN_LIBS"
done

for sym in $(grep -rhoE "^import \{[^}]*\} from '(@kit\.[A-Za-z]+|@ohos\.[a-z.]+)'" \
    "$APP_DIR/entry/src/main/ets" "$APP_DIR"/feature/*/src/main/ets 2>/dev/null \
  | sed -E 's/^import \{//; s/\} from .*//' | tr ',' '\n' \
  | sed -E 's/ as .*//; s/[[:space:]]//g' | grep -v '^$' | sort -u); do
  case "$sym" in
    [a-z]*) ;;
    *) continue ;; # 大写开头：ArkTS 类型/类，不是插件模块名
  esac
  lib="lib$(echo "$sym" | tr 'A-Z' 'a-z').so"
  grep -qx "$lib" <<<"$SDK_PLUGIN_LIBS" || continue # 该 SDK 没有同名插件库，本脚本不做断言
  require_in_apk "$lib" "源码导入了 $sym"
done
echo "==> 插件库校验通过（APK 内 native 库 $(grep -c . <<<"$APK_LIBS") 个）"

echo
echo "构建完成，产物目录：$OUT"
echo "$APK_FILE"
