#!/usr/bin/env bash
# 在已具备 /dev/kvm 的 Linux 上启动 OpenHarmony 模拟器，安装 HAP 并拉起入口 Ability。
#
# 依赖: qemu-system-x86_64、curl、python3，以及命令行工具链里的 hdc。
# 官方 DevEco 模拟器不提供 Linux 版，GitHub 托管 runner 也没有 KVM，
# 因此这条路径跑在标签为 harmony-emulator 的自托管 runner 上。
#
# 环境变量:
#   HAP            已签名 HAP（必填）
#   BUNDLE         默认 com.zhonxinya.talebook
#   ABILITY        默认 EntryAbility
#   HDC_BIN        hdc 可执行文件；缺省时在 ./command-line-tools 与 PATH 里找
#   OHOS_QEMU_RELEASE  ohos-qemu 发行标签，默认 v20260809
#   HDC_PORT       默认 5555
#   EMULATOR_WAIT_SECONDS  等待 hdc 上线的秒数，默认 420
#   ARTIFACT_DIR   截图与日志目录，默认 ./emulator-artifacts
set -euo pipefail

HAP="${HAP:?缺少 HAP}"
BUNDLE="${BUNDLE:-com.zhonxinya.talebook}"
ABILITY="${ABILITY:-EntryAbility}"
HDC_PORT="${HDC_PORT:-5555}"
WAIT_SECONDS="${EMULATOR_WAIT_SECONDS:-420}"
RELEASE="${OHOS_QEMU_RELEASE:-v20260809}"
ARTIFACT_DIR="${ARTIFACT_DIR:-emulator-artifacts}"
DEVICE="127.0.0.1:${HDC_PORT}"

mkdir -p "$ARTIFACT_DIR"
QEMU_LOG="${ARTIFACT_DIR}/qemu.log"
QEMU_PID="${ARTIFACT_DIR}/qemu.pid"

