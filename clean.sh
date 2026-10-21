#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLEAN_ALL=0
CLEAN_PKG=""
ASSUME_YES=0

usage() {
    cat <<EOF
用法: ./clean.sh [选项]

清除交叉编译产生的 build、install 和 log 目录。

不带参数运行时会列出 src 中的 ROS 包，选择全部清除或只清除其中一个。

选项:
  -a, --all               清除全部构建产物
  -p, --package NAME      只清除指定包的构建产物
  -y, --yes               跳过确认
  -h, --help              显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--all) CLEAN_ALL=1; shift ;;
        -p|--package) CLEAN_PKG="${2:?缺少包名}"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

if [ "$CLEAN_ALL" -eq 1 ] && [ -n "$CLEAN_PKG" ]; then
    die "--all 不能和 --package 同时使用"
fi

mapfile -t PKGS < <(list_packages)

if [ "$CLEAN_ALL" -eq 0 ] && [ -z "$CLEAN_PKG" ]; then
    if [ "${#PKGS[@]}" -eq 0 ] &&
        [ ! -d "$WS_DIR/build" ] &&
        [ ! -d "$WS_DIR/install" ] &&
        [ ! -d "$WS_DIR/log" ]; then
        log_info "没有可清理的构建产物"
        exit 0
    fi

    printf '\n检测到以下 ROS 包:\n'
    for i in "${!PKGS[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${PKGS[$i]}"
    done
    printf '   0) 全部清除\n\n'

    if [ "${#PKGS[@]}" -eq 0 ]; then
        CLEAN_ALL=1
    else
        while true; do
            if ! read -r -p "请选择 [0-${#PKGS[@]}]: " choice; then
                die "没有选择清理目标"
            fi
            if [ "$choice" = "0" ]; then
                CLEAN_ALL=1
                break
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] &&
                [ "$choice" -ge 1 ] &&
                [ "$choice" -le "${#PKGS[@]}" ]; then
                CLEAN_PKG="${PKGS[$((choice - 1))]}"
                break
            fi
            printf '无效选择，请输入 0 到 %d 之间的数字\n' "${#PKGS[@]}"
        done
    fi
fi

if [ "$CLEAN_ALL" -eq 1 ]; then
    TARGETS=()
    for d in build install log; do
        [ -e "$WS_DIR/$d" ] && TARGETS+=("$WS_DIR/$d")
    done

    if [ "${#TARGETS[@]}" -eq 0 ]; then
        log_info "没有可清理的构建产物"
        exit 0
    fi

    log_step "将清除以下目录"
    for t in "${TARGETS[@]}"; do
        printf '  %s\t%s\n' "$(du -sh "$t" 2>/dev/null | cut -f1)" "$t"
    done

    confirm "确认清除全部构建产物？" n || { log_info "已取消"; exit 0; }

    for t in "${TARGETS[@]}"; do
        rm -rf -- "$t"
    done
    log_info "已清除全部构建产物"
    exit 0
fi

valid_pkg_name "$CLEAN_PKG" || die "非法的包名: $CLEAN_PKG"

TARGETS=()
for p in \
    "$WS_DIR/build/$CLEAN_PKG" \
    "$WS_DIR/install/$CLEAN_PKG" \
    "$WS_DIR/log/latest_build/$CLEAN_PKG" \
    "$WS_DIR/log/latest_test/$CLEAN_PKG"; do
    [ -e "$p" ] && TARGETS+=("$p")
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
    log_info "包 $CLEAN_PKG 没有构建产物"
    exit 0
fi

log_step "将清除包 $CLEAN_PKG 的以下目录"
for t in "${TARGETS[@]}"; do
    printf '  %s\t%s\n' "$(du -sh "$t" 2>/dev/null | cut -f1)" "$t"
done

confirm "确认清除包 $CLEAN_PKG 的构建产物？" n || { log_info "已取消"; exit 0; }

for t in "${TARGETS[@]}"; do
    rm -rf -- "$t"
done
log_info "已清除包 $CLEAN_PKG 的构建产物"
