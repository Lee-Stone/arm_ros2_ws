#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

BUILD_ALL=0
SELECTED=()
JOBS=2
BUILD_TYPE="Release"
WITH_DEPS=0
LIST_ONLY=0
DRY_RUN=0
ASSUME_YES=0

usage() {
    cat <<EOF
用法: ./build.sh [选项]

在 ARM64 Docker 容器中编译 src 下的 ROS 包，产物输出到当前目录的 install/。

不带参数运行时会列出 src 中的 ROS 包，选择全部编译或只编译其中一个。

选项:
  -a, --all               编译 src 下全部 ROS 包
  -p, --package NAME      只编译指定包，可重复使用
      --packages A,B      只编译指定的多个包，逗号分隔
  -j, --jobs N            并行编译任务数，默认 2
      --debug             使用 Debug 构建，默认 Release
      --with-deps         使用 --packages-up-to，连同 src 中的依赖包一起编译
      --list              只列出 src 中的 ROS 包，不编译
      --dry-run           只打印将要执行的 Docker 命令
  -y, --yes               跳过确认
  -h, --help              显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--all) BUILD_ALL=1; shift ;;
        -p|--package) SELECTED+=("${2:?缺少包名}"); shift 2 ;;
        --packages)
            IFS=',' read -r -a _pkgs <<< "${2:?缺少包名列表}"
            SELECTED+=("${_pkgs[@]}")
            shift 2
            ;;
        -j|--jobs) JOBS="${2:?缺少任务数}"; shift 2 ;;
        --debug) BUILD_TYPE="Debug"; shift ;;
        --release) BUILD_TYPE="Release"; shift ;;
        --with-deps) WITH_DEPS=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

[[ "$JOBS" =~ ^[0-9]+$ ]] && [ "$JOBS" -ge 1 ] || die "并行任务数必须是正整数: $JOBS"

if [ ! -d "$SRC_DIR" ]; then
    die "src 目录不存在: $SRC_DIR"
fi

mapfile -t PKGS < <(list_packages)
if [ "${#PKGS[@]}" -eq 0 ]; then
    log_error "src 目录下没有找到 ROS 包（package.xml）"
    log_info "请把 ROS 包放到 $SRC_DIR 后重试"
    exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    printf '%s\n' "${PKGS[@]}"
    exit 0
fi

require_image

img_hash="$(dk image inspect "$IMAGE_NAME" \
    --format '{{ index .Config.Labels "org.arm-ros2-ws.build-hash" }}' \
    2>/dev/null || true)"
expected_hash="$(build_hash || true)"
if [ -n "$expected_hash" ] && [ "$img_hash" != "$expected_hash" ]; then
    log_warn "当前镜像与 Dockerfile 不一致，建议先运行 ./install.sh 更新环境"
fi

if [ "$BUILD_ALL" -eq 1 ] && [ "${#SELECTED[@]}" -gt 0 ]; then
    die "--all 不能和 --package/--packages 同时使用"
fi

if [ "${#SELECTED[@]}" -gt 0 ]; then
    for pkg in "${SELECTED[@]}"; do
        valid_pkg_name "$pkg" || die "非法的包名: $pkg"
        printf '%s\n' "${PKGS[@]}" | grep -qx "$pkg" ||
            die "src 中找不到包: $pkg（可用包: ${PKGS[*]}）"
    done
fi

if [ "$BUILD_ALL" -eq 0 ] && [ "${#SELECTED[@]}" -eq 0 ]; then
    printf '\n检测到以下 ROS 包:\n'
    for i in "${!PKGS[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${PKGS[$i]}"
    done
    printf '   0) 全部编译\n\n'

    while true; do
        if ! read -r -p "请选择 [0-${#PKGS[@]}]: " choice; then
            die "没有选择编译目标"
        fi
        if [ "$choice" = "0" ]; then
            BUILD_ALL=1
            break
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            [ "$choice" -ge 1 ] &&
            [ "$choice" -le "${#PKGS[@]}" ]; then
            SELECTED=("${PKGS[$((choice - 1))]}")
            break
        fi
        printf '无效选择，请输入 0 到 %d 之间的数字\n' "${#PKGS[@]}"
    done
fi

