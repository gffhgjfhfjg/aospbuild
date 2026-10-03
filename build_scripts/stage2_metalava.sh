#!/usr/bin/env bash
# =============================================================================
#  build_scripts/stage2_metalava.sh —— Job3 主体
# -----------------------------------------------------------------------------
#  职责：
#    1) 解包 Job2 产出的 out 目录（已在 workflow 步骤里做，这里做校验兜底）
#    2) lunch aosp_arm64-eng
#    3) 串行（-j1）单独执行全部 metalava 任务
#       - metalava / metalava-full / metalava-sdk   （工具本身）
#       - update-api                                 （重新生成 api/current.txt）
#       - check-api                                  （可选，做 API 一致性校验）
#    4) 打包 out 目录上传
#
#  为什么单独一段：
#    metalava 一次性扫描全量 SDK 源码生成 api/current.txt，是 AOSP 10 全流程中
#    最慢、内存占用最高、最容易 OOM 的环节。拆出来单独串行跑，失败也容易定位。
#
#  额外收益：
#    本阶段产出的 api/current.txt / prebuilts/sdk/current/**/api/current.txt 会随
#    out 一起上传，是后续接入 ART 方法打桩 / Dobby / SandHook 时的 API 契约基线。
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

start_logging "stage2_metalava"

# metalava 相关的 API 产物清单（打包时打 zip 一并上传）
API_ARTIFACTS=(
  "frameworks/base/api/current.txt"
  "frameworks/base/api/system-current.txt"
  "frameworks/base/api/test-current.txt"
  "prebuilts/sdk/current/1/api/current.txt"
  "prebuilts/sdk/current/2/api/current.txt"
  "prebuilts/sdk/current/3/api/current.txt"
  "core/java/api/current.txt"
)

