#!/usr/bin/env bash
# =============================================================================
#  lib/common.sh —— 所有构建脚本共用的基础库
# -----------------------------------------------------------------------------
#  提供：严格模式(set -euo pipefail)、统一日志、ERR 陷阱、命令重试、
#        磁盘/内存守卫、AOSP 环境变量默认值
#  任何脚本只需 `source` 本文件即可，禁止直接执行。
# =============================================================================

# ---- 硬性要求：所有脚本 set -euo pipefail，出错立刻终止 -------------------------
set -euo pipefail
set -o pipefail

# ---- 防呆：必须用 bash 执行 ----------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[FATAL] 本脚本必须用 bash 执行（shebang 已是 #!/usr/bin/env bash）" >&2
  exit 1
fi

# =============================================================================
# 1. AOSP 相关默认参数（可被 workflow 的 env 覆盖）
# =============================================================================
: "${AOSP_TAG:=android-10.0.0_r47}"
: "${AOSP_MANIFEST_URL:=https://android.googlesource.com/platform/manifest}"
: "${AOSP_MIRROR_MANIFEST:=}"
# 注意：GitHub runner 上 /mnt 由 root 拥有，runner 用户 mkdir 会 Permission denied。
#       实测整机只有一个 ext4 根卷，任何路径可用空间相同，故放 $HOME 下。
: "${AOSP_SRC_DIR:=/home/runner/aosp}"
: "${AOSP_LUNCH_TARGET:=aosp_arm64-eng}"
: "${AOSP_OUT_PRODUCT_DIR:=arm64}"
: "${AOSP_REPO_SYNC_JOBS:=4}"
: "${AOSP_REPO_RETRY_FETCHES:=3}"      # 硬性约束：repo sync 必须带 --retry-fetches=3
: "${AOSP_REPO_DEPTH:=1}"
: "${AOSP_BUILD_JOBS:=1}"              # 硬性约束：-j1 串行编译
: "${AOSP_BUILD_KEEP_GOING:=0}"
: "${AOSP_CCACHE_ENABLE:=0}"
: "${AOSP_LMBGEN:=0}"
: "${AOSP_SKIP_METALAVA:=1}"
: "${AOSP_METALAVA_TARGETS:=metalava metalava-full metalava-sdk update-api}"
: "${AOSP_STAGE3_IMAGE_TARGETS:=systemimg vendorimg odmimg productimg ramdisk userdataimg vbmetaimg}"
: "${AOSP_SWAP_SIZE_GB:=16}"           # 硬性约束：16G swap
: "${AOSP_SWAP_FILE:=/home/runner/aosp.swap}"
: "${AOSP_SWAP_MODE:=auto}"             # auto | zram | file | both | none
: "${AOSP_ENABLE_SWAP:=1}"
: "${AOSP_FREE_SPACE_GB:=40}"
: "${AOSP_OUT_ESTIMATE_GB:=45}"
: "${AOSP_FREE_SPACE_GUARD:=1}"
: "${AOSP_OUT_PACK_MODE:=slim}"        # slim | full
: "${AOSP_OUT_PACK_LEVEL:=3}"
: "${AOSP_OUT_PART_MB:=8000}"
: "${AOSP_ARTIFACT_RETENTION_DAYS:=5}"
: "${AOSP_NINJA_TARGETS_MODE:=rspfile}" # rspfile(@file) | xargs
: "${PATCH_DIR:=$(pwd)/patches}"
: "${PATCH_APPLY_ENABLED:=1}"
: "${CI_LOG_DIR:=$(pwd)/ci_logs}"
: "${CI_ARTIFACT_DIR:=$(pwd)/.ci_artifacts}"
: "${DIST_DIR:=$(pwd)/dist_images}"