if [[ ! -e /dev/kvm ]] || [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
  echo "::error::模拟器需要可读写的 /dev/kvm。GitHub 托管 runner 没有嵌套虚拟化，请在带 KVM 的 Linux 上注册标签为 harmony-emulator 的自托管 runner（scripts/ci/setup-emulator-host.sh）。" >&2
  exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "::error::未找到 qemu-system-x86_64。先运行 scripts/ci/setup-emulator-host.sh，或在 job 里安装 qemu-system-x86。" >&2
  exit 1
fi

find_hdc() {
  if [[ -n "${HDC_BIN:-}" && -x "${HDC_BIN}" ]]; then
    echo "$HDC_BIN"
    return
  fi
  local found
  found="$(find "${GITHUB_WORKSPACE:-.}/command-line-tools" "$HOME/command-line-tools" \
    -type f -name hdc 2>/dev/null | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    chmod +x "$found" || true
    echo "$found"
    return
  fi
  if command -v hdc >/dev/null 2>&1; then
    command -v hdc
    return
  fi
  echo ""
}

HDC="$(find_hdc)"
if [[ -z "$HDC" ]]; then
  echo "::error::未找到 hdc。先跑编译步骤以准备 command-line-tools，或设置 HDC_BIN。" >&2
  exit 1
fi
echo "hdc: $HDC"

install_image() {
  local launch
  launch="$(find "${HOME}/.ohos-qemu" -path '*/launch/linux.sh' -type f 2>/dev/null | head -n 1 || true)"
  if [[ -n "$launch" ]]; then
    echo "$launch"
    return
  fi
  echo "安装 ohos-qemu ${RELEASE}" >&2
  local installer="${ARTIFACT_DIR}/install-ohos-qemu.sh"
  curl -fsSL -o "$installer" \
    "https://raw.githubusercontent.com/harmony-contrib/ohos-qemu/main/scripts/install.sh"
  # Actions 自带的 GITHUB_TOKEN 不能访问这个公开仓库，带上它下载 Release 会 403。
  # 签名用本仓库的 sign-hap.sh，不安装上游 hap-sign（那个安装脚本指向的仓库当前不可用）。
  env -u GITHUB_TOKEN bash "$installer" \
    --release "$RELEASE" \
    --device-type phone \
    --without-hap-signer >&2
  launch="$(find "${HOME}/.ohos-qemu" -path '*/launch/linux.sh' -type f | head -n 1 || true)"
  if [[ -z "$launch" ]]; then
    echo "::error::ohos-qemu 安装后没有找到 launch/linux.sh" >&2
    exit 1
  fi
  echo "$launch"
}

LAUNCH="$(install_image)"
echo "模拟器启动脚本: $LAUNCH"

stop_emulator() {
  if [[ -f "$QEMU_PID" ]]; then
    local pid
    pid="$(cat "$QEMU_PID" || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      local pgid
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      if [[ -n "$pgid" ]]; then
        kill -TERM -- "-${pgid}" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  pkill -f "qemu-system-x86_64.*${HDC_PORT}" 2>/dev/null || true
}
trap stop_emulator EXIT

echo "启动无界面模拟器，HDC ${DEVICE}"
setsid "$LAUNCH" --headless --hdc-port "$HDC_PORT" -m 4G >"$QEMU_LOG" 2>&1 < /dev/null &
echo $! >"$QEMU_PID"

"$HDC" start || true
deadline=$((SECONDS + WAIT_SECONDS))
ready=0
while (( SECONDS < deadline )); do
  "$HDC" tconn "$DEVICE" >/dev/null 2>&1 || true
  if "$HDC" list targets 2>/dev/null | grep -q "$DEVICE"; then
    ready=1
    break
  fi
  if ! kill -0 "$(cat "$QEMU_PID")" 2>/dev/null; then
    echo "::error::模拟器进程已退出，见 ${QEMU_LOG}" >&2
    tail -n 80 "$QEMU_LOG" || true
    exit 1
  fi
  sleep 5
done
if [[ "$ready" != "1" ]]; then
  echo "::error::${WAIT_SECONDS}s 内 hdc 没有连上 ${DEVICE}" >&2
  tail -n 80 "$QEMU_LOG" || true
  exit 1
fi
echo "hdc 已连接:"
"$HDC" list targets | tee "${ARTIFACT_DIR}/targets.txt"

shell_ready=0
for _ in $(seq 1 24); do
  if "$HDC" -t "$DEVICE" shell "echo ready" 2>/dev/null | grep -q ready; then
    shell_ready=1
    break
  fi
  sleep 5
done
if [[ "$shell_ready" != "1" ]]; then
  echo "::error::hdc 已连上，但 shell 在 120s 内没有响应" >&2
  exit 1
fi

"$HDC" -t "$DEVICE" shell power-shell wakeup || true

echo "安装 $HAP"
install_ok=0
for attempt in $(seq 1 5); do
  : > "${ARTIFACT_DIR}/install.txt"
  if "$HDC" -t "$DEVICE" install -r "$HAP" | tee "${ARTIFACT_DIR}/install.txt"; then
    if ! grep -Eiq 'failed to install|error:|\[Fail\]|9568[0-9]{3}' "${ARTIFACT_DIR}/install.txt"; then
      install_ok=1
      break
    fi
  fi
  echo "安装未成功（第 ${attempt} 次），等系统服务起来后再试" >&2
  sleep 15
done
if [[ "$install_ok" != "1" ]]; then
  echo "::error::HAP 安装失败。OpenHarmony 模拟器只接受这套调试签名；若包依赖 HarmonyOS 专有 API，安装或启动会在这里失败。" >&2
  exit 1
fi

echo "启动 ${BUNDLE}/${ABILITY}"
"$HDC" -t "$DEVICE" shell power-shell wakeup || true
"$HDC" -t "$DEVICE" shell aa start -b "$BUNDLE" -a "$ABILITY" -m entry | tee "${ARTIFACT_DIR}/launch.txt"

found=0
for _ in $(seq 1 30); do
  if "$HDC" -t "$DEVICE" shell pidof "$BUNDLE" | grep -q '[0-9]'; then
    found=1
    break
  fi
  sleep 2
done
if [[ "$found" != "1" ]]; then
  echo "::error::应用进程没有起来: ${BUNDLE}" >&2
  "$HDC" -t "$DEVICE" shell hilog -x | tail -n 200 > "${ARTIFACT_DIR}/hilog.txt" || true
  exit 1
fi

SHOT_REMOTE="/data/local/tmp/ci-screen.jpeg"
SHOT_LOCAL="${ARTIFACT_DIR}/screen.jpeg"
if ! "$HDC" -t "$DEVICE" shell snapshot_display -f "$SHOT_REMOTE"; then
  "$HDC" -t "$DEVICE" shell uitest screenCap -p "$SHOT_REMOTE" || true
fi
"$HDC" -t "$DEVICE" file recv "$SHOT_REMOTE" "$SHOT_LOCAL" || true
"$HDC" -t "$DEVICE" shell hilog -x | tail -n 400 > "${ARTIFACT_DIR}/hilog.txt" || true

if [[ ! -s "$SHOT_LOCAL" ]]; then
  echo "::warning::没有拿到截图，安装和进程检查已经通过"
else
  echo "截图: $SHOT_LOCAL"
fi
echo "模拟器验证完成"
