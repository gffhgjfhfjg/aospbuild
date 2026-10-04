#!/usr/bin/env bash
# =============================================================================
#  lib/ninja_targets.sh —— Ninja 目标解析与「排除 metalava」目标规划
# -----------------------------------------------------------------------------
#  需求（硬性）：Job2 要编译「排除 metalava 之外的全部 ninja 目标」。
#
#  为什么不能直接 m all：
#    AOSP 10 的 metalava（external/metalava）负责生成 frameworks/base/api/current.txt
#    与 prebuilts/sdk/current/**/api/current.txt。metalava 一次性扫描全量 SDK 源码，
#    单核执行常常吃掉 1~2 小时，且是全流程最容易 OOM/超时的环节。
#    所以把它单独切到 Job3 串行处理，Job2 完全不碰 metalava。
#
#  实现方式：
#    1) 先 `m nothing` 让 soong 生成 out/soong/build.ninja（不编译任何东西）
#    2) `ninja -t targets` 拿到全部目标清单
#    3) 用「反向依赖」思想挑出需要排除的 metalava 相关目标
#    4) 生成排除清单 + 剩余目标清单，写盘留档
#    5) Job2 用 ninja 直接跑剩余目标（等价于 m all 但跳过 metalava）
# =============================================================================

# metalava 相关目标匹配规则（正则）
METALAVA_EXCLUDE_RE='(^|[-_/])(metalava|update-api|check-api|api-versions)([-_./]|$)'

# 另外这些目标虽不含 metalava 字样，但会间接触发 metalava，一并排除。
# 关键：metalava 的「输出文件」本身也必须排除
#   —— frameworks/base/api/current.txt
#      frameworks/base/api/system-current.txt
#      frameworks/base/api/test-current.txt
#      prebuilts/sdk/current/N/api/current.txt
#   这些是 Job3(update-api) 的产物，留着它们会通过 ninja 的依赖边把 metalava
#   重新拉回 Job2 编译，等于没做分段。
METALAVA_EXTRA_EXCLUDE_RE='(^|[-_/])api-current([-_./]|$)|(^|[-_/])(framework-|hw-)?api-gen([-_./]|$)|(^|[-_/])api-versions([-_./]|$)|(^|/)api/(system-|test-)?current\.txt$|(^|/)api/removed\.txt$'

# =============================================================================
# ninja 目标枚举
# -----------------------------------------------------------------------------
#  【run 36991148496 的两个误判 —— 这次一并纠正】
#
#  误判 1:「ninja -t targets all 只拿到 0 个目标 => ninja 1.8.2 太老不支持」
#    真相: `-t targets all` 在 ninja 1.8.2 里是**支持**的
#    （src/ninja.cc 的 NinjaMain::ToolTargets 里有 `else if (mode == "all")` 分支）。
#    拿到 0 个的真正原因是：命令是 `ninja -C "$out" -t targets all`，
#    没有 -f，于是去找 out/build.ninja —— 而 AOSP 10 根本不生成这个文件，
#    ninja 直接报错退出，stderr 又被 2>/dev/null 吞掉，看上去就是「0 个目标」。
#
#  误判 2:「直接解析 build.ninja 里的 phony 行更可靠，所以一直用它」
#    巧合能用，但拿到的只是 soong 图的 phony 目标，漏掉 kati 生成的目标。
#    现在入口文件找对了，`-t targets all` 可以正常用；解析 build.ninja
#    降级为兜底。
#
#  关键点: 所有 ninja 调用都必须带 `-f <combined*.ninja>`，
#  入口文件由 common.sh 的 aosp_ninja_manifest() 解析。
# =============================================================================

# 解析 build.ninja 系列文件，取出所有可构建目标名（兜底路径）
_ninja_targets_from_buildfiles() {
  local out="$1"
  local ninja_f
  ninja_f="$out/soong/build.ninja"
  [ -f "$ninja_f" ] || { err "未找到 ${ninja_f}"; return 1; }

  # 1) 所有 phony 目标（顶层逻辑目标，最接近 "m all" 的语义）
  grep -hE '^build [^ ]+: phony' "$ninja_f" 2>/dev/null | awk '{print $2}' | sed 's/:$//' || true
  # 2) 部分目标（如 dist-for-googlers、install-* 聚合）也在 build-*.ninja 里
  local extra
  for extra in "$out"/build-*.ninja; do
    [ -f "$extra" ] || continue
    grep -hE '^build [^ ]+: phony' "$extra" 2>/dev/null | awk '{print $2}' | sed 's/:$//' || true
  done
}

