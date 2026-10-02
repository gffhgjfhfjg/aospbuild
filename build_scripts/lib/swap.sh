#!/usr/bin/env bash
# =============================================================================
#  lib/swap.sh —— 16G swap 准备
# -----------------------------------------------------------------------------
#  背景：GitHub 托管 runner 只有 14GB 物理内存，AOSP soong/java/javac 在 -j1 下
#        仍可能瞬时吃掉 10GB+，没有 swap 会被 OOM Killer 直接杀掉（表现为
#        ninja 突然退出 137 / "Killed"），加上 swap 后编译能稳定跑完。
#  注意：swap 占磁盘空间，github-latest 仅 ~72GB SSD，启用前请先确认剩余空间，
#        详见 README「硬性容量约束」章节。
# =============================================================================

# swap 文件默认放在 /mnt（与 AOSP_SRC_DIR 同一分区），保证和 out 目录互不干扰
create_swap() {
  local size_gb="${1:-$AOSP_SWAP_SIZE_GB}"     # 硬性约束：16
  local swapfile="${2:-$AOSP_SWAP_FILE}"

  banner "准备 ${size_gb}G swap（规避云端 runner 内存不足 OOM）"

  if [ "$AOSP_ENABLE_SWAP" != "1" ]; then
    warn "AOSP_ENABLE_SWAP != 1，跳过 swap 创建（如遇 ninja exit 137 请打开）"
    return 0
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$swapfile"; then
    log "swap 已存在且已启用: ${swapfile}"
    swapon --show || true
    return 0
  fi

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "非 root 且无 sudo，无法配置 swap"
    SUDO="sudo"
  fi

  # 1) 清理可能的残留
  if [ -e "$swapfile" ]; then
    warn "发现已存在的残留 swap 文件 ${swapfile}，先 swapoff 并删除"
    $SUDO swapoff "$swapfile" 2>/dev/null || true
    $SUDO rm -f "$swapfile"
  fi

  # 2) 预检查剩余空间：swap 需要 size_gb + 少量余量
  local dir; dir="$(dirname "$swapfile")"
  mkdir -p "$dir" 2>/dev/null || true
  local avail
  avail="$(df -BG --output=avail "$dir" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
  local need=$(( size_gb + 2 ))
  log "swap 目标分区 ${dir} 剩余 ${avail}GB，需要 >= ${need}GB"
  if [ "$avail" -lt "$need" ]; then
    die "剩余空间不足以创建 ${size_gb}G swap（${avail}GB < ${need}GB）。
     github-latest 磁盘不够同时放下 AOSP 源码 + out + swap。
     建议：把 AOSP_SWAP_FILE 指向剩余空间最大的分区，或改用 self-hosted runner。"
  fi

  # 3) 创建 + 格式化 + 启用
  log "fallocate -l ${size_gb}G ${swapfile}"
  if ! $SUDO fallocate -l "${size_gb}G" "$swapfile"; then
    warn "fallocate 失败（部分文件系统不支持），改用 dd"
    $SUDO dd if=/dev/zero of="$swapfile" bs=1M count=$(( size_gb * 1024 )) status=none
  fi
  $SUDO chmod 600 "$swapfile"
  $SUDO mkswap -f "$swapfile"
  $SUDO swapon "$swapfile"

  # 4) 调整内核参数
  #    swappiness=60：内存不够时才换出，兼顾速度；调 100 会让编译极慢
  $SUDO sysctl -w vm.swappiness=60 >/dev/null 2>&1 || warn "sysctl vm.swappiness 设置失败"
  #    vfs_cache_pressure=50：编译期元数据 IO 密集，适度保留 dentry 缓存
  $SUDO sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
  #    禁止 OOM Killer 优先杀 javac（同样会被杀，但换成可控的失败信息）
  $SUDO sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true

  log "swap 状态:"
  swapon --show || true
  free -h || true
  log "swap 准备完成（${size_gb}G @ ${swapfile}）"
}

# 打印当前 swap/内存，编译前留档
report_memory() {
  banner "内存与 swap 现状"
  free -h
  echo
  swapon --show
  echo
  cat /proc/meminfo | head -n 5
}
