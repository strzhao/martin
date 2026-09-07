#!/bin/bash
# mail-gate.sh — Tier U：邮件闸门行为表（stub himalaya seam，零真实 IMAP）
# 覆盖：首启只定位不回灌 / 增量产出 pending（to 分流 + [GitHub] 排除）/ 幂等重跑零新增
#       / --commit-cursor 推进游标 / --drain 清空 / 无未读 exit 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"

source "$TESTS_ROOT/lib/assert.sh"
t_init "mail-gate.sh"

GATE="$CONTRIB_TEST_TARGET/mail_gate.sh"
[[ -f "$GATE" ]] || { echo "FATAL: 找不到 $GATE"; exit 1; }

# 每用例独立沙箱 + stub himalaya（envelope list 读 MAIL_STUB_ENVELOPES 文件；message read 读 read-<id>.txt）
SB=""; STUB=""; DATA=""; CURSOR=""; PENDING=""
new_sb() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/mail-gate-u.XXXXXX")"
  STUB="$SB/stub"; DATA="$SB/data"
  mkdir -p "$STUB" "$DATA"
  cat > "$STUB/himalaya" <<'STUBEOF'
#!/bin/bash
case "$1" in
  envelope) cat "${MAIL_STUB_ENVELOPES:?}" ;;
  message)
    f="${MAIL_STUB_DIR:?}/read-$3.txt"
    if [[ -f "$f" ]]; then cat "$f"; else printf 'Message-ID: <default-%s@github.com>\n\n正文默认行。\n' "$3"; fi
    ;;
  *) exit 2 ;;
esac
STUBEOF
  chmod +x "$STUB/himalaya"
  CURSOR="$DATA/mail-cursor.json"
  PENDING="$DATA/mail-pending.json"
}

run_gate() { # <可选参数> → stdout, RC 全局
  MAIL_STUB_DIR="$STUB" MAIL_STUB_ENVELOPES="$STUB/envelopes.json" \
    HIMALAYA_BIN="$STUB/himalaya" CONTRIB_DATA_DIR="$DATA" \
    bash "$GATE" "$@" 2>/dev/null
  RC=$?
}

env_row() { # <id> <to-addr> <subject> → envelope JSON 行（jq -n 构造，自动处理转义）
  jq -cn --arg id "$1" --arg to "$2" --arg subj "$3" \
    '{"id":$id,"flags":[],"subject":$subj,"from":{"name":"Teknium","addr":"notifications@github.com"},"to":{"name":"x","addr":$to},"date":"2026-09-07 05:57-07:00","has_attachment":false}'
}

t_case "无未读 → exit 0，零 cursor"
new_sb
printf '[]\n' > "$STUB/envelopes.json"
run_gate
assert_exit 0 $RC
no_cursor=0; [[ ! -f "$CURSOR" ]] || no_cursor=1
assert_eq "$no_cursor" "0" "无未读不写 cursor"

t_case "首启：有存量未读只定位不回灌"
new_sb
printf '[%s]\n' "$(env_row 8001 "hermes-agent@noreply.github.com" "Re: [NousResearch/hermes-agent] 某PR (PR #100)")" > "$STUB/envelopes.json"
run_gate
assert_exit 0 $RC
assert_eq "$(jq -r '.last_id' "$CURSOR")" "8001" "cursor 定位到最大 id"
no_pending=0; [[ ! -f "$PENDING" ]] || no_pending=1
assert_eq "$no_pending" "0" "首启零 pending（存量不研判）"

t_case "增量：cursor 后新邮件 → pending 产出 + exit 10"
new_sb
printf '{"last_id":8000,"initialized":"t"}\n' > "$CURSOR"
{
  printf '['
  env_row 8002 "hermes-agent@noreply.github.com" "Re: [NousResearch/hermes-agent] 新评论 (PR #101)"
  printf ','
  env_row 8003 "user@foxmail.com" "[NousResearch/hermes-agent] 主题分流命中 (Issue #7)"
  printf ','
  env_row 8004 "hermes-agent@noreply.github.com" "[GitHub] 账号类通知"
  printf ','
  env_row 7999 "hermes-agent@noreply.github.com" "Re: [NousResearch/hermes-agent] 游标之前 (PR #99)"
  printf ']\n'
} > "$STUB/envelopes.json"
printf 'Message-ID: <pr101-a@github.com>\n\nTeknium 评论了你的 PR。\n' > "$STUB/read-8002.txt"
printf 'Message-ID: <i7-a@github.com>\n\n新 issue 正文。\n' > "$STUB/read-8003.txt"
run_gate
assert_exit 10 $RC
assert_eq "$(jq 'length' "$PENDING")" "2" "pending 恰 2 封（to/主题双分流命中，[GitHub] 排除，游标前排除）"
assert_eq "$(jq -r '.[0].id' "$PENDING")" "8002" "按 id 排序"
assert_eq "$(jq -r '.[0].message_id' "$PENDING")" "pr101-a@github.com" "Message-ID 已提取"
assert_contains "$(jq -r '.[0].preview' "$PENDING")" "Teknium 评论了你的 PR" "正文节选已预取"

t_case "幂等：同批未消费重跑 → 仍 exit 10 + 去重不翻倍"
run_gate
assert_exit 10 $RC
assert_eq "$(jq 'length' "$PENDING")" "2" "pending 去重后条数不变"

t_case "--commit-cursor：拨游标 + 清 pending（消费闭环）"
run_gate --commit-cursor
assert_exit 0 $RC
assert_eq "$(jq -r '.last_id' "$CURSOR")" "8003" "cursor 拨到 8003"
assert_eq "$(jq 'length' "$PENDING")" "0" "pending 已清空"

t_case "commit 后重跑：同批邮件不再进 pending"
run_gate
assert_exit 0 $RC
assert_eq "$(jq 'length' "$PENDING")" "0" "零重复消费"

t_case "上轮遗留 pending + 本轮无新邮件 → 仍 exit 10（不卡死遗留）"
new_sb
printf '{"last_id":8005,"committed":"t"}\n' > "$CURSOR"
printf '[%s]\n' "$(env_row 8004 "hermes-agent@noreply.github.com" "Re: [N/hermes-agent] 遗留未研判 (PR #98)")" > "$PENDING"
printf '[]\n' > "$STUB/envelopes.json"
run_gate
assert_exit 10 $RC
assert_eq "$(jq 'length' "$PENDING")" "1" "遗留保留待研判"

t_case "--drain：清空 pending"
run_gate --drain
assert_exit 0 $RC
assert_eq "$(jq 'length' "$PENDING")" "0" "pending 清空"

t_case "himalaya 异常 → exit 非 10（fail-soft 上抛错误）"
new_sb
cat > "$STUB/himalaya" <<'STUBEOF'
#!/bin/bash
exit 7
STUBEOF
chmod +x "$STUB/himalaya"
run_gate
assert_ne "$RC" "10" "himalaya 挂时不误报有新邮件"

t_finish
