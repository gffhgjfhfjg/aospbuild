#!/usr/bin/env bash
# =============================================================================
#  lib/apt_deps.sh —— 宿主依赖 + ARM64 交叉编译工具链安装
# -----------------------------------------------------------------------------
#  作用范围：GitHub 托管 ubuntu-latest (ubuntu-22.04 x86_64)
#  关键点：
#    * AOSP 官方 host 要求清单（Android 10 版本），32 位多架构库必须装（host 工具是 32bit）
#    * AOSP 自带 prebuilts/clang/host/linux-x86/aarch64/aarch64-linux-android-4.9
#      本身就是 arm64 目标交叉编译器，TARGET_ARCH=arm64 时由 soong 自动选用，
#      因此这里不需要额外从 apt 装 aarch64-linux-gnu-gcc（装了也没用，soong 不用）
#    * python-is-python3：AOSP10 大量脚本 shebang 是 `#!/usr/bin/env python`
#      Ubuntu 22.04 已移除 python2 别名，不处理会直接 "No such file or directory"
#    * python2：这条是硬性要求，不是可选兼容。
#      AOSP 10 (Q) 官方宿主是 Ubuntu 18.04，**同时**带 python2.7 与 python3；
#      到 Ubuntu 22.04 只剩 python3，于是「语法上能过 py3 编译、运行时却是 py2 语义」
#      和「压根是 py2 语法」的两类脚本会一起暴毙（run 37093496242 实测 935 个目标失败）：
#        build/make/tools/merge-event-log-tags.py   except X, e      -> SyntaxError
#        build/tools/java-event-log-tags.py        except X, e      -> SyntaxError
#        bionic/libc/fs_config_generator.py         print x          -> SyntaxError
#        build/make/tools/check_radio_versions.py   print x          -> SyntaxError
#        build/make/tools/normalize_path.py         print x          -> SyntaxError
#        external/clang/clang-version-inc.py       print x          -> SyntaxError
#        bionic 的 genfunctosyscallnrs 直接 AssertionError: Could not find python binary: python2.7
#      22.04 的 jammy/universe 里 python2.7 (2.7.18-13ubuntu1.5) 仍在源里，
#      apt 装得上（universe 在 GitHub runner 上默认已启用）。
# =============================================================================

# ---------- 分组包清单 ----------
# 1) AOSP 官方 Android 10 host 依赖（含 32 位多架构库，缺一不可）
APT_PKGS_CORE=(
  bc
  bison
  build-essential
  ccache
  curl
  flex
  g++
  gcc-multilib
  g++-multilib
  git
  git-lfs
  gn
  zip
  zlib1g-dev
  zlib1g-dev:i386
  libc6-dev-i386
  lib32z1
  lib32readline-dev
  lib32ncurses5
  lib32ncurses5-dev
  libncurses5-dev
  libxml2
  libxml2-utils
  libssl-dev
  libssl-dev:i386
  libelf-dev
  libgcrypt11-dev
  libgmp3-dev
  liblz4-tool
  libcurl4-openssl-dev
  libsdl1.2-dev
  # --- AOSP 10 prebuilt 依赖的 ncurses5 ABI ---
  # AOSP 自带的 clang-3289846 / 部分 host 工具是链接 libncurses.so.5 /
  # libtinfo.so.5 编译的，而 Ubuntu 22.04 默认只提供 .so.6。
  # 缺了会报 "error while loading shared libraries: libncurses.so.5"，
  # 整个 ARM64 交叉编译直接不可用。22.04 的 apt 源里这两个包还在。
  libncurses5
  libtinfo5
  lzop
  pngcrush
  rsync
  schedtool
  squashfs-tools
  xsltproc
  zstd
  openjdk-11-jdk
  openjdk-11-jdk-headless
  repo
)

