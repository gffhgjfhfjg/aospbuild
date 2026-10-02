#!/usr/bin/env bash
# =============================================================================
#  build_scripts/sync_source.sh —— Job1 主力脚本（源码获取 + 预处理）
# -----------------------------------------------------------------------------
#  子命令（可组合，按此顺序执行）：
#    --init              repo init（浅克隆 + 指定 tag）
#    --sync              repo sync（--retry-fetches=3 抗网络抖动）
#    --fix-python        修复 python shebang
#    --prune-device-trees 删除 crosshatch / bonito 设备树
#    --apply-patches     批量 apply CI 仓库 patches/
#    --prune-source      裁剪与 arm64 参考镜像无关的源码（省磁盘，可选）
#    --repack            repo repack 压缩 .git（利于 10GB 缓存配额，可选）
#    --all               = --init --sync --fix-python --prune-device-trees
#                         --apply-patches --prune-source --repack
#
#  说明：Job2/3/4 也会复用本脚本做轻量同步（.repo 命中缓存后主要耗时在 checkout 落盘）
# =============================================================================

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_here}/lib/common.sh"
enable_err_trap
# shellcheck source=lib/apt_deps.sh
source "${_here}/lib/apt_deps.sh"
# shellcheck source=lib/fix_python_shebang.sh
source "${_here}/lib/fix_python_shebang.sh"
# shellcheck source=lib/prune_device_trees.sh
source "${_here}/lib/prune_device_trees.sh"
# shellcheck source=lib/apply_patches.sh
source "${_here}/lib/apply_patches.sh"
# shellcheck source=lib/swap.sh
source "${_here}/lib/swap.sh"

start_logging "sync_source"

usage() {
  sed -n '2,30p' "$0"
}

do_init=0; do_sync=0; do_fixpy=0; do_prune_dev=0; do_patch=0; do_prune_src=0; do_repack=0
for a in "$@"; do
  case "$a" in
    --init)              do_init=1 ;;
    --sync)              do_sync=1 ;;
    --fix-python)        do_fixpy=1 ;;
    --prune-device-trees) do_prune_dev=1 ;;
    --apply-patches)     do_patch=1 ;;
    --prune-source)      do_prune_src=1 ;;
    --repack)            do_repack=1 ;;
    --all)               do_init=1; do_sync=1; do_fixpy=1; do_prune_dev=1
                         do_patch=1; do_prune_src=1; do_repack=1 ;;
    --help|-h)           usage; exit 0 ;;
    *) usage; die "未知参数: $a" ;;
  esac
done
if [ $(( do_init + do_sync + do_fixpy + do_prune_dev + do_patch + do_prune_src + do_repack )) -eq 0 ]; then
  usage; die "至少需要一个子命令"
fi

ensure_repo_tool() {
  if ! command -v repo >/dev/null 2>&1; then
    # 系统没有 repo 时，先尝试装官方 launcher
    install_repo_launcher
  fi
  command -v repo >/dev/null 2>&1 || die "未找到 repo 工具。apt 装不上时手动安装：
  mkdir -p ~/bin && curl -fLo ~/bin/repo https://storage.googleapis.com/git-repo-downloads/repo
  chmod +x ~/bin/repo && export PATH=\$PATH:~/bin"
  log "repo 路径  : $(command -v repo)"
  log "repo 版本  : $(repo --version 2>&1 | head -n3 | tr '\n' ' ')"
}

# -----------------------------------------------------------------------------
# repo 子命令参数能力探测
# -----------------------------------------------------------------------------
# 用法: filter_repo_args <init|sync> <参数...>   结果写入全局数组 REPO_ARGS
#
# 不同发行版的 repo 包版本差异很大（Ubuntu 22.04 = 2.17，24.04 = 2.36），
# 某些新选项（如 --git-lfs / --retry-fetches）在老版本上直接
# "no such option" 让命令失败。
#
# 关键：必须用对应子命令的 --help 来判定。
#   repo init --help 里没有 --retry-fetches（那是 sync 的选项），
#   如果拿 init 的 help 去校验 sync 参数，会把硬性要求的 --retry-fetches 误删。
# -----------------------------------------------------------------------------
REPO_ARGS=()
filter_repo_args() {
  local sub="$1"; shift
  REPO_ARGS=()

  local help_out
  help_out="$(repo "$sub" --help 2>&1 || true)"
  # 注意：repo 缺失或报错时 help_out 是 "command not found" 之类的错误串而非空串。
  # 如果不校验就拿去 grep，会把所有选项全判为"不支持"而误删 —— 必须验证它真是 help。
  if ! printf '%s\n' "$help_out" | grep -qiE 'usage|--[a-z]'; then
    warn "无法获取有效的 repo ${sub} --help（repo 可能未正确安装），原样使用参数"
    REPO_ARGS=("$@")
    return 0
  fi

  local a opt dropped=0
  for a in "$@"; do
    case "$a" in
      --*)
        opt="$a"
        if [[ "$a" == *=* ]]; then opt="${a%%=*}"; fi
        if printf '%s\n' "$help_out" | grep -qF -- "$opt"; then
          REPO_ARGS+=("$a")
        else
          warn "当前 repo 版本不支持 ${opt}，已从 ${sub} 参数中剔除"
          dropped=1
        fi
        ;;
      *) REPO_ARGS+=("$a") ;;   # -u/-b/-j 及其取值原样保留
    esac
  done
  [ "$dropped" -eq 1 ] && log "剔除不兼容选项后 ${sub} 参数: ${REPO_ARGS[*]}"
  return 0
}

