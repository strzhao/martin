#!/bin/bash
# sandbox.sh — mktemp 沙箱工厂（tests/ 套件共用；bash 3.2 兼容）
#
# 职责（设计「被测脚本注入机制」节）：
#   1. 伪造 CONTRIB 目录（config/events/queue/budget/state/logs/pending/runs）
#   2. 从 CONTRIB_TEST_TARGET 复制被测脚本（默认仓库 scripts/contrib；detect 维度指向缺陷注入副本）
#   3. 安装影子 stub（hermes/claude/gh/tunnel/osascript/pgrep）到沙箱 bin/
#   4. 建 shim 目录：只符号链接白名单真实工具（jq/python3/shellcheck/git/zsh/bash/awk/sed/grep），
#      **绝不**含 hermes/gh/claude/tunnel/osascript —— 外部命令逃逸在任何 PATH 下都会被抓
#   5. 导出全部 seam 变量 + sb_run 受控 env 白名单子进程（env 跨用例隔离）
#
# 红线：本库绝不读写真实 contrib-data/，绝不调用真实 hermes/gh/claude/tunnel/osascript。
# HOME 指向沙箱内 home，且 $HOME/workspace/martin 软链回沙箱根——万一哪处 seam 漏配，
# 默认值也落在沙箱里，生产零风险。

SB_ROOT=""
SB_HOME=""
SB_TMP=""
SB_STUBLOG=""
SB_STRICT_PATH=""
SB_OUT_FILE=""

