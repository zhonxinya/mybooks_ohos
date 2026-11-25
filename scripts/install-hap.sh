#!/usr/bin/env bash
#
# 签名 + 安装 HAP 到设备（建议 #749/#1222）。
# 替代每次上板手敲的 hap-sign-tool 长命令；材料固定 .hapsign/（dev.p12 /
# dev-signed.cer / debug-profile.p7b，bundleName com.zhonxinya.mybooks.harmonyos）。
#
# 用法：
#   scripts/install-hap.sh                 # 用现成未签名产物，签名+安装+启动
#   scripts/install-hap.sh --build         # 先跑 build-hap.sh 再签装
#   scripts/install-hap.sh --no-install    # 只签名（模拟器离线时验证签名链）
#   scripts/install-hap.sh -f <a.hap>      # 指定未签名输入
#
# 关键参数教训（记忆 hap-sign-install-params）：-mode 必须 localSign（写错报
# 11011002）；aa start 的 -b 必须是全 bundleName（简写报 10104001）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/android-env.sh"

SIGN_DIR="$ROOT/.hapsign"
HDC="$HOS_CLT_DIR/sdk/default/openharmony/toolchains/hdc"
SIGN_JAR="$HOS_CLT_DIR/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
SN="127.0.0.1:5555"
BUNDLE="com.zhonxinya.mybooks.harmonyos"
UNSIGNED="$ROOT/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"
OUT="$SIGN_DIR/entry-install-signed.hap"
DO_BUILD=0
DO_INSTALL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --build) DO_BUILD=1 ;;
    --no-install) DO_INSTALL=0 ;;
    -f) shift; UNSIGNED="$1" ;;
    -s) shift; SN="$1" ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$SIGN_JAR" ] || { echo "错误：未找到 $SIGN_JAR（SDK 路径变动需同步本脚本）" >&2; exit 1; }

if [ "$DO_BUILD" = 1 ]; then
  "$ROOT/scripts/build-hap.sh"
fi
[ -f "$UNSIGNED" ] || { echo "错误：未找到未签名产物 $UNSIGNED（先 --build）" >&2; exit 1; }

# 固定签名参数（2026-11-17 实测；口令为 debug 材料公开值）
java -jar "$SIGN_JAR" sign-app \
  -mode localSign -keyAlias mybooks_dev \
  -keyPwd 123456 -keystorePwd 123456 \
  -signAlg SHA256withECDSA \
  -appCertFile "$SIGN_DIR/dev-signed.cer" \
  -profileFile "$SIGN_DIR/debug-profile.p7b" -profileSigned 1 \
  -keystoreFile "$SIGN_DIR/dev.p12" \
  -inFile "$UNSIGNED" -outFile "$OUT" 2>&1 | tee /tmp/install-hap-sign.log
grep -q 'Sign Hap success' /tmp/install-hap-sign.log || {
  echo "错误：签名未成功，完整输出见 /tmp/install-hap-sign.log" >&2; exit 1; }
echo "签名产物：$OUT"

if [ "$DO_INSTALL" = 1 ]; then
  "$HDC" -t "$SN" install -r "$OUT"
  "$HDC" -t "$SN" shell aa start -a EntryAbility -b "$BUNDLE"
else
  echo "已跳过安装（--no-install）；设备在线时去掉该参数即可 install -r + aa start。"
fi