# =============================================================================
# --init
# =============================================================================
do_repo_init() {
  banner "repo init  (tag=${AOSP_TAG})"
  ensure_repo_tool

  # 可写性预检：runner 上 /mnt、/opt 这类 root 拥有的目录会直接 Permission denied，
  # 必须在 repo init 前就失败并说清楚，否则 2 分钟后才炸且看不出原因。
  ensure_writable_dir "$AOSP_SRC_DIR"
  mkdir -p "$AOSP_SRC_DIR"
  cd "$AOSP_SRC_DIR"

  # 已有 .repo 目录时，检测 manifest 是否已指向目标 tag；不一致则重建
  if [ -d ".repo" ] && [ -f ".repo/manifest.xml" ]; then
    local cur
    cur="$(git -C .repo/manifests config --get remote.origin.url 2>/dev/null || echo '')"
    log "检测到已有 .repo，manifest remote = ${cur}"
    if [ -f ".repo/manifests/.repo-initialized" ]; then
      log "已初始化过，跳过 repo init（如需强制重来请手工删除 ${AOSP_SRC_DIR}/.repo）"
      return 0
    fi
  fi

  local init_args=(
    -u "$AOSP_MANIFEST_URL"
    -b "$AOSP_TAG"
    --depth="$AOSP_REPO_DEPTH"
    --no-repo-verify
  )
  # 可选镜像加速
  if [ -n "$AOSP_MIRROR_MANIFEST" ]; then
    init_args=( -u "$AOSP_MIRROR_MANIFEST" -b "$AOSP_TAG" --depth="$AOSP_REPO_DEPTH" --no-repo-verify )
    log "使用镜像源: ${AOSP_MIRROR_MANIFEST}"
  fi
  # AOSP 10 本身不用 git-lfs；按开关添加，且经能力探测后老 repo 会自动剔除
  if [ "${AOSP_REPO_GIT_LFS:-0}" = "1" ]; then
    init_args+=(--git-lfs)
  fi

  # 能力探测：剔除当前 repo 版本不认识的选项（Ubuntu 22.04 的 repo 2.17 缺 --git-lfs）
  filter_repo_args init "${init_args[@]}"
  init_args=("${REPO_ARGS[@]}")

  log "repo init ${init_args[*]}"
  retry 3 repo init "${init_args[@]}"
  touch ".repo/manifests/.repo-initialized"
  log "repo init 完成"
}