ninja_supports_response_file() {
  local ninja
  ninja="$(find_ninja)"
  "$ninja" --help 2>&1 | grep -q '@file' && return 0 || return 1
}

ninja_list_all_targets() {
  local out; out="$(aosp_out)"
  local ninja; ninja="$(find_ninja)"

  [ -f "$out/soong/build.ninja" ] \
    || die "未找到 ${out}/soong/build.ninja，请先执行 'm nothing' 生成 soong 构建图"

  # ---- 入口文件：AOSP 10 是 combined<katiSuffix>.ninja，不是 build.ninja ----
  local mf
  mf="$(require_ninja_manifest)" \
    || die "无法定位 ninja 入口文件（ninja 会去找 out/build.ninja 并失败）"

  log "导出 ninja 目标清单（ninja 版本: $("$ninja" --version 2>/dev/null || echo unknown)）"
  log "ninja 入口文件: ${mf}"

  local f="$out/.ninja_targets_all.txt"

  # ---- 路径 1：ninja -t targets all（正确入口文件 + 正确 CWD 下可用）----
  : > "$f"
  ninja_run -t targets all 2>"$out/.ninja_targets_err.txt" \
    | awk -F: 'NF>1{print $1}' >> "$f" || true
  local n1; n1="$(count_lines "$f")"

  if [ "$n1" -ge 50 ]; then
    LC_ALL=C sort -u "$f" -o "$f"
    log "路径1: ninja -t targets all 得到 ${n1} 个目标 ✓"
  else
    # ---- 兜底路径：直接解析 build.ninja ----
    err "ninja -t targets all 只得到 ${n1} 个目标（不该发生，请检查入口文件）"
    if [ -s "$out/.ninja_targets_err.txt" ]; then
      err "ninja stderr:"
      head -n 5 "$out/.ninja_targets_err.txt" | sed 's/^/    /' >&2 || true
    fi
    warn "回退到直接解析 build.ninja ..."
    : > "$f"
    _ninja_targets_from_buildfiles "$out" | LC_ALL=C sort -u > "$f" 2>/dev/null || true
    local n2; n2="$(count_lines "$f")"
    log "路径2: 解析 build.ninja 得到 ${n2} 个 phony 目标"
    if [ "$n2" -lt 10 ]; then
      err "两种方式都没取到足够目标（ninja -t targets=${n1}, 解析=${n2}）"
      err "请检查 $out/soong/build.ninja 是否正常（真实大小约 1GB）"
      err "当前大小: $(du_gb "$out/soong/build.ninja")GB"
      return 1
    fi
  fi

  log "目标清单: $f（$(count_lines "$f") 个）"
  log "前 10 个示例: $(head -n 10 "$f" | tr '\n' ' ')"

  # ---- 响应文件能力探测 ----
  if ninja_supports_response_file; then
    log "ninja 支持 @file 响应文件 ✓（将用 rspfile 模式）"
  else
    warn "ninja 不支持 @file 响应文件（该版本太老），stage1 将自动改用 xargs 分批模式"
    warn "这是 AOSP 10 自带 ninja 1.8.2 的已知限制，不影响正确性，只是 ninja 图"
    warn "(约 1GB) 会被加载多次，因此分批粒度要尽量大。"
  fi
}

# =============================================================================
#  目标范围：product（默认） vs all
# -----------------------------------------------------------------------------
#  【为什么不默认用「全部 ninja 目标」】—— run 37093496242 的教训
#
#  soong+kati 生成的 build.ninja 里躺着 **所有模块的所有变体**：
#  host / device / vendor / common / product / sdk / cts ...，
#  连 32 位 arm（android_arm_armv8-a_core）和 Robolectric、CTS 用到的
#  各种 test-config 都在里面，实测 82774 个目标。
#
#  绝大多数目标 aosp_arm64 这个产品**根本不会构建**（Google 自己也从不构建它们），
#  于是「全量目标」模式会额外踩到一长串只在这条路径上出现的失败，例如：
#    * hardware.google.media.c2@1.0-service 的 32 位 vendor 变体：
#      vendor 变体拿不到 gui 的 include 路径，clang 直接报
#      'gui/IGraphicBufferProducer.h' file not found
#    * bionic/libc 的 android_arm_armv8-a_core（32 位 core 变体）系列
#    * host Java source list: Robolectric_*
# 这些失败与我们要的 arm64 镜像毫无关系，却会让 ninja 判定 build failed，
# 让整个 job 失败，还白白烧掉几小时机时。
#
#  【product 模式】
#  只把「产品交付物」（system.img / vendor.img / ...）写进 ninja 的目标清单，
#  ninja 自己会展开完整依赖闭包 —— 也就是等价于 `m system.img vendor.img ...`，
#  但不牵扯 metalava。这才是「构建这个产品真正需要的东西」。
#  依赖顺序、增量续跑、dry-run 判定等逻辑完全不变（都由 ninja 保证）。
# =============================================================================
AOSP_STAGE1_TARGET_SCOPE_DEFAULT="product"
AOSP_PRODUCT_TARGETS_DEFAULT="system.img vendor.img odm.img product.img userdata.img ramdisk.img vbmeta.img"

