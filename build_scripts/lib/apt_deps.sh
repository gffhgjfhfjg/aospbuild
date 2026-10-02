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
  libiostream-dev
  libsdl1.2-dev
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
# repo launcher 安装
# -----------------------------------------------------------------------------
#  必须装官方最新 launcher，不能用 apt 的 repo 包：
#    Ubuntu 22.04 的 repo 包是 2.17（2020 年），缺 --git-lfs 等新选项，
#    会直接 "repo: error: no such option: --git-lfs" 让 repo init 失败。
#    Ubuntu 24.04 的更老（实测 2.36 但也没 --git-lfs？见 run 36948461975 的实际情况，
#    无论如何官方 launcher 最稳）。
#  官方安装方式：https://gerrit.googlesource.com/git-repo/+master/README.md
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
# 交叉编译工具链自检：确认 arm64 目标工具链存在于源码树中
# =============================================================================
verify_cross_toolchain() {
  banner "ARM64 交叉编译工具链自检"
  local root="${1:-$AOSP_SRC_DIR}"
  local found=0

  # 1) AOSP 自带 clang（真正给 arm64 目标编译的就是它）
  local clang
  clang="$(ls -d "$root"/prebuilts/clang/host/linux-x86/clang-* 2>/dev/null | head -n1 || true)"
  if [ -n "$clang" ]; then
    log "找到 clang 工具链: $clang"
    if [ -x "$clang/bin/clang" ]; then
      log "clang 版本: $("$clang/bin/clang" --version | head -n1)"
      "$clang/bin/clang" --target=aarch64-linux-android10 --version >/dev/null 2>&1 \
        && log "aarch64-linux-android 目标可用 ✓" \
        || warn "clang 无法以 aarch64-linux-android10 目标运行（一般无害）"
    fi
    found=1
  fi

  # 2) AOSP 自带 aarch64 GNU 工具链（部分 libcutils/sanitizer 目标会用到）
  local gcc
  gcc="$(ls -d "$root"/prebuilts/gcc/linux-x86/aarch64/*/bin 2>/dev/null | head -n1 || true)"
  if [ -n "$gcc" ] && [ -x "$gcc/aarch64-linux-android-gcc" ]; then
    log "找到 aarch64 GNU 工具链: $gcc"
    found=1
  fi

  # 3) soong 自带 ninja / clang 依赖
  local ninja
  ninja="$(ls -d "$root"/prebuilts/build-tools/linux-x86/bin/ninja 2>/dev/null | head -n1 || true)"
  [ -x "$ninja" ] && { log "找到 ninja: $ninja"; found=1; }

  [ "$found" -eq 1 ] || die "未在 ${root} 找到任何 ARM64 交叉编译工具链，请确认 repo sync 完整（prebuilts/clang 是否 sync）"

  log "交叉编译工具链自检通过"
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
