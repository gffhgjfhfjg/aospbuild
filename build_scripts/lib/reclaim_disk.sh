#!/usr/bin/env bash
# =============================================================================
#  lib/reclaim_disk.sh —— 回收 GitHub 托管 runner 上的预装磁盘空间
# -----------------------------------------------------------------------------
#  【为什么必须做】
#  ubuntu-22.04 托管 runner 实测（2026-10-02，image 20260927.309）：
#     /dev/root  ext4  146G  已用 59G  可用 87G
#  而 AOSP 10 `repo sync --depth=1` 实测占用 **~62GB**，
#  留给 out 的只有 22GB，而 aosp_arm64-eng 的 out 需要 30~50GB —— 装不下。
#
#  runner 镜像里预装了大量与 AOSP 编译无关的东西，实测可回收 ~22GB：
#     /usr/local/lib/android      11.0G   预装 Android SDK + 3 个 NDK 版本
#     /usr/share/dotnet            5.8G   .NET SDK
#     /usr/share/swift             3.5G   Swift 工具链
#     /usr/local/lib/node_modules  1.2G   全局 npm 包
#     /opt/pipx                    456M   pipx 工具
#  回收后：87 + 22 = 109GB 可用 - 62GB 源码 = 47GB 给 out → 可行。
#
#  【绝不回收】
#     /opt/hostedtoolcache  5.2G
#       actions/checkout、upload-artifact 等在 Post 阶段还要从这里取 node/python，
#       删了会让 job 的收尾步骤（上传日志/artifact）直接失败。
#       只在必要时清理其中的历史版本（保留当前 node 版本）。
# =============================================================================

# 可安全删除的目录（按「回收收益」排序）
RECLAIM_TARGETS=(
  "/usr/local/lib/android"       # 11.0G 预装 Android SDK/NDK，AOSP 编译用不到
  "/usr/share/dotnet"            #  5.8G
  "/usr/share/swift"             #  3.5G
  "/usr/local/lib/node_modules"  #  1.2G
  "/opt/pipx"                    #  456M
  "/usr/local/graalvm"           # 若存在
  "/usr/local/share/boost"       # 若存在
  "/opt/ghc"                     # 若存在
  "/usr/local/.ghcup"            # 若存在
)

# 删掉 Android SDK 后必须一并清掉指向它的环境变量，
# 否则 build 里任何 `if os.Getenv("ANDROID_NDK_HOME") != ""` 分支
# 会拿到一个悬空路径而报错（比没有这个变量更容易炸）。
RECLAIM_UNSET_ENV=(
  ANDROID_HOME
  ANDROID_SDK_ROOT
  ANDROID_NDK_HOME
  ANDROID_NDK_ROOT
  ANDROID_NDK_LATEST_HOME
  ANDROID_NDK_VERSION
  ANDROID_NDK
)

# 历史版 hostedtoolcache 清理阈值：超过该大小才动手
RECLAIM_TOOLCACHE_THRESHOLD_GB="${AOSP_RECLAIM_TOOLCACHE_GB:-4}"

