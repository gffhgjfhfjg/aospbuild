#!/usr/bin/env bash
# =============================================================================
#  lib/fix_python_shebang.sh —— AOSP 10 在 Ubuntu 22.04 上的 python 解释器适配
# -----------------------------------------------------------------------------
#  背景（run 37093496242 的真实死因）：
#    AOSP 10 (android-10.0.0_r47) 的官方宿主是 Ubuntu 18.04，上面 **同时** 有
#    python2.7 与 python3。Ubuntu 20.04 起发行版不再默认提供 python2，
#    22.04 的 jammy/universe 里虽然还有 python2.7 (2.7.18-13ubuntu1.5)，
#    但必须显式 apt 安装。
#
#    之前本脚本把源码树里所有 `#!/usr/bin/env python` 一律改写成 python3，
#    注释里写的是「AOSP 10 已全量 python3 化」—— 这个前提是错的。
#    AOSP 10 的构建脚本是 py2 / py3 混编，一刀切 python3 会让下面两类同时暴毙：
#
#      A) py2-only 语法（print 语句、except X, e）
#         py3 直接 SyntaxError，脚本根本跑不起来：
#           build/make/tools/merge-event-log-tags.py
#           build/tools/java-event-log-tags.py
#           bionic/libc/fs_config_generator.py
#           build/make/tools/check_radio_versions.py
#           build/make/tools/normalize_path.py
#           external/clang/clang-version-inc.py
#         另外 bionic 的 genfunctosyscallnrs 会自己在 PATH 里 exec python2.7，
#         缺解释器直接 AssertionError: Could not find python binary: python2.7
#
#      B) 语法合法但语义是 py2（minidom.toxml(encoding=) 在 py3 返回 bytes，
#         老代码把 str 写进 open(..., 'wb')）
#         编译期看不出来，运行期必炸：
#           build/soong/scripts/manifest_fixer.py 的 write_xml()
#           -> TypeError: a bytes-like object is required, not 'str'
#         这一个脚本被 soong 用来处理「每一个带 AndroidManifest.xml 的模块」，
#         一次编译里会命中几百个目标（实测 896 次），是失败量最大的一项。
#         B) 类没法靠语法探测识别，只能就地打补丁（见本文件第 3 步）。
#
#  处理策略（三步）：
#    1) 系统层：装 python2 + python3，并建立 python -> python3 别名
#    2) 源码层：**逐文件**做语法探测，py3 能编译就写 python3，
#       只有 py3 编译不过而 py2.7 能编译时才写 python2.7
#    3) 语义层：就地修manifest_fixer / manifest.py 的 write_xml（py2/py3 通用）
#
#  只改 shebang（第 1 行）与 write_xml 函数体，不动其它 python 源码。
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

# 第 3 步要修的「py2 语义 / py3 语义错位」脚本。
# 两个路径都试：
#   * 早期Q 的 manifest_fixer.py 自带 write_xml
#   * 后期 Q 把 write_xml 挪进了 manifest.py，manifest_fixer 从那里 import
SENTINEL_SEMANTIC_FILES=(
  "build/soong/scripts/manifest.py"
  "build/soong/scripts/manifest_fixer.py"
)

# 抽样自检用的文件（py2-only 语法的典型代表）
SHEBANG_SAMPLES=(
  "build/make/tools/merge-event-log-tags.py"
  "build/tools/java-event-log-tags.py"
  "bionic/libc/fs_config_generator.py"
  "build/make/tools/normalize_path.py"
)

