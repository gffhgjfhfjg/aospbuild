# =============================================================================
#  patches/ —— AOSP 源码补丁存放目录
# =============================================================================
#
#  本目录只存放 .patch 文件，不存放任何被修改的原始文件。
#  AOSP 源码不在本 git 仓库内（云端由 repo sync 拉取），所以补丁使用
#  `patch -p1 --forward` 对工作区做文件级修补，不依赖 git 历史。
#
#  ── 命名规范（决定应用顺序，务必使用两位数字前缀）────────────────────────
#     0001-<简短描述>.patch
#     0002-<简短描述>.patch
#     …
#     9999-<收尾清理>.patch
#
#  ── 内容规范 ────────────────────────────────────────────────────────────
#     1) 路径前缀必须是 a/ 和 b/（脚本用 -p1 剥离）
#        --- a/build/soong/Android.bp
#        +++ b/build/soong/Android.bp
#     2) 路径相对 AOSP 源码根目录
#     3) 不要带 android- 提交号头（不是 git format-patch 出来的）
#     4) 必须在 android-10.0.0_r47 上验证能干净应用
#
#  ── 本地生成方式（最简）─────────────────────────────────────────────────
#     cd $HOME/aosp-android10
#     ( cd build/soong && git diff ) \
#       | sed -E 's@^(\+\+\+|---) [ab]/@\1 a/@' > /tmp/0001-fix-soong.patch
#
#     # 或对无 git 历史的文件手工构造
#     cp a /tmp/a.orig && vim a && \
#     diff -u /tmp/a.orig a \
#       | sed -e '1s|.*|--- a/path/to/a|' -e '2s|.*|+++ b/path/to/a|' \
#       > /tmp/0002-xxx.patch
#
#  ── 校验（本地 AOSP 树）────────────────────────────────────────────────
#     patch -p1 --dry-run --forward -i patches/0001-fix-soong.patch
#
#  ── 查看与管理 ─────────────────────────────────────────────────────────
#     ./build_scripts/apply_patches.sh --list      # 列出补丁与影响文件
#     ./build_scripts/apply_patches.sh --dry-run   # 只验证能否应用
#     ./build_scripts/apply_patches.sh             # 真正应用
#     ./build_scripts/apply_patches.sh --howto     # 完整编写指南
#
#  ── 已打过的补丁不会重复应用（脚本用 --forward + 失败回退判定）─────────
# =============================================================================

（把 .patch 文件放这一行下方即可）
