#!/usr/bin/env bash
# =============================================================================
#  lib/fix_python_shebang.sh —— AOSP 10 在 Ubuntu 22.04 上的 python shebang 修复
# -----------------------------------------------------------------------------
#  问题背景：
#    AOSP 10 (Q) 大量脚本使用 `#!/usr/bin/env python` 或 `#!/usr/bin/python`。
#    Ubuntu 20.04 起不再提供 `python` 这个名字（只有 python3），直接执行会报
#      bad interpreter: No such file or directory
#    —— 典型报错点：build/make 的部分 python 工具、external/* 的 codegen 脚本、
#       frameworks/base/tools/*、hardware/interfaces/*、system/tools/*。
#
#  处理策略（双保险）：
#    1) 系统层：安装 python-is-python3，建立 python -> python3 别名（apt_deps.sh 已做）
#    2) 源码层：把源码树里 shebang 指向不存在解释器的脚本批量改成 python3
#       （这样即使容器里没有别名也能跑，且不受 /usr/bin 写权限影响）
#
#  注意：只改 shebang（第 1 行），不改任何 python 源码，语法层面 100% 安全。
# =============================================================================

# 需要检查的源码顶层目录（避免全盘扫描 .repo / out / cts 巨量目录）
SCAN_ROOTS=(
  build
  device
  external
  frameworks
  hardware
  libcore
  packages
  system
  tools
  vendor
  art
  bionic
  dalvik
  prebuilts
)

# 不参与扫描的目录。
# 注意：--exclude-dir 是「按目录名全局匹配」，所以这里绝不能写 soong ——
# 那会把 build/soong、external/soong 等 AOSP 最核心的 python 目录一起排除掉。
# 排除 out 靠 SCAN_ROOTS 本身不包含 out 来实现。
SCAN_EXCLUDES=(
  --exclude-dir=.git
  --exclude-dir=.repo
  --exclude-dir=out
  --exclude-dir=cts
  --exclude-dir=third_party
  --exclude-dir=third_party_party
  --exclude-dir=node_modules
)

