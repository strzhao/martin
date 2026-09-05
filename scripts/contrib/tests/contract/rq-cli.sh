#!/bin/bash
# rq-cli.sh — Tier C：rq.sh 对外 API 契约（hermes 微信审批环 SKILL.md 消费面）
# 覆盖契约规约：子命令闭集 / 10 态闭集 / 非法迁移 exit 2 + 字节级零改动 / budget 三态 / set-draft 登记
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=contract

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "rq-cli.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"

# ---------------- 子命令闭集（删名/改名 = FAIL）----------------
t_case "子命令闭集：13 个 case 分支全部在实现中"
for sub in init add set next list show sweep budget validate tunnel-deploy tunnel-removed set-draft retry-failed; do
  if grep -qF "$sub)" "$SB_ROOT/scripts/contrib/rq.sh"; then
    _pass "子命令 $sub"
  else
    _fail "子命令 $sub" "case 分支缺失（对外 API 静默破坏）"
  fi
done

t_case "状态闭集：validate 内嵌合法状态表 = 10 态"
for s in queued deep-check awaiting-approval approved executed revise shelved rejected expired failed; do
  if grep -qF "\"$s\"" "$SB_ROOT/scripts/contrib/rq.sh"; then
    _pass "状态 $s 在实现中"
  else
    _fail "状态 $s" "闭集缺员"
  fi
done

# ---------------- set 状态机：非法迁移字节级零改动 ----------------
t_case "非法迁移：exit 2 且 ready-queue.json 字节级零改动"
sb_seed_queue_item "rq-20260905-301" 301 deep queued 40
before="$(shasum -q "$QUEUE_FILE")"
out="$(sb_rq set rq-20260905-301 executed 2>&1)"
rc=$?
assert_exit 2 $rc "queued → executed 非法"
after="$(shasum -q "$QUEUE_FILE")"
assert_eq "$before" "$after" "字节级零改动"

t_case "非法状态名：exit 2 且零改动"
out="$(sb_rq set rq-20260905-301 bogus-state 2>&1)"
rc=$?
assert_exit 2 $rc "bogus-state 拒绝"
after2="$(shasum -q "$QUEUE_FILE")"
assert_eq "$before" "$after2" "字节级零改动"

t_case "合法迁移：exit 0 且状态落盘"
out="$(sb_rq set rq-20260905-301 deep-check --note '契约测试')"
rc=$?
assert_exit 0 $rc
assert_contains "$(jq -r '.items[0].state' "$QUEUE_FILE")" "deep-check" "state 已写"
assert_contains "$(jq -r '.items[0].history | length' "$QUEUE_FILE")" "1" "history 追加"

t_case "set 不存在的 id：exit 2"
sb_rq set rq-20260905-404 deep-check >/dev/null 2>&1
assert_exit 2 $?

# ---------------- 黑盒：add / list / show / budget ----------------
t_case "add：disposition 闭集校验"
sb_rq add --issue 302 --disposition bogus-disp --score 10 >/dev/null 2>&1
assert_exit 2 $? "bogus disposition 拒绝"

t_case "add：lane 缺省规则（probe-salvage→probe，其余→deep）"
id1="$(sb_rq add --issue 303 --disposition probe-salvage --score 12)"
assert_contains "$(jq -r --arg id "$id1" '.items[] | select(.id == $id) | .lane' "$QUEUE_FILE")" "probe" "probe-salvage → probe lane"
id2="$(sb_rq add --issue 304 --disposition review-evidence --score 12)"
assert_contains "$(jq -r --arg id "$id2" '.items[] | select(.id == $id) | .lane' "$QUEUE_FILE")" "deep" "review-evidence → deep lane"

t_case "add：secret 拦截"
sb_rq add --issue 305 --disposition review-evidence --score 12 --title 'leak ghp_1234567890abcdefghijklmn' >/dev/null 2>&1
assert_exit 2 $? "secret 拒绝写入"

