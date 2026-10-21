#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

USER_NAME=""
HOST=""
REMOTE_PATH=""
PORT=22
SSH_KEY=""
DRY_RUN=0
ASSUME_YES=0
POSITIONAL=()

usage() {
    cat <<EOF
用法: ./push.sh [选项] [用户名 IP 路径]

把本地 install/ 推送到香橙派，并覆盖远端 ros2_ws 下的 install。

推荐写法:
  ./push.sh -u orangepi -i 192.168.1.14 -p "~/ros2_ws"

也支持简写:
  ./push.sh -orangepi -192.168.1.14 -"~/ros2_ws"
  ./push.sh orangepi 192.168.1.14 "~/ros2_ws"

选项:
  -u, --user NAME          SSH 用户名，默认 orangepi
  -i, --ip HOST            香橙派 IP 或主机名
  -p, --path PATH          远端工作空间路径，默认 ~/ros2_ws
  -P, --port PORT          SSH 端口，默认 22
  -k, --key FILE           SSH 私钥文件
  -n, --dry-run            只打印计划，不连接香橙派
  -y, --yes                跳过确认
  -h, --help               显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user) USER_NAME="${2:?缺少用户名}"; shift 2 ;;
        -i|--ip|--host) HOST="${2:?缺少 IP 或主机名}"; shift 2 ;;
        -p|--path) REMOTE_PATH="${2:?缺少远端路径}"; shift 2 ;;
        -P|--port) PORT="${2:?缺少端口}"; shift 2 ;;
        -k|--key) SSH_KEY="${2:?缺少私钥路径}"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; POSITIONAL+=("$@"); break ;;
        --*) die "未知参数: $1" ;;
        -?*) POSITIONAL+=("${1#-}"); shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONAL[@]}" -gt 3 ]; then
    die "位置参数最多 3 个: 用户名 IP 路径"
fi

if [ "${#POSITIONAL[@]}" -ge 1 ] && [ -z "$USER_NAME" ]; then
    USER_NAME="${POSITIONAL[0]}"
fi
if [ "${#POSITIONAL[@]}" -ge 2 ] && [ -z "$HOST" ]; then
    HOST="${POSITIONAL[1]}"
fi
if [ "${#POSITIONAL[@]}" -ge 3 ] && [ -z "$REMOTE_PATH" ]; then
    REMOTE_PATH="${POSITIONAL[2]}"
fi

USER_NAME="${USER_NAME:-orangepi}"
REMOTE_PATH="${REMOTE_PATH:-~/ros2_ws}"

[ -n "$HOST" ] || die "缺少香橙派 IP，例如: ./push.sh -u orangepi -i 192.168.1.14 -p \"~/ros2_ws\""