# 2) Ubuntu 22.04 兼容补充（AOSP10 官方清单基于 18.04/20.04，22.04 需额外补）
#    注意：libiostream-dev 在 22.04 已不存在（apt 源里查不到），
#          install_group 逐个安装并在失败时告警，不会中断，但列在这里只是噪音，故移除。
APT_PKGS_COMPAT=(
  python3
  python3-dev
  python3-distutils        # 22.04 的 python3.10 里 distutils 仍可用但已弃用，显式装上更稳
  python-is-python3        # 关键：提供 /usr/bin/python -> python3
  python2                  # 关键：提供 /usr/bin/python2.7。AOSP 10 的 py2-only 构建脚本靠它
  python2-dev              # 少数 py2 脚本要 distutils 头文件
  libtinfo5                # lib32ncurses5 依赖 libtinfo5
  m4
  gperf
  automake
  autoconf
  libtool
  pkg-config
  texinfo
  texlive-latex-recommended
  texlive-fonts-recommended
  gettext
  cpio
  kmod
  e2fsprogs
  dosfstools
  mtools
  x11proto-core-dev
  imagemagick
)

# 3) 可选：GPU/图形/远程调试相关，AOSP 参考镜像不依赖，默认不装
APT_PKGS_OPTIONAL=(
  libgl1-mesa-dev
  libx11-dev
  mesa-common-dev
)

