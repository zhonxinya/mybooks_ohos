#!/usr/bin/env bash
# 启动鸿蒙模拟器（headless）并等待开机完成。
#
# 与 hos-emulator.sh 的差异：本脚本不强制要求 /dev/kvm（无 KVM 时 Emulator
# 自动降级 TCG 软件模拟，冷启动明显更慢，故 BOOT_TIMEOUT 放宽）。
# 实测本机（2026-10-12）Emulator 可访问 KVM：日志 "KVM is supported and accessible"，
# 冷启动约 1 分钟（bootevent.wms.ready 在 uptime +40s 出现）。
#
# 重要（2026-10-12 事故教训）：不要在开机早期做 tconn/shell —— 启动窗口内的连接
# 会与 Emulator 自身的 hdc 保活探测冲突，使 express 桥连接表失步
# （qemu.log 出现 get_bridge_connection_context: thread_context is null），
# 之后 hdc 通道永久卡死，只能重启模拟器恢复。因此先固定等待再连接。
#
# 用法: start-emulator.sh [实例名] [超时秒数]
set -uo pipefail

NAME="${1:-Pura70Pro}"
TIMEOUT="${2:-900}"

export HOS_CLT_DIR="${HOS_CLT_DIR:-/vol1/home/zhonxinya/workspace/harmony-sdk/command-line-tools}"
export HOME=/home/zhonxinya
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

EMU_BIN="$HOS_CLT_DIR/emulator/Emulator"
HDC="$HOS_CLT_DIR/sdk/default/openharmony/toolchains/hdc"
LOG_DIR="$HOME/.hoshos-logs"
mkdir -p "$LOG_DIR"

[ -x "$EMU_BIN" ] || { echo "找不到 Emulator: $EMU_BIN"; exit 1; }
[ -x "$HDC" ]     || { echo "找不到 hdc: $HDC"; exit 1; }

# 已在运行则直接返回
if "$HDC" list targets 2>/dev/null | grep -q "127.0.0.1:5555"; then
    echo "模拟器已在运行"
    if ! timeout 12 "$HDC" shell "echo ok" 2>/dev/null | grep -q "ok"; then
        echo "⚠️ 但 hdc 通道无响应（可能因开机早期连接竞态卡死）；持续无响应需重启模拟器恢复。"
    fi
    exit 0
fi

# 清理上次崩溃残留的死 hdc 通道（否则 shell 会永久挂起）
"$HDC" kill -r >/dev/null 2>&1
sleep 1

echo "启动实例 $NAME (冷启动约 1 分钟, 超时 ${TIMEOUT}s)..."
setsid nohup "$EMU_BIN" -start "$NAME" -noWindow \
    > "$LOG_DIR/$NAME.out" 2>&1 < /dev/null &
disown 2>/dev/null || true
echo "已后台启动, 日志: $LOG_DIR/$NAME.out"

# 先等系统启动完成再做第一次连接（KVM 下约 1 分钟；120s 留足余量）
echo "等待系统启动 120s（避开开机早期连接竞态）..."
sleep 120

# 轮询开机完成；boot.completed 的值是字符串 true 而非 1
echo "等待开机完成..."
for ((i = 0; i < TIMEOUT; i += 10)); do
    timeout 15 "$HDC" tconn 127.0.0.1:5555 >/dev/null 2>&1
    out="$(timeout 20 "$HDC" shell "param get bootevent.boot.completed" 2>/dev/null | tr -d '\r\n ')"
    if [ "$out" = "true" ]; then
        echo "开机完成 (${i}s) ✓"
        "$HDC" list targets
        exit 0
    fi
    sleep 10
done

echo "超时 ${TIMEOUT}s 仍未开机完成, 最后日志:"
tail -15 "$LOG_DIR/$NAME.out"
exit 1
