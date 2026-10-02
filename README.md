# AOSP 10 ARM64 云端构建 CI

GitHub Actions 分段流水线：**x86_64 runner 交叉编译 ARM64 固件**，目标产物 `aosp_arm64-eng` 镜像。

基线来源：[看雪论坛 bbs.kanxue.com/thread-292331.htm](https://bbs.kanxue.com/thread-292331.htm)

后续将逐步集成：Dobby → SandHook/Xposed → ART 方法打桩 → 增强 SysTrace → `setup_stealth` 环境伪装 → `dex_dumper` 内存 DEX 转储 → GhostHWBP 硬件断点 ko。
**当前仓库只做基础 AOSP10 ARM64 CI 流水线的稳定化，暂不集成任何 hook 模块。**

---

## 声明

> 本项目仅用于 **Android 安全研究与逆向教学**。
> 严禁用于未授权应用逆向、破解、篡改等违法场景。
> 使用者需自行确保行为符合所在司法辖区的法律法规，并获得目标应用作者的明确授权。

---

## 一、目录结构

本仓库是**独立的小 CI 仓库**，只存放 workflow / 编译脚本 / 补丁，**不包含 AOSP 源码**。
AOSP 源码由云端 runner 内部 `repo sync` 拉取，不进 git 版本管理。

```
aosp-ci/                                  # CI 仓库根目录（就是 GitHub 上的仓库）
│
├── .github/
│   └── workflows/
│       └── aosp_build.yml                # ★ 唯一的工作流定义：4 个串行 job
│
├── build_scripts/
│   ├── prepare_runner.sh                 # runner 环境准备总入口（磁盘回收/依赖/swap）
│   ├── sync_source.sh                    # Job1 主体：repo sync + 预处理
│   ├── stage1_build.sh                   # ★ Job2 主体：-j1 编译（排除 metalava）
│   ├── stage2_metalava.sh                # ★ Job3 主体：metalava 串行专项
│   ├── stage3_package.sh                 # ★ Job4 主体：镜像打包与产物导出
│   ├── apply_patches.sh                  # 补丁便捷入口（list / dry-run / apply / howto）
│   └── lib/
│       ├── common.sh                     # 严格模式、日志、ERR 陷阱、重试、lunch、磁盘守卫
│       ├── apt_deps.sh                   # 宿主依赖 + ARM64 交叉工具链 + 官方 repo launcher + JDK11
│       ├── swap.sh                       # 16G swap（zram 优先，不占磁盘）
│       ├── reclaim_disk.sh               # 回收 runner 预装的 Android SDK 等 ~22GB
│       ├── fix_python_shebang.sh         # Ubuntu 22.04 python shebang 修复
│       ├── prune_device_trees.sh         # 删除 crosshatch / bonito 设备树
│       ├── apply_patches.sh              # 批量 apply 补丁（被 sync_source.sh source）
│       ├── ninja_targets.sh              # ninja 目标枚举 + 排除 metalava 的目标规划
│       ├── artifacts.sh                  # out 目录分片 tar.zst 打包 / 解包 / 裁剪
│       └── print_patch_howto.sh          # 打印补丁编写指南（独立入口）
│
├── patches/                              # AOSP 源码补丁（只有真 .patch 文件）
│   └── README.md                         # 补丁编写与导出规范（含模板内容）
│
├── .github/workflows/
│   ├── aosp_build.yml                    # ★ 唯一的工作流定义：4 个串行 job
│   ├── _os-probe.yml                     # 手动触发：runner 规格 / 磁盘占用探测
│   └── _runner-avail.yml                 # 手动触发：哪些 runner label 真的可用
│
├── .gitignore                            # 忽略本地调试产物
└── README.md                             # 本文件
```

云端 runner 运行时会**自动生成**（已加入 `.gitignore`，不要提交）：

```
.ci_artifacts/out/part-00000 ...          # out 目录的分片压缩包
.ci_artifacts/api-contracts.zip           # metalava 阶段产出的 API 契约快照
ci_logs/*.log                              # 各阶段完整日志（失败时作为 artifact 上传）
dist_images/*.img                          # 最终 ARM64 镜像
```

---

## 二、4 段串行 Job 设计

| Job | 名称 | 职责 | timeout |
|-----|------|------|---------|
| 1 | `sync_source` | 装宿主依赖 + ARM64 交叉工具链；`repo sync --retry-fetches=3`；python shebang 修复；删除 crosshatch/bonito 设备树；批量 apply 补丁；缓存 `.repo` | 300 min |
| 2 | `build_stage1` | 16G swap；`lunch aosp_arm64-eng`；`m nothing` 生成构建图；**-j1 串行编译「排除 metalava 之外全部 ninja 目标」**；分片打包 `out` 上传 | 300 min |
| 3 | `build_stage2` | 下载 stage1 的 `out`；**串行单独执行全部 metalava 任务**（`metalava` / `metalava-full` / `metalava-sdk` / `update-api`）；重新打包上传 | 300 min |
| 4 | `build_stage3` | 下载 metalava 阶段 `out`；`m installclean` + **镜像打包**；导出 `system.img` / `vendor.img` / `odm.img` 等；上传最终镜像 | 300 min |

依赖关系：`sync_source → build_stage1 → build_stage2 → build_stage3`（严格串行，`needs:` 声明）。

### 关键实现说明

**排除 metalava 的做法**（`build_scripts/lib/ninja_targets.sh`）
`ninja` 本身不支持「排除某目标」，所以脚本先 `m nothing` 生成 `out/soong/build.ninja`，
再用 `ninja -t targets all` 导出全量目标清单，用正则筛出 metalava 相关目标写入
`.ninja_targets_exclude.txt`，剩余写入 `.ninja_targets_keep.txt`，
最后用 `ninja @out/.stage1_targets.rsp` 精确构建保留目标（响应文件方式，避免命令行长度溢出）。
清单落在 `out/.ninja_targets_*.txt`，失败时可直接复盘。

排除正则除了 `metalava` / `update-api` / `check-api` / `api-versions` 这些显式目标，
**还必须排除 metalava 的输出文件本身**（`*/api/current.txt`、`*/api/system-current.txt`、
`*/api/test-current.txt`、`*/api/removed.txt`、`api-versions.xml`、`api-current.txt`）。
否则这些文件会通过 ninja 的依赖边把 `metalava` 重新拉回 Job2，分段就白做了。
`all` 与 `clean` 也会一并从 rsp 里剔除（`all` 是 metalava 的总入口）。
若本机 ninja 不支持 `@file` 响应文件，设 `AOSP_NINJA_TARGETS_MODE=xargs` 走分批回退。

**python shebang 修复**（`build_scripts/lib/fix_python_shebang.sh`）
系统层装 `python-is-python3` 并建 `python -> python3` 软链；源码层把
`#!/usr/bin/env python` / `#!/usr/bin/python` / `#!/usr/bin/env python2[.7]`
统一改写成 `python3`（只改第 1 行，源码零改动，改写用 `cat tmp > f` 保留可执行位）。
默认 `AOSP_SHEBANG_SKIP_EXISTING=1`（本机若已有该解释器就跳过，适合本地开发机）；
CI 上建议设成 `0`，保证结果确定可复现 —— GitHub runner 上本来就没有 `python`/`python2`。

**out 目录不进 cache**（硬性约束）
只对 `.repo` 使用 `actions/cache`。`out` 通过 `actions/upload-artifact` 传递。
`out` 体积大，必须先 `tar | zstd` 再分片（默认 8000MB/片），
因为 `upload-artifact` v4 **不保留可执行位与符号链接** —— 先打成 tar 才能在解包后完整还原。

**slim 裁剪模式**（默认开启）
裁掉 `obj/PACKAGES`、`obj/SOURCES`、install staging 目录、soong 缓存等**可再生中间物**，
不触碰 `out/host/**`（metalava / mkfs / simg2img 都在这里）与 `obj/**` 的镜像输入。
既能把上传体积压下来，又不影响 Job3/Job4 的正确性。
需要原样全量时把 workflow 里的 `out_pack_mode` 输入改成 `full`。

**16G swap**（`build_scripts/lib/swap.sh`）
`fallocate` → `mkswap` → `swapon`，并调 `vm.swappiness=60`。
目的是避免 soong/javac 瞬时吃满 14GB 物理内存被 OOM Killer 杀掉（表现为 ninja exit 137 / `Killed`）。

---

## 三、部署操作步骤

### 1. 创建 CI 仓库

```bash
mkdir aosp-ci && cd aosp-ci
# 把本目录下的 .github / build_scripts / patches / .gitignore / README.md 拷进来
```

### 2. 初始化 git 并推送

```bash
cd aosp-ci
git init -b main
git add -A
git commit -m "ci: aosp10 arm64 分段云端构建流水线"
git remote add origin git@github.com:<你的账号>/aosp-ci.git
git push -u origin main
```

### 3. 添加执行权限（★ 必须，否则 bash 报 Permission denied）

**Linux / macOS / WSL / Git Bash：**

```bash
cd aosp-ci
chmod +x build_scripts/*.sh
chmod +x build_scripts/lib/*.sh

# 或一次性
find build_scripts -type f -name '*.sh' -exec chmod +x {} \;

# 验证
ls -l build_scripts/*.sh build_scripts/lib/*.sh
# 期望看到 -rwxr-xr-x

# 记录进 git，保证其他机器 clone 后权限一致
git update-index --chmod=+x build_scripts/*.sh
git update-index --chmod=+x build_scripts/lib/*.sh
git commit -m "chore: mark build scripts executable"
git push
```

**Windows PowerShell（本仓库所在环境）**，Git 会依据 `core.fileMode` 处理；若 clone 后权限丢失：

```powershell
git config core.fileMode false
```

> 兜底：workflow 里每条执行脚本的步骤开头都有 `chmod +x build_scripts/*.sh build_scripts/lib/*.sh`，
> 即使仓库权限位丢失，CI 仍能正常运行。

### 4. 在 GitHub 仓库设置 Environment（推荐）

`Settings → Environments → New environment`，命名 `aosp-build`。
可在此配置：
- **Required reviewers**：防止误触发长任务
- **Deployment branch rules**：限制只有 `main` 能跑
- **把 artifact 归类到该 environment**，方便统一审计与计费

### 5. 触发第一次构建

`Actions → AOSP10-arm64-cloud-build → Run workflow`，参数：

| 输入 | 默认值 | 说明 |
|------|--------|------|
| `aosp_tag` | `android-10.0.0_r47` | AOSP release tag |
| `sync_jobs` | `4` | `repo sync` 并发数 |
| `out_pack_mode` | `slim` | `slim` 裁剪中间物 / `full` 原样全量 |

### 6. 本地干跑单个阶段（调试用）

```bash
# 1) 先在自己机器上按脚本拉一份源码
export AOSP_SRC_DIR=/data/aosp        # 换成本机路径
./build_scripts/prepare_runner.sh --all
./build_scripts/sync_source.sh --all

# 2) 编译（务必 -j1）
./build_scripts/stage1_build.sh

# 3) 只看 metalava
./build_scripts/stage2_metalava.sh

# 4) 只打镜像
./build_scripts/stage3_package.sh

# 5) 补丁相关
./build_scripts/apply_patches.sh --list
./build_scripts/apply_patches.sh --dry-run
./build_scripts/apply_patches.sh --howto
```

---

## 四、硬性容量约束（务必先读）

> **以下全部是 `ubuntu-22.04` 托管 runner 的实测数据（2026-10-02，image 20260927.309），
> 不是估算。**

| 项目 | 实测值 |
|------|--------|
| 整机磁盘 | `/dev/root ext4 146G`，已用 59G，**可用 87G**（只有这一个卷） |
| 内存 / CPU | 15GiB RAM（预置 3GiB swap）/ 4 核 |
| `/mnt` | **root 拥有，runner 用户不可写**（不要往这儿放东西） |
| AOSP 10 源码（`repo sync --depth=1 -c --prune`） | **~62GB** |
| 回收预装软件前剩余 | 87 − 62 = **25GB** ❌ |
| `aosp_arm64-eng` 的 out 需要 | **30~50GB** |
| runner 上可回收的预装软件 | **~22GB** |
| 回收后剩余（109 − 62） | **47GB** ✅ |

### 磁盘回收（`build_scripts/lib/reclaim_disk.sh`，`AOSP_RECLAIM_DISK=1` 默认开启）

不做这一步就**必然**装不下。实测可回收：

| 目录 | 大小 | 说明 |
|------|------|------|
| `/usr/local/lib/android` | **11.0G** | 预装 Android SDK + 3 个 NDK；AOSP 从源码编译用的是自己的 `prebuilts/ndk`，完全用不到 |
| `/usr/share/dotnet` | 5.8G | .NET SDK |
| `/usr/share/swift` | 3.5G | Swift 工具链 |
| `/usr/local/lib/node_modules` | 1.2G | 全局 npm 包 |
| `/opt/pipx` | 456M | pipx |
| `/opt/hostedtoolcache` | 5.2G | **只清历史 node 版本，绝不整个删** —— actions 的 Post 步骤还要从这里取 node/python |

删除 `/usr/local/lib/android` 后会一并 `unset` `ANDROID_HOME` / `ANDROID_SDK_ROOT` /
`ANDROID_NDK_*` 并写入 `$GITHUB_ENV`。
**这一步不能省**：留着悬空的 `ANDROID_NDK_HOME` 比没有这个变量更容易让 soong 崩。

### 16G swap 为什么用 zram 而不是 swap 文件（`build_scripts/lib/swap.sh`）

47GB 要留给 out，16G swap 文件等于吃掉三分之一；而 runner 只有 15GB 内存，本就有 OOM 风险。
zram 是内存里的压缩块设备：逻辑容量同样是 16GB、同样受 `vm.swappiness` 控制，
但匿名页用 lz4/zstd 压缩（典型 2.5~4:1），**实际只吃 4~7GB 物理内存且完全不占磁盘**。
`AOSP_SWAP_MODE`：`auto`（默认，磁盘够就 zram+file 都开）/`zram`/`file`/`both`/`none`。

### 已验证不可行的方案

| 方案 | 实测结果 |
|------|----------|
| `ubuntu-latest` | 已是 **Ubuntu 24.04.5**（gcc 13.3 / Python 3.12 / JDK 17）→ AOSP 10 编不过（见 workflow 顶部说明） |
| `ubuntu-22.04-large` / `2xlarge` / `4xlarge` | **不会被调度**，job 一直 `queued` 且 `runner_name` 为空（本账号未启用 larger runners） |
| 只靠 `--prune-source` 补磁盘缺口 | 缺口 20~30GB，裁剪最多省 5~10GB，不够 |

### 已内置的省空间措施

| 措施 | 位置 | 效果 |
|------|------|------|
| 回收预装 Android SDK / dotnet / swift | `reclaim_disk.sh` | **+22GB** |
| zram 替代 16G swap 文件 | `swap.sh` | **+16GB** |
| `repo sync --depth=1 -c --prune --no-clone-bundle` | `sync_source.sh` | 源码 110GB → 62GB |
| `device/google`（含 crosshatch/bonito）删除 | `prune_device_trees.sh` | 省 3~6GB |
| `cts` 目录删除 + 注释其 soong namespace | `sync_source.sh --prune-source` | 省 2~4GB |
| out slim 裁剪（只影响上传，不影响本地编译） | `artifacts.sh` | 上传体积降 40~70% |
| `repo repack -ad --depth=50` | `sync_source.sh --repack` | `.repo` 体积降 20~40% |
| 编译前容量预估守卫 | `common.sh` `project_build_capacity` | 磁盘不够时**提前失败**并给出可执行建议，而不是让 out 写坏 |

### 容量守卫行为

`AOSP_FREE_SPACE_GUARD=1`（默认）时，Job2 编译前会：

```
  分区可用     : 109GB
  AOSP 源码    : 62GB (含 .repo/.git，不含 out)
  swap 文件    : 0GB (mode=auto, zram 不占盘)
  out 预估     : 42GB
  合计需要     : 104GB
容量充足（余量 5GB）✓
```

余量不足则**直接终止**并按影响从大到小打印建议。确实要冒险继续时设
`AOSP_FREE_SPACE_GUARD=0`（`out` 可能在编译途中因磁盘写满而半残）。

### 4 段串行带来的固定开销

每个 job 都在**独立新机器**上运行，所以 Job2/3/4 也要各自 `repo sync` 一次。
`.repo` 缓存能省掉网络拉取（只省 manifest/refs，不省工作区落盘），
但 4 次 checkout 落盘仍是本设计最大的固定开销。
若后续想消除它，可选方案：

- 把 4 段合并成 2 段（sync+stage1 一体，metalava+package 一体）
- 或迁到**有持久工作区的自托管 runner**（`runs-on` 带 workspace 复用脚本），本仓库的脚本结构无需改动

---

## 五、补丁导出与自动批量 apply

### 5.1 批量 apply 代码片段（脚本已内置）

`build_scripts/lib/apply_patches.sh` 的核心逻辑：

```bash
cd "$AOSP_SRC_DIR"

# 自然排序，保证 0001 -> 0002 -> 0003 的应用顺序
mapfile -t patches < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)

applied=0; already=0; failed=0
for p in "${patches[@]}"; do
  # --forward : 已打过则识别为 reversed/applied 并跳过（幂等）
  # --batch   : 非交互
  # -p1       : 剥离 a/ b/ 前缀
  # -f        : 强制，避免提问
  if patch -p1 --forward --batch --reject-file=- -f -i "$p"; then
    log "  [OK]   $(basename "$p")"
    applied=$((applied+1))
  else
    # 失败时二次判定：是否"此前已应用"
    if patch -p1 --dry-run --forward --batch -f -i "$p" >/dev/null 2>&1; then
      log "  [SKIP] $(basename "$p")（此前已应用）"
      already=$((already+1))
    else
      err "  [FAIL] $(basename "$p")"
      # reject 内容落盘，便于排错
      patch -p1 --forward --batch --reject-file="${CI_LOG_DIR}/reject-$(basename "$p").rej" \
            -f -i "$p" >/dev/null 2>&1 || true
      failed=$((failed+1))
    fi
  fi
done
```

应用时机：`sync_source.sh --apply-patches`，在 Job1/2/3/4 的 sync 之后、编译之前。
因为 AOSP 源码没有 git 历史，**不能用 `git am` / `git apply`**，只能用 `patch -p1`。

### 5.2 补丁导出代码片段

**方式 A：子仓有 git 历史（绝大多数情况）**

```bash
# 在本地完整 AOSP 树里改完代码
cd $HOME/aosp-android10
( cd build/soong && git diff ) \
  | sed -E 's@^(\+\+\+|---) [ab]/@\1 a/@' \
  > /tmp/patches/0001-fix-soong-jobs.patch

( cd system/core && git diff ) \
  | sed -E 's@^(\+\+\+|---) [ab]/@\1 a/@' \
  > /tmp/patches/0002-rootdir-perm.patch
```

**方式 B：没有 git 历史的文件，手工构造 a/ b/ 前缀**

```bash
cp a /tmp/a.orig
vim a
diff -u /tmp/a.orig a \
  | sed -e '1s|.*|--- a/path/to/a|' \
        -e '2s|.*|+++ b/path/to/a|' \
  > /tmp/patches/0003-xxx.patch
```

**方式 C：批量导出所有子仓改动**

```bash
cd $HOME/aosp-android10
mkdir -p /tmp/patches
i=0
for d in build/soong system/core frameworks/base external/icu packages/modules; do
  [ -d "$d/.git" ] || continue
  out=$( ( cd "$d" && git diff ) )
  [ -n "$out" ] || continue
  i=$((i+1))
  printf '%s\n' "$out" \
    | sed -E "s@^(\+\+\+|---) [ab]/@\1 a/@; s@^diff --git a/[^ ]+ b/.*@#" \
    > "$(printf '/tmp/patches/%04d-%s.patch' "$i" "$(basename "$d")")"
done
ls -1 /tmp/patches/
```

**方式 D：完整 AOSP 工作区一次性导出（diff 递归，量大但最通用）**

```bash
cd $HOME/aosp-android10
# 先记录基线快照
rsync -a --exclude='.repo' --exclude='out' --exclude='.git' \
      /tmp/aosp-baseline/ ./
# 改代码后
diff -ruN --label "a/x" --label "b/x" /tmp/aosp-baseline/ ./ > /tmp/all.patch
# 然后手工按文件拆成 patches/0001-*.patch ...
```

### 5.3 校验与应用

```bash
# 校验能否干净应用
patch -p1 --dry-run --forward -i patches/0001-fix-soong-jobs.patch

# 放进 CI 仓库
cp /tmp/patches/*.patch <CI仓库>/patches/

# 列出 / 试运行 / 真正应用
./build_scripts/apply_patches.sh --list
./build_scripts/apply_patches.sh --dry-run
./build_scripts/apply_patches.sh
```

### 5.4 补丁规范

1. 命名 `0001-<描述>.patch` … `9999-<描述>.patch`，**必须两位数字前缀**（决定应用顺序）
2. 路径前缀必须是 `a/` `b/`，路径**相对 AOSP 源码根目录**
3. 必须在 `android-10.0.0_r47` 上验证能干净应用
4. `patches/` 只放 `.patch`，不放原始文件
5. 脚本**幂等**：已应用过的补丁不会重复应用

常见失败原因：`AOSP_TAG` 与补丁基线不一致 / 前置步骤删掉了补丁涉及的文件 /
补丁已被上游吸收 / 路径前缀不是 `a/ b/`。

---

## 六、失败处理与日志

任意 job 失败时，以下步骤都会执行（`if: always()`）：

| Job | 上传的 artifact | 内容 | 保留 |
|-----|-----------------|------|------|
| 1 | `logs-1-sync_source` | `ci_logs/`（含 `repo-sync-revisions.txt`） | 7 天 |
| 2 | `logs-2-build_stage1` | `ci_logs/` + `out/soong/*.log` + `out/err.log` + `out/*.log` | 7 天 |
| 3 | `logs-3-build_stage2` | 同上 + `frameworks/base/api/current.txt` + `prebuilts/sdk/current/**/api/current.txt` | 7 天 |
| 4 | `logs-4-build_stage3` | 同上 | 7 天 |
| 2 | `out-stage1` | out 分片（`part-*`） | 5 天 |
| 3 | `out-stage2` | out 分片 | 5 天 |
| 4 | `aosp_arm64-eng-images` | `dist_images/*.img` + `SHA256SUMS` + `BUILD_INFO.txt` | 30 天 |

`ci_logs/` 里各阶段日志由 `common.sh` 的 `start_logging()` 通过 `tee` 落盘，
`common.sh` 还注册了 ERR 陷阱，失败时自动打印**出错行号 + 最近 40 行日志**。

### Artifact 保留时长配置位置

`retention-days` 就地写在 `.github/workflows/aosp_build.yml` 的每个
`actions/upload-artifact` 步骤里，或用 workflow `env` 统一管理：

```yaml
env:
  AOSP_ARTIFACT_RETENTION_DAYS: '5'    # 中间 out 产物保留天数
  # 日志固定 7 天、最终镜像固定 30 天（就地写在步骤里）
```

GitHub 允许的 `retention-days` 范围是 **1~90 天**，上限由仓库/组织设置兜底
（`Settings → Actions → General → Maximum artifact retention`）。
所有 artifact 达到保留期后自动删除。

### ⚠️ 存储计费提醒（私有仓库 / 商业账号）

Artifact **按压缩后实际大小**占用仓库存储配额，与保留期直接相乘：

| 方案 | 免费额度 | 超出后 |
|------|---------|--------|
| GitHub Free | 500 MB | 存储写入直接**被阻止**，构建失败 |
| GitHub Pro | 500 MB | 按量计费 |
| GitHub Team | 2 GB | 按量计费 |
| GitHub Enterprise Cloud | 50 GB | 按量计费 |

按本流水线估算（`slim` 模式，单次完整 4 段构建）：

```
out-stage1        ≈ 6~12 GB  × 5 天  ≈ 30~60 GB·天
out-stage2        ≈ 6~12 GB  × 5 天  ≈ 30~60 GB·day
aosp_...-images   ≈ 2~4  GB  × 30 天 ≈ 60~120 GB·天
logs-*            ≈ 0.1 GB  × 7 天
-----------------------------------------------
单次构建峰值占用 ≈ 15~28 GB
```

**结论：如果仓库是私有 + 免费账号，几乎必然在第 1~2 次构建就撞上 500MB 上限导致上传失败。**
可采取的措施：

1. 仓库设为 **Public**（artifact 对公开仓库免费，但会公开 `BUILD_INFO.txt` 里的构建元信息 —— 请勿在公开仓库执行敏感构建）
2. 或升级到 Pro / Team（500MB / 2GB 起步）
3. 或把 `AOSP_ARTIFACT_RETENTION_DAYS` 调到 **1**，日志与最终镜像保留期缩短
4. 或在 workflow 顶部加 job 完成后自动清理：
   ```yaml
   # Job4 结束后清理中间 artifact（保留最终镜像）
   - name: '清理中间 out artifact'
     if: success()
     run: gh api --method DELETE "/repos/${{ github.repository }}/actions/artifacts?name=out-stage1" || true
     env:
       GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```
5. `AOSP_OUT_PACK_MODE=slim` + `AOSP_OUT_PART_MB` 调小不会减少总量，只影响单片大小
6. `concurrency` 已设为 `cancel-in-progress: false`，避免并发构建互相挤占存储

> Cache（`.repo`，10GB/仓库）**不计入 artifact 存储计费**，这是本设计只缓存 `.repo` 的原因之一。

---

## 七、重要提示（务必阅读）

### 7.1 `aosp_arm64-eng` 是通用参考镜像，不能刷机

```
aosp_arm64-eng = AOSP generic ARM64 参考产品 (AOSP reference / GSI 风格 target)
```

- 它**不是**任何实体手机（Pixel / 小米 / OPPO / vivo / 荣耀 / 一加…）的固件
- 它的 `kernel/` 是 AOSP 通用内核配置（`aosp_arm64_defconfig`），**与任何真机的内核 ABI 都不匹配**
- 它缺少对应机型的 vendor 分区内容、bootloader 校验、摄像头/指纹/基带等私有 HAL
- **直接刷入真机会变砖**，且存在变砖后无法恢复的风险
- 正确用法：作为 **GSI 通用系统镜像**刷入支持 GSI 的设备（需设备已解锁 bootloader + 设备内核支持 GSI 接口）
- 本流水线产物的**主要价值是 AOSP 10 源码级研究、模块编译基线、API 契约基线**，而非刷机

### 7.2 GhostHWBP 硬件断点 ko 的内核匹配约束

后续集成 `GhostHWBP`（利用 ARM64 硬件调试寄存器 `DBGBVR/DBGBCR` 实现用户态硬件断点的 ko 驱动）时：

| 要求 | 说明 |
|------|------|
| **必须匹配目标设备内核源码** | ko 是内核模块，加载时内核会校验 `vermagic`（版本、SMP、preempt、编译器、mod_unload 等） |
| **需要 `CONFIG_HAVE_HW_BREAKPOINT` + `CONFIG_HAVE_ARCH_HW_BREAKPOINT`** | AOSP generic 内核通常已开启，但真机内核可能被厂商裁剪掉 |
| **需要内核导出 debug breakpoint 接口** | 依赖 `arch/arm64/kernel/hw_breakpoint.c` 与 `perf_event` 子系统 |
| **需要 3.18+ 的 ARM64** | 更早内核的 `hw_breakpoint` API 不完整，需要自行 backport |
| **通用镜像内核无法加载该 ko** | `aosp_arm64-eng` 的 `kernel_aarch64` 与真机内核 vermagic / 符号表完全不同，insmod 必然 `Invalid module format` |
| **安全加固设备会拦截** | 部分厂商内核开启 `CONFIG_MODULE_SIG_FORCE` + ` lockdown`，未签名的 ko 无法加载 |

**集成路线建议**（与基线方案一致）：

1. **保持 AOSP 参考镜像作为「模块编译与 API 基线」** —— 用来编译 Dobby / SandHook / dex_dumper 等用户态模块，产出 `.so`
2. **额外准备目标机型 kernel 源码**，例如 `kernel/xiaomi/msm-4.14` 或设备对应的 `kernel/<vendor>`
3. **为目标机型加一棵设备树** `device/<vendor>/<name>/`（含 `AndroidProducts.mk`、`BoardConfig.mk`、proprietary 目录），用 `lunch <vendor>_<name>-userdebug` 替换 `aosp_arm64-eng` 产设备固件
4. 在设备树的 `Android.mk` / `BoardConfig.mk` 里加入 `GhostHWBP.ko` 的预编译模块声明，让 `m` 把它打进 `/system/lib/modules/` 或 `/vendor/lib/modules/`
5. 用 **userdebug** 而非 **user** 变体（user 变体会锁 root、关闭 `insmod`）

> 本次只做基础 CI 稳定化，以上模块（虚拟化内核 + 显式 root + Magisk）**均未集成**。

---

## 八、故障速查

| 现象 | 原因 | 处理 |
|------|------|------|
| `bad interpreter: No such file or directory` | python shebang 指向 `python` | `sync_source.sh --fix-python`（脚本已自动执行）；确认 `python-is-python3` 装上 |
| `ninja: error: unknown target` | 目标清单含 ninja 图里没有的目标 | 改用 `AOSP_NINJA_TARGETS_MODE=xargs` 回退模式 |
| `ninja: ... Killed` / exit 137 | OOM | 确认 16G swap 生效（`swapon --show`）；调小 `JAVA_TOOL_OPTIONS` 的 `-Xmx` |
| `patch: **** Only garbage was found in the patch input` | 补丁不是 `a/ b/` 前缀或格式错 | 用 `--howto` 重新生成 |
| `m installclean` 报错后继续 | out 已是干净状态 | 脚本已降级为 warning，不阻塞 |
| `Out of disk space` / `No space left on device` | 磁盘不足 | 见第四章「硬性容量约束」，优先换大磁盘 runner |
| `repo sync` 频繁失败 | 网络抖动 | 已用 `--retry-fetches=3` + 外层 3 次重试；仍失败则配 `AOSP_MIRROR_MANIFEST` 走镜像 |
| artifact 上传失败（超配额） | 存储超限 | 见第六章计费提醒 |
| `m installclean` 之后 `m systemimg` 仍缺文件 | 上一段 out 被 slim 裁剪过头 | 把 `AOSP_OUT_PACK_MODE` 改 `full` 复现定位 |

---

## 九、声明

本仓库与流水线仅用于 **Android 安全研究与逆向教学**。
严禁用于未授权应用逆向、破解、篡改等违法场景。
所有操作请在获得目标应用作者明确授权、且符合所在司法辖区法律法规的前提下进行。
