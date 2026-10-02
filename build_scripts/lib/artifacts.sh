#!/usr/bin/env bash
# =============================================================================
#  lib/artifacts.sh —— out 目录的跨 job 传递（分片 tar.zst）
# -----------------------------------------------------------------------------
#  为什么要分片：
#    1) GitHub Actions 单个 artifact 体积有上限（托管 runner 上传单文件/单 artifact
#       过大会在上传阶段失败或静默截断），分片后可稳定续传。
#    2) upload-artifact v4 不会保留可执行位与符号链接，所以不能直接把 out/ 目录
#       当文件上传 —— 必须先在 runner 上打成 tar（tar 内部完整记录 mode/symlink），
#       解包后完全还原。
#    3) zstd 预压缩后，upload-artifact 必须设 compression-level: 0，避免二次压缩。
#
#  用法：
#    artifacts.sh pack                 # 打包 $AOSP_SRC_DIR/out -> .ci_artifacts/out/part-*
#    artifacts.sh unpack               # 解包 .ci_artifacts/out/part-* -> $AOSP_SRC_DIR/out
#    artifacts.sh info                 # 查看分片信息
#    artifacts.sh prune --mode slim    # 按模式裁剪 out（可再生中间物）
# =============================================================================

ART_SUBDIR_OUT="out"
ART_OUT_TAR_PREFIX="out"
ART_META_FILE="artifact-manifest.txt"

