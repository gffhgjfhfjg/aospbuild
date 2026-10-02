#!/usr/bin/env bash
# =============================================================================
#  build_scripts/stage1_build.sh —— Job2 主体
# -----------------------------------------------------------------------------
#  职责：
#    1) 准备 16G swap（规避 runner 内存不足 OOM）
#    2) lunch aosp_arm64-eng
#    3) m nothing 生成 soong 构建图
#    4) 规划 ninja 目标：排除 metalava，保留其余全部
#    5) -j1 串行编译
#    6) 打包 out -> .ci_artifacts/out/part-*（交由 workflow 上传）
#
#  硬性约束：
#    * -j1 串行（规避 OOM）
#    * 排除 metalava 之外编译全部 ninja 目标
#    * set -euo pipefail
# =============================================================================

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_here}/lib/common.sh"
enable_err_trap
# shellcheck source=lib/swap.sh
source "${_here}/lib/swap.sh"
# shellcheck source=lib/ninja_targets.sh
source "${_here}/lib/ninja_targets.sh"
# shellcheck source=lib/artifacts.sh
source "${_here}/lib/artifacts.sh"
# shellcheck source=lib/apt_deps.sh
source "${_here}/lib/apt_deps.sh"

start_logging "stage1_build"

main() {
  banner "Stage1 开始：aosp_arm64-eng -j1 串行编译（排除 metalava）"

  log "参数:"
  log "  AOSP_SRC_DIR      = ${AOSP_SRC_DIR}"
  log "  AOSP_LUNCH_TARGET = ${AOSP_LUNCH_TARGET}"
  log "  AOSP_BUILD_JOBS   = ${AOSP_BUILD_JOBS}"
  log "  AOSP_SKIP_METALAVA= ${AOSP_SKIP_METALAVA}"
  log "  AOSP_OUT_PACK_MODE= ${AOSP_OUT_PACK_MODE}"

  [ -d "$AOSP_SRC_DIR" ] || die "AOSP 源码目录不存在: ${AOSP_SRC_DIR}（请先执行 sync_source.sh）"
  [ -d "$AOSP_SRC_DIR/build/make" ] || die "${AOSP_SRC_DIR} 不是有效的 AOSP 根目录（缺 build/make）"

  # ---------------------------------------------------------------- 0) 资源准备
  create_swap "$AOSP_SWAP_SIZE_GB" "$AOSP_SWAP_FILE"
  report_memory
  require_free_gb "$AOSP_FREE_SPACE_GB" "$AOSP_SRC_DIR"

  # ---------------------------------------------------------------- 1) lunch
  aosp_lunch "$AOSP_LUNCH_TARGET"
  verify_cross_toolchain "$AOSP_SRC_DIR"

  # ---------------------------------------------------------------- 2) 关键环境变量
  #  -j1：硬性要求
  if [ -f "$AOSP_SRC_DIR/build/core/version_defaults.mk" ]; then
    BUILD_NUMBER="$(grep -oE '^BUILD_NUMBER[[:space:]]*=[[:space:]]*[0-9]+' \
                    "$AOSP_SRC_DIR/build/core/version_defaults.mk" | grep -oE '[0-9]+$' | head -n1 || true)"
  fi
  export BUILD_NUMBER="${BUILD_NUMBER:-1}"
  # 关闭 ccache / lz4，减小 IO 与磁盘压力
  export USE_CCACHE="$AOSP_CCACHE_ENABLE"
  export LMBGEN="$AOSP_LMBGEN"
  # soong 内部 ninja 用的并行度也强制为 1
  export NINJA_ARGS="-j${AOSP_BUILD_JOBS} -k ${AOSP_BUILD_KEEP_GOING}"
  # 关闭 soong 的内容哈希缓存里的并行（保险）
  export SOONG_NINJA_NUM_JOBS="$AOSP_BUILD_JOBS"
  # 语言/字符集
  export LANG="${LANG:-C.UTF-8}"
  # 避免 soong 反复弹交互（答不上来的问题自动跳过）
  export SOONG_SILENT=true

  log "BUILD_NUMBER = ${BUILD_NUMBER}"
  log "NINJA_ARGS   = ${NINJA_ARGS}"

  # ---------------------------------------------------------------- 3) m nothing
  # 目的：仅生成 soong 构建图 out/soong/build.ninja，不编译任何东西。
  #      AOSP 10 官方支持 `m nothing`（空目标）。
  banner "生成 soong 构建图 (m nothing)"
  m -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" nothing
  [ -f "$AOSP_SRC_DIR/out/soong/build.ninja" ] \
    || die "soong 构建图生成失败：未找到 out/soong/build.ninja"
  log "out/soong/build.ninja 已生成 ($(du -h "$AOSP_SRC_DIR/out/soong/build.ninja" | cut -f1))"

  # ---------------------------------------------------------------- 4) 目标规划
  plan_targets_excluding_metalava
  plan_print_phony_summary

  # ---------------------------------------------------------------- 5) 串行编译
  #  两种执行路径：
  #    A) rspfile 模式（默认）：把保留目标写入 .rsp，用 ninja @file 精确构建
  #    B) xargs 模式：ninja 不支持 @file 时的回退，分批喂目标
  local out ninja
  out="$(aosp_out)"
  ninja="$(find_ninja)"

  if [ "$AOSP_SKIP_METALAVA" = "1" ]; then
    banner "串行编译保留目标（-j${AOSP_BUILD_JOBS}，已排除 metalava）"
    case "$AOSP_NINJA_TARGETS_MODE" in
      xargs)
        warn "使用 xargs 回退模式：ninja 可能不支持 @file 响应文件"
        # 分批：每批 2000 个目标，ninja 自身会做依赖排序，重复目标无副作用
        grep -v '^all$' "$out/.ninja_targets_keep.txt" \
          | grep -vE '^clean' \
          | xargs -r -n 2000 "$ninja" -C "$out" -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING"
        ;;
      rspfile|*)
        local rsp="$out/.stage1_targets.rsp"
        # 排除 all / clean 这类聚合/清理目标：all 会把 metalava 重新拉进来
        grep -v -x -e 'all' -e 'clean' -e 'rebuild' "$out/.ninja_targets_keep.txt" > "$rsp" || true
        local n_rsp
        n_rsp="$(wc -l < "$rsp")"
        log "响应文件 ${rsp}（${n_rsp} 个目标）"
        if [ "$n_rsp" -eq 0 ]; then
          die "保留目标清单为空，请检查 ninja 目标规划（out/.ninja_targets_keep.txt）"
        fi
        # -d explain 可解释为何某个目标没被构建；-w dupbuild=err 便于发现依赖图异常
        "$ninja" -C "$out" -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" \
                 -w dupbuild=err -d explain "@${rsp}"
        ;;
    esac
  else
    banner "串行编译默认目标（-j${AOSP_BUILD_JOBS}，含 metalava）"
    m -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" all
  fi

  # ---------------------------------------------------------------- 6) 结果核验
  banner "Stage1 编译结果核验"
  local prod; prod="$(aosp_product)"
  log "产物目录: ${prod}"
  ls -la "$prod" 2>/dev/null | head -n 60 || warn "产物目录不存在"

  # 关键中间产物存在性检查
  local checks=(
    "out/target/product/${AOSP_OUT_PRODUCT_DIR}/obj/INTERMEDIATES"
    "out/host/linux-x86/bin"
    "out/soong/build.ninja"
  )
  local c ok=0 fail=0
  for c in "${checks[@]}"; do
    if [ -e "$AOSP_SRC_DIR/$c" ]; then log "  [OK]   $c"; ok=$((ok+1))
    else warn "  [MISS] $c"; fail=$((fail+1)); fi
  done

  local sz; sz="$(du -sh "$(aosp_out)" 2>/dev/null | cut -f1 || echo '?')"
  log "out 体积: ${sz}"
  log "检查通过 ${ok} 项，缺失 ${fail} 项"

  # soong build 统计
  if [ -f "$(aosp_out)/soong/build.ninja" ]; then
    log "ninja 目标图大小: $(du -h "$(aosp_out)/soong/build.ninja" | cut -f1)"
  fi

  # ---------------------------------------------------------------- 7) 记录构建元信息
  {
    echo "stage=stage1"
    echo "lunch_target=${AOSP_LUNCH_TARGET}"
    echo "aosp_tag=${AOSP_TAG}"
    echo "build_number=${BUILD_NUMBER}"
    echo "build_jobs=${AOSP_BUILD_JOBS}"
    echo "skip_metalava=${AOSP_SKIP_METALAVA}"
    echo "finished_at_utc=$(date -u +%FT%TZ)"
    echo "--- excluded (metalava) targets ---"
    cat "$(aosp_out)/.ninja_targets_exclude.txt" 2>/dev/null || true
  } > "${CI_LOG_DIR}/stage1-meta.txt"

  # ---------------------------------------------------------------- 8) 打包 out
  artifacts_pack

  banner "Stage1 完成"
  log "构建元信息: ${CI_LOG_DIR}/stage1-meta.txt"
  log "out 分片目录: ${CI_ARTIFACT_DIR}/out"
  log "下一步：workflow 会把 .ci_artifacts/out/part-* 上传为 out-stage1 artifact"
}

main "$@"