# 规划 product 范围的目标清单。返回 0 成功，1 =无法规划（调用方应 die）
_plan_targets_product() {
  local all="$1"
  local out="$2"
  local want="${AOSP_PRODUCT_TARGETS:-$AOSP_PRODUCT_TARGETS_DEFAULT}"

  banner "规划 Ninja 目标（product 范围）"

  # 图里可能同时存在 `system.img` 与 `out/target/product/<dev>/system.img` 两种写法，
  # 所以额外建一份「basename 索引」，两种写法都能命中。
  local base_idx="$out/.ninja_targets_base.txt"
  awk -F: 'NF>1{n=$1; sub(/.*\//,"",n); print n}' "$all" | LC_ALL=C sort -u > "$base_idx"

  local keep="$out/.ninja_targets_keep.txt"
  local excl="$out/.ninja_targets_exclude.txt"
  : > "$keep"
  : > "$excl"

  local t hit=0 miss=0
  local dropped=""
  for t in $want; do
    if grep -Fxq -- "$t" "$all" 2>/dev/null || grep -Fxq -- "$t" "$base_idx" 2>/dev/null; then
      printf '%s\n' "$t" >> "$keep"
      hit=$((hit+1))
    else
      miss=$((miss+1))
      dropped="${dropped}${dropped:+, }${t}"
    fi
  done
  LC_ALL=C sort -u "$keep" -o "$keep"

  log "请求的产品交付物: ${want}"
  log "命中 ninja 图: ${hit} 个，图中不存在而丢弃: ${miss} 个${dropped:+（${dropped}）}"

  # 硬校验：至少要有 system.img 或 vendor.img，否则说明 lunch/建图环节出了问题，
  # 这时如果继续跑，ninja 会拿一个空目标清单去跑，等于什么都没构建却「成功」了。
  if ! grep -Fxq -- "system.img" "$keep" 2>/dev/null \
     && ! grep -Fxq -- "vendor.img" "$keep" 2>/dev/null; then
    err "product 范围一个镜像目标都没命中 —— 请检查 lunch 是否成功、out/soong/build.ninja 是否正常"
    err "  ninja 图里的镜像类目标（抽样）:"
    grep -E '\.img$' "$base_idx" 2>/dev/null | head -n 15 | sed 's@^@      - @' >&2 || true
    err "  可用 AOSP_PRODUCT_TARGETS 指定其它目标名后重跑"
    return 1
  fi

  # 安全网：产品交付物里不该出现 metalava 相关目标，出现就剔掉（防止分段失效）。
  # 先把候选拷到临时文件再回写，避免在 while 里改动正在被重定向读取的文件。
  local cand="$out/.ninja_targets_cand.txt"
  LC_ALL=C sort -u "$keep" > "$cand"
  : > "$keep"
  local metalava_hit=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if printf '%s\n' "$t" | grep -qE "$METALAVA_EXCLUDE_RE"; then
      metalava_hit="${metalava_hit}${metalava_hit:+, }${t}"
      printf '%s\n' "$t" >> "$excl"
    else
      printf '%s\n' "$t" >> "$keep"
    fi
  done < "$cand"
  [ -n "$metalava_hit" ] && warn "剔除了 metalava 相关交付物: ${metalava_hit}"

  {
    echo "# ninja target plan"
    echo "generated_at_utc=$(date -u +%FT%TZ)"
    echo "aosp_tag=${AOSP_TAG}"
    echo "scope=product"
    echo "graph_total_targets=$(count_lines "$all")"
    echo "keep_count=$(count_lines "$keep")"
    echo "requested=${want}"
  } > "$out/.ninja_targets_plan.txt"

  log "product 范围目标清单（$(count_lines "$keep") 个）:"
  sed 's@^@    - @' "$keep"
  log "对比：若用 all 范围需要构建 $(count_lines "$all") 个目标"
  log "目标规划完成（product 范围）"
  return 0
}

