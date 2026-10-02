#!/usr/bin/env bash
# =============================================================================
#  lib/apply_patches.sh —— 批量 apply CI 仓库 patches/ 目录下的补丁
# -----------------------------------------------------------------------------
#  仓库分离原则：
#    AOSP 源码不在 git 仓库里（云端 repo sync 拉取），因此不能用 git am / git apply
#    针对源码历史来打补丁。这里用 `patch -p1 --forward` 对工作区做纯文件级修补，
#    对"没有版本历史的工作区"同样有效，且可重复执行（已打过则自动跳过）。
#
#  补丁文件命名规范（决定 apply 顺序，务必用两位数字前缀）：
#    patches/0001-xxx.patch
#    patches/0002-xxx.patch
#    ...
#    patches/9999-xxx.patch      # 最后执行，例如收尾清理
#
#  补丁内容必须满足：
#    - 路径前缀是 a/ 和 b/（配合 -p1）
#    - 路径相对 AOSP 源码根目录，例如 a/build/soong/... 对应 $AOSP_SRC_DIR/build/soong/...
#    - 用 `git diff --no-index` / `git diff` 在 AOSP 源码树内生成，不要带 android- 提交号
# =============================================================================

apply_all_patches() {
  local root="${1:-$AOSP_SRC_DIR}"
  local pdir="${2:-$PATCH_DIR}"

  banner "批量 apply 补丁"

  if [ "$PATCH_APPLY_ENABLED" != "1" ]; then
    warn "PATCH_APPLY_ENABLED != 1，跳过补丁应用"
    return 0
  fi

  if [ ! -d "$pdir" ]; then
    warn "补丁目录不存在: ${pdir}（本次不应用任何补丁）"
    return 0
  fi

  cd "$root"

  # ---------- 收集补丁（自然排序保证 0001 -> 0002 顺序）----------
  mapfile -t patches < <(find "$pdir" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)
  local n=${#patches[@]}
  if [ "$n" -eq 0 ]; then
    log "补丁目录 ${pdir} 中没有 *.patch 文件"
    return 0
  fi
  log "发现 ${n} 个补丁，位于 ${pdir}"

  # ---------- 工具依赖 ----------
  if ! command -v patch >/dev/null 2>&1; then
    err "系统缺少 patch 命令，无法应用补丁"
    return 1
  fi

  # ---------- 逐个应用 ----------
  local applied=0
  local already=0
  local failed=0
  local failed_list=()

  local p
  for p in "${patches[@]}"; do
    local rel
    rel="$(basename "$p")"
    logv "----- 应用 ${rel} -----"

    # --forward：只往后打，绝不反向改写
    # --batch  ：非交互
    # -p1     ：剥离 a/ b/ 前缀
    # -f      ：强制，避免交互式提问
    # patch 的原始输出先收进临时文件，三种结局都判定完之后再决定是否打印，
    # 避免 "Hunk #1 FAILED" 噪音在幂等跳过场景里误伤日志可读性
    local pout
    pout="$(mktemp -t patch_out.XXXXXX)"
    if patch -p1 --forward --batch --reject-file=- -f -i "$p" >"$pout" 2>&1; then
      log "  [OK]   ${rel}"
      [ -s "$pout" ] && sed 's/^/         /' "$pout"
      applied=$((applied+1))
    elif patch -p1 --dry-run --reverse --batch -f -i "$p" >/dev/null 2>&1; then
      # 反向可应用 == 说明工作区已经是打过补丁的状态
      log "  [SKIP] ${rel}（已应用，幂等跳过）"
      already=$((already+1))
    else
      err "  [FAIL] ${rel} 应用失败"
      [ -s "$pout" ] && sed 's/^/         /' "$pout" >&2
      # 把 reject 内容落盘方便排错
      local rej
      rej="${CI_LOG_DIR}/reject-${rel}.rej"
      patch -p1 --forward --batch --reject-file="$rej" -f -i "$p" >/dev/null 2>&1 || true
      if [ -f "$rej" ]; then
        err "        reject 内容已保存: ${rej}"
        head -n 20 "$rej" >&2 || true
      fi
      failed=$((failed+1))
      failed_list+=("$rel")
    fi
    rm -f "$pout"
  done

  log "补丁应用统计: applied=${applied}, already=${already}, failed=${failed}"

  if [ "$failed" -gt 0 ]; then
    err "以下补丁应用失败: ${failed_list[*]}"
    err "常见原因："
    err "  1) AOSP 源码版本与补丁基线不一致（检查 AOSP_TAG）"
    err "  2) 前置补丁被 --prune-source 删掉了文件"
    err "  3) 补丁路径前缀不是 a/ b/（无法用 -p1）"
    err "  4) 补丁已被上游 upstream 吸收，需要重新生成"
    return 1
  fi

  log "所有补丁应用完成"
}

# =============================================================================
# 供本地导出补丁时对照的说明（打印用）
# =============================================================================
print_patch_howto() {
  cat <<'EOF'
==============================================================================
 补丁导出与自动批量 apply 指南
==============================================================================

【A. 在本地完整 AOSP 源码树里改好，然后导出补丁】

  # 1) 进 AOSP 根目录
  cd $HOME/aosp-android10

  # 2) 改代码后，逐文件生成 diff
  git -C build/soong diff >  /tmp/patches/0001-fix-soong-xxx.patch
  git -C frameworks/base diff > /tmp/patches/0002-fix-api-xxx.patch

  # 3) 对没有 git 历史的目录（repo sync 下来的多数子仓其实有 .git，
  #     但若某些目录是预置文件、无 git），用 --no-index：
  diff -uNr \
      --label a/system/core/rootdir/Android.bp \
      --label b/system/core/rootdir/Android.bp \
      /dev/null /dev/null >/dev/null
  # 更实用的写法：
  cp -a system/core/rootdir/Android.bp /tmp/Android.bp.orig
  vim system/core/rootdir/Android.bp
  diff -u /tmp/Android.bp.orig system/core/rootdir/Android.bp \
    | sed -e '1s|.*|--- a/system/core/rootdir/Android.bp|' \
          -e '2s|.*|+++ b/system/core/rootdir/Android.bp|' \
    >  /tmp/patches/0003-rootdir-xxx.patch

  # 4) 一键把所有改动导出成带 a/ b/ 前缀的 patch
  cd $HOME/aosp-android10
  mkdir -p /tmp/patches
  for d in $(git -C . diff --name-only 2>/dev/null); do :; done
  # 更直接：分别进子仓
  ( cd build/soong   && git diff ) | sed -E 's@^(\+\+\+|---) [ab]/@\1 a/@' > /tmp/patches/0001.patch
  ( cd system/core   && git diff ) | sed -E 's@^(\+\+\+|---) [ab]/@\1 a/@' > /tmp/patches/0002.patch

【B. 校验补丁能被 patch -p1 正确应用】

  cd $HOME/aosp-android10
  patch -p1 --dry-run --forward -i /tmp/patches/0001.patch && echo "dry-run OK"

【C. 放进 CI 仓库】

  cp /tmp/patches/*.patch <CI仓库根>/patches/
  # CI 仓库里 patches/ 只放 .patch 文件，不要放原文件

【D. 命名与顺序】
  0001-xxx.patch  0002-xxx.patch ... 9999-xxx.patch
  脚本用 LC_ALL=C sort 保证按文件名顺序 apply

【E. 提交】
  git add patches/ && git commit -m "patches: add xxx"
  git push
==============================================================================
EOF
}
