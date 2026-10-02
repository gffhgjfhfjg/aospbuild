#!/usr/bin/env bash
# =============================================================================
#  build_scripts/lib/apply_patches.sh 的独立执行入口（仅用于查看指南）
#  实际打补丁请用 build_scripts/apply_patches.sh
# =============================================================================
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_here}/common.sh"
print_patch_howto
