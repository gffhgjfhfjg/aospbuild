#!/usr/bin/env bash
# =============================================================================
#  lib/prune_device_trees.sh —— 删除 crosshatch / bonito 设备树
# -----------------------------------------------------------------------------
#  背景（来自 bbs.kanxue.com/thread-292331.htm 基线方案）：
#    AOSP 10 的 device/google/crosshatch（Pixel 4）与 device/google/bonito
#    带摄像头/传感器私有 HAL 依赖与大量 Soong 模块，会拖慢构建、引入无关编译错误，
#    并且它们不在 aosp_arm64 参考镜像的编译目标里。基线方案的做法是直接删掉这两棵
#    设备树，从而：
#      1) 减少构建量、缩短 -j1 串行时间
#      2) 避免 crosshatch 特有模块的编译失败阻塞主流程
#      3) 彻底摆脱对特定厂商 HAL blob 的依赖
#
#  处理范围：
#    - device/google/crosshatch  (Pixel 4)
#    - device/google/bonito     (Pixel 4 XL)
#    - 顺带清掉 hardware/google/crosshatch（若存在）
#    - 清理 device/google/devices.mk 中对上述树的引用，避免 make 解析报缺目录
#    - 清理 vendor/google 下同名目录（若存在）
#
#  可通过环境变量扩展：AOSP_EXTRA_PRUNE_DEVICE_TREES="aosp_angler device/xiaomi"
# =============================================================================

# 默认要删除的设备树（相对 AOSP 根目录）
PRUNE_DEVICE_TREES_DEFAULT=(
  "device/google/crosshatch"
  "device/google/bonito"
  "hardware/google/crosshatch"
  "hardware/google/bonito"
)

prune_device_trees() {
  local root="${1:-$AOSP_SRC_DIR}"
  banner "删除 crosshatch / bonito 设备树"

  cd "$root"

  # 合并默认列表与用户自定义列表
  local trees=()
  local t
  for t in "${PRUNE_DEVICE_TREES_DEFAULT[@]}"; do trees+=("$t"); done
  if [ -n "${AOSP_EXTRA_PRUNE_DEVICE_TREES:-}" ]; then
    # shellcheck disable=SC2206
    local extra=($(printf '%s' "$AOSP_EXTRA_PRUNE_DEVICE_TREES" | tr ',' ' '))
    for t in "${extra[@]}"; do [ -n "$t" ] && trees+=("$t"); done
  fi

  # ---------- 1) 记录删除前状态 ----------
  local total_before
  total_before="$(du -sh device hardware 2>/dev/null | awk '{s+=$1} END{print s}' || echo '?')"
  log "删除前 device+hardware 合计约: ${total_before}"

  # ---------- 2) 逐个删除 ----------
  local removed=0
  for t in "${trees[@]}"; do
    if [ -d "$t" ]; then
      local sz
      sz="$(du -sh "$t" 2>/dev/null | cut -f1 || echo '?')"
      log "删除设备树: ${t}  (${sz})"
      rm -rf -- "$t" || { err "删除 ${t} 失败"; exit 1; }
      removed=$((removed + 1))
    elif [ -e "$t" ]; then
      log "删除文件: ${t}"
      rm -rf -- "$t"
      removed=$((removed + 1))
    else
      logv "跳过（不存在）: ${t}"
    fi
  done
  log "共删除 ${removed} 个目录/文件"

  # ---------- 3) 清理 device/google/devices.mk 中的悬空引用 ----------
  # devices.mk 由 add-lcd-build-list 生成，会把树路径塞进 BOARD_DEVICE_PATHS，
  # 树被删后 make 仍会把它当有效路径，导致 lunch/soong 阶段报 "directory not found"。
  # 这里只删「指向已删除树」的行，其余行保持原样。
  local devices_mk="device/google/devices.mk"
  if [ -f "$devices_mk" ]; then
    local backup="${devices_mk}.aosp-ci.bak"
    cp -a "$devices_mk" "$backup"
    local changed=0
    local name
    for name in crosshatch bonito; do
      if grep -q "$name" "$devices_mk"; then
        # 注释掉而不是删除，保留可追溯性
        sed -i -E "s@^([^#]*(device/google|hardware/google)/${name}.*)\$@# [aosp-ci pruned] \1@" "$devices_mk"
        changed=1
      fi
    done
    if [ "$changed" -eq 1 ]; then
      log "已清理 ${devices_mk} 中的 crosshatch/bonito 引用（原文件备份: ${backup}）"
    else
      log "${devices_mk} 无需修改"
    fi
  else
    logv "${devices_mk} 不存在，跳过引用清理"
  fi

  # ---------- 4) 清理 build 侧残留引用 ----------
  # build/release-candidate / build/target/product/*.mk 极少引用具体树，这里做一次
  # 全局兜底扫描，只提示不删除（避免误伤）。
  log "全局扫描残留引用（仅提示，不修改）:"
  local leftover
  leftover="$(grep -rIl --include='*.mk' --include='*.bp' --include='*.xml' \
                 -e 'device/google/crosshatch' -e 'device/google/bonito' \
                 build device frameworks system 2>/dev/null | head -n 20 || true)"
  if [ -n "$leftover" ]; then
    printf '%s\n' "$leftover" | while IFS= read -r f; do
      warn "  残留引用: ${f}"
    done
  else
    log "  无残留引用"
  fi

  # ---------- 5) 清理 device 列表缓存 ----------
  # Android 10 的 lunch 走 device/<vendor>/<name>/AndroidProducts.mk，
  # 删树后 lunch 不会自动刷新；删掉 out/soong 下的设备清单缓存强制重扫。
  if [ -f "out/soong/soong.environment.available" ]; then
    log "删除 out/soong/soong.environment.available 强制 lunch 重新扫描设备树"
    rm -f "out/soong/soong.environment.available"
  fi

  local total_after
  total_after="$(du -sh device hardware 2>/dev/null | awk '{s+=$1} END{print s}' || echo '?')"
  log "删除后 device+hardware 合计约: ${total_after}"

  # ---------- 6) 验证 aosp_arm64 仍在设备列表中 ----------
  if [ -f "device/generic/aosp_arm64/AndroidProducts.mk" ]; then
    log "aosp_arm64 参考设备树完好: device/generic/aosp_arm64"
  else
    warn "未找到 device/generic/aosp_arm64，请确认 repo sync 完整"
  fi

  log "设备树裁剪完成"
}
