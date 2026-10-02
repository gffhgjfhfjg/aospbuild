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

# ninja target 探测
ninja_list_all_targets() {
  local out ninja
  out="$(aosp_out)"
  ninja="$(find_ninja)"

  [ -f "$out/soong/build.ninja" ] \
    || die "未找到 ${out}/soong/build.ninja，请先执行 'm nothing' 生成 soong 构建图"

  log "导出 ninja 目标清单（$("$ninja" --version 2>/dev/null || echo unknown)）…"
  # -t targets deep 2：深度 2 足以覆盖 phony 顶层目标与主要规则，
  # -t targets all 则包含上万个文件级目标，噪音太大且会拖慢 IO
  "$ninja" -C "$out" -t targets all 2>/dev/null \
    | awk -F: '{print $1}' \
    | LC_ALL=C sort -u \
    > "$out/.ninja_targets_all.txt"

  local n
  n="$(wc -l < "$out/.ninja_targets_all.txt")"
  log "ninja 目标总数: ${n}"
  [ "$n" -eq 0 ] && die "ninja 目标清单为空，检查 soong 构建图是否损坏"
}

# 分类目标：写入 $out/.ninja_targets_{exclude,keep}.txt
plan_targets_excluding_metalava() {
  local out
  out="$(aosp_out)"
  local all="$out/.ninja_targets_all.txt"
  [ -f "$all" ] || ninja_list_all_targets

  banner "规划 Ninja 目标（排除 metalava）"

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
  "$ninja" -C "$out" -t targets 2>/dev/null \
    | grep -E ': phony' | awk -F: '{print $1}' | LC_ALL=C sort -u | head -n 60 | sed 's/^/    /'
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
