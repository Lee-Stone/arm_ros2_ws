#!/bin/bash
# 公共函数：路径、日志、Docker 检测、ROS 包发现

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="$(cd "$_COMMON_DIR/.." && pwd)"
SRC_DIR="$WS_DIR/src"
DOCKERFILE="$WS_DIR/docker/Dockerfile"
ENTRYPOINT_FILE="$WS_DIR/docker/entrypoint.sh"
IMAGE_NAME="${IMAGE_NAME:-arm_ros2_ws:jazzy}"

if [ -t 1 ]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_RESET=''
fi

log_info()  { printf '%s[INFO]%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%s==> %s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
die()       { log_error "$*"; exit 1; }

# 检测可用的 docker 命令；需要 sudo 时自动使用 sudo docker
detect_docker() {
    DOCKER=()
    command -v docker >/dev/null 2>&1 || return 1

    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
    elif sudo -n docker info >/dev/null 2>&1; then
        DOCKER=(sudo docker)
    elif sudo docker info >/dev/null 2>&1; then
        DOCKER=(sudo docker)
    else
        return 1
    fi
    return 0
}

dk() {
    "${DOCKER[@]}" "$@"
}

image_exists() {
    dk image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

# Dockerfile 与 entrypoint 的内容哈希，用来判断镜像是否需要重建
build_hash() {
    [ -f "$DOCKERFILE" ] && [ -f "$ENTRYPOINT_FILE" ] || return 1
    cat "$DOCKERFILE" "$ENTRYPOINT_FILE" | sha256sum | cut -c1-16
}

# 列出 src 下所有 ROS 包名，按名称排序去重
list_packages() {
    local src="${1:-$SRC_DIR}"
    [ -d "$src" ] || return 0

    find "$src" -type f -name package.xml -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            local name
            name=$(awk -F'[<>]' '/<name>/{print $3; exit}' "$f")
            [ -n "$name" ] && printf '%s\n' "$name"
        done |
        sort -u
}

valid_pkg_name() {
    [[ "${1:-}" =~ ^[a-z0-9_]+$ ]]
}

# 要求交叉编译镜像已经安装；没有则提示运行 install.sh
require_image() {
    detect_docker || die "未检测到可用的 Docker，请先运行: $WS_DIR/install.sh"
    if ! image_exists; then
        log_error "交叉编译环境未安装，或镜像 $IMAGE_NAME 不存在"
        log_info "请先运行: $WS_DIR/install.sh"
        exit 1
    fi
}

confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [ "${ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n] "
    else
        prompt="$prompt [y/N] "
    fi
    read -r -p "$prompt" answer || return 1
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}
