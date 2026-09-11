#!/bin/bash
# notify-send-env-isolation.sh — Tier U：send-digest 的 hermes send 子进程 env 剥离（t_f3876050）
# 覆盖：
#   ① worker env 注入态（dispatcher 注入 HERMES_HOME=<contrib profile home> + HERMES_PROFILE=contrib）
#     下 send-digest 成功链路 → hermes send 子进程 env 中两变量必须 unset（stub hermes-env.log 逐字断言）
#   ② 回写契约不变：批次末 sent:true 控制行 + send_result.success + 账本 pushed/pushed_at + alerts+1
#   ③ 非注入态（launchd/普通 shell 宿主）：同一链路照常成功且零 env 泄露副作用
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN stub 沙箱隔离，零真实 hermes/微信调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "notify-send-env-isolation.sh"

TODAY="$(date +%F)"

# ---- 通用工具（口径同 unit/notify-digest-cardify.sh） ----
count_send() { # hermes send 调用次数（calls.log 行形如 hermes|cwd|send --to ...）
  [[ -f "$CONTRIB_TEST_STUB_LOG/calls.log" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
hermes_env_line_count() { # hermes-env.log 行数（缺文件/空文件=0；每 stub 调用恰一行）
  [[ -s "$CONTRIB_TEST_STUB_LOG/hermes-env.log" ]] || { printf '0'; return 0; }
  wc -l <"$CONTRIB_TEST_STUB_LOG/hermes-env.log" | tr -d ' '
}
hermes_env_last_line() { # hermes-env.log 末行（缺文件/空文件=空串）
  [[ -s "$CONTRIB_TEST_STUB_LOG/hermes-env.log" ]] || { printf ''; return 0; }
  tail -n 1 "$CONTRIB_TEST_STUB_LOG/hermes-env.log"
}
batch_sent_field() { # <batch_file> → true|false（显式 sent:true 控制行才算）
  local n
  n="$(jq -s '[.[] | select(.sent == true)] | length' "$1" 2>/dev/null || echo 0)"
  [[ "${n:-0}" -ge 1 ]] && printf 'true' || printf 'false'
}
make_batch() { # <path> — 从 events.jsonl 按未推 contrib 过滤出批次文件（同 flush 口径）
  jq -c 'select(.pushed == false and (.channel // "contrib") == "contrib")' \
    "$SB_ROOT/contrib-data/events.jsonl" >"$1" 2>/dev/null
}
make_digest() { # <path> — 合法摘要文件（报头+实质行，过空卡守卫）
  { printf '🟠【contrib 告警】%s\n\n' "$(date +%m-%d)"
    printf 'scan 研判 claude -p 失败 exit=1，已挂账下轮重试；无需动作。\n'
  } >"$1"
}
seed_chain() { # <key> <batch_path> <digest_path> — 事件入账 + 批次快照 + 摘要文件
  sb_notify event pipeline-failure --key "$1" --summary "叙事事件 env 隔离用例" >/dev/null
  mkdir -p "$SB_ROOT/contrib-data/pending"
  make_batch "$2"
  make_digest "$3"
}
run_send_digest() { # <batch> <digest> — send-digest 成功链路（send 子进程 env 剥离已生效前提）
  sb_run -e "HERMES_HOME=/Users/stringzhao/.hermes/profiles/contrib" -e "HERMES_PROFILE=contrib" \
    "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$2' --batch '$1'"
}

# ================= t_f3876050：_send 调 hermes 前剥离 profile 定位 env =================

t_case "send-digest: worker env 注入态 → hermes send 子进程 HERMES_HOME/HERMES_PROFILE 全剥离"
sb_new >/dev/null 2>&1
BATCH="$SB_ROOT/contrib-data/pending/digest-env-a.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-env-a.digest.md"
seed_chain "env-a" "$BATCH" "$DIGEST"
out="$(run_send_digest "$BATCH" "$DIGEST")"
assert_exit 0 $?
assert_eq "$out" "OK" "stdout 闭集 OK"
assert_eq "$(count_send)" "1" "hermes send 恰一次"
assert_eq "$(hermes_env_line_count)" "1" "hermes-env.log 恰 1 行（每 stub 调用一行）"
assert_eq "$(hermes_env_last_line)" "hermes_home=absent hermes_profile=absent" \
  "worker 注入的两变量在 send 子进程 env 中全剥离（stub 子进程视角逐字断言）"
sb_cleanup

t_case "send-digest: 注入态成功链路回写契约不变 → sent:true + send_result + 账本 pushed + alerts+1"
sb_new >/dev/null 2>&1
BATCH="$SB_ROOT/contrib-data/pending/digest-env-b.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-env-b.digest.md"
seed_chain "env-b" "$BATCH" "$DIGEST"
out="$(run_send_digest "$BATCH" "$DIGEST")"
assert_exit 0 $?
assert_eq "$out" "OK" "stdout 闭集 OK"
assert_eq "$(batch_sent_field "$BATCH")" "true" "批次末控制行 sent:true"
assert_eq "$(jq -s '[.[] | select(has("sent"))][0].send_result.success // false' "$BATCH" 2>/dev/null)" "true" "send_result.success 佐证落行"
assert_eq "$(jq -r 'select(.key == "env-b") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "true" "账本标记 pushed"
assert_not_contains "$(jq -r 'select(.key == "env-b") | .pushed_at' "$SB_ROOT/contrib-data/events.jsonl")" "null" "pushed_at 落值"
assert_eq "$(jq -r --arg d "$TODAY" '.alerts[$d] // 0' "$SB_ROOT/contrib-data/notify-state.json")" "1" "state_bump alerts 今日 +1"
sb_cleanup

t_case "send-digest: 非注入态（launchd/普通 shell 宿主）→ 同一链路照常且零 env 泄露副作用"
sb_new >/dev/null 2>&1
BATCH="$SB_ROOT/contrib-data/pending/digest-env-c.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-env-c.digest.md"
seed_chain "env-c" "$BATCH" "$DIGEST"
out="$(sb_notify send-digest --digest "$DIGEST" --batch "$BATCH")"
assert_exit 0 $?
assert_eq "$out" "OK" "stdout 闭集 OK"
assert_eq "$(batch_sent_field "$BATCH")" "true" "sent:true 回写不变"
assert_eq "$(hermes_env_line_count)" "1" "hermes-env.log 恰 1 行"
assert_eq "$(hermes_env_last_line)" "hermes_home=absent hermes_profile=absent" \
  "两变量 absent（未注入本就 absent，env -u 须为 no-op 零副作用）"

sb_cleanup
t_finish
