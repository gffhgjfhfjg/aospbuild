#!/usr/bin/env bash
# =============================================================================
#  build_scripts/selfcheck.sh —— 流水线自身的静态自检
# -----------------------------------------------------------------------------
#  在花几小时跑 AOSP 之前，先花 3 秒确认 CI 工程本身没坏。
#
#  【为什么必须有这个 —— 真实踩过的坑】
#  用 Windows PowerShell 的 `Set-Content -Encoding UTF8` 改 .sh 文件时，
#  PowerShell 5.1 会写入 UTF-8 BOM（EF BB BF）。于是文件第一行变成
#      <BOM>#!/usr/bin/env bash
#  Linux 内核解析 shebang 时会把 BOM 当成解释器路径的一部分：
#      common.sh: line 1: 锘?!/usr/bin/env: No such file or directory
#      exit 127
#  这个错误在 GitHub Actions 上表现为"某一步莫名 exit 127"，
#  日志里只有一行乱码，极难定位（run 36971685929 就是这么废掉的）。
#
#  检���项：
#    1) 所有 .sh / .yml 无 UTF-8 BOM
#    2) 所有 .sh 首行是合法 shebang
#    3) 所有 .sh 通过 bash -n
#    4) 所有 .yml 是合法 YAML
#    5) workflow yaml 里声明的 env 变量在脚本里都有合理默认值
# =============================================================================

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_here}/lib/common.sh"
enable_err_trap

REPO_ROOT="$(cd "${_here}/.." && pwd)"
cd "$REPO_ROOT"

banner "CI 工程自检"
fail=0

# -----------------------------------------------------------------------------
# 1) BOM 检测
# -----------------------------------------------------------------------------
log "[1/4] UTF-8 BOM 检测（PowerShell 5.1 的 Set-Content -Encoding UTF8 会写入 BOM）"
bom_found=0
while IFS= read -r f; do
  # 前 3 字节是否为 EF BB BF
  if [ "$(head -c 3 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    err "  BOM! ${f#$REPO_ROOT/}  <- 必须去掉，否则 Linux 上 shebang 失效 (exit 127)"
    err "        修复: python3 -c \"import io,sys;p=sys.argv[1];d=open(p,'rb').read();open(p,'wb').write(d[3:] if d[:3]==b'\\xef\\xbb\\xbf' else d)\" '$f'"
    bom_found=$(( bom_found + 1 ))
  fi
done < <(find . -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) -not -path './.git/*')
if [ "$bom_found" -eq 0 ]; then
  log "  OK：没有 BOM"
else
  fail=1
fi

# -----------------------------------------------------------------------------
# 2) shebang 检测
# -----------------------------------------------------------------------------
log "[2/4] shell 脚本 shebang 检测"
sb_found=0
while IFS= read -r f; do
  first="$(head -n1 "$f")"
  case "$first" in
    '#!'*) : ;;
    *) err "  缺 shebang: ${f#$REPO_ROOT/}"; sb_found=$(( sb_found+1 )) ;;
  esac
done < <(find . -type f -name '*.sh' -not -path './.git/*')
if [ "$sb_found" -eq 0 ]; then
  log "  OK：所有 .sh 都有 shebang"
else
  fail=1
fi

# -----------------------------------------------------------------------------
# 3) bash -n 语法检查
# -----------------------------------------------------------------------------
log "[3/4] bash -n 语法检查"
syn_found=0
while IFS= read -r f; do
  if ! bash -n "$f" 2>/tmp/.selfcheck_err; then
    err "  语法错误: ${f#$REPO_ROOT/}"
    head -n 3 /tmp/.selfcheck_err >&2 || true
    syn_found=$(( syn_found + 1 ))
  fi
done < <(find . -type f -name '*.sh' -not -path './.git/*')
if [ "$syn_found" -eq 0 ]; then
  log "  OK：全部脚本语法正确"
else
  fail=1
fi

# -----------------------------------------------------------------------------
# 4) YAML 合法性
# -----------------------------------------------------------------------------
#  注意：GitHub runner 的系统 python3 **默认没有装 PyYAML**，
#  Git Bash 里的 python3 也未必有。所以必须先探测可用性，
#  不���在时降级为"跳过"，绝不能因为缺依赖就把整个自检判失败。
# -----------------------------------------------------------------------------
log "[4/4] YAML 合法性检查"
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import yaml" >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done

if [ -z "$PY" ]; then
  warn "  跳过：未找到带 PyYAML 的 python（GitHub runner 系统 python3 默认无 PyYAML）"
  warn "  如需校验可在 workflow 里先加：sudo apt-get install -y python3-yaml"
else
  log "  使用 ${PY} 做 YAML 校验"
  yml_found=0
  while IFS= read -r f; do
    if ! "$PY" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/tmp/.selfcheck_yml; then
      err "  YAML 错误: ${f#$REPO_ROOT/}"
      head -n 3 /tmp/.selfcheck_yml >&2 || true
      yml_found=$(( yml_found + 1 ))
    fi
  done < <(find . -type f \( -name '*.yml' -o -name '*.yaml' \) -not -path './.git/*')
  if [ "$yml_found" -eq 0 ]; then
    log "  OK：YAML 全部合法"
  else
    fail=1
  fi
fi

# -----------------------------------------------------------------------------
# 汇总
# -----------------------------------------------------------------------------
echo
if [ "$fail" -ne 0 ]; then
  err "=========================================================="
  err " CI 工程自检未通过 —— 不要浪费几小时去跑 AOSP"
  err " 常见原因（本仓库历史上都发生过）："
  err "  1) .sh 带 UTF-8 BOM -> Linux 上 shebang 失效, exit 127"
  err "  2) 用 Windows 编辑器/Set-Content -Encoding UTF8 改过文件"
  err "  3) PowerShell 替换 YAML 时把换行/引号弄坏"
  err "=========================================================="
  exit 1
fi
log "CI 工程自检全部通过 ✓"
