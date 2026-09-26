#!/usr/bin/env bash
# 给未签名 HAP 打上可在 OpenHarmony 模拟器安装的调试签名。
#
# 默认使用 OpenHarmony 公开的调试密钥（仓库 developtools_hapsigner/dist，口令 123456）。
# 若设置了 HARMONY_STORE_FILE / HARMONY_CERT_FILE / HARMONY_PROFILE_FILE，
# 则改用这套材料（真机或官方 HarmonyOS 模拟器的调试证书）。
#
# 用法: sign-hap.sh <unsigned.hap> <signed.hap> [bundle-name]
set -euo pipefail

UNSIGNED="${1:?缺少未签名 HAP 路径}"
SIGNED="${2:?缺少输出 HAP 路径}"
BUNDLE="${3:-com.zhonxinya.talebook}"

if [[ ! -f "$UNSIGNED" ]]; then
  echo "::error::找不到未签名 HAP: $UNSIGNED" >&2
  exit 1
fi

SIGN_HOME="${SIGN_HOME:-${HOME}/.cache/ohos-hapsign}"
mkdir -p "$SIGN_HOME"

JAVA_BIN="${JAVA_BIN:-}"
if [[ -z "$JAVA_BIN" ]]; then
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    JAVA_BIN="${JAVA_HOME}/bin/java"
  elif command -v java >/dev/null 2>&1; then
    JAVA_BIN="$(command -v java)"
  else
    echo "::error::未找到 java，无法调用 hap-sign-tool" >&2
    exit 1
  fi
fi

fetch() {
  local name="$1"
  local url="$2"
  if [[ ! -s "${SIGN_HOME}/${name}" ]]; then
    echo "下载签名材料 ${name}"
    curl -fL --retry 3 --retry-delay 2 -o "${SIGN_HOME}/${name}.partial" "$url"
    mv "${SIGN_HOME}/${name}.partial" "${SIGN_HOME}/${name}"
  fi
}

BASE="https://raw.githubusercontent.com/openharmony/developtools_hapsigner/master/dist"
fetch hap-sign-tool.jar "${BASE}/hap-sign-tool.jar"
JAR="${SIGN_HOME}/hap-sign-tool.jar"

if [[ -n "${HARMONY_STORE_FILE:-}" && -n "${HARMONY_CERT_FILE:-}" && -n "${HARMONY_PROFILE_FILE:-}" ]]; then
  echo "使用仓库密钥里的 HarmonyOS 签名材料"
  "$JAVA_BIN" -jar "$JAR" sign-app \
    -mode localSign \
    -keyAlias "${HARMONY_KEY_ALIAS:?缺少 HARMONY_KEY_ALIAS}" \
    -signAlg SHA256withECDSA \
    -appCertFile "$HARMONY_CERT_FILE" \
    -profileFile "$HARMONY_PROFILE_FILE" \
    -inFile "$UNSIGNED" \
    -keystoreFile "$HARMONY_STORE_FILE" \
    -outFile "$SIGNED" \
    -keyPwd "${HARMONY_KEY_PASSWORD:?缺少 HARMONY_KEY_PASSWORD}" \
    -keystorePwd "${HARMONY_STORE_PASSWORD:?缺少 HARMONY_STORE_PASSWORD}" \
    -signCode 1
  echo "已签名: $SIGNED"
  exit 0
fi

fetch OpenHarmony.p12 "${BASE}/OpenHarmony.p12"
fetch OpenHarmonyApplication.pem "${BASE}/OpenHarmonyApplication.pem"
fetch OpenHarmonyProfileRelease.pem "${BASE}/OpenHarmonyProfileRelease.pem"
fetch UnsgnedReleasedProfileTemplate.json "${BASE}/UnsgnedReleasedProfileTemplate.json"

PROFILE_JSON="${SIGN_HOME}/profile-${BUNDLE}.json"
python3 - "$SIGN_HOME/UnsgnedReleasedProfileTemplate.json" "$PROFILE_JSON" "$BUNDLE" <<'PY'
import json, sys
src, dst, bundle = sys.argv[1:]
data = json.loads(open(src, encoding="utf-8").read())
# 模拟器刚启动时系统时间经常停在旧值，有效期从 2020 覆盖到 2050，避免 not-before 把安装拦住。
data["validity"] = {"not-before": 1577836800, "not-after": 2524608000}
data["bundle-info"]["bundle-name"] = bundle
with open(dst, "w", encoding="utf-8") as out:
    json.dump(data, out, ensure_ascii=False, indent=2)
    out.write("\n")
PY

P7B="${SIGN_HOME}/profile-${BUNDLE}.p7b"
"$JAVA_BIN" -jar "$JAR" sign-profile \
  -keyAlias "openharmony application profile release" \
  -signAlg SHA256withECDSA \
  -mode localSign \
  -profileCertFile "${SIGN_HOME}/OpenHarmonyProfileRelease.pem" \
  -inFile "$PROFILE_JSON" \
  -keystoreFile "${SIGN_HOME}/OpenHarmony.p12" \
  -outFile "$P7B" \
  -keyPwd 123456 \
  -keystorePwd 123456

"$JAVA_BIN" -jar "$JAR" sign-app \
  -keyAlias "openharmony application release" \
  -signAlg SHA256withECDSA \
  -mode localSign \
  -appCertFile "${SIGN_HOME}/OpenHarmonyApplication.pem" \
  -profileFile "$P7B" \
  -inFile "$UNSIGNED" \
  -keystoreFile "${SIGN_HOME}/OpenHarmony.p12" \
  -outFile "$SIGNED" \
  -keyPwd 123456 \
  -keystorePwd 123456 \
  -signCode 1

echo "已签名: $SIGNED"
