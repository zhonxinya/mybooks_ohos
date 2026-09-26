#!/usr/bin/env bash
# 在一台 Linux x86_64 上准备模拟器验证机：KVM、QEMU、OpenHarmony 镜像。
# 不会自动注册 GitHub Actions runner；脚本末尾打印注册命令。
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "这台脚本只适用于 Linux。" >&2
  exit 1
fi

if [[ ! -e /dev/kvm ]]; then
  echo "没有 /dev/kvm。在 BIOS/虚拟化平台打开 VT-x/AMD-V，并安装 qemu-kvm。" >&2
  echo "GitHub 托管 runner 没有这项能力，不能拿来跑模拟器。" >&2
  exit 1
fi

if ! [[ -r /dev/kvm && -w /dev/kvm ]]; then
  echo "当前用户读写不了 /dev/kvm。把用户加入 kvm 组后重新登录：" >&2
  echo "  sudo usermod -aG kvm \"$USER\"" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    qemu-system-x86 libatomic1 curl ca-certificates python3 openjdk-17-jre-headless unzip
elif ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "没有 apt-get 或 sudo。请自行安装 qemu-system-x86、libatomic1、openjdk-17-jre-headless。" >&2
  exit 1
fi

RELEASE="${OHOS_QEMU_RELEASE:-v20260809}"
if ! find "${HOME}/.ohos-qemu" -path '*/launch/linux.sh' -type f 2>/dev/null | grep -q .; then
  installer="$(mktemp)"
  curl -fsSL -o "$installer" \
    "https://raw.githubusercontent.com/harmony-contrib/ohos-qemu/main/scripts/install.sh"
  env -u GITHUB_TOKEN bash "$installer" \
    --release "$RELEASE" \
    --device-type phone \
    --without-hap-signer
  rm -f "$installer"
fi

echo
echo "主机已具备模拟器镜像。接下来把这台机器注册成 GitHub Actions runner，标签必须包含 harmony-emulator："
echo
echo "  mkdir -p ~/actions-runner && cd ~/actions-runner"
echo "  # 从 GitHub → Settings → Actions → Runners → New self-hosted runner 复制下载与 config 命令"
echo "  ./config.sh --url https://github.com/zhonxinya/mybooks_ohos --token <TOKEN> --labels harmony-emulator --name harmony-emulator"
echo "  # 服务要和上面安装镜像的是同一个用户，否则 runner 看不到 ~/.ohos-qemu"
echo "  sudo ./svc.sh install \"$USER\" && sudo ./svc.sh start"
echo
echo "已登录 gh 时，注册令牌可以这样取："
echo "  gh api -X POST repos/zhonxinya/mybooks_ohos/actions/runners/registration-token --jq .token"
echo
echo "注册完成后，在 Actions 里手动运行「HarmonyOS Emulator」。"
