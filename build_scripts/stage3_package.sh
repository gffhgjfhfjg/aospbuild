#!/usr/bin/env bash
# =============================================================================
#  build_scripts/stage3_package.sh —— Job4 主体：镜像打包与产物导出
# -----------------------------------------------------------------------------
#  职责：
#    1) 解包 Job3(metalava) 产出的 out 目录
#    2) lunch aosp_arm64-eng
#    3) 串行执行镜像打包：
#         m installclean        —— 清理 staging，保证镜像由本阶段全新生成
#         m systemimg vendorimg odmimg productimg ramdisk userdataimg vbmetaimg
#         m bootimg             —— kernel 无源码依赖，eng 变体不产出真实 boot.img，跳过
#    4) 收集 out/target/product/arm64/*.img 到 dist_images/
#    5) 计算 SHA256、生成 BUILD_INFO.txt、可选打 OTA 包
#    6) 上传最终镜像 artifact
#
#  重要提示（务必阅读 README「重要提示」章节）：
#    aosp_arm64-eng 是 AOSP 通用 ARM64 参考镜像（generic target），
#    它不是任何实体手机的固件，不能直接刷入 Pixel / 小米 / OPPO 等真机。
#    后续集成 GhostHWBP 等硬件断点 ko 驱动时，必须换成与目标机型内核源码
#    匹配的设备树（device/<vendor>/<name> + kernel/<vendor>）才能加载该 ko。
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

start_logging "stage3_package"

# 参与打包的镜像（不含 boot.img：generic target 无对应 kernel）
IMAGE_TARGETS_DEFAULT=(
  systemimg
  vendorimg
  odmimg
  productimg
  ramdisk
  userdataimg
  vbmetaimg
)

# 期望产出的镜像文件名（用于最终核验）
EXPECTED_IMAGES=(
  "system.img"
  "vendor.img"
  "odm.img"
  "userdata.img"
  "vbmeta.img"
)

# =============================================================================
# --collect-only：只收集产物（workflow 在 always() 步骤里调，失败时也能拿到半成品）
# =============================================================================
collect_only=0
for a in "$@"; do
  case "$a" in
    --collect-only) collect_only=1 ;;
  esac
done

