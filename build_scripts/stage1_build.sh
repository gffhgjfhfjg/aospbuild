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
# shellcheck source=lib/compile_shard.sh
source "${_here}/lib/compile_shard.sh"

# ---- 分片编译参数 ----
: "${AOSP_SHARD_INDEX:=1}"          # 本 job 是第几个编译 shard（从 1 开始）
: "${AOSP_SHARD_TOTAL:=2}"          # 编译 shard 总数
: "${AOSP_SHARD_BUDGET_MIN:=250}"   # 本 job 的 ninja 时间预算（分钟）
: "${AOSP_SHARD_DOWNLOAD:=0}"       # 1 = 本 job 需要先解包上一个 shard 的 out
: "${AOSP_SHARD_REQUIRE_COMPLETE:=0}" # 1 = 本 job 是最后一个，必须把目标编完

trap 'compile_shard_cleanup' EXIT

# 带上 shard 编号，避免同名日志互相覆盖
start_logging "stage1_build-shard${AOSP_SHARD_INDEX}of${AOSP_SHARD_TOTAL}"

main() {
  banner "编译 shard ${AOSP_SHARD_INDEX}/${AOSP_SHARD_TOTAL} 开始：aosp_arm64-eng -j1 串行编译（排除 metalava）"

  log "参数:"
  log "  AOSP_SRC_DIR        = ${AOSP_SRC_DIR}"
  log "  AOSP_LUNCH_TARGET   = ${AOSP_LUNCH_TARGET}"
  log "  AOSP_BUILD_JOBS     = ${AOSP_BUILD_JOBS}"
  log "  AOSP_SKIP_METALAVA  = ${AOSP_SKIP_METALAVA}"
  log "  shard               = ${AOSP_SHARD_INDEX}/${AOSP_SHARD_TOTAL}"
  log "  时间预算            = ${AOSP_SHARD_BUDGET_MIN} 分钟"
  log "  需解包上游 out      = ${AOSP_SHARD_DOWNLOAD}"
  log "  必须编完            = ${AOSP_SHARD_REQUIRE_COMPLETE}"
  log "  AOSP_OUT_PACK_MODE  = ${AOSP_OUT_PACK_MODE}"

  [ -d "$AOSP_SRC_DIR" ] || die "AOSP 源码目录不存在: ${AOSP_SRC_DIR}（请先执行 sync_source.sh）"
  [ -d "$AOSP_SRC_DIR/build/make" ] || die "${AOSP_SRC_DIR} 不是有效的 AOSP 根目录（缺 build/make）"

  # ---------------------------------------------------------------- 0) 资源准备
  ensure_writable_dir "$AOSP_SRC_DIR"
  create_swap "$AOSP_SWAP_SIZE_GB" "$AOSP_SWAP_FILE"
  report_memory
  require_free_gb "$AOSP_FREE_SPACE_GB" "$AOSP_SRC_DIR"
  # 容量预估：源码实测 + swap + out 还需空间（续跑 shard 时 out 已存在，不会重复计）
  project_build_capacity "$AOSP_SRC_DIR"

  # ---------------------------------------------------------------- 0b) 解包上游 out
  local out; out="$(aosp_out)"
  if [ "$AOSP_SHARD_DOWNLOAD" = "1" ]; then
    if [ -f "$out/soong/build.ninja" ]; then
      log "检测到已解包的 out 目录，跳过解包"
    else
      banner "解包上一个编译 shard 的 out 目录（增量续跑的前提）"
      artifacts_unpack
      log "out 体积: $(du -sh "$out" | cut -f1)"
    fi
  fi

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
  #  分片策略：所有 shard 跑**同一份完整目标清单**，靠时间预算划分工作量。
  #  ninja 天然跳过已完成的边，所以 shard2+ 会自动从 shard1 停下的地方接着编。
  #  绝不能按目标名切分 —— 那会破坏依赖顺序或让下游重做上游的活。
  local ninja
  ninja="$(find_ninja)"

  local rsp="$out/.stage1_targets.rsp"
  if [ "$AOSP_SKIP_METALAVA" = "1" ]; then
    # 排除 all / clean / rebuild 这类聚合或清理目标：
    #   all 是 metalava 的总入口，不排除会把 metalava 拉回本阶段
    grep -v -x -e 'all' -e 'clean' -e 'rebuild' "$out/.ninja_targets_keep.txt" > "$rsp" || true
    local n_rsp
    n_rsp="$(wc -l < "$rsp")"
    log "目标清单 ${rsp}（${n_rsp} 个目标，已排除 metalava 与其 API 产物）"
    if [ "$n_rsp" -eq 0 ]; then
      die "目标清单为空，请检查 ninja 目标规划（out/.ninja_targets_keep.txt）"
    fi
  else
    warn "AOSP_SKIP_METALAVA != 1，走 m all（含 metalava）路径，不做分片"
  fi

  local build_rc=0
  if [ "$AOSP_SKIP_METALAVA" = "1" ]; then
    set +e
    build_with_budget "$rsp" "$out" "$AOSP_SHARD_BUDGET_MIN"
    build_rc=$?
    set -e

    case "$build_rc" in
      0)
        log "本 shard 预算内跑完了全部目标 ✓"
        ;;
      "$BUDGET_EXIT_EXHAUSTED")
        log "本 shard 用完预算并优雅停止，剩余工作交给 shard $(( AOSP_SHARD_INDEX + 1 ))"
        warn "下一次续跑时 ninja 会自动跳过已完成部分"
        ;;
      *)
        err "ninja 失败（build_with_budget 返回 ${build_rc}）"
        err "常见原因：磁盘写满 / 内存不足被 kill(exit 137) / 真实编译错误"
        err "排查："
        err "  1) 看本 job 日志里 ninja 的最后 50 行"
        err "  2) ci_logs/capacity-projection.txt 确认磁盘余量"
        err "  3) exit 137 = OOM，确认 zram/swap 是否生效（swapon --show）"
        err "  4) 磁盘满会出现 'No space left on device'"
        exit 1
        ;;
    esac
  else
    banner "串行编译默认目标（-j${AOSP_BUILD_JOBS}，含 metalava）"
    m -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" all
  fi

  # ---------------------------------------------------------------- 5b) 完工判定
  banner "编译进度判定"
  local done_flag=1   # 1 = 已全部编完
  set +e
  is_build_complete "$rsp" "$out"
  if [ $? -eq 0 ]; then
    done_flag=1
    log "判定结果: 目标已全部构建完成 ✓"
  else
    done_flag=0
    warn "判定结果: 仍有目标未构建（还有活留给后续 shard）"
  fi
  set -e

  if [ "$AOSP_SHARD_REQUIRE_COMPLETE" = "1" ] && [ "$done_flag" -eq 0 ]; then
    err "=========================================================="
    err " 这是最后一个编译 shard，但目标仍未编完。"
    err " 处理办法：把 AOSP_COMPILE_SHARDS 调大（当前 ${AOSP_SHARD_TOTAL}），"
    err " 每个 shard 约 ${AOSP_SHARD_BUDGET_MIN} 分钟有效编译时间。"
    err " 也可能是磁盘不够了 —— 看 ci_logs/capacity-projection.txt"
    err "=========================================================="
    exit 1
  fi

  # ---------------------------------------------------------------- 6) 结果核验
  banner "编译结果核验 (shard ${AOSP_SHARD_INDEX}/${AOSP_SHARD_TOTAL})"

  # 6a) 宿主工具冒烟测试 —— 在这里做最划算：
  #     此时 out/host/linux-x86/bin 里已经有 metalava / mksquashfs / mke2fs / avbtool 等，
  #     如果它们缺共享库，现在发现只需几分钟；等打包时才发现要浪费好几小时。
  #     注意：只在前置工具已构建时才有意义（第一个 shard 可能还没编到）。
  smoke_test_prebuilt_tools "$AOSP_SRC_DIR" "$(aosp_out)/host/linux-x86/bin"

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
    echo "stage=compile_shard"
    echo "shard=${AOSP_SHARD_INDEX}/${AOSP_SHARD_TOTAL}"
    echo "budget_min=${AOSP_SHARD_BUDGET_MIN}"
    echo "build_complete=${done_flag}"
    echo "lunch_target=${AOSP_LUNCH_TARGET}"
    echo "aosp_tag=${AOSP_TAG}"
    echo "build_number=${BUILD_NUMBER}"
    echo "build_jobs=${AOSP_BUILD_JOBS}"
    echo "skip_metalava=${AOSP_SKIP_METALAVA}"
    echo "finished_at_utc=$(date -u +%FT%TZ)"
    echo "--- excluded (metalava) targets ---"
    cat "$(aosp_out)/.ninja_targets_exclude.txt" 2>/dev/null || true
  } > "${CI_LOG_DIR}/shard${AOSP_SHARD_INDEX}-meta.txt"

  # ---------------------------------------------------------------- 8) 打包 out
  artifacts_pack

  banner "编译 shard ${AOSP_SHARD_INDEX}/${AOSP_SHARD_TOTAL} 完成"
  log "构建元信息: ${CI_LOG_DIR}/shard${AOSP_SHARD_INDEX}-meta.txt"
  log "out 分片目录: ${CI_ARTIFACT_DIR}/out"
  if [ "$done_flag" -eq 1 ]; then
    log "状态: 目标已全部编完 ✓"
  else
    log "状态: 仍有目标未编完，下一个 shard 会增量续跑"
  fi
}

main "$@"