reclaim_runner_disk() {
  banner "回收 runner 预装磁盘空间"

  if [ "${AOSP_RECLAIM_DISK:-1}" != "1" ]; then
    warn "AOSP_RECLAIM_DISK != 1，跳过磁盘回收"
    warn "注意：不同步回收的话，可用空间只有 87GB，装不下 AOSP 源码(62GB) + out"
    return 0
  fi

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { warn "无 sudo，跳过磁盘回收"; return 0; }
    SUDO="sudo"
  fi

  local before after
  before="$(avail_gb /)"
  log "回收前可用: ${before}GB"
  df -hT / | tail -1

  # ---- 1) 删除已知的可回收目录 ----
  local p sz freed rerr
  for p in "${RECLAIM_TARGETS[@]}"; do
    if [ -e "$p" ]; then
      sz="$($SUDO du -x -sh "$p" 2>/dev/null | cut -f1 || true)"
      [ -n "$sz" ] || sz='?'
      log "删除 ${p}  (${sz})"
      rerr="$($SUDO rm -rf -- "$p" 2>&1)" || true
      if [ -e "$p" ]; then
        warn "删除 ${p} 失败：${rerr:-<无 stderr>}"
        # 常见原因：sudo 不可用 / 目录正被占用 / 只读挂载
      fi
    else
      logv "跳过（不存在）: ${p}"
    fi
  done

  # ---- 2) 清掉指向已删目录的环境变量 ----
  local v dropped=0
  for v in "${RECLAIM_UNSET_ENV[@]}"; do
    if [ -n "${!v:-}" ]; then
      log "unset ${v}=${!v}"
      unset "$v" || true
      dropped=1
    fi
  done
  # 通过 GITHUB_ENV 传给同 job 的后续 step（run 级别 unset 对后续 step 无效）
  for v in "${RECLAIM_UNSET_ENV[@]}"; do
    echo "${v}=" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  done
  [ "$dropped" -eq 1 ] && log "已 unset ${#RECLAIM_UNSET_ENV[@]} 个 ANDROID_* 变量并写入 GITHUB_ENV"

  # ---- 3) 清理 hostedtoolcache 的历史版本（保留当前 node，绝不整个删）----
  #     注意：整个 /opt/hostedtoolcache 不能删，actions 的 post 步骤要用
  if [ -d "/opt/hostedtoolcache/node" ]; then
    local tcsize
    tcsize="$($SUDO du -x -sm /opt/hostedtoolcache 2>/dev/null | cut -f1 || echo 0)"
    if [ "$tcsize" -gt $(( RECLAIM_TOOLCACHE_THRESHOLD_GB * 1024 )) ]; then
      log "hostedtoolcache 占用 ${tcsize}MB，清理 Node 历史版本（保留最新）"
      local keep
      keep="$(ls -1 /opt/hostedtoolcache/node 2>/dev/null | LC_ALL=C sort -V | tail -n1 || true)"
      log "保留 node 版本: ${keep:-<无>}"
      local d
      for d in /opt/hostedtoolcache/node/*; do
        [ -d "$d" ] || continue
        [ "$(basename "$d")" = "$keep" ] && continue
        log "  rm -rf $d"
        $SUDO rm -rf -- "$d" 2>/dev/null || warn "  清理 $d 失败（忽略）"
      done
    else
      log "hostedtoolcache 仅 ${tcsize}MB，未超过阈值，保留"
    fi
  fi

  # ---- 4) apt 缓存 ----
  if command -v apt-get >/dev/null 2>&1; then
    # 注意：prepare_runner 之后紧接着就要跑 install_apt_deps（需要 apt lists），
    # 所以这里先不清 apt lists，等依赖装完再清。install_apt_deps 末尾会清。
    $SUDO apt-get clean >/dev/null 2>&1 || true
    log "已清理 apt 包缓存（/var/lib/apt/lists 留到依赖安装完再清）"
  fi

  after="$(avail_gb /)"
  freed=$(( after - before ))
  log "回收后可用: ${after}GB  (净回收 ${freed}GB)"

  {
    echo "reclaim_before_gb=${before}"
    echo "reclaim_after_gb=${after}"
    echo "reclaim_freed_gb=${freed}"
    echo "reclaim_at_utc=$(date -u +%FT%TZ)"
  } > "${CI_LOG_DIR}/reclaim-disk.txt"

  df -hT / | tail -1
  if [ "$freed" -le 0 ]; then
    warn "没有回收到空间。若 AOSP 源码已 sync 完，这里不会再变 —— 属于正常情况。"
  else
    log "磁盘回收完成 ✓"
  fi

  # ---- 5) 回收后立刻复核容量 ----
  local need="${AOSP_FREE_SPACE_GB:-40}"
  if [ "$after" -lt "$need" ]; then
    warn "回收后可用 ${after}GB 仍小于建议下限 ${need}GB，请检查 AOSP_RECLAIM_DISK 与回收列表"
  fi
}