# =============================================================================
# 安装主函数
# =============================================================================
install_apt_deps() {
  local mode="${1:-all}"   # all | core | compat | optional
  banner "安装宿主依赖 + ARM64 交叉编译工具链 (mode=${mode})"

  log "系统信息: $(. /etc/os-release && echo "${PRETTY_NAME}")  内核: $(uname -r)"

  # 非 root 环境下用 sudo；root 直接执行
  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "当前非 root 且没有 sudo，GitHub runner 上不应出现"
    SUDO="sudo"
  fi

  log "apt-get update ..."
  retry 3 $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y

  install_group() {
    local name="$1"; shift
    local pkgs=("$@")
    [ "${#pkgs[@]}" -eq 0 ] && { log "包组 ${name} 为空，跳过"; return 0; }
    log "安装包组 ${name}（${#pkgs[@]} 个）..."
    # 逐个安装：个别包在新版 Ubuntu 改名/移除时，不应导致整组失败
    local p missing=0
    for p in "${pkgs[@]}"; do
      if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p"; then
        warn "包 ${p} 安装失败（该发行版可能已改名/移除），继续"
        missing=$((missing + 1))
      fi
    done
    [ "$missing" -gt 0 ] && warn "包组 ${name} 有 ${missing} 个包未安装成功，请对照 AOSP 官方清单确认" || true
  }

  case "$mode" in
    core)     install_group "core"     "${APT_PKGS_CORE[@]}" ;;
    compat)   install_group "compat"   "${APT_PKGS_COMPAT[@]}" ;;
    optional) install_group "optional" "${APT_PKGS_OPTIONAL[@]}" ;;
    all)
      install_group "core"     "${APT_PKGS_CORE[@]}"
      install_group "compat"   "${APT_PKGS_COMPAT[@]}"
      install_group "optional" "${APT_PKGS_OPTIONAL[@]}" ;;
    *) die "未知模式: ${mode}" ;;
  esac

  # ---- python2 -> python3 兼容（Ubuntu 22.04 必做）----
  ensure_python3_alias

  # ---- python2.7 存在性确认（AOSP 10 py2-only 脚本的硬性依赖）----
  ensure_python2

  # ---- JDK 11（AOSP 10 硬要求）----
  #    Ubuntu 24.04 的默认 JDK 是 17，22.04 是 11；这里不依赖默认值，
  #    显式把 JAVA_HOME 指向 JDK 11，并在 AOSP 源码就位后用 prebuilts/jdk 兜底。
  setup_java11

  # ---- git 全局配置，避免 repo sync 阶段反复询问 ----
  git config --global user.email  "ci@aosp-build.local"
  git config --global user.name   "AOSP CI"
  git config --global advice.detachedHead false
  git config --global pack.threads 0
  # 大仓库（.repo/projects 下几百个 git 仓库）用窗口收缩加快 checkout
  git config --global core.fsmonitor true || true

  # ---- 字符集 / 时区，避免 soong & metalava 输出乱码 ----
  locale_gen_utf8

  # ---- AOSP 10 prebuilt 依赖的 ncurses5 ABI（缺了 clang 根本起不来）----
  ensure_ncurses5_abi

  # ---- repo launcher（apt 的 repo 包太老，必须用官方版）----
  install_repo_launcher

  log "宿主依赖安装完成"

  # ---- 依赖装完后清 apt 缓存（reclaim 阶段故意留着 lists 给这里用）----
  local SUDO2=""
  [ "$(id -u)" -ne 0 ] && SUDO2="sudo"
  $SUDO2 apt-get clean >/dev/null 2>&1 || true
  $SUDO2 rm -rf /var/lib/apt/lists/* 2>/dev/null || true
  log "已清理 apt lists 与包缓存"
  df -hT / | tail -1
}

# python3 别名兜底：apt 装不上 python-is-python3 时手工建软链
ensure_python3_alias() {
  if command -v python >/dev/null 2>&1; then
    log "python -> $(readlink -f "$(command -v python)") （已可用）"
    return 0
  fi
  warn "系统无 python 命令，手工建立 /usr/local/bin/python -> python3 软链"
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO ln -sf "$(command -v python3)" /usr/local/bin/python
  log "已创建 /usr/local/bin/python -> $(command -v python3)"
}

# ---------------------------------------------------------------------------
# python2.7 解析：返回可用的 py2 解释器，解析不出来则die
# ---------------------------------------------------------------------------
#  AOSP 10 的构建脚本是「py2 + py3 混编」：
#    * 一部分是 py2-only语法（print 语句 / except X, e），py3 直接 SyntaxError
#    * 一部分是 py2 语义但语法合法（manifest_fixer 的 write_xml），py3 编译过、运行时炸
#  前者靠 fix_python_shebang.sh 路由到 python2.7，后者靠就地打补丁。
#  另外 bionic 的 genfunctosyscallnrs 会自己去 PATH 里找 python2.7，
#  所以 python2.7 必须在 PATH 里，而不是藏在某个目录中。
resolve_python2() {
  local c
  for c in "${AOSP_PY2_BIN:-}" python2.7 python2 /usr/bin/python2.7; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}

ensure_python2() {
  local py2
  if py2="$(resolve_python2)"; then
    log "python2.7 = ${py2} ($("$py2" -V 2>&1))"
    # bionic 的 genfunctosyscallnrs 会直接按名字 exec python2.7，必须能按名解析
    case ":$PATH:" in
      *":$(dirname -- "$py2"):"*) : ;;
      *) warn "python2.7 不在 PATH 里（当前 ${py2}）；若 genfunctosyscallnrs 报 Could not find python binary: python2.7 请检查 PATH" ;;
    esac
  else
    err "找不到 python2.7 —— AOSP 10 有 py2-only 构建脚本，缺它必然编译失败"
    err "  22.04 应可直接 apt 装：sudo apt-get install -y python2"
    err "  若 apt 源里没有 python2，请检查 universe 是否启用（jammy/universe 有 2.7.18-13ubuntu1.5）"
    exit 1
  fi
}

# C.UTF-8 locale（部分 prebuilt 需要）
locale_gen_utf8() {
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  if ! locale -a 2>/dev/null | grep -qix 'C.utf8'; then
    $SUDO locale-gen C.UTF-8 2>/dev/null || warn "locale-gen C.UTF-8 失败（一般不影响构建）"
  fi
  export LANG="${LANG:-C.UTF-8}"
}

# =============================================================================
# JDK 11 定位与 JAVA_HOME 设置
# -----------------------------------------------------------------------------
#  AOSP 10 要求 JDK 11。优先级：
#    1) AOSP 自带 prebuilts/jdk/jdk11（最权威，envsetup.sh 自己也会用它）
#    2) 系统的 /usr/lib/jvm/java-11-openjdk-*
#    3) 找不到 -> 告警（不同 AOSP 版本 fallback 行为不同，不硬失败）
# =============================================================================
setup_java11() {
  local root="${1:-$AOSP_SRC_DIR}"

  # 1) AOSP 自带 JDK
  if [ -x "$root/prebuilts/jdk/jdk11/bin/javac" ]; then
    export JAVA_HOME="$root/prebuilts/jdk/jdk11"
    export PATH="$JAVA_HOME/bin:$PATH"
    log "JAVA_HOME = ${JAVA_HOME} (AOSP 自带 jdk11)"
    return 0
  fi

  # 2) 系统 JDK 11
  local cand
  for cand in /usr/lib/jvm/java-11-openjdk-amd64 /usr/lib/jvm/java-11-openjdk-arm64; do
    if [ -x "$cand/bin/javac" ]; then
      export JAVA_HOME="$cand"
      export PATH="$JAVA_HOME/bin:$PATH"
      log "JAVA_HOME = ${JAVA_HOME} (系统 JDK 11)"
      return 0
    fi
  done

  # 3) 兜底：看看当前 java 是多少版本
  if command -v java >/dev/null 2>&1; then
    local ver
    ver="$(java -version 2>&1 | head -n1)"
    warn "未找到 JDK 11，当前 java: ${ver}"
    warn "AOSP 10 官方要求 JDK 11。若编译期出现 javac/UnsupportedClassVersionError，"
    warn "请在 workflow env 里显式设置 JAVA_HOME，或用 self-hosted runner 预装 JDK 11。"
  else
    warn "未找到任何 java，AOSP 10 编译将失败（需要 JDK 11）"
  fi
  return 0
}

# =============================================================================
# ncurses5 ABI 兜底
# -----------------------------------------------------------------------------
# AOSP 10 自带的 prebuilts（尤其 clang-3289846）是链接 libncurses.so.5 /
# libtinfo.so.5 的老 ABI，Ubuntu 22.04 默认只有 .so.6。
# 缺了会在编译真正开始时才炸，必须在这里就保证存在。
#
# 已在 ubuntu-22.04 (image 20260927.309) 实测：
#   apt-cache policy libncurses5 -> Candidate: 6.3-2ubuntu0.3，apt install 成功，
#   安装后 /usr/lib/x86_64-linux-gnu/libncurses.so.5 -> libncurses.so.5.9 存在。
#   （focal 的 libncurses5_6.2-0ubuntu2_amd64.deb 直链已 404，不要依赖）
#
# 三级兜底：apt 安装 -> 软链 .so.6 -> 明确报错
# =============================================================================
ensure_ncurses5_abi() {
  local libdir="/usr/lib/x86_64-linux-gnu"
  local need_ok=0

  # 1) 直接用 apt 装（首选，ABI 正确）
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  log "确保 ncurses5 ABI 可用 (libncurses.so.5 / libtinfo.so.5) ..."
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       libncurses5 libtinfo5 >/dev/null 2>&1 || true
  $SUDO ldconfig 2>/dev/null || true

  if [ -e "$libdir/libncurses.so.5" ]; then
    log "  libncurses.so.5 就绪 (apt)"
    need_ok=1
  fi

  # 2) 兜底：软链 .so.6 -> .so.5（ABI 不完全兼容，clang 只用基础 terminfo 调用时可行）
  if [ "$need_ok" -eq 0 ]; then
    warn "  apt 未提供 libncurses.so.5，尝试软链 .so.6 作为兜底"
    local pair
    for pair in "libncursesw.so.6:libncurses.so.5" \
                "libncurses.so.6:libncurses.so.5" \
                "libtinfo.so.6:libtinfo.so.5"; do
      local src="${pair%%:*}" dst="${pair##*:}"
      if [ ! -e "$libdir/$dst" ] && [ -e "$libdir/$src" ]; then
        $SUDO ln -sf "$libdir/$src" "$libdir/$dst" && log "  软链 $dst -> $src"
      fi
    done
    $SUDO ldconfig 2>/dev/null || true
    [ -e "$libdir/libncurses.so.5" ] && need_ok=1
  fi

  if [ "$need_ok" -eq 1 ]; then
    log "ncurses5 ABI 准备完成"
    return 0
  fi

  err "无法提供 libncurses.so.5 —— AOSP 10 自带的 clang 将无法启动："
  err "  error while loading shared libraries: libncurses.so.5"
  err "当前系统: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  err "请改用 ubuntu-22.04（22.04 的 apt 源里有 libncurses5），"
  err "或把仓库变量 AOSP_RUNNER_OS 指向一个自带 libncurses5 的镜像。"
  return 1
}

# =============================================================================
# repo launcher 安装
# -----------------------------------------------------------------------------
#  必须装官方最新 launcher，不能用 apt 的 repo 包：
#    Ubuntu 22.04 的 repo 包是 2.17（2020 年），缺 --git-lfs 等新选项，
#    会直接 "repo: error: no such option: --git-lfs" 让 repo init 失败。
# =============================================================================
install_repo_launcher() {
  local bindir="${1:-$HOME/bin}"
  local url="https://storage.googleapis.com/git-repo-downloads/repo"

  mkdir -p "$bindir" 2>/dev/null || true
  [ -w "$bindir" ] || { warn "无法写入 ${bindir}，跳过 repo launcher 安装"; return 0; }

  log "安装官方 repo launcher → ${bindir}/repo"
  if ! curl -fsSL --retry 3 -o "${bindir}/repo.new" "$url"; then
    warn "下载 repo launcher 失败（网络问题），回退到系统 repo"
    rm -f "${bindir}/repo.new"
    return 0
  fi
  chmod +x "${bindir}/repo.new"
  mv -f "${bindir}/repo.new" "${bindir}/repo"

  # 放到 PATH 最前面
  case ":$PATH:" in
    *":$bindir:"*) : ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  local ver
  ver="$("$bindir/repo" --version 2>&1 | head -n3 | tr '\n' ' ' || true)"
  log "repo launcher 版本: ${ver}"
  log "repo 路径: $(command -v repo)"
}

# =============================================================================
# 交叉编译工具链自检
# -----------------------------------------------------------------------------
#  这里是「早失败」的关键位置。
#  历史教训：clang 缺 libncurses.so.5 起不来时，这里只 WARN「一般无害」，
#  结果白等 1 小时进入 ninja 才炸。现在任何 prebuilt 跑不起来都直接 die。
# =============================================================================
verify_cross_toolchain() {
  local root="${1:-$AOSP_SRC_DIR}"
  local fatal=0
  banner "ARM64 交叉编译工具链自检"

  # ---------- 1) AOSP 自带 clang（真正给 arm64 目标编译的就是它）----------
  local clang
  clang="$(ls -d "$root"/prebuilts/clang/host/linux-x86/clang-* 2>/dev/null | head -n1 || true)"
  if [ -z "$clang" ]; then
    err "未找到 AOSP 自带 clang：${root}/prebuilts/clang/host/linux-x86/clang-*"
    err "请确认 repo sync 完整（prebuilts/clang 是否同步下来）"
    exit 1
  fi
  log "clang 工具链: $clang"

  if [ ! -x "$clang/bin/clang" ]; then
    err "clang 不可执行: ${clang}/bin/clang"
    exit 1
  fi

  # --version 失败通常意味着缺共享库（AOSP 10 最常见的是 libncurses.so.5）
  local cver
  if ! cver="$("$clang/bin/clang" --version 2>&1)"; then
    err "clang 无法启动："
    printf '%s\n' "$cver" | head -n 5 >&2
    local miss
    miss="$(printf '%s\n' "$cver" | grep -oE 'lib[a-zA-Z0-9_.+-]*\.so[0-9.]*' | head -n1 || true)"
    [ -n "$miss" ] && err "缺失的共享库: ${miss}"
    err "修复方向：安装对应的老 ABI 包（22.04 上 libncurses5 / libtinfo5 可直接 apt 装）"
    fatal=1
  else
    log "clang 版本: $(printf '%s\n' "$cver" | head -n1)"
  fi

  # aarch64 目标必须能真正编译出目标文件
  if [ "$fatal" -eq 0 ]; then
    if "$clang/bin/clang" --target=aarch64-linux-android10 -x c -c /dev/null -o /dev/null 2>/dev/null; then
      log "aarch64-linux-android10 目标编译可用 ✓"
    else
      err "clang 无法以 aarch64-linux-android10 目标编译 —— ARM64 交叉编译不可用"
      fatal=1
    fi
  fi

  # ---------- 2) soong 自带 ninja ----------
  local ninja
  ninja="$(ls -d "$root"/prebuilts/build-tools/linux-x86/bin/ninja 2>/dev/null | head -n1 || true)"
  if [ -x "$ninja" ]; then
    log "ninja: $ninja ($("$ninja" --version 2>&1 | head -n1))"
    # @file 响应文件支持检测（stage1 依赖它来排除 metalava）
    if "$ninja" --help 2>&1 | grep -q '@file'; then
      log "ninja 支持 @file 响应文件 ✓"
    else
      warn "ninja 不支持 @file，stage1 将回退到 AOSP_NINJA_TARGETS_MODE=xargs"
    fi
  else
    err "未找到 ninja: ${root}/prebuilts/build-tools/linux-x86/bin/ninja"
    fatal=1
  fi

  # ---------- 3) aarch64 GNU 工具链（部分目标会用到）----------
  local gcc
  gcc="$(ls -d "$root"/prebuilts/gcc/linux-x86/aarch64/*/bin 2>/dev/null | head -n1 || true)"
  if [ -n "$gcc" ] && [ -x "$gcc/aarch64-linux-android-gcc" ]; then
    log "aarch64 GNU 工具链: $gcc"
  else
    logv "未找到 aarch64 GNU 工具链（AOSP 10 以 clang 为主，非必需）"
  fi

  # ---------- 4) JDK 11（AOSP 10 硬要求）----------
  if [ -x "$root/prebuilts/jdk/jdk11/bin/javac" ]; then
    log "AOSP 自带 JDK: $("$root/prebuilts/jdk/jdk11/bin/javac" -version 2>&1 | head -n1)"
  else
    warn "未找到 prebuilts/jdk/jdk11，改用系统 JDK"
    local jv
    jv="$(java -version 2>&1 | head -n1 || true)"
    log "系统 JDK: ${jv:-<无 java>}"
    case "$jv" in
      *\"11.*) : ;;
      *) warn "系统 JDK 不是 11，AOSP 10 可能出现 UnsupportedClassVersionError" ;;
    esac
  fi

  if [ "$fatal" -ne 0 ]; then
    echo
    err "=========================================================="
    err " 交叉编译工具链自检未通过 —— 继续编译只会浪费时间"
    err " 常见根因："
    err "   1) 缺 libncurses.so.5（Ubuntu 22.04 需 apt install libncurses5 libtinfo5）"
    err "   2) runner 镜像太新（24.04/26 的 glibc 与 AOSP 10 prebuilt 不兼容）"
    err "      -> 把仓库变量 AOSP_RUNNER_OS 固定为 ubuntu-22.04"
    err "   3) repo sync 不完整，prebuilts/clang 没拉下来"
    err "=========================================================="
    exit 1
  fi

  log "交叉编译工具链自检通过 ✓"
}

