#!/usr/bin/env bash
# =============================================================================
#  lib/compile_shard.sh —— 带时间预算的 ninja 执行 + 完工判定
# -----------------------------------------------------------------------------
#  【为什么不能按目标名切分】
#  AOSP 的 ninja 图有上万个 target 和强依赖顺序。把 "保留清单" 按名字切成两半
#  交给两个 job，会出现两种坏结果：
#    1) 后一半的依赖在前一半里 -> 第二个 job 把前一半的活重做一遍（白干）
#    2) 依赖关系算错 -> 顺序错乱、重复编译，甚至生成不一致的产物
#  要正确切分必须做拓扑分层，而 `ninja -t graph` 在 AOSP 规模上极其昂贵。
#
#  【本方案：时间预算 + 增量续跑】
#  每个编译 shard 跑**同一份完整目标清单**，只是各自有时间预算：
#    shard A: 跑 250 分钟 -> 到点给 ninja 发 SIGINT 优雅停止 -> 打包 out
#    shard B: 跑同一份清单 250 分钟 -> ninja 瞬间跳过 A 已完成的边 -> 接着往下编
#  好处：
#    * 零拓扑分析风险 —— ninja 自己保证依赖正确性
#    * 工作量自动均衡，不需要人为划分边界
#    * SIGINT 是优雅停止：ninja 会完成当前边再退出，.ninja_log 保持一致
#    * 天然可续跑：再加一个 shard 就能多编 250 分钟，改配置即可
#
#  【完工判定】
#  `ninja -n @rsp`（dry run）只打印"还要执行的命令"。
#  输出为空 => 全部目标已构建完成，可以进入 metalava 阶段。
# =============================================================================

# =============================================================================
# build_with_budget —— 在时间预算内跑 ninja，到点优雅停止
# -----------------------------------------------------------------------------
# 返回值：
#   0  ninja 正常跑完且退出码为 0（目标全部完成）
#   10 预算耗尽，主动 SIGINT 停止（正常情况，还有活没干完）
#   11 预算内就失败了（真错误，交给调用方处理）
# =============================================================================
BUDGET_EXIT_EXHAUSTED=10
BUDGET_EXIT_FAILED=11

build_with_budget() {
  local rsp="$1"                    # 目标清单（ninja @file）
  local out="$2"                    # out 目录
  local budget_min="$3"             # 时间预算（分钟）
  local poll_sec="${4:-30}"

  local ninja
  ninja="$(find_ninja)"

  [ -f "$rsp" ] || { err "目标清单不存在: ${rsp}"; return "$BUDGET_EXIT_FAILED"; }

  banner "开始串行编译（预算 ${budget_min} 分钟，-j${AOSP_BUILD_JOBS}）"
  log "ninja   : $ninja"
  log "目标清单: $rsp ($(wc -l < "$rsp") 个目标)"
  log "预算    : ${budget_min} 分钟（到点优雅停止，工作量留给下一个 shard）"
  log "提示    : 进度可看本 job 日志，或 ninja 的 -d stats 输出"

  local t0=$SECONDS
  local pid rc=0 budget_hit=0

  # 后台起 ninja，父进程轮询时间预算
  # --no-duplicate: 避免 ninja 重复执行同一条命令
  "$ninja" -C "$out" -j"$AOSP_BUILD_JOBS" -k "$AOSP_BUILD_KEEP_GOING" \
           -d stats "@${rsp}" &
  pid=$!
  # 记下 pid，脚本退出时用它兜底收尾
  COMPILE_SHARD_NINJA_PID="$pid"

  local elapsed last_report
  last_report=$t0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll_sec"
    elapsed=$(( SECONDS - t0 ))

    # 每 5 分钟打印一次已用时间
    if [ $(( elapsed - last_report )) -ge 300 ]; then
      last_report=$elapsed
      log "编译中… 已用 $(( elapsed / 60 )) 分 / 预算 ${budget_min} 分（剩余 $(( (budget_min * 60 - elapsed) / 60 )) 分）"
      # 顺便报一下 out 当前体积，便于观察增长速率
      log "  out 体积: $(du -sh "$out" 2>/dev/null | cut -f1 || echo '?')"
      log "  磁盘剩余: $(df -BG --output=avail "$out" 2>/dev/null | tail -n1 | tr -dc '0-9')GB"
    fi

    if [ "$elapsed" -ge $(( budget_min * 60 )) ]; then
      budget_hit=1
      log "时间预算耗尽（${budget_min} 分钟），向 ninja(pid=${pid}) 发送 SIGINT 优雅停止"
      # SIGINT 让 ninja 完成当前正在编译的那条边再干净退出，.ninja_log 保持一致
      kill -INT "$pid" 2>/dev/null || true
      # 优雅期：ninja 需要时间收尾（大 C++ 文件可能要一两分钟）
      local wait_s=0
      while kill -0 "$pid" 2>/dev/null && [ "$wait_s" -lt "${AOSP_SHARD_SIGINT_GRACE_SEC:-120}" ]; do
        sleep 5
        wait_s=$(( wait_s + 5 ))
      done
      # 还没退就升级信号：SIGTERM -> SIGKILL，保证 job 不会被挂死
      if kill -0 "$pid" 2>/dev/null; then
        warn "SIGINT 后 ${wait_s}s 仍未退出，升级为 SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        wait_s=0
        while kill -0 "$pid" 2>/dev/null && [ "$wait_s" -lt 30 ]; do
          sleep 5
          wait_s=$(( wait_s + 5 ))
        done
      fi
      if kill -0 "$pid" 2>/dev/null; then
        err "SIGTERM 后仍未退出，强制 SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 3
      fi
      log "ninja 已停止（等待 ${wait_s}s）"
      break
    fi
  done

  # 取 ninja 退出码（budget_hit 时 SIGINT 会让它非 0 退出，这是预期的）
  if wait "$pid" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  COMPILE_SHARD_NINJA_PID=""

  local used=$(( (SECONDS - t0) / 60 ))
  local used_s=$(( SECONDS - t0 ))
  log "ninja 退出: rc=${rc}, 用时 ${used} 分 ${used_s} 秒"

  if [ "$budget_hit" -eq 1 ]; then
    log "已优雅停止，工作量留给下一个编译 shard"
    return "$BUDGET_EXIT_EXHAUSTED"
  fi

  if [ "$rc" -ne 0 ]; then
    err "ninja 在预算内失败（rc=${rc}），用时 ${used} 分"
    return "$BUDGET_EXIT_FAILED"
  fi

  log "ninja 在预算内跑完且无错误 ✓"
  return 0
}