fix_python_shebang() {
  local root="${1:-$AOSP_SRC_DIR}"
  banner "修复 python shebang（Ubuntu 22.04 兼容）"

  # ---------- 第 1 步：系统级别名 ----------
  if command -v python >/dev/null 2>&1; then
    log "[1/2] 系统已有 python 命令 -> $(readlink -f "$(command -v python)")"
  else
    warn "[1/2] 系统无 python 命令，尝试建立软链"
    local SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO ln -sf "$(command -v python3)" /usr/local/bin/python
    log "[1/2] 已创建 /usr/local/bin/python -> $(command -v python3)"
  fi
  log "      python3 版本: $(python3 --version 2>&1)"

  # ---------- 第 2 步：源码级 shebang 改写 ----------
  log "[2/2] 扫描源码树中的非 python3 shebang ..."
  cd "$root"

  local tmp_list
  tmp_list="$(mktemp -t py_shebang_list.XXXXXX)"
  # 捕获方式：
  #   ^#!.*python$      -> 恰好以 python 结尾（不含 python3/python2/2to3）
  #   ^#!.*python[0-9]   -> 形如 python2 的行，稍后统一判断解释器是否存在
  local scan_args=()
  local d
  for d in "${SCAN_ROOTS[@]}"; do
    [ -d "$d" ] || continue
    scan_args+=("$d")
  done
  if [ "${#scan_args[@]}" -eq 0 ]; then
    warn "源码顶层目录不存在，跳过扫描"
    return 0
  fi

  # -r 递归, -I 跳过二进制, -l 只列文件名, -E 正则
  grep -rIlE '^#!.*\bpython[0-9.]*$' "${SCAN_ROOTS[@]}" "${SCAN_EXCLUDES[@]}" \
    > "$tmp_list" 2>/dev/null || true

  local total
  total="$(wc -l < "$tmp_list")"
  log "      命中 ${total} 个候选脚本"

  if [ "$total" -eq 0 ]; then
    log "无需改写，shebang 已全部合规"
    rm -f "$tmp_list"
    return 0
  fi

  # ---------- 逐个判断解释器是否存在，存在则跳过 ----------
  local fixed=0 skipped=0 failed=0
  local f line interp target new_line prefix last base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # 读取第 1 行 shebang
    line="$(head -n1 "$f" 2>/dev/null || true)"
    case "$line" in
      '#!'*) : ;;
      *) skipped=$((skipped+1)); continue ;;
    esac

    # 取出 shebang 最后一个空白分隔字段作为解释器，例如:
    #   #!/usr/bin/env python   -> python
    #   #!/usr/bin/python        -> /usr/bin/python
    #   #!/bin/bash              -> /bin/bash
    local has_space=1
    if [[ "$line" == *" "* ]]; then
      prefix="${line% *}"
      last="${line##* }"
    else
      has_space=0
      prefix="#!"
      last="${line#\#!}"
    fi
    interp="$last"

    # 非 python 解释器一律不动（bash / sh / perl / ruby / node …）
    base="$(basename -- "$interp")"
    case "$base" in
      python|python[0-9]|python[0-9].[0-9]*) : ;;
      *) skipped=$((skipped+1)); continue ;;
    esac

    # 已经是 python3 就跳过（AOSP 10 源码里绝大多数脚本本来就是 python3）
    if [ "$base" = "python3" ]; then
      skipped=$((skipped+1))
      continue
    fi

    # 判定是否为"本来就跑得通"的情况。
    #   AOSP_SHEBANG_SKIP_EXISTING=1（默认）：解释器在本机存在就跳过，
    #     适合本地仍有 python2 的开发机；
    #   AOSP_SHEBANG_SKIP_EXISTING=0：不管本机有没有，一律改写成 python3，
    #     适合 CI 强制统一，保证结果可复现。
    if [ "${AOSP_SHEBANG_SKIP_EXISTING:-1}" = "1" ]; then
      if [ "${interp:0:1}" = "/" ]; then
        [ -x "$interp" ] && { skipped=$((skipped+1)); continue; }
      else
        command -v "$interp" >/dev/null 2>&1 && { skipped=$((skipped+1)); continue; }
      fi
    fi

    # 形如 python / python2 / python2.7 一律统一到 python3（AOSP 10 已全量 python3 化）
    target="python3"
    if [ "$has_space" -eq 1 ]; then
      new_line="${prefix} ${target}"
    else
      # 无空格形式：#!/usr/bin/python  ->  #!/usr/bin/python3
      new_line="#!$(dirname -- "$interp")/${target}"
    fi

    # 改写第 1 行。
    # 用 `cat tmp > f` 而不是 `mv tmp f`：前者写进原 inode，保留可执行位与属主。
    if {
          printf '%s\n' "$new_line"
          tail -n +2 "$f"
        } > "$f.aosp-ci.tmp" 2>/dev/null \
       && cat "$f.aosp-ci.tmp" > "$f" 2>/dev/null; then
      rm -f "$f.aosp-ci.tmp"
      fixed=$((fixed+1))
      [ "$fixed" -le 20 ] && log "      fixed: ${f#./}  ->  ${new_line}"
    else
      rm -f "$f.aosp-ci.tmp" 2>/dev/null || true
      failed=$((failed+1))
      warn "      改写失败: ${f#./}"
    fi
  done < "$tmp_list"

  [ "$fixed" -gt 20 ] && log "      … 其余 ${fixed} 个已改写脚本省略打印"
  log "改写完成: fixed=${fixed}, skipped=${skipped}, failed=${failed}"

  rm -f "$tmp_list"

  [ "$failed" -gt 0 ] && warn "有 ${failed} 个文件改写失败，请人工检查（通常是只读权限）"

  # ---------- 抽样自检 ----------
  local sample
  for sample in \
      "$root/build/soong/scripts/soong_ui.bash" \
      "$root/build/make/tools/post_process_props.py" \
      "$root/frameworks/base/tools/make-api.py" ; do
    [ -f "$sample" ] || continue
    log "抽样: ${sample#${root}/}  shebang = $(head -n1 "$sample")"
  done

  log "python shebang 修复完成"
}
