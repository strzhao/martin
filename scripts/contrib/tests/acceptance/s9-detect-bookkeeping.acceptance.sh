#!/usr/bin/env bash
# =============================================================================
# s9-detect-bookkeeping.acceptance.sh — 场景 9：捕获⑤ 簿记回归（配额/幂等/重试/告警限额）
# 覆盖谓词：9.P1 9.P2 9.P3（det-machine + 第三方独立复现）
# 依据：state.md `## 验收场景` + 契约「flush 防双发」「失败兜底契约」：
#   - 距 last_flush_epoch < notify_min_interval_min 分钟 → 不发送不 bump 配额
#   - 当日 alerts[date] >= max_alert_pushes_per_day → 拒推 + osascript 兜底
#   - key 幂等唯一（同 key 二次 event 不新增行）；attempts 递增
# 9.P3 抗伪机制真实执行：DETECT_KEEP=1 取簿记守卫拆除副本 → CONTRIB_TEST_TARGET 独立复跑。
# CONTRACT_AMBIGUOUS: mutated 副本目录布局按预注册 driver 字面取 `<sandbox>/mutated`。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s9-p{1,2,3}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
TARGET="$REPO_ROOT/scripts/contrib"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
j(){ printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
[ -f "$SUITE/detect/run.sh" ] || die "env" "detect 入口缺失: $SUITE/detect/run.sh"

# -----------------------------------------------------------------------------
# 9.P1 [det-machine] driver: bash scripts/contrib/tests/detect/run.sh bookkeeping
# assert: exit==0 且 .cases 数>=4 且 全部 pristine 绿 / mutated 红 / diff>=1
# -----------------------------------------------------------------------------
P="9.P1"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/detect/run.sh bookkeeping </dev/null ) >"$ART/s9-p1.out" 2>&1
RC=$?
eq "$RC" 0 "$P detect bookkeeping exit"
LAST="$(jlast "$ART/s9-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
j "$LAST" "(.cases|length)>=4"                              || die "$P" ".cases 数<4: $LAST"
j "$LAST" '[.cases[]|select(.pristine_exit!=0)]|length==0'  || die "$P" "存在 pristine_exit!=0 的 case: $LAST"
j "$LAST" '[.cases[]|select(.mutated_exit==0)]|length==0'   || die "$P" "存在 mutated_exit==0 的 case（簿记缺陷未被捕获）: $LAST"
j "$LAST" '[.cases[]|select((.diff_lines//0)<1)]|length==0' || die "$P" "存在 diff_lines<1 的 case: $LAST"
echo "PASS $P（cases=$(printf '%s' "$LAST" | jq -r '.cases|length')）"

# -----------------------------------------------------------------------------
# 9.P2 [det-machine] driver: fs-grep s9-p1.out（case 名集合覆盖四簿记语义）
# assert: .cases 数>=4 且 组一(quota|limit) 组二(dedup|idempot) 组三(retry)
#              组四(alert|notify) 各含其一
# -----------------------------------------------------------------------------
P="9.P2"
[ -s "$ART/s9-p1.out" ] || die "$P" "前置产物缺失: $ART/s9-p1.out"
NAMES="$(jlast "$ART/s9-p1.out" | jq -r '[.cases[].name]|join(" ")')"
j "$(jlast "$ART/s9-p1.out")" "(.cases|length)>=4" || die "$P" ".cases 数<4"
printf '%s' "$NAMES" | grep -qiE 'quota|limit'   || die "$P" "组一 quota/limit 未覆盖: [$NAMES]"
printf '%s' "$NAMES" | grep -qiE 'dedup|idempot' || die "$P" "组二 dedup/idempot 未覆盖: [$NAMES]"
printf '%s' "$NAMES" | grep -qiE 'retry'         || die "$P" "组三 retry 未覆盖: [$NAMES]"
printf '%s' "$NAMES" | grep -qiE 'alert|notify'  || die "$P" "组四 alert/notify 未覆盖: [$NAMES]"
echo "$NAMES" > "$ART/s9-p2.out"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 9.P3 [det-machine] 独立复现（簿记守卫拆除副本必须使套件红）
# driver: DETECT_KEEP=1 detect/run.sh bookkeeping
#         → CONTRIB_TEST_TARGET=<sandbox>/mutated bash scripts/contrib/tests/run.sh
# assert: exit!=0 且 差异行数>=1
# -----------------------------------------------------------------------------
P="9.P3"
( cd "$REPO_ROOT" && DETECT_KEEP=1 bash scripts/contrib/tests/detect/run.sh bookkeeping </dev/null ) >"$ART/.s9-p3.detect.out" 2>&1
RC_D=$?
eq "$RC_D" 0 "$P DETECT_KEEP=1 复跑 detect exit"
DETJSON="$(jlast "$ART/.s9-p3.detect.out")"
SB="$(printf '%s' "$DETJSON" | jq -r '.sandbox // empty')"
[ -n "$SB" ] && [ -d "$SB" ] || die "$P" "DETECT_KEEP 沙箱缺失: $DETJSON"
MUT="$SB/mutated"
[ -d "$MUT" ] || die "$P" "mutated 副本目录缺失（契约布局 <sandbox>/mutated）: $MUT"

DIFFLINES=0; FOUND=0
for f in notify.sh rq.sh scan_gate.sh deep_check_gate.sh deep-check.sh run-deepcheck.sh run-watch.sh; do
  if [ -f "$TARGET/$f" ] && [ -f "$MUT/$f" ]; then
    FOUND=$((FOUND+1))
    DIFFLINES=$((DIFFLINES + $(diff "$TARGET/$f" "$MUT/$f" | wc -l | tr -d ' ')))
  fi
done
ge "$FOUND" 1 "$P mutated 副本中至少存在一个被注入的生产脚本"
ge "$DIFFLINES" 1 "$P pristine/mutated 差异行数（簿记守卫拆除非空操作）"

( cd "$REPO_ROOT" && CONTRIB_TEST_TARGET="$MUT" bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s9-p3.out" 2>&1
RC=$?
ne "$RC" 0 "$P 以簿记守卫拆除副本独立复跑套件竟然 exit 0"
{
  echo "--- detect(DETECT_KEEP=1) JSON: $DETJSON"
  echo "--- mutated 副本: $MUT  diff_lines=$DIFFLINES"
  echo "--- CONTRIB_TEST_TARGET=$MUT 重跑 exit=$RC（期望非 0）"
} >> "$ART/s9-p3.out"
echo "PASS $P（重跑 exit=$RC，diff=$DIFFLINES 行）"

echo "s9: ALL PASS（9.P1 9.P2 9.P3）"
exit 0