# =============================================================================
# is_build_complete —— 判定目标清单是否已全部构建
# -----------------------------------------------------------------------------
# 用 ninja -n（dry run）: 只打印"将要执行的命令"，不实际执行。
# 输出为空 => 全部完成。
# =============================================================================
is_build_complete() {
  local rsp="$1"
  local out="$2"
  local ninja
  ninja="$(find_ninja)"

  [ -f "$out/soong/build.ninja" ] || { err "未找到 $out/soong/build.ninja"; return 2; }
  [ -f "$rsp" ] || { err "目标清单不存在: ${rsp}"; return 2; }

  local dry
  dry="$(mktemp -t ninja_dryrun.XXXXXX)"
  # -n 只列出"将要执行的命令"，不实际执行；返回码非 0 不影响"还有没有活"的判断
  "$ninja" -C "$out" -n -j"$AOSP_BUILD_JOBS" "@${rsp}" > "$dry" 2>&1 || true

  # ninja 自己说的话（no work to do / warning / error）不算"待执行命令"
  #
  # 注意：这里必须用 `|| true` 而不是 `|| echo 0`。
  #   grep -c 在"匹配 0 行"时会打印 0 并返回退出码 1，
  #   `|| echo 0` 会再追加一行 0，得到 "0\n0" 这种两行字符串，
  #   后续整数比较会直接报语法错 —— 也就是说"全部完成"这个最关键的情况会失效。
  local real
  real="$(grep -vE '^[[:space:]]*ninja:' "$dry" 2>/dev/null | grep -c '[^[:space:]]' || true)"
  case "$real" in
    ''|*[!0-9]*) real=0 ;;   # 空值/异常值一律当 0（无待执行命令）
  esac

  log "dry-run 待执行命令行数: ${real}"
  if [ "$real" -gt 0 ]; then
    log "尚未完成的构建（dry run 前 20 行）:"
    head -n 20 "$dry" | sed 's/^/    /'
  fi
  cp "$dry" "${CI_LOG_DIR}/ninja-dryrun-shard${AOSP_SHARD_INDEX:-1}.txt" 2>/dev/null || true
  rm -f "$dry"

  # 容差：默认为 0（严格）。
  #   ninja -n 在图完全构建完毕时输出为空，所以"还有 N 条命令"就等于"还有 N 个活"。
  #   容差 >0 会带来危险方向的误判：把"仅剩少量工作"当成"已完成"，
  #   于是一个不完整的 out 被当成完整产物传给 metalava / 打包阶段，静默产出坏镜像。
  #   宁可误报（最后一个 shard 显式失败、提示调大 compile_shards）也不能漏报。
  local tol="${AOSP_COMPLETE_TOLERANCE:-0}"
  if [ "$real" -le "$tol" ]; then
    log "判定：已完成（待执行命令 ${real} <= 容差 ${tol}）"
    return 0
  else
    log "判定：未完成（还有 ${real} 条命令要执行，容差 ${tol}）"
    return 1
  fi
}

# =============================================================================
# ninja 孤儿进程兜底
# =============================================================================
COMPILE_SHARD_NINJA_PID=""

compile_shard_cleanup() {
  local pid="${COMPILE_SHARD_NINJA_PID:-}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    warn "清理残留的 ninja 进程 pid=${pid}"
    kill -TERM "$pid" 2>/dev/null || true
  fi
}
