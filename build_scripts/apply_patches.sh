#!/usr/bin/env bash
# =============================================================================
#  apply_patches.sh —— 便捷入口：批量应用补丁 / 打印补丁编写与导出指南
# -----------------------------------------------------------------------------
#  用法：
#    ./build_scripts/apply_patches.sh              # 应用 patches/ 下全部补丁
#    ./build_scripts/apply_patches.sh --howto      # 打印补丁导出/应用完整指南
#    ./build_scripts/apply_patches.sh --dry-run    # 只做 dry-run，不落盘
#    ./build_scripts/apply_patches.sh --list       # 列出待应用补丁
# =============================================================================

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_here}/lib/common.sh"
enable_err_trap
# shellcheck source=lib/apply_patches.sh
source "${_here}/lib/apply_patches.sh"

start_logging "apply_patches"

mode="apply"
for a in "$@"; do
  case "$a" in
    --howto)   mode="howto" ;;
    --dry-run) mode="dry" ;;
    --list)    mode="list" ;;
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "未知参数: $a" ;;
  esac
done

case "$mode" in
  howto)
    print_patch_howto
    ;;
  list)
    banner "patches/ 目录内容"
    if [ -d "$PATCH_DIR" ]; then
      find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort | while IFS= read -r p; do
        echo "  $(basename "$p")  ($(wc -l < "$p") 行, $(du -h "$p" | cut -f1))"
        # 打印前 3 个受影响文件
        grep -E '^\+\+\+ ' "$p" | head -n 3 | sed 's|^|      |'
      done
    else
      log "补丁目录不存在: ${PATCH_DIR}"
    fi
    ;;
  dry)
    banner "补丁 dry-run"
    if [ ! -d "$PATCH_DIR" ]; then die "补丁目录不存在: ${PATCH_DIR}"; fi
    cd "$AOSP_SRC_DIR"
    mapfile -t ps < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
    [ "${#ps[@]}" -eq 0 ] && { log "无补丁"; exit 0; }
    for p in "${ps[@]}"; do
      if patch -p1 --dry-run --forward --batch -f -i "$p" >/dev/null 2>&1; then
        log "  [DRY-OK]   $(basename "$p")  (可应用)"
      elif patch -p1 --dry-run --reverse --batch -f -i "$p" >/dev/null 2>&1; then
        log "  [ALREADY]  $(basename "$p")  (已应用)"
      else
        err "  [FAIL]     $(basename "$p")  (无法干净应用)"
      fi
    done
    ;;
  apply)
    apply_all_patches "$AOSP_SRC_DIR" "$PATCH_DIR"
    ;;
esac