t_case "list：--state 过滤 + --oneline"
list_out="$(sb_rq list --state queued)"
assert_exit 0 $?
assert_contains "$list_out" "$id2" "--state 过滤命中 queued 项（id 动态取自 add 返回，修复日期依赖冻结字面量）"
one="$(sb_rq list --state queued --oneline)"
assert_contains "$one" "prio=" "oneline 格式"

t_case "show：--json 与文本两形态"
js="$(sb_rq show rq-20260905-301 --json)"
assert_exit 0 $?
assert_contains "$(printf '%s' "$js" | jq -r '.id')" "rq-20260905-301" "json 形态"
txt="$(sb_rq show rq-20260905-301)"
assert_contains "$txt" "state:" "文本形态"

t_case "budget reserve：drill 件不计额"
out="$(sb_rq budget reserve rq-20260905-301-drill --lane deep)"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "OK(drill-不计额)" "drill 不占预算"

t_case "budget reserve：超额 DENY exit 1"
sb_config_set '.deep_check_per_day = 1'
out="$(sb_rq budget reserve rq-20260905-303 --lane deep)"
assert_exit 0 $? "第 1 次 OK"
out="$(sb_rq budget reserve "$id2" --lane deep 2>/dev/null)"
rc=$?
assert_exit 1 $rc "第 2 次 DENY"
assert_contains "$out" "DENY" "DENY 输出"

t_case "budget refund：默认 refund_failed_deep_check=false → SKIP 不返还"
out="$(sb_rq budget refund rq-20260905-303 --lane deep)"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "SKIP" "默认不返还"

t_case "budget status：输出可读行"
out="$(sb_rq budget status)"
assert_exit 0 $?
assert_contains "$out" "deep 本周" "status 格式"

t_case "set-draft / tunnel-deploy / tunnel-removed 登记链"
printf 'draft content\n' >"$SB_ROOT/contrib-data/pending/rq-20260905-301.md"
sb_rq set-draft rq-20260905-301 "$SB_ROOT/contrib-data/pending/rq-20260905-301.md" >/dev/null
assert_exit 0 $? "set-draft"
assert_contains "$(jq -r '.items[] | select(.id == "rq-20260905-301") | .draft' "$QUEUE_FILE")" "pending/rq-20260905-301.md" "draft 已登记"
sb_rq tunnel-deploy rq-20260905-301 "https://d.stringzhao.life/x" "x" >/dev/null
assert_exit 0 $? "tunnel-deploy"
assert_contains "$(jq -r '.items[] | select(.id == "rq-20260905-301") | .tunnel.slug' "$QUEUE_FILE")" "x" "slug 已登记"
sb_rq tunnel-removed rq-20260905-301 >/dev/null
assert_exit 0 $? "tunnel-removed"
assert_contains "$(jq -r '.items[] | select(.id == "rq-20260905-301") | .tunnel.removed_at' "$QUEUE_FILE")" "20" "removed_at 已登记"

t_case "validate：干净队列 OK"
out="$(sb_rq validate)"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "validate: OK" "校验通过"

t_case "sweep：TTL 搁置/过期路径产出 shelved 与 expired"
sb_seed_queue_item "rq-20260905-311" 311 deep awaiting-approval 35
sb_config_set '.approval_ttl_hours = 1'
# awaiting_epoch 拨回 2h 前（jq now 内建取当前 epoch，零 sleep 构造时间闸门前置态）
jq '.items |= map(if .id == "rq-20260905-311" then .awaiting_epoch = ((now | floor) - 7200) else . end)' \
  "$QUEUE_FILE" >"$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
out="$(sb_rq sweep)"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "搁置" "awaiting-approval 超 TTL → shelved"
assert_contains "$(jq -r '.items[] | select(.id == "rq-20260905-311") | .state' "$QUEUE_FILE")" "shelved" "状态落盘"

sb_cleanup
t_finish