sb_find_tool() { # <name> → 绝对路径或 return 1（已知前缀探测，launchd 同款手法）
  local p prefix
  p="$(command -v "$1" 2>/dev/null || true)"
  if [[ -n "$p" && -x "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  for prefix in /opt/homebrew/bin /usr/local/bin "${HOME:-$SB_ROOT}/.local/bin" /usr/bin /bin; do
    if [[ -x "$prefix/$1" ]]; then
      printf '%s/%s' "$prefix" "$1"
      return 0
    fi
  done
  return 1
}

sb_make_shim() { # <dir> — 白名单真实工具符号链接（不含任何外部服务命令）
  local dir="$1" t p
  mkdir -p "$dir"
  for t in jq python3 shellcheck git zsh bash awk sed grep; do
    p="$(sb_find_tool "$t")" || continue
    ln -sf "$p" "$dir/$t" 2>/dev/null || true
  done
}

sb_seed_data() { # 沙箱 contrib-data 底座（与生产 config 默认值同构）
  cat >"$SB_ROOT/contrib-data/config.json" <<'EOF'
{
  "auto_build": true,
  "max_auto_builds_per_day": 1,
  "min_build_score": 12,
  "stale_pr_days": 10,
  "repo": "NousResearch/hermes-agent",
  "auto_deep_check": true,
  "deep_check_per_week": 30,
  "deep_check_per_day": 30,
  "refund_failed_deep_check": false,
  "ready_min_score": 11,
  "allow_own_pr_push": false,
  "probe_per_day": 1,
  "max_alert_pushes_per_day": 3,
  "max_approval_pushes_per_day": 3,
  "approval_ttl_hours": 48,
  "notify_min_interval_min": 20,
  "notify_dry_run": false,
  "notify_target": "weixin:test-target@sandbox",
  "notify_digest": true
}
EOF
  printf '{"version":1,"updated":"","items":[]}\n' >"$SB_ROOT/contrib-data/ready-queue.json"
  jq -n '{limits:{week:3,day:1},days:{},weeks:{},probes:{}}' >"$SB_ROOT/contrib-data/budget.json"
  : >"$SB_ROOT/contrib-data/events.jsonl"
  printf '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}\n' >"$SB_ROOT/contrib-data/notify-state.json"
}

sb_new() { # sb_new → 创建沙箱；设置 SB_* 与 seam env（当前进程及子进程生效）
  SB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contrib-sb.XXXXXX")" || return 1
  SB_ROOT="$(cd "$SB_ROOT" && pwd)"   # 规范化路径（macOS TMPDIR 尾部带 / 会产生 // 形态）
  SB_HOME="$SB_ROOT/home"
  SB_TMP="$SB_ROOT/tmp"
  SB_STUBLOG="$SB_ROOT/stublog"
  mkdir -p "$SB_ROOT/scripts/contrib" \
    "$SB_ROOT/contrib-data/logs" \
    "$SB_ROOT/contrib-data/pending" \
    "$SB_ROOT/contrib-data/runs/deep-check" \
    "$SB_ROOT/bin" "$SB_STUBLOG/bodies" "$SB_ROOT/locks" \
    "$SB_HOME/workspace" "$SB_TMP" || return 1
  ln -s "$SB_ROOT" "$SB_HOME/workspace/martin"

  # 1) 被测脚本副本（接受两种布局：脚本目录本身，或含 scripts/contrib/ 的沙箱根——后者
  #    支持 DETECT_KEEP 保留沙箱后直接 CONTRIB_TEST_TARGET=<sandbox> 独立复现）
  local src="${CONTRIB_TEST_TARGET:-}"
  if [[ -z "$src" ]]; then
    echo "sandbox: CONTRIB_TEST_TARGET 未设置（应由 run.sh/e2e-smoke/detect 入口注入）" >&2
    return 1
  fi
  if ! ls "$src"/*.sh >/dev/null 2>&1; then
    if ls "$src/scripts/contrib"/*.sh >/dev/null 2>&1; then
      src="$src/scripts/contrib"
    else
      echo "sandbox: 被测脚本目录无 .sh 文件: ${CONTRIB_TEST_TARGET}" >&2
      return 1
    fi
  fi
  cp "$src"/*.sh "$SB_ROOT/scripts/contrib/"
  chmod +x "$SB_ROOT"/scripts/contrib/*.sh 2>/dev/null || true

  # 2) 影子 stub
  local stubsrc="${CONTRIB_TEST_STUBS:-}"
  if [[ -z "$stubsrc" ]]; then
    echo "sandbox: CONTRIB_TEST_STUBS 未设置（影子 stub 目录）" >&2
    return 1
  fi
  cp "$stubsrc"/hermes "$stubsrc"/claude "$stubsrc"/gh "$stubsrc"/tunnel "$stubsrc"/osascript "$stubsrc"/pgrep "$SB_ROOT/bin/"
  chmod +x "$SB_ROOT"/bin/*

  # 3) shim + 数据底座
  sb_make_shim "$SB_ROOT/shim"
  sb_seed_data

  # 4) seam 全量导出（默认值与生产硬编码逐字符一致，仅指向沙箱）
  export MARTIN_DIR="$SB_ROOT"
  export CONTRIB_DATA_DIR="$SB_ROOT/contrib-data"
  export NOTIFY_LOCK="$SB_ROOT/locks/notify.lock"
  export NOTIFY_SEND_LAST="$SB_STUBLOG/hermes-send-last.json"
  export RQ_LOCKDIR="$SB_ROOT/locks/rq.lock"
  export WATCH_LOCK="$SB_ROOT/locks/watch.lock"
  export DEEPCHECK_TARGET_FILE="$SB_ROOT/locks/deepcheck-target"
  export DEEPCHECK_LOCK="$SB_ROOT/locks/deepcheck.lock"
  export HERMES_BIN="$SB_ROOT/bin/hermes"
  export GH_BIN="$SB_ROOT/bin/gh"
  export TUNNEL_BIN="$SB_ROOT/bin/tunnel"
  export OSASCRIPT_BIN="$SB_ROOT/bin/osascript"
  export GATEWAY_PROBE_BIN="$SB_ROOT/bin/pgrep"
  export CLAUDE_BIN="$SB_ROOT/bin/claude"
  export STUB_LOG_DIR="$SB_STUBLOG"
  export CONTRIB_TEST_STUB_LOG="$SB_STUBLOG"

  SB_STRICT_PATH="$SB_ROOT/bin:$SB_ROOT/shim:/usr/bin:/bin"
  SB_OUT_FILE="$SB_ROOT/last-run.out"
  return 0
}

# sb_run [-C dir] [-e K=V]... <bash-snippet>
#   在受控 env 白名单**子进程**中执行 snippet（env 跨用例隔离：白名单外的变量一律不可见）。
#   stdout → sb_run 的 stdout（可 $() 捕获）；stderr → ${SB_OUT_FILE}（失败排查用）。
#   rc → return 值（调用方以 $? / if 判断）。
sb_run() {
  local cwd="$SB_ROOT" snippet="" rc=0
  local -a envs=()
  while [[ "${1:-}" == "-C" || "${1:-}" == "-e" ]]; do
    case "$1" in
      -C) cwd="$2"; shift 2 ;;
      -e) envs[${#envs[@]}]="$2"; shift 2 ;;
    esac
  done
  snippet="${1:-}"
  : >"$SB_OUT_FILE"
  (
    cd "$cwd" || exit 99
    exec env -i \
      HOME="$SB_HOME" \
      TMPDIR="$SB_TMP" \
      PATH="$SB_STRICT_PATH" \
      MARTIN_DIR="$SB_ROOT" \
      CONTRIB_DATA_DIR="$SB_ROOT/contrib-data" \
      NOTIFY_LOCK="$SB_ROOT/locks/notify.lock" \
      NOTIFY_SEND_LAST="$SB_STUBLOG/hermes-send-last.json" \
      RQ_LOCKDIR="$SB_ROOT/locks/rq.lock" \
      WATCH_LOCK="$SB_ROOT/locks/watch.lock" \
      DEEPCHECK_TARGET_FILE="$SB_ROOT/locks/deepcheck-target" \
      DEEPCHECK_LOCK="$SB_ROOT/locks/deepcheck.lock" \
      HERMES_BIN="$SB_ROOT/bin/hermes" \
      GH_BIN="$SB_ROOT/bin/gh" \
      TUNNEL_BIN="$SB_ROOT/bin/tunnel" \
      OSASCRIPT_BIN="$SB_ROOT/bin/osascript" \
      GATEWAY_PROBE_BIN="$SB_ROOT/bin/pgrep" \
      CLAUDE_BIN="$SB_ROOT/bin/claude" \
      STUB_LOG_DIR="$SB_STUBLOG" \
      CONTRIB_TEST_STUB_LOG="$SB_STUBLOG" \
      ${envs[@]+"${envs[@]}"} \
      bash -c "$snippet"
  ) 2>"$SB_OUT_FILE"
  rc=$?
  return $rc
}

# sb_rq <args...> — 运行沙箱副本的 rq.sh（参数安全引用）
sb_rq() {
  local a snippet=""
  for a in "$@"; do
    snippet="$snippet$(printf '%q ' "$a")"
  done
  sb_run "bash \"\$MARTIN_DIR/scripts/contrib/rq.sh\" $snippet"
}

# sb_notify <args...> — 运行沙箱副本的 notify.sh
sb_notify() {
  local a snippet=""
  for a in "$@"; do
    snippet="$snippet$(printf '%q ' "$a")"
  done
  sb_run "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" $snippet"
}

# sb_zsh <args...> — 运行沙箱内 zsh 脚本（run-watch/run-deepcheck 等编排层）
sb_zsh() {
  local a snippet=""
  for a in "$@"; do
    snippet="$snippet$(printf '%q ' "$a")"
  done
  sb_run "zsh $snippet"
}

sb_out() { tail -n "${1:-40}" "$SB_OUT_FILE" 2>/dev/null; }

# sb_seed_event <class> <key> <summary> [channel] [attempts] [pushed(true|false)]
#   直接注入一条事件（构造边缘前置态用：attempts>=3 / 已推送行 / 非 contrib 渠道）
sb_seed_event() {
  local cls="$1" key="$2" summary="$3" ch="${4:-contrib}" att="${5:-0}" pushed="${6:-false}"
  jq -cn --arg ts "2026-01-01T00:00:00+08:00" --arg cls "$cls" --arg key "$key" \
    --arg summary "$summary" --arg ch "$ch" --argjson att "$att" --argjson pushed "$pushed" \
    '{ts: $ts, class: $cls, key: $key, channel: $ch, summary: $summary,
      pushed: $pushed, attempts: $att, pushed_at: null}' \
    >>"$SB_ROOT/contrib-data/events.jsonl"
}

# sb_seed_queue_item <id> <issue> <lane> <state> [priority]
#   直接注入一个 ready-queue 项（gate/e2e 前置态构造用）
sb_seed_queue_item() {
  local id="$1" issue="$2" lane="$3" state="$4" prio="${5:-30}"
  local item
  item="$(jq -cn --arg id "$id" --argjson issue "$issue" --arg lane "$lane" --arg state "$state" --argjson prio "$prio" \
    '{id: $id, issue: $issue, pr: null, title: ("issue #" + ($issue | tostring)),
      disposition: "review-evidence", lane: $lane, score: 12, priority: $prio,
      source: "scan", state: $state, premises: [], ammo: [], draft: null,
      tunnel: {url: null, slug: null, deployed_at: null, removed_at: null},
      budget: {week: "2026-W01", day: "2026-01-01"},
      queued_at: "2026-01-01T00:00:00+08:00", queued_epoch: 1767196800,
      awaiting_at: null, awaiting_epoch: null, history: []}')"
  jq --argjson item "$item" '.items += [$item]' "$SB_ROOT/contrib-data/ready-queue.json" \
    >"$SB_ROOT/contrib-data/ready-queue.json.tmp" \
    && mv "$SB_ROOT/contrib-data/ready-queue.json.tmp" "$SB_ROOT/contrib-data/ready-queue.json"
}

# sb_state_set <jq 表达式（作用于 notify-state.json）> — 预置 state 边缘值
sb_state_set() {
  jq "$1" "$SB_ROOT/contrib-data/notify-state.json" >"$SB_ROOT/contrib-data/notify-state.json.tmp" \
    && mv "$SB_ROOT/contrib-data/notify-state.json.tmp" "$SB_ROOT/contrib-data/notify-state.json"
}

# sb_config_set <jq 表达式（作用于 config.json）> — 预置配置旋钮
sb_config_set() {
  jq "$1" "$SB_ROOT/contrib-data/config.json" >"$SB_ROOT/contrib-data/config.json.tmp" \
    && mv "$SB_ROOT/contrib-data/config.json.tmp" "$SB_ROOT/contrib-data/config.json"
}

sb_cleanup() { # 默认删沙箱；TESTS_KEEP=1 保留（排查用）
  if [[ "${TESTS_KEEP:-}" == "1" ]]; then
    echo "sandbox: 保留 $SB_ROOT"
  else
    rm -rf "$SB_ROOT"
  fi
  return 0
}
