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
: "${AOSP_SWAP_MODE:=auto}"
: "${AOSP_SWAP_FALLBACK_FILE:=0}"   # zram 不可用时是否退回建 swap 文件(会占 out 余量)             # auto | zram | file | both | none
: "${AOSP_ENABLE_SWAP:=1}"
: "${AOSP_FREE_SPACE_GB:=40}"
: "${AOSP_OUT_ESTIMATE_GB:=42}"
: "${AOSP_SOURCE_ESTIMATE_GB:=64}"   # repo sync --depth=1 实测 63~64GB
: "${AOSP_DISK_STOP_GB:=5}"           # 编译期磁盘阈值, 低于则优雅停止(不写坏 out)
: "${AOSP_FREE_SPACE_GUARD:=warn}"   # warn=告警放行(默认) | 1=硬失败 | 0=静默
: "${AOSP_OUT_PACK_MODE:=slim}"        # slim | full
: "${AOSP_OUT_PACK_LEVEL:=3}"
: "${AOSP_OUT_PART_MB:=8000}"
: "${AOSP_ARTIFACT_RETENTION_DAYS:=5}"
: "${AOSP_NINJA_TARGETS_MODE:=rspfile}" # rspfile(@file) | xargs
# 完工判定的行数容差，0 = 严格（推荐）。
# 容差 >0 会把"仅剩少量工作"误判成"已完成"，导致不完整的 out 被当成完整产物传下去。
: "${AOSP_COMPLETE_TOLERANCE:=0}"
# 编译 shard 的 SIGINT 优雅停止等待秒数（超时升级 SIGTERM -> SIGKILL）
: "${AOSP_SHARD_SIGINT_GRACE_SEC:=120}"
: "${AOSP_SHARD_INDEX:=1}"
: "${AOSP_SHARD_TOTAL:=2}"
: "${AOSP_SHARD_BUDGET_MIN:=250}"
: "${AOSP_SHARD_DOWNLOAD:=0}"
: "${AOSP_SHARD_REQUIRE_COMPLETE:=0}"
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
  avail="$(avail_gb "$p")"
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

# =============================================================================
# 体积/空间数值读取helper
# -----------------------------------------------------------------------------
#  【为什么需要它们 —— 踩过的坑】
#  1) `du -BG <dir> | cut -f1 | tr -dc '0-9'` 是错的：
#     du 输出是 "63G<TAB>/home/runner/aosp"，cut -f1 依赖 TAB 分隔符，
#     一旦分隔符不是 TAB（比如 locale/实现差异）就会把整行交给 tr -dc '0-9'，
#     结果把**路径里的数字也拼进来**。run 36970996892 里就出现了
#     source_measured_gb=1111111111111111111111111111111111111111111111111111111111
#     （58 个 1，全来自路径 /home/runner/aosp 被重复拼接），直接导致容量守卫算错。
#  2) `grep -c` 在匹配 0 行时打印 0 但退出码为 1，
#     后面接 `|| echo 0` 会多出一行，变成 "0\n0" 这种两行字符串。
#
#  统一用下面两个函数，避免同类 bug 再次出现。
# =============================================================================