[[ "$USER_NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "非法的用户名: $USER_NAME"
[[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "非法的 IP 或主机名: $HOST"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] ||
    die "非法端口: $PORT"
[[ "$REMOTE_PATH" =~ ^(~|/|[A-Za-z0-9_.])[A-Za-z0-9_./~-]*$ ]] ||
    die "远端路径只能包含字母、数字、下划线、点、斜杠、波浪线和短横线，且不能以短横线开头"
[[ "$REMOTE_PATH" != *".."* ]] || die "远端路径不能包含 .."

while [[ "$REMOTE_PATH" != "/" && "$REMOTE_PATH" == */ ]]; do
    REMOTE_PATH="${REMOTE_PATH%/}"
done

if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then
    die "SSH 私钥不存在: $SSH_KEY"
fi

[ -d "$WS_DIR/install" ] || die "本地 install 不存在，请先运行: ./build.sh"
[ -f "$WS_DIR/install/setup.bash" ] || die "本地 install/setup.bash 不存在，请先运行: ./build.sh"

PKG_COUNT="$(find "$WS_DIR/install" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
INSTALL_SIZE="$(du -sh "$WS_DIR/install" 2>/dev/null | cut -f1)"
TARGET="$USER_NAME@$HOST"
REMOTE_INSTALL="$REMOTE_PATH/install"

log_step "推送计划"
log_info "本地 install: ${INSTALL_SIZE:-unknown}，${PKG_COUNT} 个包目录"
log_info "目标: $TARGET:$REMOTE_INSTALL"
log_warn "远端原有的 install 目录会被覆盖"

CONTROL_PATH="/tmp/arm_ros2_ws_ssh_%r@%h:%p"
SSH_OPTS=(
    -p "$PORT"
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -o ControlMaster=auto
    -o "ControlPath=$CONTROL_PATH"
    -o ControlPersist=60
)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")

if [ "$DRY_RUN" -eq 1 ]; then
    log_info "[dry-run] 将先检查 SSH: ssh ${SSH_OPTS[*]} $TARGET"
    log_info "[dry-run] 将同步: $WS_DIR/install/ -> $TARGET:$REMOTE_INSTALL/"
    log_info "[dry-run] 远端有 rsync 时使用 rsync --delete，否则使用 tar 覆盖"
    exit 0
fi

confirm "继续推送？" n || { log_info "已取消"; exit 0; }

log_step "检查 SSH 连接"
if ! ssh "${SSH_OPTS[@]}" "$TARGET" true; then
    log_error "SSH 连接失败，请检查用户名、IP、网络和密钥"
    log_info "可先手动执行: ssh $TARGET"
    log_info "如果提示 REMOTE HOST IDENTIFICATION HAS CHANGED，先清除旧记录:"
    log_info "ssh-keygen -f ~/.ssh/known_hosts -R $HOST"
    exit 1
fi
log_info "SSH 连接正常"

REMOTE_HAS_RSYNC=0
if ssh "${SSH_OPTS[@]}" "$TARGET" "command -v rsync >/dev/null 2>&1"; then
    REMOTE_HAS_RSYNC=1
fi

log_step "传输 install"
if command -v rsync >/dev/null 2>&1 && [ "$REMOTE_HAS_RSYNC" -eq 1 ]; then
    log_info "使用 rsync 同步，远端多余文件会被删除"
    RSYNC_SSH="ssh -p $PORT -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$CONTROL_PATH -o ControlPersist=60"
    [ -n "$SSH_KEY" ] && RSYNC_SSH="$RSYNC_SSH -i $SSH_KEY"

    if ! rsync -az --delete --delay-updates --progress \
        -e "$RSYNC_SSH" \
        "$WS_DIR/install/" "$TARGET:$REMOTE_INSTALL/"; then
        die "rsync 推送失败"
    fi
else
    log_info "使用 tar 传输（本机或香橙派没有 rsync）"

    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "set -e; mkdir -p $REMOTE_PATH; rm -rf $REMOTE_PATH/install.new; mkdir -p $REMOTE_PATH/install.new"

    if ! tar -C "$WS_DIR/install" -czf - . |
        ssh "${SSH_OPTS[@]}" "$TARGET" "tar -C $REMOTE_PATH/install.new -xzf -"; then
        die "传输失败，远端原有 install 未改动"
    fi

    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "set -e; rm -rf $REMOTE_PATH/install.old; if [ -d $REMOTE_PATH/install ]; then mv $REMOTE_PATH/install $REMOTE_PATH/install.old; fi; mv $REMOTE_PATH/install.new $REMOTE_PATH/install; rm -rf $REMOTE_PATH/install.old"
fi

log_step "验证远端产物"
if ! ssh "${SSH_OPTS[@]}" "$TARGET" "test -f $REMOTE_INSTALL/setup.bash"; then
    die "推送完成，但远端没有找到 $REMOTE_INSTALL/setup.bash"
fi

REMOTE_SIZE="$(ssh "${SSH_OPTS[@]}" "$TARGET" "du -sh $REMOTE_INSTALL 2>/dev/null | cut -f1" || true)"
ssh -O exit "${SSH_OPTS[@]}" "$TARGET" >/dev/null 2>&1 || true

log_step "推送完成"
log_info "远端 install: $TARGET:$REMOTE_INSTALL (${REMOTE_SIZE:-unknown})"
log_info "在香橙派上执行:"
printf '  source %s/setup.bash\n' "$REMOTE_INSTALL"
printf '  ros2 pkg list\n'
