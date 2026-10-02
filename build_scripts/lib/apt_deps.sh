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
APT_PKGS_COMPAT=(
  python3
  python3-dev
  python-is-python3          # 关键：提供 /usr/bin/python -> python3
  libtinfo5                  # 22.04 默认 libtinfo6，lib32ncurses5 依赖 libtinfo5
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
  openjdk-8-jdk              # 部分老 prebuilt 脚本硬要求 JAVA_HOME 指向 8，缺了不致命
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

  # ---- git 全局配置，避免 repo sync 阶段反复询问 ----
  git config --global user.email  "ci@aosp-build.local"
  git config --global user.name   "AOSP CI"
  git config --global advice.detachedHead false
  git config --global pack.threads 0
  # 大仓库（.repo/projects 下几百个 git 仓库）用窗口收缩加快 checkout
  git config --global core.fsmonitor true || true

  # ---- 字符集 / 时区，避免 soong & metalava 输出乱码 ----
  locale_gen_utf8

  log "宿主依赖安装完成"
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