# ---------------------------------------------------------------------------
# 语法探测：某个解释器能不能编译这个文件
# ---------------------------------------------------------------------------
# 用 compile() 而不是 `python -m py_compile`：后者会往源码树里写 __pycache__，
# 在 60GB 的 AOSP 树里到处留垃圾，还会污染 repo 状态。
# 只读文件 + 只看语法，不执行、不落盘。
_py_compiles() {
  local interp="$1" f="$2"
  "$interp" -c 'import sys
p = sys.argv[1]
with open(p, "rb") as fh:
    src = fh.read()
compile(src, p, "exec")' "$f" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 第 3 步：修 write_xml（py3 下 str 写进 'wb' 必崩）
# ---------------------------------------------------------------------------
# 用法: _fix_write_xml <文件> ;返回 0=已修/已修过 3=不适用 其它=出错
# 注意：python3 故意以非 0 退出（3=该文件里没有 write_xml），
# 所以这里必须用 `|| rc=$?` 兜住，否则调用方的 set -e 会直接把脚本打断。
_fix_write_xml() {
  local f="$1"
  local rc=0
  [ -f "$f" ] || return 3
  python3 - "$f" <<'PY' || rc=$?
import re
import sys

path = sys.argv[1]
MARK = '[aosp-ci] py2/py3-safe write_xml'
NL = chr(10)

# 注意：注入的注释一律用 ASCII。
# manifest.py / manifest_fixer.py 有可能被 python2 脚本 import，
# 而 python2 源码里出现非 ASCII 且没有 coding 声明会直接 SyntaxError。
NEW = [
    'def write_xml(f, doc):',
    '  """Write XML doc to provided file object."""',
    '  # ' + MARK + '.',
    '  # The original body was py2 code: it wrote a text str into a file opened',
    '  # with "wb". On py3 minidom toxml(encoding=...) returns bytes, so',
    '  # f.write(<str>) raises',
    '  #   TypeError: a bytes-like object is required, not "str"',
    '  # soong runs manifest_fixer.py once per module that has an',
    '  # AndroidManifest.xml, which fails hundreds of targets in a single build.',
    '  # Build the whole document as text, then encode for binary handles.',
    '  NL = chr(10)',
    "  parts = ['<?xml version=\"1.0\" encoding=\"utf-8\"?>' + NL]",
    '  for node in doc.childNodes:',
    "    xml = node.toxml(encoding='utf-8')",
    "    parts.append(xml.decode('utf-8') if isinstance(xml, bytes) else xml)",
    '    parts.append(NL)',
    "  data = ''.join(parts).encode('utf-8')",
    '  try:',
    '    f.write(data)',
    '  except TypeError:',
    "    f.write(data.decode('utf-8'))",
    '',
    '',
    '',
]
NEW = NL.join(NEW)

with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
    src = fh.read()

if MARK in src:
    sys.exit(0)

m = re.search(r'^def write_xml\(\s*f\s*,\s*doc\s*\)\s*:' + NL, src, re.M)
if not m:
    # 该文件里没有本地 write_xml（write_xml 在 manifest.py 里，或已被别人修过）
    sys.exit(3)

start = m.start()
nxt = re.search(r'^(?:def |class )', src[m.end():], re.M)
end = (m.end() + nxt.start()) if nxt else len(src)

out = src[:start] + NEW + src[end:]
with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
    fh.write(out)
sys.exit(0)
PY
  return "$rc"
}

# ============================================================================
fix_python_shebang() {
  local root="${1:-$AOSP_SRC_DIR}"
  banner "python 解释器适配（Ubuntu 22.04 / AOSP 10）"

  # ---------- 第1 步：解释器自检 ----------
  local py3 py2=""
  py3="$(command -v python3 || true)"
  if [ -z "$py3" ]; then
    err "找不到 python3 —— AOSP 10 至少需要 python3"
    exit 1
  fi

  # python -> python3 别名（apt 的 python-is-python3 装不上时手工补）
  if command -v python >/dev/null 2>&1; then
    log "[1/3] python-> $(readlink -f "$(command -v python)")"
  else
    warn "[1/3] 系统无 python 命令，尝试建立软链"
    local SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO ln -sf "$py3" /usr/local/bin/python || true
    log "[1/3] 已创建 /usr/local/bin/python -> ${py3}"
  fi
  log "      python3: $("$py3" --version 2>&1)  (${py3})"

  # python2.7：AOSP 10 的 py2-only 脚本要靠它
  local want_py2="${AOSP_SHEBANG_PY2:-auto}"
  if [ "$want_py2" = "auto" ] || [ "$want_py2" = "1" ]; then
    if command -v python2.7 >/dev/null 2>&1; then
      py2="$(command -v python2.7)"
    elif command -v python2 >/dev/null 2>&1; then
      py2="$(command -v python2)"
    elif [ -n "${AOSP_PY2_BIN:-}" ] && [ -x "${AOSP_PY2_BIN}" ]; then
      py2="${AOSP_PY2_BIN}"
    fi
  fi
  if [ -n "$py2" ]; then
    log "      python2.7: $("$py2" -V 2>&1)  (${py2})"
  else
    warn "      找不到 python2.7 —— AOSP 10 的 py2-only 构建脚本会全部 SyntaxError"
    warn "      22.04 装法: sudo apt-get install -y python2（jammy/universe 有 2.7.18）"
  fi

  # ---------- 第 2 步：源码级 shebang 改写（按语法探测路由）----------
  log "[2/3] 扫描源码树中的非 python3 shebang ..."
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
  local fixed=0 skipped=0 failed=0 unknown=0 to_py2=0
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
    #   AOSP_SHEBANG_SKIP_EXISTING=1：解释器在本机存在就跳过，
    #     适合本地开发机（可能还留着python2）；
    #   AOSP_SHEBANG_SKIP_EXISTING=0：不管本机有没有，一律改写，
    #     适合 CI 强制统一，保证结果可复现。
    if [ "${AOSP_SHEBANG_SKIP_EXISTING:-1}" = "1" ]; then
      if [ "${interp:0:1}" = "/" ]; then
        [ -x "$interp" ] && { skipped=$((skipped+1)); continue; }
      else
        command -v "$interp" >/dev/null 2>&1 && { skipped=$((skipped+1)); continue; }
      fi
    fi

    # ------------------------------------------------------------------
    # 关键：按「谁能编译这个文件」决定目标解释器
    #   py3 能编译            -> python3   （绝大多数脚本走这条）
    #   py3 不能 / py2.7 能   -> python2.7 （py2-only 脚本，run 37093496242 的那批）
    #   两个都不能            -> 原样保留并计数（多为 py2.7 语法但本机没有 py2）
    # ------------------------------------------------------------------
    if _py_compiles "$py3" "$f"; then
      target="python3"
    elif [ -n "$py2" ] && _py_compiles "$py2" "$f"; then
      target="$py2"
      to_py2=$((to_py2+1))
    else
      unknown=$((unknown+1))
      [ "$unknown" -le 10 ] && warn "      两套解释器都编译不过，保持原样: ${f#./}  ($(head -n1 "$f"))"
      continue
    fi

    if [ "$has_space" -eq 1 ]; then
      new_line="${prefix} ${target}"
    else
      # 无空格形式：#!/usr/bin/python  ->  #!/usr/bin/env python3
      #统一用 env 形式，这样 python2.7 绝对路径也能直接用
      new_line="#!/usr/bin/env ${target}"
    fi

    # 改写第 1 行。
    # 用 `cat tmp > f` 而不是 `mv tmp f`：前者写进原inode，保留可执行位与属主。
    if {
          printf '%s\n' "$new_line"
          tail -n +2 "$f"
        } > "$f.aosp-ci.tmp" 2>/dev/null \
       && cat "$f.aosp-ci.tmp" > "$f" 2>/dev/null; then
      rm -f "$f.aosp-ci.tmp"
      fixed=$((fixed+1))
      if [ "$fixed" -le 20 ]; then
        log "      fixed: ${f#./}  ->  ${new_line}"
      elif [ "$fixed" -eq 21 ]; then
        log "      … 其余已改写脚本省略打印"
      fi
    else
      rm -f "$f.aosp-ci.tmp" 2>/dev/null || true
      failed=$((failed+1))
      warn "      改写失败: ${f#./}"
    fi
  done < "$tmp_list"

  log "shebang 改写完成: fixed=${fixed}（其中路由到 python2.7 的 ${to_py2} 个）, skipped=${skipped}, unknown=${unknown}, failed=${failed}"
  if [ "$to_py2" -gt 0 ]; then
    log "      -> ${to_py2} 个脚本是 py2-only，已指向 ${py2:-<未找到>}"
  fi
  [ "$unknown" -gt 0 ] && warn "有 ${unknown} 个脚本两套解释器都编译不过，请人工确认"

  rm -f "$tmp_list"

  [ "$failed" -gt 0 ] && warn "有 ${failed} 个文件改写失败，请人工检查（通常是只读权限）"

  # ---------- 第 3 步：修 py2/py3 语义错位的 write_xml ----------
  # 这一类脚本语法合法，语法探测看不出问题，必须按已知位置就地修。
  log "[3/3] 修 manifest_fixer 的 write_xml（py3 下 str 写进 'wb' 必崩）"
  local rel rc fixed_wf=0
  for rel in "${SENTINEL_SEMANTIC_FILES[@]}"; do
    case "$rel" in
      "${root}"/*) f="$rel" ;;
      *) f="$root/$rel" ;;
    esac
    [ -f "$f" ] || continue
    rc=0
    _fix_write_xml "$f" || rc=$?
    case "$rc" in
      0)
        if grep -qF '[aosp-ci] py2/py3-safe write_xml' "$f" 2>/dev/null; then
          log "      已修: ${rel}"
        else
          log "      已修（此前已打过补丁）: ${rel}"
        fi
        fixed_wf=$((fixed_wf+1))
        ;;
      3) log "      ${rel}: 本文件内没有 write_xml（定义在别处或已修过）" ;;
      *) warn "      ${rel}: 修write_xml 失败（rc=${rc}）" ;;
    esac
  done
  if [ "$fixed_wf" -eq 0 ]; then
    warn "两个候选文件都没能修 write_xml。如果编译日志里出现"
    warn "  error: a bytes-like object is required, not 'str'"
    warn "说明 AOSP 10 的 write_xml 位置与本脚本假设不同，需要更新 SENTINEL_SEMANTIC_FILES。"
  fi

  # ---------- 抽样自检 ----------
  local sample
  for sample in "${SHEBANG_SAMPLES[@]}"; do
    [ -f "$root/$sample" ] || continue
    log "抽样: ${sample}  shebang = $(head -n1 "$root/$sample")"
  done
  for sample in "${SENTINEL_SEMANTIC_FILES[@]}"; do
    [ -f "$root/$sample" ] || continue
    log "抽样: ${sample}  write_xml = $(grep -c 'aosp-ci' "$root/$sample" 2>/dev/null || echo 0) 处 aosp-ci 标记"
  done

  log "python 解释器适配完成"
}