# =============================================================================
# AOSP prebuilt 宿主工具冒烟测试
# -----------------------------------------------------------------------------
# 这些工具在打包阶段（Job4）会被直接 exec 起来：
#   mksquashfs / mke2fs / simg2img / avbtool / aapt2 / zipalign / metalava ...
# 如果它们缺共享库，要到 Job4 才炸（那时已经编了 8 小时）。
# 这里提前把能跑的都跑一遍，缺什么立刻暴露。
# =============================================================================
smoke_test_prebuilt_tools() {
  local root="${1:-$AOSP_SRC_DIR}"
  local bindir="${2:-$root/out/host/linux-x86/bin}"
  banner "AOSP prebuilt 宿主工具冒烟测试"

  if [ ! -d "$bindir" ]; then
    warn "未找到 ${bindir}（编译前应为空），跳过冒烟测试"
    return 0
  fi

  # (工具名:传什么参数能让它快速退出)
  local probes=(
    "metalava:version"
    "mksquashfs:-version"
    "mke2fs:-V"
    "simg2img:-h"
    "avbtool:version"
    "aapt2:version"
    "zipalign:-h"
    "dexdump:-h"
    "ninja:--version"
    "soong_build:version"
  )
  local e name arg bad=0 ok=0 skipped=0 msg bin
  for e in "${probes[@]}"; do
    name="${e%%:*}"
    arg="${e##*:}"
    bin="${bindir}/${name}"
    if [ ! -x "$bin" ]; then
      logv "  [SKIP] ${name}（本次未构建）"
      skipped=$((skipped+1))
      continue
    fi
    # 工具的 --help/--version 一般返回非 0；只要不是"缺动态库/loader 错误"就算过
    msg="$( { "$bin" "$arg" 2>&1 || true; } | head -n 3 )"
    if printf '%s' "$msg" | grep -qiE 'error while loading shared object|cannot open shared object|not a dynamic executable'; then
      err "  [FAIL] ${name}: 缺动态库或 loader 错误"
      printf '         %s\n' "$msg" >&2
      bad=$((bad+1))
    else
      log "  [ OK ] ${name}"
      ok=$((ok+1))
    fi
  done

  log "冒烟测试: ok=${ok} fail=${bad} skipped=${skipped}"
  if [ "$bad" -gt 0 ]; then
    err "有 ${bad} 个 AOSP 宿主工具无法启动，Job4 打包阶段必然失败。"
    err "用 ldd 查具体缺哪个库，例如：ldd ${bindir}/metalava | grep 'not found'"
    exit 1
  fi
  log "宿主工具冒烟测试通过 ✓"
}

# 显式导出交叉编译环境变量（给宿主侧工具/自研脚本使用；soong 内部不依赖这些）
export_cross_env() {
  local root="${1:-$AOSP_SRC_DIR}"
  local clang
  clang="$(ls -d "$root"/prebuilts/clang/host/linux-x86/clang-* 2>/dev/null | head -n1 || true)"
  if [ -n "$clang" ]; then
    export CROSS_COMPILE=aarch64-linux-android-
    export CC_aarch64="$clang/bin/clang"
    export CXX_aarch64="$clang/bin/clang++"
    export LD_aarch64="$clang/bin/ld.lld"
    export AR_aarch64="$clang/bin/llvm-ar"
    export TARGET_ARCH=arm64
    export TARGET_BOARD_PLATFORM=aosp_arm64
    export TARGET_PRODUCT=aosp_arm64
    export TARGET_BUILD_VARIANT=eng
    log "已导出交叉编译环境变量: CROSS_COMPILE=${CROSS_COMPILE}  TARGET_ARCH=${TARGET_ARCH}"
  fi
}