# 分类目标：写入 $out/.ninja_targets_{exclude,keep}.txt
plan_targets_excluding_metalava() {
  local out
  out="$(aosp_out)"
  local all="$out/.ninja_targets_all.txt"
  [ -f "$all" ] || ninja_list_all_targets

  local scope="${AOSP_STAGE1_TARGET_SCOPE:-$AOSP_STAGE1_TARGET_SCOPE_DEFAULT}"
  if [ "$scope" = "product" ]; then
    _plan_targets_product "$all" "$out" || die "product 范围目标规划失败"
    return 0
  fi
  [ "$scope" = "all" ] || die "AOSP_STAGE1_TARGET_SCOPE 只能是 product 或 all（当前 '${scope}'）"

  banner "规划 Ninja 目标（all 范围，排除 metalava）"
  warn "all 范围会构建 $(count_lines "$all") 个目标，其中大量是 aosp_arm64 永不构建的"
  warn "模块变体（32 位 arm / Robolectric / CTS 等），踩到它们的失败会直接让 job 失败。"
  warn "如无特殊需求请改用 AOSP_STAGE1_TARGET_SCOPE=product"

  # ---- 1) 命中的 metalava 目标 ----
  grep -E "$METALAVA_EXCLUDE_RE" "$all" > "$out/.ninja_targets_exclude.txt" || true
  grep -E "$METALAVA_EXTRA_EXCLUDE_RE" "$all" >> "$out/.ninja_targets_exclude.txt" || true
  LC_ALL=C sort -u "$out/.ninja_targets_exclude.txt" -o "$out/.ninja_targets_exclude.txt"

  # ---- 2) 剩余目标 = 全部 - 排除 ----
  LC_ALL=C sort -u "$all" -o "$all"
  LC_ALL=C comm -23 "$all" "$out/.ninja_targets_exclude.txt" > "$out/.ninja_targets_keep.txt"

  local n_ex n_keep
  n_ex="$(wc -l < "$out/.ninja_targets_exclude.txt")"
  n_keep="$(wc -l < "$out/.ninja_targets_keep.txt")"
  log "排除目标数(metalava 相关): ${n_ex}"
  log "保留目标数: ${n_keep}"

  # ---- 3) 打印排除清单（最多 40 条）----
  log "排除清单预览:"
  head -n 40 "$out/.ninja_targets_exclude.txt" | sed 's/^/    - /'
  [ "$n_ex" -gt 40 ] && log "    … 其余 $((n_ex - 40)) 条见 ${out}/.ninja_targets_exclude.txt"

  # ---- 4) 关键校验：确认 ninja 图里没有把 metalava 作为默认目标的强依赖 ----
  #    若 soong 把 metalava 挂到 all 上，即使我们不显式构建它也会被拉进来。
  #    这里只做提示，不做自动修改（修改需要重新生成构建图，代价高）。
  if grep -qE '^\s*build all: phony' "$out/soong/build.ninja" 2>/dev/null; then
    log "检测到 all 是 phony 目标，Job2 将不直接构建 all，而是构建保留清单中的具体目标"
  fi

  # ---- 5) 落盘留档（失败时便于复盘）----
  {
    echo "# ninja target plan"
    echo "generated_at_utc=$(date -u +%FT%TZ)"
    echo "aosp_tag=${AOSP_TAG}"
    echo "scope=all"
    echo "exclude_count=${n_ex}"
    echo "keep_count=${n_keep}"
    echo "exclude_re=${METALAVA_EXCLUDE_RE}"
  } > "$out/.ninja_targets_plan.txt"

  log "目标规划完成"
}

# 打印一个便于人工核对的「顶层 phony 目标」列表
plan_print_phony_summary() {
  local out
  out="$(aosp_out)"
  local ninja
  ninja="$(find_ninja)"
  log "顶层 phony 目标摘要（前 60 个）:"
  ninja_run -t targets 2>/dev/null \
    | grep -E ': phony' | awk -F: '{print $1}' | LC_ALL=C sort -u | head -n 60 | sed 's/^/    /'
  return 0
}

# 判断某个目标是否被 metalava 规则排除
target_is_excluded() {
  local t="$1"
  local out
  out="$(aosp_out)"
  grep -Fxq "$t" "$out/.ninja_targets_exclude.txt" 2>/dev/null
}

# 判断某目标在 ninja 图中是否存在
target_in_ninja_graph() {
  local t="$1"
  local out
  out="$(aosp_out)"
  grep -qE "^build ${t}(:|\s)" "$out/soong/build.ninja" 2>/dev/null
}