# =============================================================================
# --sync
# =============================================================================
do_repo_sync() {
  banner "repo sync  (jobs=${AOSP_REPO_SYNC_JOBS}, retry-fetches=${AOSP_REPO_RETRY_FETCHES})"
  ensure_repo_tool
  cd "$AOSP_SRC_DIR"
  [ -d ".repo" ] || do_repo_init

  # 空间守卫：sync 前就要检查
  require_free_gb 30 "$AOSP_SRC_DIR"

  local sync_args=(
    -c                     # 只拉当前分支
    -j "$AOSP_REPO_SYNC_JOBS"
    --depth="$AOSP_REPO_DEPTH"
    --retry-fetches="$AOSP_REPO_RETRY_FETCHES"   # 硬性要求
    --no-clone-bundle
    --prune                # 清理已被 manifest 移除的分支，省磁盘
    --fail-fast
  )
  # --force-sync 可选（丢弃源码树本地改动）
  if [ "${AOSP_REPO_FORCE_SYNC:-0}" = "1" ]; then
    sync_args+=(--force-sync)
    log "启用 --force-sync（会丢弃源码树本地改动）"
  fi

  # 能力探测：剔除当前 repo 版本不认识的 sync 选项。
  # 注意必须用 repo sync --help 判定（--retry-fetches 等选项只出现在 sync 的 help 里）
  filter_repo_args sync "${sync_args[@]}"
  sync_args=("${REPO_ARGS[@]}")
  local has_retry=0 a2
  for a2 in "${sync_args[@]}"; do
    [ "${a2#--retry-fetches=}" != "$a2" ] && has_retry=1
  done
  if [ "$has_retry" -eq 0 ]; then
    die "当前 repo 版本不支持 --retry-fetches（$(repo --version 2>&1 | head -n1)）。
     抗网络抖动是硬性要求，必须安装官方 repo launcher：
       mkdir -p ~/bin && curl -fLo ~/bin/repo https://storage.googleapis.com/git-repo-downloads/repo
       chmod +x ~/bin/repo && export PATH=\$PATH:~/bin
     （apt 的 repo 包在 Ubuntu 22.04 上只有 2.17，缺少该选项）"
  fi
  log "已确认 --retry-fetches 保留 ✓"

  log "repo sync ${sync_args[*]}"
  # repo sync 内部已有重试，这里再包一层针对 git 协议级失败的兜底
  local n=0
  until repo sync "${sync_args[@]}"; do
    n=$((n+1))
    if [ "$n" -ge 3 ]; then
      err "repo sync 连续 3 次失败，放弃"
      exit 1
    fi
    warn "repo sync 第 ${n} 次失败，60s 后重试（网络抖动）"
    sleep 60
    # 重试前清掉可能的 lock
    rm -f .repo/manifests/.repo-manifests.lock 2>/dev/null || true
  done

  # 记录 revision 便于复现
  {
    echo "# repo sync 结果"
    echo "tag=${AOSP_TAG}"
    echo "synced_at_utc=$(date -u +%FT%TZ)"
    echo "## manifest revision"
    git -C .repo/manifests log -1 --format='%H %ci %s' 2>/dev/null || true
    echo "## 各仓库 revision（抽样）"
    repo forall -c 'printf "%s %s\n" "$REPO_PATH" "$(git rev-parse --short HEAD 2>/dev/null)"' 2>/dev/null \
      | head -n 200 || true
  } > "${CI_LOG_DIR}/repo-sync-revisions.txt"

  local sz
  sz="$(du -sh "$AOSP_SRC_DIR" 2>/dev/null | cut -f1 || echo '?')"
  log "repo sync 完成，AOSP 源码总大小: ${sz}"
}

# =============================================================================
# --prune-source（可选，强烈建议在磁盘紧张的 runner 上开启）
# =============================================================================
do_prune_source() {
  banner "裁剪与 arm64 参考镜像无关的源码（省磁盘）"
  cd "$AOSP_SRC_DIR"

  # 默认裁剪清单 —— 只放「100% 确定不参与 aosp_arm64 目标图」的目录。
  # 注意：crosshatch / bonito 已由 prune_device_trees.sh 单独精确删除，
  #       这里不再整棵删 device/google（那会误伤 panther/redfin 等其它树，
  #       并可能让 hardware/google 下的公共模块失去 provider）。
  # 每追加一项，都必须先确认「不参与 aosp_arm64 目标图」，否则 soong 会在
  # 构建图阶段直接报 "directory not found"，且报错点离根因很远。
  local prune_default=(
    # CTS 源码：与系统镜像构建完全无关，约 2~4GB
    "cts"
  )

  # 常见的「可以删但需要你自己确认」清单（默认注释掉，按需启用）
  #   "external/owasp"            # 第三方小库，aosp_arm64 不引用
  #   "prebuilts/android-emulator"  # 模拟器（确认 aosp_arm64 不引用再删）
  #   "external/mesa3d"           # 桌面 GL 栈（确认不用硬件加速渲染再删）
  #   "frameworks/support"        # 部分 support 库（如需则保留）
  #   "device/generic/goldfish*"  # 模拟器设备树

  # 用户可通过 AOSP_PRUNE_SOURCE_EXTRA 追加（空格分隔的相对路径）
  local items=()
  local p
  for p in "${prune_default[@]}"; do items+=("$p"); done
  if [ -n "${AOSP_PRUNE_SOURCE_EXTRA:-}" ]; then
    # shellcheck disable=SC2206
    local extra=($AOSP_PRUNE_SOURCE_EXTRA)
    for p in "${extra[@]}"; do [ -n "$p" ] && items+=("$p"); done
  fi

  local before after removed=0
  before="$(du -sh "$AOSP_SRC_DIR" 2>/dev/null | cut -f1 || echo '?')"
  log "裁剪前: ${before}"

  for p in "${items[@]}"; do
    if [ -d "$p" ]; then
      local sz; sz="$(du -sh "$p" 2>/dev/null | cut -f1 || echo '?')"
      log "删除 ${p}  (${sz})"
      rm -rf -- "$p"
      removed=$((removed+1))
    else
      logv "跳过（不存在）: ${p}"
    fi
  done

  # 删掉 cts 目录后，build/soong/Android.bp 里对 cts 的 soong namespace 声明
  # 会指向一个不存在的目录，必须一并注释掉，否则 soong 在 bootstrap 阶段就失败。
  if [ -f "build/soong/Android.bp" ]; then
    if grep -q '"cts"' "build/soong/Android.bp" 2>/dev/null; then
      cp -a "build/soong/Android.bp" "build/soong/Android.bp.aosp-ci.bak"
      sed -i -E 's@^(\s*)"cts",@\1// "cts",  // [aosp-ci pruned]@' "build/soong/Android.bp" \
        || warn "build/soong/Android.bp 中 cts 声明处理失败"
      log "已注释 build/soong/Android.bp 中的 \"cts\" soong namespace（备份: .aosp-ci.bak）"
    fi
  else
    warn "未找到 build/soong/Android.bp，跳过 cts namespace 处理"
  fi

  after="$(du -sh "$AOSP_SRC_DIR" 2>/dev/null | cut -f1 || echo '?')"
  log "裁剪后: ${after}，共删除 ${removed} 个目录"
  warn "裁剪源码属于激进的省空间手段，启用前请确认所列目录不参与 aosp_arm64 目标图"
}

