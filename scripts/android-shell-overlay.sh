#!/usr/bin/env bash
#
# 把 Android 侧的自定义内容叠加到 ace 生成的 .arkui-x 壳工程上（应用内升级用）。
#
# 叠加三样东西：
#   1) ApkFileProvider.java —— 以 content:// 提供 <filesDir>/updates/*.apk 给系统安装器；
#   2) AndroidManifest.xml —— REQUEST_INSTALL_PACKAGES 权限 + 上面的 provider 声明；
#   3) app/build.gradle —— versionCode/versionName 对齐 app.json5；存在签名材料时启用 release 签名。
#
# 为什么用叠加而不是直接把壳工程入库：ohos/.arkui-x 是 ace 的生成物（已在 .gitignore 里），
# 每次 `ace modify --project` 都会重建，故只能在其之后打补丁。脚本幂等，重复执行无副作用。
#
# 必须在 `ace build apk` 之前执行（gradle 读取的是 .arkui-x/android 下的这些文件）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_APP="$ROOT/ohos/.arkui-x/android/app"
MANIFEST="$ANDROID_APP/src/main/AndroidManifest.xml"
GRADLE="$ANDROID_APP/build.gradle"
SRC_JAVA="$ROOT/android-overlay/java"
JAVA_DIR="$ANDROID_APP/src/main/java"
APP_JSON="$ROOT/ohos/AppScope/app.json5"

if [ ! -f "$MANIFEST" ] || [ ! -f "$GRADLE" ]; then
  echo "错误：找不到 Android 壳工程（$MANIFEST）" >&2
  echo "请先执行：cd ohos && ace modify --project" >&2
  exit 1
fi

# ---- 1) provider / 安装桥源码 ----
mkdir -p "$JAVA_DIR/com/zhonxinya/talebook"
cp -f "$SRC_JAVA"/com/zhonxinya/talebook/*.java "$JAVA_DIR/com/zhonxinya/talebook/"
echo "==> 已叠加 ApkFileProvider.java / ApkInstaller.java"

# ---- 2) AndroidManifest.xml ----
# 先删掉本脚本此前插入的行再重新插入：.arkui-x 跨次构建复用，只做「没有才插」的话，
# 改动过期（例如 provider 属性调整）不会生效。
sed -i '/REQUEST_INSTALL_PACKAGES/d' "$MANIFEST"
sed -i '/com\.zhonxinya\.talebook\.ApkFileProvider/d' "$MANIFEST"
sed -i 's|^\([[:space:]]*<application\)|    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n\1|' "$MANIFEST"
sed -i 's|^\([[:space:]]*</application>\)|        <provider android:name="com.zhonxinya.talebook.ApkFileProvider" android:authorities="${applicationId}.apkprovider" android:exported="false" android:grantUriPermissions="true" />\n\1|' "$MANIFEST"
grep -q "REQUEST_INSTALL_PACKAGES" "$MANIFEST" || { echo "错误：权限注入失败" >&2; exit 1; }
grep -q "ApkFileProvider" "$MANIFEST" || { echo "错误：provider 注入失败" >&2; exit 1; }
echo "==> 已注入 REQUEST_INSTALL_PACKAGES 与 provider"

# ---- 3) app/build.gradle：版本号对齐 app.json5 ----
# ace 生成的壳工程把版本固定写成 1 / "1.0"，与 app.json5 脱节；不同步会导致
# 应用内升级比较版本时始终认为「本地是旧版」，且系统看到的 versionName 也不对。
VERSION_CODE="$(grep -oE '"versionCode"[[:space:]]*:[[:space:]]*[0-9]+' "$APP_JSON" | head -1 | grep -oE '[0-9]+$')"
VERSION_NAME="$(grep -oE '"versionName"[[:space:]]*:[[:space:]]*"[^"]*"' "$APP_JSON" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
[ -n "$VERSION_CODE" ] && [ -n "$VERSION_NAME" ] || {
  echo "错误：无法从 $APP_JSON 读取 versionCode/versionName" >&2
  exit 1
}
sed -i -E "0,/versionCode [0-9]+/s//versionCode $VERSION_CODE/" "$GRADLE"
sed -i -E "0,/versionName \"[^\"]*\"/s//versionName \"$VERSION_NAME\"/" "$GRADLE"
echo "==> 版本号已对齐 app.json5：versionCode $VERSION_CODE / versionName $VERSION_NAME"

# ---- 4) release 签名 ----
# 签名材料由环境变量提供：CI 从 GitHub Secrets 还原，本机见 scripts/android-env.sh。
# 未提供时保持 ace 默认（debug 签名）——本机自测可用，但不同构建之间无法互相覆盖安装。
#
# 注入内容带标记并每次先删旧块：.arkui-x 是跨次构建复用的生成物，若只做「有则跳过」的
# 幂等，先带签名库构建、再不带时会把上一次的 release 签名悄悄留下来（实测踩过）。
SIGN_BEGIN='// >>> mybooks-signing'
SIGN_END='// <<< mybooks-signing'
if grep -qF "$SIGN_BEGIN" "$GRADLE"; then
  sed -i "\|$SIGN_BEGIN|,\|$SIGN_END|d" "$GRADLE"
  sed -i "0,/signingConfig signingConfigs.release/s//signingConfig signingConfigs.debug/" "$GRADLE"
fi
if [ -n "${MYBOOKS_KEYSTORE_PATH:-}" ]; then
  [ -f "$MYBOOKS_KEYSTORE_PATH" ] || { echo "错误：签名库不存在 $MYBOOKS_KEYSTORE_PATH" >&2; exit 1; }
  : "${MYBOOKS_KEYSTORE_PASSWORD:?需要设置 MYBOOKS_KEYSTORE_PASSWORD}"
  : "${MYBOOKS_KEY_ALIAS:?需要设置 MYBOOKS_KEY_ALIAS}"
  : "${MYBOOKS_KEY_PASSWORD:?需要设置 MYBOOKS_KEY_PASSWORD}"
  sed -i "s|^android {|android {\n    ${SIGN_BEGIN}\n    signingConfigs {\n        release {\n            storeFile file('${MYBOOKS_KEYSTORE_PATH}')\n            storePassword '${MYBOOKS_KEYSTORE_PASSWORD}'\n            keyAlias '${MYBOOKS_KEY_ALIAS}'\n            keyPassword '${MYBOOKS_KEY_PASSWORD}'\n        }\n    }\n    ${SIGN_END}|" "$GRADLE"
  # 只替换第一处（release buildType；profile 保持 debug）
  sed -i "0,/signingConfig signingConfigs.debug/s//signingConfig signingConfigs.release/" "$GRADLE"
  grep -q "signingConfigs {" "$GRADLE" || { echo "错误：签名配置注入失败" >&2; exit 1; }
  echo "==> 已启用 release 签名（$MYBOOKS_KEY_ALIAS）"
else
  echo "==> 未设置 MYBOOKS_KEYSTORE_PATH，沿用 ace 默认签名"
fi
