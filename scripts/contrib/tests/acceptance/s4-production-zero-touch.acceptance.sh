#!/usr/bin/env bash
# =============================================================================
# s4-production-zero-touch.acceptance.sh — 场景 4：生产行为零改变
#   （生产数据零写入 / 外部命令零逃逸 / scripts/contrib 变更闭集 / 零新增脏项）
# 覆盖谓词：4.P1 4.P2 4.P3 4.P4（全部 det-machine）
# 依据：state.md `## 验收场景`（预注册 SSOT；4.P3 为调和后闭集版本）
# CONTRACT_AMBIGUOUS:
#  - 4.P1 冻结 driver 为 `find contrib-data -type f` 全量快照；设计文档另有
#    「排除 contrib-data/logs/ 高频子树 + mtime 竞速标 skipped」的套件内部纪律。
#    本验收按冻结 driver 从严执行（全量、零豁免、零 skip）；若红，先比对
#    launchd 生产写入时间窗再定性（launchd 小时级写 events.jsonl 属生产活动）。
#  - 4.P4 谓词语义取「套件运行后无**新增**脏项」：按 porcelain 前后快照 diff==0
#    求值——交付的验收文件本身位于 scripts/contrib/tests/acceptance/ 下，
#    QA 阶段若尚未 commit，静态存在的未跟踪项不属于套件造成的脏项。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s4-p{1,2,3,4}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
command -v shasum >/dev/null 2>&1 || die "env" "shasum 不可用"
[ -d "$REPO_ROOT/contrib-data" ] || die "env" "生产 contrib-data/ 不存在: $REPO_ROOT/contrib-data"
[ -f "$SUITE/run.sh" ] || die "env" "套件入口缺失: $SUITE/run.sh"

# 4.P4 前置：进入本文件前先抓 porcelain 基线（任何套件运行之前）
( cd "$REPO_ROOT" && git status --porcelain scripts/contrib </dev/null ) > "$ART/.s4-porcelain.before" 2>&1

# -----------------------------------------------------------------------------
# 4.P1 [det-machine] driver: find contrib-data -type f -exec shasum 前后对比
# assert: diff 行数==0（套件对生产数据零写入）
# -----------------------------------------------------------------------------
P="4.P1"
snap_contrib(){
  ( cd "$REPO_ROOT" && find contrib-data -type f -print0 | sort -z | xargs -0 shasum -a 256 )
}
snap_contrib > "$ART/.s4-snap.before" 2>&1
[ -s "$ART/.s4-snap.before" ] || die "$P" "快照为空（contrib-data 无文件或 shasum 失败）"

( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/.s4-run1.out" 2>&1
RC_RUN=$?

snap_contrib > "$ART/.s4-snap.after" 2>&1
diff "$ART/.s4-snap.before" "$ART/.s4-snap.after" > "$ART/s4-p1.out" 2>&1
DIFFN="$(wc -l < "$ART/s4-p1.out" | tr -d ' ')"
eq "$DIFFN" 0 "$P 生产 contrib-data 快照逐字节一致（diff 行数）——套件运行 rc=$RC_RUN"
# artifact 证据行：diff=0 时文件非空仍可判（快照文件数 + 判定结论）
echo "4.P1 snapshot diff_lines=0 PASS（前后快照各 $(wc -l < "$ART/.s4-snap.before" | tr -d ' ') 文件逐字节一致；套件 rc=${RC_RUN}）" >> "$ART/s4-p1.out"
echo "PASS ${P}（diff 行数=0；套件 rc=${RC_RUN}）"

# -----------------------------------------------------------------------------
# 4.P2 [det-machine] driver: tripwire 影子（hermes/gh/claude/tunnel/osascript 一律
#       exit 127 并记违规日志）+ PATH 预置 → 套件运行 → 违规日志行数==0
# assert: 行数==0（外部命令零逃逸；jq/python3/shellcheck/git/zsh 用真身不受影响）
# -----------------------------------------------------------------------------
P="4.P2"
TW="$(mktemp -d "${TMPDIR:-/tmp}/acc-s4-tripwire.XXXXXX")"
TWLOG="$TW/violations.log"; : > "$TWLOG"
for c in hermes gh claude tunnel osascript; do
  cat > "$TW/$c" <<TRIP
#!/bin/sh
printf '%s %s\n' "$c" "\$*" >> "$TWLOG"
echo "tripwire: escaped external command: $c \$*" >&2
exit 127
TRIP
  chmod +x "$TW/$c"
done
SAFE_PATH="$TW:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
( cd "$REPO_ROOT" && PATH="$SAFE_PATH" bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s4-p2.out" 2>&1
RC_TW=$?
VIOL="$(wc -l < "$TWLOG" | tr -d ' ')"
rm -rf "$TW"
eq "$VIOL" 0 "$P 外部命令逃逸次数（tripwire 日志行数；本轮套件 rc=${RC_TW}）"
echo "PASS ${P}（违规日志 0 行；套件 rc=$RC_TW 记录在 artifact）"

# -----------------------------------------------------------------------------
# 4.P3 [det-machine]（调和后）driver: git diff --name-only <merge-base>..HEAD -- scripts/contrib
# assert: 路径集合 ⊆ {7 个既有脚本} ∪ tests/ 前缀，集合外路径数==0
# 反 No-op：变更集必须非空，否则闭集断言空真（无意义）→ 判 FAIL
# -----------------------------------------------------------------------------
P="4.P3"
MB="$(git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null || true)"
# 直提 main 拓扑兜底：merge-base==HEAD 时 diff 恒空（闭集断言空真）——
# 回退到「首个触及 scripts/contrib 的提交」之父（=本任务交付的引入点），闭集语义不变
if [ -z "$MB" ] || [ -z "$(git -C "$REPO_ROOT" diff --name-only "$MB..HEAD" -- scripts/contrib 2>/dev/null)" ]; then
  FIRST="$(git -C "$REPO_ROOT" log --format=%H -- scripts/contrib 2>/dev/null | tail -1)"
  [ -n "$FIRST" ] || die "$P" "无法确定 scripts/contrib 的引入提交（仓库历史缺该路径）"
  MB="${FIRST%^}"
fi
( cd "$REPO_ROOT" && git diff --name-only "$MB..HEAD" -- scripts/contrib </dev/null ) >"$ART/.s4-p3.raw" 2>&1
OUTSIDE=0; TOTAL=0
OUTSIDE_LIST="$(mktemp "${TMPDIR:-/tmp}/acc-s4-p3.XXXXXX")"
# 注意：独立文件收集集合外路径，禁止向正在读取的 artifact 内追加（读回自吞）
while IFS= read -r f; do
  [ -n "$f" ] || continue
  TOTAL=$((TOTAL+1))
  case "$f" in
    scripts/contrib/tests/*) : ;;
    scripts/contrib/notify.sh|scripts/contrib/rq.sh|scripts/contrib/scan_gate.sh|\
scripts/contrib/deep_check_gate.sh|scripts/contrib/deep-check.sh|\
scripts/contrib/run-deepcheck.sh|scripts/contrib/run-watch.sh) : ;;
    *) OUTSIDE=$((OUTSIDE+1)); echo "OUTSIDE-SET: $f" >> "$OUTSIDE_LIST" ;;
  esac
done < "$ART/.s4-p3.raw"
{
  echo "--- merge-base=$MB 变更清单（$TOTAL 项）---"
  cat "$ART/.s4-p3.raw"
  echo "--- 集合外路径（$OUTSIDE 项）---"
  cat "$OUTSIDE_LIST"
} > "$ART/s4-p3.out"
rm -f "$OUTSIDE_LIST"
ge "$TOTAL" 1 "$P 变更集非空（merge-base=${MB}；为空=闭集断言空真，提交状态不对）"
eq "$OUTSIDE" 0 "$P 集合外路径数"
echo "PASS ${P}（变更 $TOTAL 项全部在闭集内；merge-base=${MB}）"

# -----------------------------------------------------------------------------
# 4.P4 [det-machine] driver: git status --porcelain scripts/contrib
# assert: 套件运行后相对运行前无新增脏项（porcelain 前后快照 diff 行数==0）
# -----------------------------------------------------------------------------
P="4.P4"
( cd "$REPO_ROOT" && git status --porcelain scripts/contrib </dev/null ) > "$ART/.s4-porcelain.after" 2>&1
diff "$ART/.s4-porcelain.before" "$ART/.s4-porcelain.after" > "$ART/s4-p4.out" 2>&1
PD="$(wc -l < "$ART/s4-p4.out" | tr -d ' ')"
eq "$PD" 0 "$P 套件运行前后 porcelain 新增脏项"
{
  echo "--- porcelain.before ---"; cat "$ART/.s4-porcelain.before"
  echo "--- porcelain.after  ---"; cat "$ART/.s4-porcelain.after"
} >> "$ART/s4-p4.out"
echo "PASS 4.P4（新增脏项=0）"

echo "s4: ALL PASS（4.P1 4.P2 4.P3 4.P4）"
exit 0
