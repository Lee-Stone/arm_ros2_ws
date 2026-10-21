#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

FORCE=0
CONFIGURE_MIRROR=0
NO_CACHE=0
UBUNTU_MIRROR=""
ROS_MIRROR=""

usage() {
    cat <<EOF
用法: ./install.sh [选项]

检测并安装 ROS2 Jazzy ARM64 交叉编译环境。

选项:
  -f, --force             强制重新构建编译镜像
      --mirror            配置 Docker 国内镜像加速并重启 Docker
      --no-cache          构建镜像时不使用缓存
      --ubuntu-mirror URL 指定 Ubuntu Ports 镜像地址
      --ros-mirror URL    指定 ROS2 apt 镜像地址
  -h, --help              显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1; shift ;;
        --mirror) CONFIGURE_MIRROR=1; shift ;;
        --no-cache) NO_CACHE=1; shift ;;
        --ubuntu-mirror) UBUNTU_MIRROR="${2:?缺少 URL}"; shift 2 ;;
        --ros-mirror) ROS_MIRROR="${2:?缺少 URL}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

CURRENT_USER="$(id -un)"
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "需要 sudo 权限安装依赖，请用有 sudo 权限的用户运行"
    SUDO="sudo"
fi

check_host() {
    log_step "检查主机环境"

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) die "不支持的 CPU 架构: $ARCH（需要 x86_64 或 aarch64）" ;;
    esac
    log_info "CPU 架构: $ARCH"

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        log_info "操作系统: ${PRETTY_NAME:-unknown}"
        if [ "${ID:-}" != "ubuntu" ]; then
            log_warn "脚本按 Ubuntu 24.04 编写，当前系统可能缺少部分依赖"
        elif [ "${VERSION_ID:-}" != "24.04" ]; then
            log_warn "推荐使用 Ubuntu 24.04，当前为 ${VERSION_ID:-unknown}"
        fi
    else
        log_warn "无法读取 /etc/os-release，跳过系统版本检查"
    fi

    local avail_kb
    avail_kb="$(df -Pk "$WS_DIR" | awk 'NR==2 {print $4}')"
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 8388608 ]; then
        log_warn "工作空间所在分区剩余空间不足 8GB，首次构建镜像可能失败"
    fi

    log_info "工作空间: $WS_DIR"
    log_info "镜像名称: $IMAGE_NAME"
}

install_docker() {
    log_step "安装 Docker"

    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，请先手动安装 Docker"
    $SUDO apt-get update
    $SUDO apt-get install -y docker.io

    # buildx 不是构建单平台镜像的硬性依赖，装不上也不影响
    $SUDO apt-get install -y docker-buildx 2>/dev/null ||
        $SUDO apt-get install -y docker-buildx-plugin 2>/dev/null ||
        log_warn "未安装 docker-buildx，将直接使用 docker build"

    $SUDO systemctl enable --now docker 2>/dev/null ||
        $SUDO service docker start 2>/dev/null ||
        log_warn "无法自动启动 Docker 服务"
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi

    if ! detect_docker; then
        log_warn "Docker 服务未运行，尝试启动..."
        $SUDO systemctl start docker 2>/dev/null ||
            $SUDO service docker start 2>/dev/null ||
            true
        sleep 2
        detect_docker || die "Docker 不可用，请检查 Docker 服务或当前用户权限"
    fi

    local version
    version="$(dk version --format '{{.Server.Version}}' 2>/dev/null || true)"
    log_info "Docker 服务版本: ${version:-unknown}"

    if [ "$(id -u)" -ne 0 ] && ! id -nG "$CURRENT_USER" | tr ' ' '\n' | grep -qx docker; then
        if getent group docker >/dev/null 2>&1; then
            $SUDO usermod -aG docker "$CURRENT_USER" || true
            log_warn "已将 $CURRENT_USER 加入 docker 组，重新登录后可免 sudo；本次继续使用 sudo docker"
        fi
    fi
}

configure_docker_mirror() {
    log_step "配置 Docker 国内镜像加速"

    local daemon_json="/etc/docker/daemon.json"
    $SUDO mkdir -p /etc/docker

    if [ -f "$daemon_json" ]; then
        local backup="${daemon_json}.bak.$(date +%Y%m%d%H%M%S)"
        $SUDO cp -a "$daemon_json" "$backup"
        log_info "原配置已备份到: $backup"
    fi

    $SUDO python3 - "$daemon_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

data["registry-mirrors"] = [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
]

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

    log_info "重启 Docker 使镜像加速生效..."
    $SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart
    sleep 2
    detect_docker || die "重启 Docker 后无法连接 Docker 服务"
    log_info "Docker 镜像加速配置完成"
}