# =============================================================================
# 2. 统一日志输出
# =============================================================================
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()  { printf '\033[1;34m[%s][INFO ]\033[0m %s\n' "$(_ts)" "$*"; }
logv() { printf '\033[0;36m[%s][DEBUG]\033[0m %s\n' "$(_ts)" "$*"; }
warn() { printf '\033[1;33m[%s][WARN ]\033[0m %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '\033[1;31m[%s][ERROR]\033[0m %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 打印醒目分隔条
banner() {
  printf '\n\033[1;32m%s\033[0m\n' "============================================================"
  printf '\033[1;32m   %s\033[0m\n' "$*"
  printf '\033[1;32m%s\033[0m\n' "============================================================"
}

# =============================================================================
# 3. ERR 陷阱：任何命令失败立刻终止并打印上下文（配合 set -euo pipefail）
# =============================================================================
_on_err() {
  local rc=$?
  local line="${1:-?}"
  err "命令执行失败 (exit=${rc})，出错行号 ≈ ${line}"
  err "当前目录: $(pwd)"
  err "最近 40 行日志（若存在 ${CI_LOG_DIR}/*.log）:"
  local last
  last="$(ls -1t "${CI_LOG_DIR}"/*.log 2>/dev/null | head -n1 || true)"
  if [ -n "$last" ] && [ -f "$last" ]; then
    tail -n 40 "$last" >&2 || true
  fi
  err "构建失败：请到该次 run 的 logs-* artifact 中下载完整日志排查。"
  exit "$rc"
}

# 只在顶层脚本里注册一次
enable_err_trap() {
  trap '_on_err $LINENO' ERR
  trap 'err "收到 SIGINT/TERM，终止构建"; exit 130' INT TERM
}

# =============================================================================
# 4. 命令重试（对抗云端网络抖动 / 临时性 IO 错误）
#    用法: retry 3 sleep 5
# =============================================================================
retry() {
  local max="$1"; shift
  local n=0
  local delay=10
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then
      err "重试 ${max} 次后依然失败: $*"
      return 1
    fi
    warn "第 ${n}/${max} 次失败，${delay}s 后重试: $*"
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 120 ] && delay=120
  done
  return 0
}

# =============================================================================
# 5. 日志收集：把脚本全部 stdout/stderr 落到 ci_logs/<name>.log
#    失败时 workflow 的 always() 步骤会上传整个 ci_logs/
# =============================================================================
start_logging() {
  local name="$1"
  mkdir -p "$CI_LOG_DIR"
  local f="${CI_LOG_DIR}/${name}.log"
  : > "$f"
  # 保留宿主 shell 原有 stdout，同时全部落盘
  exec > >(tee -a "$f") 2>&1
  export CI_LOG_FILE="$f"
  log "日志文件: ${f}"
}

# =============================================================================
# 6. 资源守卫
# =============================================================================

# 打印磁盘/内存信息（排错时第一手资料）
resource_report() {
  log "===== 磁盘 (df -hT) ====="
  df -hT || true
  log "===== 内存 (free -h) ====="
  free -h || true
  log "===== Swap (swapon --show) ====="
  swapon --show || true
  log "===== CPU (nproc) ====="
  nproc
  log "===== 磁盘 (out 所在分区) ====="
  df -h "$AOSP_SRC_DIR" 2>/dev/null || df -h . || true
}

# 开工前检查剩余空间，不足直接失败（避免编译到一半磁盘写满导致 out 损坏）
require_free_gb() {
  local need="${1:-$AOSP_FREE_SPACE_GB}"
  local p="${2:-$AOSP_SRC_DIR}"
  local avail
  avail="$(df -BG --output=avail "$p" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
  log "分区 ${p} 剩余 ${avail}GB，需要 >= ${need}GB"
  if [ "$avail" -lt "$need" ]; then
    err "剩余空间不足：${avail}GB < ${need}GB。"
    err "GitHub 托管 runner 只有 ~87GB 可用，装不下 AOSP 源码 + 16G swap + out。"
    err "可行处理："
    err "  1) 换用带大容量磁盘的 self-hosted runner（推荐，见 README「硬性容量约束」）；"
    err "  2) 启用 --prune-source 裁剪无关源码，并调小 AOSP_OUT_ESTIMATE_GB；"
    err "  3) 调低 AOSP_FREE_SPACE_GB 只做告警（不推荐，磁盘写满会导致 out 不可用）。"
    exit 1
  fi
}

# =============================================================================
# 6b. 可写性预检 + 编译容量预估
#     runner 上踩过的坑：/mnt 由 root 拥有，runner 用户 mkdir 直接 Permission denied，
#     必须在 repo init 之前就失败并说清楚，否则只会在 2 分钟后才炸。
# =============================================================================
ensure_writable_dir() {
  local d="$1"
  if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
    log "目录可写: ${d}"
    return 0
  fi
  err "无法创建/写入目录: ${d}"
  err "该路径可能属于 root（例如 /mnt、/opt、/usr/local/src）。"
  err "GitHub runner 的普通用户是 'runner'（uid 1001），只有 \$HOME 与 \$GITHUB_WORKSPACE 可写。"
  err "请把 AOSP_SRC_DIR 改成 \$HOME 下的路径，例如 /home/runner/aosp"
  exit 1
}

# 编译前容量预估：
#   可用空间  >=  源码占用 + swap + out 预估
# 不满足就提前失败（并给出可执行的调优建议），避免编译到 90% 时磁盘写满、out 半残。
project_build_capacity() {
  banner "编译容量预估"
  local p="${1:-$AOSP_SRC_DIR}"
  local avail src_gb swap_gb out_gb need_gb
  avail="$(df -BG --output=avail "$p" | tail -n1 | tr -dc '0-9')"
  src_gb="$(du -BG --exclude=out --exclude=.repo "$AOSP_SRC_DIR" 2>/dev/null | cut -f1 | tr -dc '0-9' || echo 0)"
  swap_gb="$AOSP_SWAP_SIZE_GB"
  out_gb="$AOSP_OUT_ESTIMATE_GB"
  need_gb=$(( src_gb + swap_gb + out_gb ))

  log "  分区可用     : ${avail}GB"
  log "  AOSP 源码    : ${src_gb}GB"
  log "  swap 文件    : ${swap_gb}GB"
  log "  out 预估     : ${out_gb}GB"
  log "  合计需要     : ${need_gb}GB"

  {
    echo "avail_gb=${avail}"
    echo "source_gb=${src_gb}"
    echo "swap_gb=${swap_gb}"
    echo "out_estimate_gb=${out_gb}"
    echo "need_gb=${need_gb}"
  } > "${CI_LOG_DIR}/capacity-projection.txt"

  if [ "$avail" -ge "$need_gb" ]; then
    log "容量充足（余量 $(( avail - need_gb ))GB）✓"
    return 0
  fi

  local gap=$(( need_gb - avail ))
  err "容量不足：缺 ${gap}GB"
  err "按影响从大到小的处理顺序："
  err "  1) 换大磁盘 runner（唯一根治方案，README 第四章）"
  err "  2) 把 AOSP_OUT_ESTIMATE_GB 调小并开启更多 --prune-source 项（省 5~15GB 源码）"
  err "  3) 把 AOSP_SWAP_SIZE_GB 从 16 调小（swap 占的是同一块盘）"
  err "     注意：调小 swap 会提高 OOM 风险（runner 只有 15GB 物理内存）"
  if [ "${AOSP_FREE_SPACE_GUARD:-1}" = "1" ]; then
    err "守卫开启，直接终止。确认要冒险继续请设 AOSP_FREE_SPACE_GUARD=0（out 可能在编译中损坏）"
    exit 1
  fi
  warn "守卫已关闭，继续执行（out 可能在编译途中因磁盘写满而损坏）"
}

# =============================================================================
# 7. AOSP 路径速查
# =============================================================================
aosp_src()      { echo "$AOSP_SRC_DIR"; }
aosp_out()      { echo "${AOSP_SRC_DIR}/out"; }
aosp_product()  { echo "${AOSP_SRC_DIR}/out/target/product/${AOSP_OUT_PRODUCT_DIR}"; }

# 进入 AOSP 根目录并 source envsetup + lunch。
# 注意：envsetup.sh 内部会 `set +u` 并使用未定义变量，必须临时关掉 -u/pipefail。
aosp_lunch() {
  local target="${1:-$AOSP_LUNCH_TARGET}"
  cd "$AOSP_SRC_DIR"
  log "source build/envsetup.sh + lunch ${target}"
  set +u +o pipefail
  # shellcheck disable=SC1091
  source build/envsetup.sh
  lunch "$target" || { set -u -o pipefail; die "lunch ${target} 失败"; }
  set -u -o pipefail
  log "LUNCH 目标: ${TARGET_PRODUCT}/${TARGET_BUILD_VARIANT}"
  log "TARGET_ARCH : ${TARGET_ARCH:-<unset>}"
  log "out 目录    : $(aosp_out)"
  [ "${TARGET_ARCH:-}" = "arm64" ] || warn "TARGET_ARCH=${TARGET_ARCH:-<unset>}，期望 arm64"
}

# 定位 ninja（AOSP 自带版本优先，@file 响应文件支持更可靠）
find_ninja() {
  local c
  for c in \
      "${AOSP_SRC_DIR}/prebuilts/build-tools/linux-x86/bin/ninja" \
      "${AOSP_SRC_DIR}/out/host/linux-x86/bin/ninja" \
      "${AOSP_SRC_DIR}/out/soong/soong-*/bin/ninja"; do
    if [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  if command -v ninja >/dev/null 2>&1; then command -v ninja; return 0; fi
  die "找不到 ninja 可执行文件"
}

# 目标是否在 Makefile 中真实存在（防止 m 报 Unknown target）
target_exists_in_makefile() {
  local t="$1"
  grep -qE "^\s*${t}:" "$AOSP_SRC_DIR/build/core/Makefile" 2>/dev/null
}

# 目标是否在已生成的 build.ninja 中真实存在
target_exists_in_ninja() {
  local ninja="$1" out="$2" t="$3"
  grep -qE "^build ${t}(:|\s)" "$out/soong/build.ninja" 2>/dev/null \
    || grep -qE "^build ${t}\." "$out/soong/build.ninja" 2>/dev/null
}