# du_gb <dir> [extra du args...]  -> 目录占用（向上取整的 GB，纯数字）
du_gb() {
  local d="$1"; shift
  local v
  [ -e "$d" ] || { echo 0; return 0; }
  # -s = summarize，只输出体积不带路径，从根上避免路径数字被拼进来
  v="$(du -sBG "$@" -- "$d" 2>/dev/null | head -n1 | grep -oE '[0-9]+' | head -n1 || true)"
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

# avail_gb <path>  -> 分区剩余 GB（纯数字）
avail_gb() {
  local p="${1:-/}"
  local v
  v="$(df -BG --output=avail "$p" 2>/dev/null | tail -n1 | grep -oE '[0-9]+' | head -n1 || true)"
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

# count_lines <file-or-stdin>  -> 行数（grep -c 语义安全的计数）
# 用法: n=$(count_lines "$f"); n=$(some_cmd | count_lines -)
count_lines() {
  local src="${1:--}"
  local n
  if [ "$src" = "-" ]; then
    n="$(grep -c '' || true)"
  else
    [ -f "$src" ] || { echo 0; return 0; }
    n="$(grep -c '' < "$src" || true)"
  fi
  case "$n" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
}

# 编译前容量预估：见下方 project_build_capacity
# =============================================================================
# 容量守卫（两阶段）
# -----------------------------------------------------------------------------
#  用法: project_build_capacity [pre_sync|post_sync]
#
#  【为什么要分两阶段 —— 这里踩过一个致命的公式错误】
#  `df --output=avail` 给的是"当前剩余空间"。源码一旦 repo sync 落盘，
#  它就已经从 avail 里扣掉了。如果再把 src_gb 加进需求侧，就等于把源码算了两遍：
#      磁盘 49GB 剩余 / 源码已占 62GB / 需求侧写成 62+42=104GB  -> 必然误报"容量不足"
#  正确做法：
#    pre_sync  （sync 之前）: avail >= 预计源码 + out   —— 源码还没占盘，要全额算
#    post_sync （sync 之后）: avail >= out 还需增量      —— 源码已占盘，只算增量
#
#  AOSP 10 `--depth=1` 源码实测 62~63GB（AOSP_SOURCE_ESTIMATE_GB）。
#
#  【swap 在 pre_sync 阶段按 0 计】
#  pre_sync 跑在 repo sync 之前，此刻 swap 文件还没创建，真实占用是未知的。
#  而且 AOSP_SWAP_MODE=auto 的设计是"优先 zram（0 磁盘）/ 磁盘不够就不建文件"，
#  把 16GB 记进需求等于假设了一个大概率不会发生的最坏情况，会白白拒掉本来能跑的构建。
#  swap 的真实决策由后面的 create_swap 依据当时的 df 做自适应，守卫不重复预扣。
# =============================================================================
# 容量守卫
# -----------------------------------------------------------------------------
#  用法: project_build_capacity <pre_sync|post_sync> [path]
#
#  【三个踩过的坑 —— 这段注释就是防止再犯】
#
#  1) 不要把已经落盘的东西再加进需求侧。
#     `df --output=avail` 给的是"当前剩余"，任何已经写到这块盘上的文件
#     都已经被扣掉了。重复计入会直接否决掉本来能跑通的构建：
#       * 源码: run 36970996892 之前，avail=112 却算出 need=63+42+16=121
#       * swap: run 36972642241，avail=44（已含 swap 文件占的 6GB）
#               又把 swap_on_disk=6 加进需求 -> need=48 > 44 -> 误报"缺 4GB"
#     所以：
#       pre_sync  （sync 之前）源码未落盘 -> 全额计入；swap 尚未创建 -> 0
#       post_sync （sync 之后）源码已落盘 -> 不计；  swap 已落盘     -> 不计
#
#  2) 参数顺序必须是 (phase, path)。曾经把 path 传到第一个参数，
#     结果 phase 变成 "/home/runner/aosp"，日志里直接出现
#     `phase=/home/runner/aosp` 这种一眼看得出问题的值。
#     所以这里对 phase 做白名单校验，传错立刻报错而不是继续算。
#
#  3) 守卫默认只告警（AOSP_FREE_SPACE_GUARD=warn），不硬失败。
#     原因：AOSP_OUT_ESTIMATE_GB 是**估计值**，不是实测值。
#     拿估计值硬性否决构建，估偏了就会拒掉本来能跑通的流水线；
#     而"磁盘真写满"这个真实风险，由编译过程监控磁盘 + 优雅停止来兜
#     （见 compile_shard.sh 的 build_with_budget 里的磁盘监控）。
#     需要硬失败时显式设 AOSP_FREE_SPACE_GUARD=1。
#
#  AOSP 10 `--depth=1` 源码实测 63~64GB（AOSP_SOURCE_ESTIMATE_GB）。
# =============================================================================
AOSP_SOURCE_ESTIMATE_GB="${AOSP_SOURCE_ESTIMATE_GB:-64}"

project_build_capacity() {
  local phase="${1:-post_sync}"
  local p="${2:-$AOSP_SRC_DIR}"

  # 参数顺序自检：phase 只允许两个合法值
  case "$phase" in
    pre_sync|post_sync) : ;;
    *)
      err "project_build_capacity 第 1 个参数必须是 pre_sync|post_sync，收到: '${phase}'"
      err "调用方可能还在用旧签名。正确用法："
      err "  project_build_capacity post_sync \"\$AOSP_SRC_DIR\""
      exit 1
      ;;
  esac

  banner "容量守卫（阶段=${phase}）"

  local out; out="$(aosp_out)"
  local avail src_gb out_now_gb out_need need_gb
  avail="$(avail_gb "$p")"
  src_gb="$(du_gb "$AOSP_SRC_DIR" --exclude=out)"
  out_now_gb="$(du_gb "$out")"
  out_need=$(( AOSP_OUT_ESTIMATE_GB - out_now_gb ))
  [ "$out_need" -lt 0 ] && out_need=0

  # 需求侧：严格遵守"不重复计入已落盘的东西"
  if [ "$phase" = "pre_sync" ]; then
    need_gb=$(( AOSP_SOURCE_ESTIMATE_GB + out_now_gb + out_need ))   # 源码未落盘，全额计
  else
    need_gb=$(( out_need ))                                            # 源码/swap 均已落盘
  fi

  if [ "$phase" = "pre_sync" ]; then
    log "  源码计入需求   : 是（${AOSP_SOURCE_ESTIMATE_GB}GB，尚未落盘）"
  else
    log "  源码计入需求   : 否（已落盘，已从 avail 中扣除）"
  fi
  log "  分区可用       : ${avail}GB"
  log "  AOSP 源码(实测): ${src_gb}GB"
  log "  swap 计入需求  : 0GB（zram 不占盘；swap 文件已落盘也已从 avail 扣除）"
  log "  out 现状/估计  : ${out_now_gb}GB / ${AOSP_OUT_ESTIMATE_GB}GB  -> 还需 ${out_need}GB"
  log "  本阶段需求合计 : ${need_gb}GB"
  log "  余量           : $(( avail - need_gb ))GB"

  {
    echo "phase=${phase}"
    echo "avail_gb=${avail}"
    echo "source_measured_gb=${src_gb}"
    echo "source_estimate_gb=${AOSP_SOURCE_ESTIMATE_GB}"
    echo "source_counted_in_need=$([ "$phase" = pre_sync ] && echo yes || echo no)"
    echo "swap_counted_in_need=no"
    echo "out_now_gb=${out_now_gb}"
    echo "out_estimate_gb=${AOSP_OUT_ESTIMATE_GB}"
    echo "out_need_extra_gb=${out_need}"
    echo "need_gb=${need_gb}"
    echo "slack_gb=$(( avail - need_gb ))"
    echo "guard_mode=${AOSP_FREE_SPACE_GUARD:-warn}"
    echo "shard=${AOSP_SHARD_INDEX:-1}/${AOSP_SHARD_TOTAL:-1}"
  } > "${CI_LOG_DIR}/capacity-projection.txt"

  if [ "$avail" -ge "$need_gb" ]; then
    log "容量充足（余量 $(( avail - need_gb ))GB）✓"
    return 0
  fi

  local gap=$(( need_gb - avail ))
  warn "容量可能不足：缺 ${gap}GB（估计值需求 ${need_gb}GB vs 可用 ${avail}GB）"
  warn "实测参考：回收磁盘后 ~112GB 可用 - 源码 ${src_gb}GB = 留给 out ~${avail}GB"
  warn "注意：AOSP_OUT_ESTIMATE_GB=${AOSP_OUT_ESTIMATE_GB} 是**估计值**，可能偏保守。"
  warn "     默认放行；编译过程会监控磁盘，低于 ${AOSP_DISK_STOP_GB:-5}GB 时优雅停止，"
  warn "     不会写出半残的 out。"
  warn "想省空间，按效果排序："
  warn "  1) 确认 AOSP_RECLAIM_DISK=1（回收预装 Android SDK/dotnet/swift，已省 ~25GB）"
  warn "  2) AOSP_SWAP_MODE=auto 时 zram 不可用会自动跳过 swap 文件（省 5~6GB 给 out）"
  warn "  3) 换大磁盘 runner：self-hosted（本仓库 runs-on 已参数化，改一处即可）"
  warn "     已实测 ubuntu-22.04-large/2xlarge/4xlarge 在本账号不会被调度（一直 queued）"
  warn "  4) 加 --prune-source 裁剪无关源码（每项约省 1~4GB，需自行确认不参与目标图）"

  case "${AOSP_FREE_SPACE_GUARD:-warn}" in
    1)   err "守卫模式=1(硬失败)，终止。设成 warn 可改为告警放行"; exit 1 ;;
    0)   : ;;
    warn) : ;;
    *)    warn "未知的 AOSP_FREE_SPACE_GUARD='${AOSP_FREE_SPACE_GUARD}'，按 warn 处理" ;;
  esac
  log "守卫放行，继续（编译过程会监控磁盘：低于 ${AOSP_DISK_STOP_GB:-5}GB 时优雅停止）"
}