main() {
  banner "Stage2 开始：metalava 串行专项"

  log "参数:"
  log "  AOSP_LUNCH_TARGET    = ${AOSP_LUNCH_TARGET}"
  log "  AOSP_BUILD_JOBS      = ${AOSP_BUILD_JOBS}"
  log "  AOSP_METALAVA_TARGETS= ${AOSP_METALAVA_TARGETS}"

  [ -d "$AOSP_SRC_DIR" ] || die "AOSP 源码目录不存在: ${AOSP_SRC_DIR}"
  [ -d "$AOSP_SRC_DIR/build/make" ] || die "${AOSP_SRC_DIR} 不是有效的 AOSP 根目录"

  # ---------------------------------------------------------------- 0) 资源
  create_swap "$AOSP_SWAP_SIZE_GB" "$AOSP_SWAP_FILE"
  report_memory
  require_free_gb "$AOSP_FREE_SPACE_GB" "$AOSP_SRC_DIR"

  # ---------------------------------------------------------------- 1) out 校验
  local out; out="$(aosp_out)"
  if [ -d "$out/soong" ]; then
    log "检测到已解包的 out 目录，跳过解包"
  else
    banner "解包 Job2 产出的 out 目录"
    artifacts_unpack
  fi
  [ -d "$out" ] || die "out 目录缺失，无法继续"
  log "out 体积: $(du -sh "$out" | cut -f1)"

  # ---------------------------------------------------------------- 2) lunch
  aosp_lunch "$AOSP_LUNCH_TARGET"

  # ---------------------------------------------------------------- 3) 环境变量
  export BUILD_NUMBER="${BUILD_NUMBER:-1}"
  export USE_CCACHE="$AOSP_CCACHE_ENABLE"
  export LMBGEN="$AOSP_LMBGEN"
  export NINJA_ARGS="-j${AOSP_BUILD_JOBS} -k ${AOSP_BUILD_KEEP_GOING}"
  export SOONG_NINJA_NUM_JOBS="$AOSP_BUILD_JOBS"
  export LANG="${LANG:-C.UTF-8}"
  export SOONG_SILENT=true
  # metalava 是 java 预编译工具，javac 内存要放开（配合 swap 兜底）
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:--Xmx6g -XX:+UseSerialGC}"

  log "BUILD_NUMBER = ${BUILD_NUMBER}"
  log "JAVA_TOOL_OPTIONS = ${JAVA_TOOL_OPTIONS}"

  # ---------------------------------------------------------------- 4) 刷新 soong 构建图
  #  Job2 打包时 slim 模式删掉了部分 soong 缓存，这里用 m nothing 重新生成
  banner "刷新 soong 构建图 (m nothing)"
  m -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" nothing
  [ -f "$out/soong/build.ninja" ] || die "soong 构建图生成失败"

  # ---------------------------------------------------------------- 5) metalava 任务规划
  banner "规划 metalava 任务"
  local all_targets="$out/.ninja_targets_all.txt"
  local ninja; ninja="$(find_ninja)"
  local ninja_mf
  ninja_mf="$(require_ninja_manifest)" || die "无法定位 ninja 入口文件"
  "$ninja" -C "$out" -f "$ninja_mf" -t targets all 2>/dev/null \
    | awk -F: '{print $1}' | LC_ALL=C sort -u > "$all_targets"
  log "ninja 目标总数: $(wc -l < "$all_targets")"

  # 用户配置的 metalava 目标列表
  local requested=($AOSP_METALAVA_TARGETS)
  local runnable=()
  local t
  for t in "${requested[@]}"; do
    [ -n "$t" ] || continue
    if grep -Fxq "$t" "$all_targets" || target_in_ninja_graph "$t"; then
      runnable+=("$t")
      log "  [RUN ] ${t}"
    else
      warn "  [SKIP] ${t}（本版本 ninja 图中不存在该目标）"
    fi
  done

  # 兜底：若配置的目标一个都不存在，自动从 ninja 图里发现 metalava 目标
  if [ "${#runnable[@]}" -eq 0 ]; then
    log "配置目标均不存在，改为自动发现 metalava 相关目标"
    mapfile -t runnable < <(grep -E "$METALAVA_EXCLUDE_RE" "$all_targets" \
                            | grep -vE 'checkstyle|lint|droiddoc' || true)
    [ "${#runnable[@]}" -eq 0 ] && die "ninja 图中未找到任何 metalava 目标，请确认 AOSP 版本"
    log "自动发现 ${#runnable[@]} 个目标"
  fi

  # 顺序保证：先编译工具（metalava*），再跑 update-api（依赖工具）
  local ordered=()
  for t in metalava metalava-full metalava-sdk; do
    for r in "${runnable[@]}"; do [ "$r" = "$t" ] && ordered+=("$t"); done
  done
  for t in update-api check-api; do
    for r in "${runnable[@]}"; do [ "$r" = "$t" ] && ordered+=("$t"); done
  done
  for r in "${runnable[@]}"; do
    local seen=0
    for o in "${ordered[@]}"; do [ "$o" = "$r" ] && seen=1; done
    [ "$seen" -eq 0 ] && ordered+=("$r")
  done

  {
    echo "# stage2 metalava plan"
    echo "generated_at_utc=$(date -u +%FT%TZ)"
    echo "--- ordered targets ---"
    printf '%s\n' "${ordered[@]}"
  } > "${CI_LOG_DIR}/stage2-plan.txt"

  # ---------------------------------------------------------------- 6) 执行
  local failed_targets=()
  for t in "${ordered[@]}"; do
    banner "执行 metalava 任务: ${t}"
    log "开始时间: $(date -u +%FT%TZ)"
    local t0=$SECONDS

    if m -j"$AOSP_BUILD_JOBS" -k 0 "$t"; then
      log "完成: ${t}  用时 $(( (SECONDS - t0) / 60 )) 分 $(( (SECONDS - t0) % 60 )) 秒"
    else
      err "失败: ${t}"
      failed_targets+=("$t")
      # metalava 工具本身编译失败 => 后续 update-api 必然失败，直接终止
      case "$t" in
        metalava|metalava-full|metalava-sdk)
          err "metalava 工具编译失败，后续 API 生成无法进行，终止"
          break
          ;;
      esac
    fi
  done

  # ---------------------------------------------------------------- 7) API 产物核验
  banner "API 产物核验"
  local a found=0
  for a in "${API_ARTIFACTS[@]}"; do
    if [ -f "$AOSP_SRC_DIR/$a" ]; then
      log "  [OK]   $a  ($(wc -l < "$AOSP_SRC_DIR/$a") 行, $(du -h "$AOSP_SRC_DIR/$a" | cut -f1))"
      found=$((found+1))
    else
      logv "  [MISS] $a"
    fi
  done
  log "API 产物命中: ${found}/${#API_ARTIFACTS[@]}"

  if [ "$found" -eq 0 ]; then
    err "未生成任何 api/current.txt，metalava 阶段实质失败"
    failed_targets+=("no-api-output")
  fi

  # core/java/api/current.txt 与 frameworks/base/api/current.txt 内容差异摘要
  if [ -f "$AOSP_SRC_DIR/frameworks/base/api/current.txt" ] \
     && [ -f "$AOSP_SRC_DIR/core/java/api/current.txt" ]; then
    log "framework API 行数 : $(wc -l < "$AOSP_SRC_DIR/frameworks/base/api/current.txt")"
    log "corejava API 行数  : $(wc -l < "$AOSP_SRC_DIR/core/java/api/current.txt")"
  fi

  # 收集 API 契约 zip（便于后续 hook 模块开发时对比 API 变更）
  if [ "$found" -gt 0 ]; then
    local api_zip="${CI_ARTIFACT_DIR}/api-contracts.zip"
    mkdir -p "$(dirname "$api_zip")"
    ( cd "$AOSP_SRC_DIR" && zip -q -r "$api_zip" \
        "frameworks/base/api" "core/java/api" "prebuilts/sdk/current" \
        -x '*.class' -x '*.jar' 2>/dev/null ) || warn "api-contracts.zip 打包失败（忽略）"
    [ -f "$api_zip" ] && log "API 契约快照: ${api_zip} ($(du -h "$api_zip" | cut -f1))"
  fi

  # ---------------------------------------------------------------- 8) 失败处理
  if [ "${#failed_targets[@]}" -gt 0 ]; then
    err "以下 metalava 任务失败: ${failed_targets[*]}"
    err "常见原因与排查："
    err "  1) 内存不足：javac/metalava 被 OOM Kill（exit 137）"
    err "     -> 调小 JAVA_TOOL_OPTIONS 的 -Xmx（默认 6g），确认 swap 已生效"
    err "  2) API 签名不匹配：源码改了公开 API 但没更新 current.txt"
    err "     -> 用 m update-api 生成，或在 patches/ 里带上前缀 0001 的 API 补丁"
    err "  3) metalava 工具编译失败（java 依赖不完整）"
    err "     -> 检查 out/host/linux-x86/bin/metalava 是否存在，检查 JOB2 日志"
    err "  4) AOSP 源码版本与 AOSP_TAG 不符"
    err "     -> 检查 ${CI_LOG_DIR}/repo-sync-revisions.txt"
    exit 1
  fi

  # ---------------------------------------------------------------- 9) 打包
  artifacts_pack

  banner "Stage2 完成"
  log "API 契约快照与日志已随 artifact 上传"
  log "out 分片目录: ${CI_ARTIFACT_DIR}/out"
}

main "$@"