# =============================================================================
# slim 模式裁剪清单
# -----------------------------------------------------------------------------
# 目标：把 out 体积压到 artifact 能接受的范围，同时保证 Job3(metalava) 与
#       Job4(镜像打包) 依然能正常增量工作。
#
# 裁剪原则（被删的都是「可由 ninja 重新生成、且后续阶段不读」的东西）：
#   obj/PACKAGES        —— 几万个 0 字节记录文件，纯中间索引
#   obj/SOURCES         —— 源码索引中间文件
#   obj/**/.install_depends  —— 安装依赖记录
#   intermediates/**    —— 部分体积巨大的 .dex/.jar 中间产物
#   system/ vendor/ odm/product/ (staging) —— install 暂存目录，
#                          Job4 会用 m installclean 重新 install 生成
#   *.log               —— 已经在 logs-* artifact 里单独保存
#
# 危险（默认不裁剪，需要时用 AXP_OUT_PRUNE_EXTRA 指定）：
#   out/host/**         —— 宿主工具链，metalava / mkfs / simg2img 都在这里，删了必重编
#   out/target/product/arm64/obj/**（除上面列举） —— 镜像打包要读
#   out/soong/**        —— soong 配置缓存
# =============================================================================
prune_out_slim() {
  local out="${1:-$(aosp_out)}"
  [ -d "$out" ] || { warn "out 目录不存在: ${out}"; return 0; }

  banner "裁剪 out 目录（mode=slim）"
  local before after
  before="$(du -sh "$out" 2>/dev/null | cut -f1 || echo '?')"
  log "裁剪前: ${before}"

  # ---- 1) PACKAGES / SOURCES 中间索引（体积小但文件数极多，删了能大幅加快上传）----
  find "$out/target/product" -maxdepth 2 -type d \( -name 'PACKAGES' -o -name 'SOURCES' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' d; do
        logv "rm -rf ${d#${out}/}"
        rm -rf "$d"
      done

  # ---- 2) install 暂存 staging 目录（Job4 会重新 install）----
  local staging
  staging="$(ls -d "$out"/target/product/*/{system,vendor,odm,product,system_ext} 2>/dev/null || true)"
  for d in $staging; do
    [ -d "$d" ] || continue
    # 若里面已经是构建好的镜像输出（*.img / *.odex），保留，避免白删
    if compgen -G "$d/*.img" >/dev/null 2>&1; then
      logv "跳过（内含镜像产物）: ${d#${out}/}"
      continue
    fi
    logv "rm -rf ${d#${out}/}"
    rm -rf "$d"
  done

  # ---- 3) 大体积 .log（已由 logs-* artifact 保留）----
  find "$out" -maxdepth 3 -type f -name '*.log' -size +8M -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        logv "rm ${f#${out}/}"
        rm -f "$f"
      done

  # ---- 4) soong 命令行缓存（体积大，Job3/4 会重新生成）----
  rm -rf "$out/soong/soong-build" 2>/dev/null || true
  find "$out/soong" -maxdepth 1 -type d -name 'soong-*' ! -name 'soong.environment*' -print0 2>/dev/null \
    | while IFS= read -r -d '' d; do
        logv "rm -rf ${d#${out}/}"
        rm -rf "$d"
      done

  # ---- 5) 预留钩子：用户自定义额外裁剪项（空格/换行分隔的相对 out 相对路径）----
  if [ -n "${AOSP_OUT_PRUNE_EXTRA:-}" ]; then
    log "应用 AOSP_OUT_PRUNE_EXTRA 自定义裁剪项: ${AOSP_OUT_PRUNE_EXTRA}"
    for rel in $AOSP_OUT_PRUNE_EXTRA; do
      [ -n "$rel" ] || continue
      target="${out}/${rel}"
      if [ -e "$target" ]; then
        logv "rm -rf ${rel}"
        rm -rf "$target"
      else
        logv "跳过（不存在）: ${rel}"
      fi
    done
  fi

  after="$(du -sh "$out" 2>/dev/null | cut -f1 || echo '?')"
  log "裁剪后: ${after}"
  du -sh "$out"/* 2>/dev/null | sort -h | tail -n 15 || true
  log "out 裁剪完成"
}

# =============================================================================
# pack —— 打包 out 为分片 tar.zst
# =============================================================================
artifacts_pack() {
  local out
  out="$(aosp_out)"
  [ -d "$out" ] || die "out 目录不存在: ${out}"

  # 先按配置裁剪
  case "$AOSP_OUT_PACK_MODE" in
    slim) prune_out_slim "$out" ;;
    full) log "AOSP_OUT_PACK_MODE=full，跳过裁剪（注意体积可能远超 artifact 限制）" ;;
    *)    warn "未知 AOSP_OUT_PACK_MODE=${AOSP_OUT_PACK_MODE}，按 full 处理"; ;;
  esac

  banner "打包 out 目录 -> 分片 tar.zst"
  command -v zstd >/dev/null 2>&1 || die "缺少 zstd，请检查 apt 依赖安装"
  command -v tar   >/dev/null 2>&1 || die "缺少 tar"

  local dest_dir="${CI_ARTIFACT_DIR}/${ART_SUBDIR_OUT}"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"

  local part_mb="${AOSP_OUT_PART_MB}"
  local level="${AOSP_OUT_PACK_LEVEL}"
  local raw_size
  raw_size="$(du -sm "$out" 2>/dev/null | cut -f1 || echo 0)"
  log "原始体积: ${raw_size}MB  分片大小: ${part_mb}MB  压缩等级: zstd-${level}"

  # tar 时保留权限/符号链接/硬链接；-C 到父目录使得包内路径为 out/...
  local tarball="${dest_dir}/${ART_OUT_TAR_PREFIX}.tar.zst"
  log "开始压缩（tar | zstd），大文件耗时，请耐心等待…"
  tar -C "$(dirname "$out")" \
      --exclude='*.ninja_deps' \
      --sparse \
      -cf - "$(basename "$out")" \
    | zstd -T0 "-${level}" -q -o "${tarball}.tmp"

  mv -f "${tarball}.tmp" "$tarball"
  local packed
  packed="$(du -sh "$tarball" | cut -f1)"
  log "压缩后单文件: ${packed}"

  # 分片：split 按字节切，-d 5 位数字后缀
  local tarball_bytes part_bytes
  tarball_bytes="$(stat -c%s "$tarball" 2>/dev/null || echo 0)"
  part_bytes=$(( part_mb * 1024 * 1024 ))
  if [ "$tarball_bytes" -le "$part_bytes" ]; then
    log "体积（${tarball_bytes}B）小于分片阈值（${part_bytes}B），不分片"
    mv -f "$tarball" "${dest_dir}/part-00000"
  else
    log "开始分片（每片 ${part_mb}MB，预计 $(( (tarball_bytes + part_bytes - 1) / part_bytes )) 片）…"
    split -b "${part_mb}m" -d -a 5 --additional-suffix='' \
      "$tarball" "${dest_dir}/part-"
    rm -f "$tarball"
  fi

  # 写 manifest，便于 unpack 校验
  {
    echo "aosp_out_artifact_manifest"
    echo "created_at_utc=$(date -u +%FT%TZ)"
    echo "aosp_tag=${AOSP_TAG}"
    echo "lunch_target=${AOSP_LUNCH_TARGET}"
    echo "out_pack_mode=${AOSP_OUT_PACK_MODE}"
    echo "zstd_level=${level}"
    echo "raw_size_mb=${raw_size}"
    echo "--- parts ---"
    ( cd "$dest_dir" && for f in part-*; do
        echo "$(sha256sum "$f" | cut -d' ' -f1)  $(du -b "$f" | cut -f1)  $f"
      done )
  } > "${dest_dir}/${ART_META_FILE}"

  # 自检：确保分片能拼回一个可解压的 zstd 流
  #   （不能用 "head -c 1 | zstd -t" 判断：zstd 帧头被截断必然报错，噪音大）
  log "自检：拼回分片并用 zstd 读取帧头 ..."
  if cat "$dest_dir"/part-* | head -c 4 | od -An -tx1 | tr -d ' \n' | grep -qi '28b52ffd'; then
    log "zstd 魔数 28 B5 2F FD 校验通过 ✓"
  else
    warn "未读到 zstd 帧头，分片可能损坏（unpack 阶段会做完整 sha256 校验）"
  fi

  # 输出体积报告
  log "分片列表:"
  ls -lh "$dest_dir"/part-* | awk '{print "  " $5 "  " $9}'
  log "分片总体积: $(du -sh "$dest_dir" | cut -f1)"

  if [ -f "${CI_LOG_DIR}/out-pack-report.txt" ] || [ -d "$CI_LOG_DIR" ]; then
    du -sh "$out" 2>/dev/null >  "${CI_LOG_DIR}/out-pack-report.txt" || true
    ( cd "$dest_dir" && ls -l part-* ) >> "${CI_LOG_DIR}/out-pack-report.txt" || true
  fi
  log "打包完成 → ${dest_dir}"
}

# =============================================================================
# unpack —— 从分片还原 out
# =============================================================================
artifacts_unpack() {
  local dest
  dest="$(aosp_out)"
  local src_dir="${CI_ARTIFACT_DIR}/${ART_SUBDIR_OUT}"

  banner "解包 out 目录"
  [ -d "$src_dir" ] || die "分片目录不存在: ${src_dir}"

  command -v zstd >/dev/null 2>&1 || die "缺少 zstd"

  # ---- 1) 校验 manifest ----
  if [ -f "${src_dir}/${ART_META_FILE}" ]; then
    log "校验分片 sha256 ..."
    local line sha size fname
    local bad=0
    local checked=0
    # manifest 里既有头部注释也有 <sha256> <bytes> <fname> 数据行，
    # 用「sha 必须正好 64 位十六进制」来精确筛出数据行
    while read -r sha size fname _rest; do
      [ "${#sha}" -eq 64 ] || continue
      case "$sha" in
        *[!0-9a-fA-F]*) continue ;;
      esac
      [ -n "$fname" ] || continue
      checked=$((checked + 1))
      [ -f "${src_dir}/${fname}" ] || { err "分片缺失: ${fname}"; bad=1; continue; }
      local actual
      actual="$(sha256sum "${src_dir}/${fname}" | cut -d' ' -f1)"
      if [ "$actual" != "$sha" ]; then
        err "分片校验失败: ${fname}"
        err "  期望: $sha"
        err "  实际: $actual"
        bad=1
      else
        logv "  OK ${fname}"
      fi
    done < "${src_dir}/${ART_META_FILE}"
    if [ "$checked" -eq 0 ]; then
      err "manifest 中没有任何分片记录，文件可能损坏: ${src_dir}/${ART_META_FILE}"
      head -n 20 "${src_dir}/${ART_META_FILE}" >&2 || true
      bad=1
    fi
    [ "$bad" -eq 0 ] && log "全部分片校验通过（${checked} 片）" \
                     || die "分片校验失败，artifact 可能上传不完整，请重跑该 job"
  else
    warn "缺少 ${ART_META_FILE}，跳过 sha256 校验"
  fi

  # ---- 2) 空间预检 ----
  local need_mb
  need_mb="$(du -sm "$src_dir" | cut -f1)"
  # zstd 压缩比按最差 1:1 估（保守），实际 AOSP out 通常 1:2.5~1:4
  local need_gb=$(( need_mb / 1024 + 6 ))
  local avail_gb
  avail_gb="$(avail_gb "$(dirname "$dest")")"
  log "分片压缩体积 ${need_mb}MB，保守估计需要 ${need_gb}GB，可用 ${avail_gb}GB"
  if [ "$avail_gb" -lt "$need_gb" ]; then
    die "剩余空间不足以解包 out（${avail_gb}GB < ${need_gb}GB）"
  fi

  # ---- 3) 删除旧 out，准备还原 ----
  if [ -e "$dest" ]; then
    log "清理旧 out 目录: ${dest}"
    rm -rf "$dest"
  fi
  mkdir -p "$(dirname "$dest")"

  # ---- 4) cat 分片 | zstd -d | tar -x ----
  #    必须按 part-00000, part-00001 ... 字典序拼接
  log "拼接分片并解包（大文件耗时，请耐心等待）…"
  local parts
  mapfile -t parts < <(ls -1 "$src_dir"/part-* | LC_ALL=C sort)
  [ "${#parts[@]}" -gt 0 ] || die "没有找到任何 part-* 分片"

  cat "${parts[@]}" \
    | zstd -d -T0 -q \
    | tar -C "$(dirname "$dest")" -xf -

  [ -d "$dest" ] || die "解包后未找到 out 目录: ${dest}"

  # ---- 5) 还原可执行位（tar 已保留，兜底再修一次常见路径）----
  log "还原可执行位（兜底）…"
  find "$dest/host" -type f \( -name 'metalava*' -o -name 'ninja*' -o -name 'soong*' \
        -o -name 'mkfs*' -o -name 'avbtool*' -o -name 'simg2img*' -o -name 'aapt2*' \) \
        -exec chmod +x {} + 2>/dev/null || true
  chmod +x "$dest/host/linux-x86/bin"/* 2>/dev/null || true

  # ---- 6) 完整性自检 ----
  local sz
  sz="$(du -sh "$dest" | cut -f1)"
  log "out 解包完成: ${dest}  (${sz})"
  if [ -f "$dest/soong/build.ninja" ]; then
    log "build.ninja 存在，soong 构建图已就绪 ✓"
  else
    warn "未找到 out/soong/build.ninja，可能需要重新执行 soong（stage 脚本会自动处理）"
  fi
}

# =============================================================================
# info —— 查看当前分片状态
# =============================================================================
artifacts_info() {
  local src_dir="${CI_ARTIFACT_DIR}/${ART_SUBDIR_OUT}"
  if [ -d "$src_dir" ]; then
    log "分片目录: ${src_dir}"
    ls -lh "$src_dir" || true
    [ -f "${src_dir}/${ART_META_FILE}" ] && cat "${src_dir}/${ART_META_FILE}" || true
  else
    log "分片目录不存在: ${src_dir}"
  fi
  local out; out="$(aosp_out)"
  [ -d "$out" ] && { log "本地 out: ${out}"; du -sh "$out"; } || log "本地 out 不存在"
}

# =============================================================================
# 入口分发
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/common.sh
  source "${_here}/common.sh"
  enable_err_trap
  cmd="${1:-info}"
  case "$cmd" in
    pack)   artifacts_pack ;;
    unpack) artifacts_unpack ;;
    info)   artifacts_info ;;
    prune)  prune_out_slim "$(aosp_out)" ;;
    *) die "未知子命令: ${cmd}（可用: pack | unpack | info | prune）" ;;
  esac
fi