# =============================================================================
# 7. AOSP 路径速查
# =============================================================================
aosp_src()      { echo "$AOSP_SRC_DIR"; }
aosp_out()      { echo "${AOSP_SRC_DIR}/out"; }
aosp_product()  { echo "${AOSP_SRC_DIR}/out/target/product/${AOSP_OUT_PRODUCT_DIR}"; }

# 进入 AOSP 根目录并 source envsetup + lunch。
#
# 【为什么这么绕 —— run 36978202595 实测踩的坑】
# AOSP 10 的 build/envsetup.sh 里，m() 在第 744 行直接引用 $TOP。
# 当 TOP 未预置、且 shell 处于 nounset（set -u）状态时会报：
#     build/envsetup.sh: line 744: TOP: unbound variable
#     Couldn't locate the top of the tree.  Try setting TOP.
# 表现极具迷惑性：envsetup 和 lunch 都成功了、工具链自检也过了，
# 但紧接着的 `m nothing` 直接失败 —— 看起来像 soong 问题，其实是 shell 选项问题。
#
# 三管齐下：
#   1) 预置并 export TOP / ANDROID_BUILD_TOP，让 envsetup 跳过目录发现逻辑
#   2) 关闭 nounset（AOSP 的 envsetup 与 m() 大量使用未加 :- 的变量引用）
#   3) 不再把 nounset 恢复回去 —— 后续所有 m 调用都依赖它处于关闭状态
#
# 副作用：脚本余下部分不再有 nounset 保护（变量名打错不会报错）。
# 所有对外参数都用 ${VAR:-default} 兜了默认值，可接受。
aosp_lunch() {
  local target="${1:-$AOSP_LUNCH_TARGET}"
  cd "$AOSP_SRC_DIR"

  export TOP="$AOSP_SRC_DIR"
  export ANDROID_BUILD_TOP="$AOSP_SRC_DIR"

  log "source build/envsetup.sh + lunch ${target}"
  set +u
  set +o pipefail
  # shellcheck disable=SC1091
  source build/envsetup.sh
  lunch "$target" || die "lunch ${target} 失败"
  # 双保险：即使 envsetup 内部覆盖过，这里再导出一次
  export TOP="${TOP:-$AOSP_SRC_DIR}"
  export ANDROID_BUILD_TOP="${ANDROID_BUILD_TOP:-$AOSP_SRC_DIR}"

  log "TOP=$TOP"
  log "TARGET_PRODUCT=${TARGET_PRODUCT:-<unset>}  TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT:-<unset>}"
  # 注意：不要检查 TARGET_ARCH —— 它是 make 变量(build/core/config.mk)，
  # 不是 shell 环境变量，lunch 之后在 shell 里本来就查不到。
  # 判断 lunch 是否生效要看 TARGET_PRODUCT / TARGET_BUILD_VARIANT。
  if [ "${TARGET_PRODUCT:-}" != "aosp_arm64" ]; then
    warn "TARGET_PRODUCT=${TARGET_PRODUCT:-<unset>}，期望 aosp_arm64（lunch 可能未生效）"
  fi
  if [ "${TARGET_BUILD_VARIANT:-}" != "eng" ]; then
    warn "TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT:-<unset>}，期望 eng"
  fi

  # m() 能否工作，取决于 nounset 是否关闭 —— 这里做一次真实自检
  if ! command -v m >/dev/null 2>&1 && ! type m >/dev/null 2>&1; then
    die "envsetup 之后 m 函数不存在，lunch 流程异常"
  fi
  log "out 目录: $(aosp_out)"
  # 精确读取 nounset 状态。
  #   不能用 `set -o | grep -q nounset`  —— 关闭时也会打印 "nounset  off"，仍会命中。
  #   也不能用 glob *"nounset"*on*      —— bash 的 set -o 列表里 nounset 后面还有
  #                                          onecmd 这类选项，含 "on"，会误判为 ON。
  local nounset_state
  nounset_state="$(set -o | awk '$1=="nounset"{print $2; exit}')"
  if [ "$nounset_state" = "on" ]; then
    die "nounset 处于 ON 状态，m() 会报 'TOP: unbound variable'。这是 run 36978202595 的失败原因。"
  fi
  log "nounset: ${nounset_state:-unknown} ✓（若为 on，m 会报 TOP: unbound variable）"
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

# =============================================================================
#  定位 out 目录下的 ninja 入口文件（combined*.ninja）
# -----------------------------------------------------------------------------
#  【为什么必须有这个函数 —— run 36991148496 的失败根因】
#  AOSP 10 的 soong_ui **不会**生成 out/build.ninja，它生成的是：
#      out/combined<katiSuffix>.ninja      katiSuffix = "-<TARGET_PRODUCT>"
#  即 aosp_arm64 产品下是 out/combined-aosp_arm64.ninja。
#  该文件内容极短（见 build/soong/ui/build/build.go 的 combinedBuildNinjaTemplate）：
#      builddir = out
#      build _kati_always_build_: phony
#      subninja out/build-aosp_arm64.ninja          <- kati 主体
#      subninja out/build-aosp_arm64-package.ninja  <- kati 打包
#      subninja out/soong/build.ninja               <- soong 图（约 1GB）
#
#  不带 -f 时 ninja 默认读 ./build.ninja，于是：
#      ninja -C out ...
#      ninja: Entering directory `.../out'
#      ninja: error: loading 'build.ninja': No such file or directory
#  直接 exit 1。注意 out/soong/build.ninja 是存在的（1GB+），
#  所以「文件缺失」只可能是入口文件名不对，不是图没生成。
#
# =============================================================================
#  【为什么还必须去掉 -C，并且在 $TOP 下执行 —— run 37088938342 的失败根因】
#  上面那些 subninja 路径是**相对路径**（`out/build-...`），ninja 按 **CWD** 解析。
#  根因在 AOSP 10 的 build/soong/ui/build/config.go：
#      outDir := "out"                       // 相对，不做绝对化
#      ret.environ.Set("OUT_DIR", outDir)
#  对比 AOSP 8/9（同一函数的旧版本）会把 outDir 绝对化：
#      outDir = filepath.Join(os.Getenv("TOP"), outDir)
#  AOSP 10 删掉了这一步，所以 combined*.ninja 里全是相对路径。
#
#  soong_ui 自己跑 ninja 时（ui/build/ninja.go 的 runNinja）只传 `-f`，**不传 `-C`**，
#  即 ninja 的 CWD 就是 $TOP，相对路径才解析得对。
#  我们如果写 `ninja -C "$out" -f "$mf"`，CWD 被切到 out/，就会去找
#  out/out/build-aosp_arm64.ninja：
#      ninja: error: .../combined-aosp_arm64.ninja:6:
#        loading 'out/build-aosp_arm64.ninja': No such file or directory
#
#  结论：所有 ninja 调用一律走下面的 ninja_run / ninja_run_bg，
#  它们负责「切到 $TOP + 显式 -f」，不要手写 ninja 命令行。
# =============================================================================
aosp_ninja_manifest() {
  local out; out="$(aosp_out)"
  local prod="${TARGET_PRODUCT:-}"
  local f

  # 1) 优先匹配当前产品（AOSP 9/10）
  if [ -n "$prod" ] && [ -f "$out/combined-${prod}.ninja" ]; then
    echo "$out/combined-${prod}.ninja"; return 0
  fi
  # 2) kati suffix 可能带额外参数（combined-<product>-<md5>），取最新的一个
  f="$(ls -1t "$out"/combined*.ninja 2>/dev/null | head -n1 || true)"
  if [ -n "$f" ] && [ -f "$f" ]; then echo "$f"; return 0; fi
  # 3) AOSP 8 及更早：入口就叫 build.ninja
  if [ -f "$out/build.ninja" ]; then echo "$out/build.ninja"; return 0; fi

  return 1
}

# 同上，但失败时给出可操作的报错信息
require_ninja_manifest() {
  local out; out="$(aosp_out)"
  local mf
  if mf="$(aosp_ninja_manifest)"; then
    echo "$mf"; return 0
  fi
  err "找不到 out 下的 ninja 入口文件（找过 combined*.ninja 与 build.ninja）"
  err "out 目录: ${out}"
  err "请确认本 job 已经成功执行过 'm nothing'（会先生成构建图）"
  err "out 下现有的 *.ninja 文件："
  ls -1 "$out"/*.ninja 2>/dev/null | sed 's/^/    /' >&2 || true
  return 1
}

# -----------------------------------------------------------------------------
# ninja 执行的唯一入口（CWD=$TOP + 显式 -f），不要绕过它手写 ninja 命令行
# -----------------------------------------------------------------------------
# 用法:
#   ninja_run    <ninja参数...>            前台执行
#   ninja_run_bg <ninja参数...>            后台执行，ninja 的 PID 存到 $!
#
# 用 `exec` 是为了让子 shell 被 ninja 进程本身替换掉，
# 这样后台启动时 `$!` 拿到的就是 ninja 的真实 PID —— build_with_budget 靠它发 SIGINT
# 做优雅停止，如果拿到的是子 shell 的 PID，信号就不会传给 ninja。
ninja_run() {
  local mf ninja
  mf="$(require_ninja_manifest)" || return 1
  ninja="$(find_ninja)"
  ( cd "$AOSP_SRC_DIR" && exec "$ninja" -f "$mf" "$@" )
}

ninja_run_bg() {
  local mf ninja
  mf="$(require_ninja_manifest)" || return 1
  ninja="$(find_ninja)"
  ( cd "$AOSP_SRC_DIR" && exec "$ninja" -f "$mf" "$@" ) &
  COMPILE_SHARD_NINJA_PID=$!
  return 0
}

# 供 xargs 批量模式使用：在管道里执行需要先把 CWD 切到 $TOP。
# 用法: <产生目标清单的命令> | ninja_xargs_pipe <ninja参数...>
# 注意 xargs 自身会再 fork 多次，所以这里不能用 exec（会丢掉 xargs 的命令行），
# 但 xargs 是前台等待的，不存在 SIGINT 传递问题。
ninja_xargs_pipe() {
  local mf ninja
  mf="$(require_ninja_manifest)" || return 1
  ninja="$(find_ninja)"
  ( cd "$AOSP_SRC_DIR" && xargs -r "$ninja" -f "$mf" "$@" )
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