if [ "$BUILD_ALL" -eq 1 ]; then
    TARGET_DESC="全部 ${#PKGS[@]} 个包"
else
    TARGET_DESC="${SELECTED[*]}"
fi

log_step "编译计划"
log_info "目标: $TARGET_DESC"
log_info "构建类型: $BUILD_TYPE"
log_info "并行任务数: $JOBS"
log_info "产物目录: $WS_DIR/install"

confirm "开始编译？" y || { log_info "已取消"; exit 0; }

mkdir -p "$WS_DIR/build" "$WS_DIR/install" "$WS_DIR/log"
for d in build install log; do
    if [ ! -w "$WS_DIR/$d" ]; then
        log_warn "$d 目录不可写（可能是之前用 root 编译过），尝试修正权限..."
        if [ "$(id -u)" -eq 0 ]; then
            chown -R "$(id -u):$(id -g)" "$WS_DIR/$d"
        else
            $SUDO chown -R "$(id -u):$(id -g)" "$WS_DIR/$d" ||
                die "无法修正 $d 目录权限，请手动执行: sudo chown -R $(id -u):$(id -g) $WS_DIR/$d"
        fi
    fi
done

COLCON_ARGS=(
    --log-base log
    build
    --build-base build
    --install-base install
    --event-handlers console_direct+
    --parallel-workers "$JOBS"
)

if [ "$BUILD_ALL" -eq 0 ]; then
    if [ "$WITH_DEPS" -eq 1 ]; then
        COLCON_ARGS+=(--packages-up-to "${SELECTED[@]}")
    else
        COLCON_ARGS+=(--packages-select "${SELECTED[@]}")
    fi
fi

COLCON_ARGS+=(
    --cmake-args
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
    "-DBUILD_TESTING=OFF"
)

DOCKER_RUN=(
    run
    --rm
    --platform linux/arm64
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    -e "MAKEFLAGS=-j$JOBS"
    -e "CMAKE_BUILD_PARALLEL_LEVEL=$JOBS"
    -v "$WS_DIR:/ws"
    -w /ws
    "$IMAGE_NAME"
    bash -c 'source /opt/ros/jazzy/setup.bash && exec "$@"' _
    colcon
)

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'docker '
    printf '%q ' "${DOCKER_RUN[@]}" "${COLCON_ARGS[@]}"
    printf '\n'
    exit 0
fi

log_step "开始编译"
if ! dk "${DOCKER_RUN[@]}" "${COLCON_ARGS[@]}"; then
    log_error "编译失败"
    log_info "请查看 $WS_DIR/log 下的日志"
    exit 1
fi

log_step "检查编译产物"

mapfile -t INSTALLED_PKGS < <(
    find "$WS_DIR/install" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
)

if [ "${#INSTALLED_PKGS[@]}" -eq 0 ]; then
    log_warn "install 目录下没有找到包目录"
else
    log_info "已安装的包: ${INSTALLED_PKGS[*]}"
fi

if command -v file >/dev/null 2>&1; then
    arm_count=0
    bad_count=0
    while IFS= read -r -d '' bin; do
        desc="$(file -b "$bin" 2>/dev/null || true)"
        case "$desc" in
            *ELF*)
                if printf '%s' "$desc" | grep -q 'aarch64'; then
                    arm_count=$((arm_count + 1))
                else
                    bad_count=$((bad_count + 1))
                    log_warn "非 ARM64 可执行文件: $bin ($desc)"
                fi
                ;;
        esac
    done < <(find "$WS_DIR/install" -type f -perm -u+x -path '*/lib/*' -print0 2>/dev/null)

    if [ "$bad_count" -eq 0 ] && [ "$arm_count" -gt 0 ]; then
        log_info "架构检查通过: $arm_count 个 ARM64 可执行文件"
    elif [ "$arm_count" -eq 0 ]; then
        log_info "未发现 ELF 可执行文件（可能是接口包或纯库包）"
    fi
else
    log_warn "系统没有 file 命令，跳过产物架构检查"
fi

log_step "编译完成"
log_info "产物目录: $WS_DIR/install"
log_info "推送到香橙派: ./push.sh -u orangepi -i <香橙派IP> -p \"~/ros2_ws\""
