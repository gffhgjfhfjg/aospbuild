#!/usr/bin/env bash
# =============================================================================
#  build_scripts/prepare_runner.sh —— runner 环境准备总入口
# -----------------------------------------------------------------------------
#  用法：
#    ./build_scripts/prepare_runner.sh --deps-only   # 只装宿主依赖 + 交叉工具链
#    ./build_scripts/prepare_runner.sh --swap-only   # 只做 16G swap + 空间守卫
#    ./build_scripts/prepare_runner.sh --all         # 两者都做（本地调试用）
# =============================================================================

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_here}/lib/common.sh"
enable_err_trap

usage() {
  cat <<'EOF'
用法: prepare_runner.sh [--deps-only | --swap-only | --all] [--help]
  --deps-only  安装宿主依赖 + ARM64 交叉编译工具链（apt 层面）
  --swap-only  创建 16G swap + 打印资源报告 + 空间守卫
  --all        两者都做
EOF
}

do_deps=0
do_swap=0
for a in "$@"; do
  case "$a" in
    --deps-only) do_deps=1 ;;
    --swap-only) do_swap=1 ;;
    --all)       do_deps=1; do_swap=1 ;;
    --help|-h)   usage; exit 0 ;;
    *) usage; die "未知参数: $a" ;;
  esac
done
# 不带参数时默认两者都做
if [ "$do_deps" -eq 0 ] && [ "$do_swap" -eq 0 ]; then do_deps=1; do_swap=1; fi

# shellcheck source=lib/apt_deps.sh
source "${_here}/lib/apt_deps.sh"
# shellcheck source=lib/swap.sh
source "${_here}/lib/swap.sh"
# shellcheck source=lib/reclaim_disk.sh
source "${_here}/lib/reclaim_disk.sh"

start_logging "prepare_runner"

# 磁盘回收必须最先做 —— 后面每一步（AOSP 62GB 源码 + out 40GB）都靠这多出来的 22GB
if [ "$do_deps" -eq 1 ]; then
  reclaim_runner_disk
fi

if [ "$do_deps" -eq 1 ]; then
  install_apt_deps all
  # 若 AOSP 源码已就位，顺带做一次交叉工具链自检
  if [ -d "$AOSP_SRC_DIR/prebuilts/clang" ]; then
    verify_cross_toolchain "$AOSP_SRC_DIR"
    export_cross_env "$AOSP_SRC_DIR"
  else
    log "AOSP 源码尚未 sync，跳过交叉工具链自检（Job1 之后会做）"
  fi
fi

if [ "$do_swap" -eq 1 ]; then
  create_swap "$AOSP_SWAP_SIZE_GB" "$AOSP_SWAP_FILE"
  report_memory
fi

resource_report
log "prepare_runner 完成"
