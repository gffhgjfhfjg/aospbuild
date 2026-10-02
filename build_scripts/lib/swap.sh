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

# swap 文件默认放在 $HOME（与 AOSP_SRC_DIR 同一分区），保证和 out 目录互不干扰
# -----------------------------------------------------------------------------
# 【为什么默认优先用 zram 而不是 swap 文件】
#   GitHub 托管 runner 实测：4 核 / 15GiB RAM / 预置 3GiB swap / 根卷可用 ~87GB
#   AOSP 源码(~50-60GB) + out(~40-60GB) 已经把 87GB 吃紧，
#   再放一个 16GB 的 swap 文件 = 纯浪费磁盘，而且磁盘一满 out 就会半残。
#
#   zram 是内存里的压缩块设备：
#     * 逻辑容量同样是 16GB，vm.swappiness 生效方式与 swap 文件完全一致
#     * 匿名页用 lz4/zstd 压缩，典型 2.5~4:1，实际只吃 4~7GB 物理内存
#     * 不占任何磁盘
#   对"内存不够 + 磁盘也不够"的两难场景，zram 严格优于 swap 文件。
#
#   AOSP_SWAP_MODE 控制：
#     auto  (默认) 磁盘够就 zram+file 都开；磁盘不够就只开 zram
#     zram          只开 zram
#     file          只开 swap 文件（严格按原始需求）
#     both          强制两者都开
#     none          关闭
# =============================================================================

# zram 设备初始化：返回 0 表示成功
setup_zram() {
  local size_gb="${1:-$AOSP_SWAP_SIZE_GB}"
  local dev="/dev/zram0"

  # 已就绪？
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$dev"; then
    log "zram 已启用: ${dev}"
    return 0
  fi

  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"

  # 内核模块
  if ! lsmod 2>/dev/null | grep -q '^zram'; then
    $SUDO modprobe zram num_devices=1 2>/dev/null || return 1
    log "已加载 zram 模块"
  fi
  [ -e /sys/block/zram0 ] || { warn "zram0 设备未出现（内核未启用 zram）"; return 1; }

  # 选压缩算法：优先 zstd(3)，退化 lz4(2)
  local algo_id=2 algo_name="lz4"
  if grep -qw zstd /sys/block/zram0/comp_algorithm 2>/dev/null; then
    algo_id=3; algo_name="zstd"
  fi
  echo "$algo_id" | $SUDO tee /sys/block/zram0/comp_algorithm >/dev/null 2>&1 || return 1

  echo "$(( size_gb * 1024 ))M" | $SUDO tee /sys/block/zram0/disksize >/dev/null 2>&1 || return 1

  $SUDO mkswap "$dev" >/dev/null 2>&1 || return 1
  $SUDO swapon "$dev" 2>/dev/null || return 1

  log "zram 就绪: ${dev}  压缩算法=${algo_name}  逻辑容量=${size_gb}GB（实际占用内存远小于此）"
  return 0
}

create_swap() {
  local size_gb="${1:-$AOSP_SWAP_SIZE_GB}"     # 硬性约束：16
  local swapfile="${2:-$AOSP_SWAP_FILE}"

  banner "准备 ${size_gb}G swap（规避云端 runner 内存不足 OOM）"

  if [ "$AOSP_ENABLE_SWAP" != "1" ]; then
    warn "AOSP_ENABLE_SWAP != 1，跳过 swap 创建（如遇 ninja exit 137 请打开）"
    return 0
  fi

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "非 root 且无 sudo，无法配置 swap"
    SUDO="sudo"
  fi

  local mode="${AOSP_SWAP_MODE:-auto}"
  local have_zram=0 have_file=0

  # ---- 决定是否还要建 swap 文件 ----
  # 只有磁盘足够容纳 swap 文件时才建，否则白白吃掉 16GB 磁盘。
  local dir; dir="$(dirname "$swapfile")"
  local avail
  avail="$(df -BG --output=avail "$dir" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
  local file_need=$(( size_gb + 2 ))
  log "当前 swap 总览:"
  swapon --show || true

  case "$mode" in
    none)
      warn "AOSP_SWAP_MODE=none，跳过 swap"
      return 0
      ;;
    zram)
      setup_zram "$size_gb" && have_zram=1 || warn "zram 初始化失败"
      ;;
    file)
      have_file=1
      ;;
    both)
      setup_zram "$size_gb" && have_zram=1 || warn "zram 初始化失败（继续尝试 swap 文件）"
      have_file=1
      ;;
    auto|*)
      # auto：先建 zram（不占磁盘），再看磁盘是否宽裕决定要不要 swap 文件
      setup_zram "$size_gb" && have_zram=1 || warn "zram 初始化失败"
      if [ "$avail" -ge $(( file_need + ${AOSP_OUT_ESTIMATE_GB:-45} )) ]; then
        have_file=1
      else
        warn "磁盘剩余 ${avail}GB，容纳不下 ${file_need}GB swap 文件（要留给 out ${AOSP_OUT_ESTIMATE_GB:-45}GB）"
        warn "-> 只用 zram（不占磁盘）。如确实需要 swap 文件：设 AOSP_SWAP_MODE=both 或 file"
      fi
      ;;
  esac

  # ---- swap 文件 ----
  if [ "$have_file" -eq 1 ]; then
    log "创建 swap 文件 ${swapfile} (${size_gb}G)"
    if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$swapfile"; then
      log "swap 文件已存在且已启用: ${swapfile}"
    else
      mkdir -p "$dir" 2>/dev/null || true
      if [ -e "$swapfile" ]; then
        warn "清理残留 swap 文件 ${swapfile}"
        $SUDO swapoff "$swapfile" 2>/dev/null || true
        $SUDO rm -f "$swapfile"
      fi
      if [ "$avail" -lt "$file_need" ]; then
        warn "磁盘不足（${avail}GB < ${file_need}GB），放弃 swap 文件"
        have_file=0
      else
        log "fallocate -l ${size_gb}G ${swapfile}"
        if ! $SUDO fallocate -l "${size_gb}G" "$swapfile" 2>/dev/null; then
          warn "fallocate 失败，改用 dd"
          $SUDO dd if=/dev/zero of="$swapfile" bs=1M count=$(( size_gb * 1024 )) status=none
        fi
        $SUDO chmod 600 "$swapfile"
        $SUDO mkswap -f "$swapfile" >/dev/null
        $SUDO swapon "$swapfile"
      fi
    fi
  fi

  if [ "$have_zram" -eq 0 ] && [ "$have_file" -eq 0 ]; then
    err "未能启用任何 swap！"
    err "soong/javac 很可能在编译途中被 OOM Killer 杀掉（ninja exit 137 / Killed）。"
    err "排查：'modprobe zram' 是否可用；'swapon --show' 是否有输出；'free -h' 是否显示 swap。"
    exit 1
  fi

  # ---- 内核参数 ----
  #  swappiness=60：内存不够时才换出，兼顾速度；调 100 会让编译极慢
  $SUDO sysctl -w vm.swappiness=60 >/dev/null 2>&1 || warn "sysctl vm.swappiness 设置失败"
  #  vfs_cache_pressure=50：编译期元数据 IO 密集，适度保留 dentry 缓存
  $SUDO sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
  #  禁止 overcommit 记账失败导致 javac 写内存时被拒
  $SUDO sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true

  log "swap 最终状态:"
  swapon --show || true
  free -h || true
  log "swap 准备完成（zram=${have_zram} file=${have_file}）"
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