# =============================================================================
# --repack（可选）
# =============================================================================
do_repack() {
  banner "repo repack（压缩 .git 体积，利于 10GB 缓存配额）"
  cd "$AOSP_SRC_DIR"
  # 单个 ref 的浅克隆 repack，收益有限但安全
  repo forall -c '
      if [ -d .git ] || git rev-parse --git-dir >/dev/null 2>&1; then
        git config gc.auto 0
        git repack -a -d -q --window=250 --depth=50 2>/dev/null || true
        git prune-packed -q 2>/dev/null || true
      fi
  ' 2>/dev/null || warn "部分仓库 repack 失败，忽略"

  # 再收一遍 manifest 自身
  git -C .repo/manifests gc --auto 2>/dev/null || true

  local sz
  sz="$(du -sh "$AOSP_SRC_DIR/.repo" 2>/dev/null | cut -f1 || echo '?')"
  log ".repo 当前大小: ${sz}"
  log "提示：GitHub 仓库 cache 配额 10GB，若 .repo 仍超限请改用 --depth=1 + --prune-source"
}

# =============================================================================
# 主流程
# =============================================================================
banner "sync_source 开始"
log "参数:"
log "  AOSP_TAG            = ${AOSP_TAG}"
log "  AOSP_SRC_DIR        = ${AOSP_SRC_DIR}"
log "  AOSP_LUNCH_TARGET   = ${AOSP_LUNCH_TARGET}"
log "  repo sync jobs      = ${AOSP_REPO_SYNC_JOBS}"
log "  repo retry-fetches  = ${AOSP_REPO_RETRY_FETCHES}"
log "  repo depth          = ${AOSP_REPO_DEPTH}"
log "  PATCH_DIR           = ${PATCH_DIR}"
log "  PATCH_APPLY_ENABLED = ${PATCH_APPLY_ENABLED}"

# 开工前统一做一次可写性 + 资源自检（不管跑哪个子命令）
ensure_writable_dir "$AOSP_SRC_DIR"
resource_report

[ "$do_init" -eq 1 ]      && do_repo_init
[ "$do_sync" -eq 1 ]      && do_repo_sync
[ "$do_fixpy" -eq 1 ]     && fix_python_shebang "$AOSP_SRC_DIR"
[ "$do_prune_dev" -eq 1 ] && prune_device_trees "$AOSP_SRC_DIR"
[ "$do_patch" -eq 1 ]     && apply_all_patches "$AOSP_SRC_DIR" "$PATCH_DIR"
[ "$do_prune_src" -eq 1 ] && do_prune_source
[ "$do_repack" -eq 1 ]    && do_repack

# 交叉工具链最终自检（源码就位后）
if [ -d "$AOSP_SRC_DIR/prebuilts/clang" ]; then
  verify_cross_toolchain "$AOSP_SRC_DIR"
else
  warn "未找到 prebuilts/clang，请确认 repo sync 完整"
fi

# 打印补丁使用说明，便于新同学
if [ "$do_patch" -eq 0 ]; then
  logv "提示: 可执行 './build_scripts/lib/apply_patches.sh' 查看补丁导出/应用指南"
fi

log "sync_source 完成"