ensure_qemu() {
    if [ "$ARCH" = "aarch64" ]; then
        log_info "当前是 ARM64 主机，不需要 QEMU 模拟"
        return 0
    fi

    log_step "检查 QEMU ARM64 支持"

    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ||
        ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        log_info "安装 qemu-user-static..."
        $SUDO apt-get update
        $SUDO apt-get install -y qemu-user-static binfmt-support 2>/dev/null ||
            $SUDO apt-get install -y qemu-user-static
        $SUDO systemctl restart systemd-binfmt 2>/dev/null ||
            $SUDO update-binfmts --enable qemu-aarch64 2>/dev/null ||
            true
        sleep 2
    fi

    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ||
        ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        log_warn "binfmt 未启用，尝试通过 multiarch 容器注册..."
        dk run --rm --privileged multiarch/qemu-user-static --reset -p yes ||
            log_warn "multiarch 注册失败，稍后的镜像构建可能报 exec format error"
    fi

    if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] &&
        grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        log_info "QEMU ARM64 已启用"
    else
        die "QEMU ARM64 未启用，无法在 x86 主机上构建 ARM64 镜像"
    fi
}

ensure_base_image() {
    log_step "检查 ARM64 基础镜像"

    if dk image inspect arm64v8/ros:jazzy-ros-base >/dev/null 2>&1; then
        local image_arch
        image_arch="$(dk image inspect arm64v8/ros:jazzy-ros-base --format '{{.Architecture}}' 2>/dev/null || true)"
        if [ "$image_arch" = "arm64" ]; then
            log_info "基础镜像已存在: arm64v8/ros:jazzy-ros-base"
            return 0
        fi
        log_warn "本地基础镜像架构为 ${image_arch:-unknown}，重新拉取 ARM64 版本"
    fi

    log_info "拉取 arm64v8/ros:jazzy-ros-base ..."
    if ! dk pull --platform linux/arm64 arm64v8/ros:jazzy-ros-base; then
        log_error "基础镜像拉取失败"
        log_info "如果在中国大陆，请先运行: $SCRIPT_DIR/install.sh --mirror"
        exit 1
    fi
}

build_image() {
    log_step "构建 ARM64 编译镜像"

    local hash current
    hash="$(build_hash)" || die "无法计算 Dockerfile 哈希"
    current=""
    if image_exists; then
        current="$(dk image inspect "$IMAGE_NAME" \
            --format '{{ index .Config.Labels "org.arm-ros2-ws.build-hash" }}' \
            2>/dev/null || true)"
    fi

    if [ "$FORCE" -eq 0 ] && image_exists && [ "$current" = "$hash" ]; then
        log_info "镜像已是最新 (hash: $hash)，跳过构建"
        log_info "如需强制重建，请运行: ./install.sh --force"
        return 0
    fi

    if [ "$FORCE" -eq 1 ]; then
        log_info "强制重建镜像"
    elif image_exists; then
        log_info "Dockerfile 有变化，重新构建镜像"
    else
        log_info "首次构建镜像"
    fi

    log_info "镜像: $IMAGE_NAME"
    log_info "首次构建需要下载并安装依赖，通常需要 10-30 分钟"

    local args=(
        build
        --platform linux/arm64
        --progress=plain
        -t "$IMAGE_NAME"
        -f "$DOCKERFILE"
        --label "org.arm-ros2-ws.build-hash=$hash"
    )
    [ "$NO_CACHE" -eq 1 ] && args+=(--no-cache)
    [ -n "$UBUNTU_MIRROR" ] && args+=(--build-arg "UBUNTU_MIRROR=$UBUNTU_MIRROR")
    [ -n "$ROS_MIRROR" ] && args+=(--build-arg "ROS_MIRROR=$ROS_MIRROR")
    args+=("$WS_DIR/docker")

    if ! dk "${args[@]}"; then
        log_error "镜像构建失败"
        log_info "可尝试: ./install.sh --mirror --no-cache"
        exit 1
    fi
}

verify_image() {
    log_step "验证交叉编译镜像"

    local arch ros_info
    arch="$(dk run --rm --platform linux/arm64 "$IMAGE_NAME" uname -m 2>/dev/null || true)"
    [ "$arch" = "aarch64" ] || die "镜像架构不是 aarch64: ${arch:-unknown}"

    ros_info="$(dk run --rm --platform linux/arm64 "$IMAGE_NAME" \
        bash -c 'source /opt/ros/jazzy/setup.bash >/dev/null 2>&1; printf "%s | colcon: %s" "$ROS_DISTRO" "$(command -v colcon)"' \
        2>/dev/null || true)"

    log_info "镜像架构: $arch"
    log_info "ROS2 环境: ${ros_info:-验证失败}"
    [[ "$ros_info" == jazzy* ]] || die "镜像内 ROS2 环境不完整"
}

main() {
    printf '\n%s\n' "${C_BLUE}ROS2 Jazzy ARM64 交叉编译环境安装${C_RESET}"
    printf '%s\n\n' "目标平台: 香橙派 Zero 2W (aarch64)"

    check_host
    ensure_docker
    [ "$CONFIGURE_MIRROR" -eq 1 ] && configure_docker_mirror
    ensure_qemu
    ensure_base_image
    build_image
    verify_image

    log_step "安装完成"
    log_info "交叉编译镜像: $IMAGE_NAME"
    log_info "下一步: 把 ROS 包放到 $SRC_DIR，然后运行 ./build.sh"
}

main