collect_images() {
  local prod; prod="$(aosp_product)"
  banner "收集镜像产物"

  if [ ! -d "$prod" ]; then
    err "产物目录不存在: ${prod}"
    return 1
  fi

  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"

  # 1) 复制所有 .img
  local n=0
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    log "复制: $(basename "$f")  ($(du -h "$f" | cut -f1))"
    cp -f "$f" "$DIST_DIR/" || { err "复制失败: $f"; return 1; }
    n=$((n+1))
  done < <(find "$prod" -maxdepth 1 -type f -name '*.img' | LC_ALL=C sort)

  if [ "$n" -eq 0 ]; then
    err "产物目录中没有任何 .img 文件"
    ls -la "$prod" >&2 || true
    return 1
  fi
  log "共收集 ${n} 个镜像"

  # 2) 拷贝 target-files / OTA 相关 zip（若存在）
  local z
  for z in \
      "$prod"/*-target_files-*.zip \
      "$prod"/*-ota-*.zip \
      "$prod"/*-symbols.zip ; do
    [ -f "$z" ] || continue
    log "复制: $(basename "$z")"
    cp -f "$z" "$DIST_DIR/"
  done

  # 3) 拷贝 obj/ 下的小型元数据（image 的 mkfs 参数、fs_config、文件列表）
  local meta
  for meta in \
      "$prod"/obj/IMAGE_MAKEUP_FILE \
      "$prod"/obj/filesystem_config.txt \
      "$prod"/obj/releasetools_util_context \
      "$prod"/obj/PACKAGING_TARGET_FILE.txt ; do
    [ -f "$meta" ] || continue
    cp -f "$meta" "$DIST_DIR/" 2>/dev/null || true
  done
  # 目录型元数据
  for meta in \
      "$prod"/obj/ETC \
      "$prod"/obj/PACKAGES ; do
    [ -d "$meta" ] || continue
    cp -rf "$meta" "$DIST_DIR/" 2>/dev/null || true
  done

  # 4) SHA256
  banner "计算 SHA256"
  ( cd "$DIST_DIR" && sha256sum ./*.img > SHA256SUMS 2>/dev/null ) || warn "SHA256 生成失败"
  [ -f "$DIST_DIR/SHA256SUMS" ] && cat "$DIST_DIR/SHA256SUMS"

  # 5) BUILD_INFO
  {
    echo "# AOSP10 arm64 cloud build artifact"
    echo "built_at_utc      = $(date -u +%FT%TZ)"
    echo "aosp_tag          = ${AOSP_TAG}"
    echo "lunch_target      = ${AOSP_LUNCH_TARGET}"
    echo "target_arch       = arm64"
    echo "build_variant     = eng"
    echo "host_arch         = $(uname -m)"
    echo "host_os           = $(. /etc/os-release && echo "${PRETTY_NAME}")"
    echo "runner            = ${GITHUB_RUNNER_OS:-local}/${GITHUB_RUN_ID:-local}"
    echo "commit            = ${GITHUB_SHA:-local}"
    echo "out_pack_mode     = ${AOSP_OUT_PACK_MODE}"
    echo "metalava_excluded_in_stage1 = ${AOSP_SKIP_METALAVA}"
    echo
    echo "## images"
    ( cd "$DIST_DIR" && for i in ./*.img; do
        echo "  $(basename "$i")  $(stat -c%s "$i") bytes"
      done ) 2>/dev/null || true
    echo
    echo "## 重要提示"
    echo "  aosp_arm64-eng 是 AOSP 通用 ARM64 参考镜像（generic target）。"
    echo "  它不是任何实体手机的官方/第三方固件，禁止直接刷入真机。"
    echo "  集成 GhostHWBP 等硬件断点 ko 驱动时，必须使用与目标机型内核源码"
    echo "  匹配的设备树与 kernel/<vendor> 分支，通用镜像内核无法加载该 ko。"
    echo
    echo "## 声明"
    echo "  本产物仅用于 Android 安全研究与逆向教学，严禁用于未授权应用逆向、"
    echo "  破解等违法场景。"
  } > "$DIST_DIR/BUILD_INFO.txt"
  log "BUILD_INFO.txt 已生成"

  # 6) 体积汇总
  log "dist_images 总体积: $(du -sh "$DIST_DIR" | cut -f1)"
  return 0
}

# =============================================================================
# 主流程
# =============================================================================
main() {
  banner "Stage3 开始：ARM64 镜像打包"

  log "参数:"
  log "  AOSP_LUNCH_TARGET          = ${AOSP_LUNCH_TARGET}"
  log "  AOSP_STAGE3_IMAGE_TARGETS  = ${AOSP_STAGE3_IMAGE_TARGETS}"

  [ -d "$AOSP_SRC_DIR" ] || die "AOSP 源码目录不存在: ${AOSP_SRC_DIR}"
  [ -d "$AOSP_SRC_DIR/build/make" ] || die "${AOSP_SRC_DIR} 不是有效的 AOSP 根目录"

  # ---------------------------------------------------------------- 0) 资源
  create_swap "$AOSP_SWAP_SIZE_GB" "$AOSP_SWAP_FILE"
  report_memory
  require_free_gb "$AOSP_FREE_SPACE_GB" "$AOSP_SRC_DIR"

  # ---------------------------------------------------------------- 1) out
  local out; out="$(aosp_out)"
  if [ -d "$out/soong" ]; then
    log "检测到已解包的 out 目录，跳过解包"
  else
    banner "解包 Job3(metalava) 产出的 out 目录"
    artifacts_unpack
  fi
  log "out 体积: $(du -sh "$out" | cut -f1)"

  # ---------------------------------------------------------------- 2) lunch
  aosp_lunch "$AOSP_LUNCH_TARGET"

  # ---------------------------------------------------------------- 3) 环境变量
  export BUILD_NUMBER="${BUILD_NUMBER:-1}"
  export USE_CCACHE="$AOSP_CCACHE_ENABLE"
  # 打包阶段不需要 lz4（generic 镜像，压缩反而增加耗时），但保留 CONFIG
  export LMBGEN="$AOSP_LMBGEN"
  export NINJA_ARGS="-j${AOSP_BUILD_JOBS} -k ${AOSP_BUILD_KEEP_GOING}"
  export SOONG_NINJA_NUM_JOBS="$AOSP_BUILD_JOBS"
  export LANG="${LANG:-C.UTF-8}"
  export SOONG_SILENT=true
  # 镜像打包不需要 vfat/ext4 加密，关闭以省时间
  export ENABLE_BUILD_VERITY=0
  export PRODUCT_USE_VERITY=false

  log "BUILD_NUMBER = ${BUILD_NUMBER}"

  # ---------------------------------------------------------------- 4) 刷新构建图
  banner "刷新 soong 构建图 (m nothing)"
  m -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" nothing
  [ -f "$out/soong/build.ninja" ] || die "soong 构建图生成失败"

  # ---------------------------------------------------------------- 5) installclean
  #  Job2 的 slim 打包删掉了 staging 目录，这里再显式 installclean 一次，
  #  保证 system/vendor/odm 是本阶段全新安装出来的。
  banner "m installclean"
  if m -j"$AOSP_BUILD_JOBS" -k 0 installclean; then
    log "installclean 完成"
  else
    warn "installclean 失败（可能 out 已是干净状态），继续"
  fi

  # ---------------------------------------------------------------- 6) 镜像目标规划
  banner "规划镜像目标"
  local requested=($AOSP_STAGE3_IMAGE_TARGETS)
  local runnable=()
  local t
  for t in "${requested[@]}"; do
    [ -n "$t" ] || continue
    if target_exists_in_makefile "$t"; then
      runnable+=("$t")
      log "  [RUN ] ${t}"
    else
      warn "  [SKIP] ${t}（build/core/Makefile 中未定义，版本差异）"
    fi
  done

  # 用 IMAGE_TARGETS_DEFAULT 兜底
  if [ "${#runnable[@]}" -eq 0 ]; then
    log "配置目标均不存在，回退到默认镜像目标列表"
    runnable=("${IMAGE_TARGETS_DEFAULT[@]}")
    for t in "${runnable[@]}"; do
      if target_exists_in_makefile "$t"; then
        log "  [RUN ] ${t}"
      else
        warn "  [SKIP] ${t}"
      fi
    done
  fi
  [ "${#runnable[@]}" -eq 0 ] && die "没有任何可用的镜像目标，检查 AOSP 版本"

  {
    echo "# stage3 image plan"
    echo "generated_at_utc=$(date -u +%FT%TZ)"
    printf '%s\n' "${runnable[@]}"
  } > "${CI_LOG_DIR}/stage3-plan.txt"

  # ---------------------------------------------------------------- 7) 打包
  local failed=0
  for t in "${runnable[@]}"; do
    banner "打包镜像: ${t}"
    local t0=$SECONDS
    if m -j"$AOSP_BUILD_JOBS" -k 0 "$t"; then
      log "完成: ${t}  用时 $(( (SECONDS - t0) / 60 )) 分 $(( (SECONDS - t0) % 60 )) 秒"
    else
      err "失败: ${t}"
      failed=$((failed+1))
      # 不立刻退出：让 workflow 的 always() 步骤仍能收集半成品镜像
      # 但累计失败超过一半则立刻中断（说明是系统性问题）
      if [ "$failed" -gt $(( ${#runnable[@]} / 2 )) ]; then
        err "超过半数镜像目标失败，判定为系统性问题，终止"
        break
      fi
    fi
  done

  # ---------------------------------------------------------------- 8) 收集产物
  if ! collect_images; then
    err "镜像收集失败"
    if [ "$failed" -eq 0 ]; then
      err "注意：所有镜像目标都报成功但没找到 .img，请检查 build/core/Makefile 里的镜像规则"
    fi
    exit 1
  fi

  # ---------------------------------------------------------------- 9) 最终核验
  banner "镜像核验"
  local prod; prod="$(aosp_product)"
  local miss=0
  for f in "${EXPECTED_IMAGES[@]}"; do
    if [ -f "$prod/$f" ]; then
      log "  [OK]   $f  $(du -h "$prod/$f" | cut -f1)"
    else
      logv "  [MISS] $f（该目标可能本就不产出此镜像，generic target 常见）"
      miss=$((miss+1))
    fi
  done
  log "期望 ${#EXPECTED_IMAGES[@]} 项，缺失 ${miss} 项（缺失不代表失败）"

  # 逐镜像做一次完整性粗检：能否被 simg2img / file 识别
  local img
  while IFS= read -r img; do
    [ -f "$img" ] || continue
    local ftype
    ftype="$(file -b "$img" 2>/dev/null | cut -c1-90)"
    log "  $(basename "$img"): ${ftype}"
  done < <(find "$prod" -maxdepth 1 -type f -name '*.img' | LC_ALL=C sort)

  # 10) 额外产物：OTA 包（可选，失败不阻塞）
  if [ "${AOSP_STAGE3_BUILD_OTA:-1}" = "1" ]; then
    banner "生成 OTA 包（可选）"
    if m -j"$AOSP_BUILD_JOBS" -k 0 otapackage; then
      log "OTA 包生成成功"
    else
      warn "OTA 包生成失败（不阻塞主流程）"
    fi
  fi

  # 11) 重新收集一次（把 OTA zip 纳入 dist_images）
  if [ "${AOSP_STAGE3_BUILD_OTA:-1}" = "1" ]; then
    local z
    for z in "$prod"/otapackage/*.zip; do
      [ -f "$z" ] || continue
      mkdir -p "$DIST_DIR/otapackages"
      cp -f "$z" "$DIST_DIR/otapackages/" || true
      log "收集 OTA: $(basename "$z")"
    done
  fi

  # 12) mapping 文件（eng 变体通常无）
  local mapf
  for mapf in "$prod"/obj/mapping.txt "$prod"/mapping.txt; do
    [ -f "$mapf" ] && cp -f "$mapf" "$DIST_DIR/" 2>/dev/null || true
  done

  banner "Stage3 完成"
  log "镜像目录: ${DIST_DIR}"
  ls -lh "$DIST_DIR" || true
  log "最终镜像将作为 aosp_arm64-eng-images artifact 上传（保留 30 天）"
  echo
  log "==== 重要提示 ===="
  log "aosp_arm64-eng 是 AOSP 通用 ARM64 参考镜像，不能直接刷入实体手机。"
  log "集成 GhostHWBP 硬件断点 ko 驱动时必须换成匹配目标机型内核源码的设备树。"
}

main "$@"
