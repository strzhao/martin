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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析——git rev-parse --show-toplevel 在 ${SELF_DIR} 无输出（非 git 仓库 / git 不可用）；本套件禁静默兜底到生产主 checkout" >&2
  exit 1
fi
SUITE="$REPO_ROOT/scripts/contrib/tests"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
command -v shasum >/dev/null 2>&1 || die "env" "shasum 不可用"
[ -x /usr/bin/diff ] || die "env" "缺 /usr/bin/diff（pin 绝对路径依赖前提；禁裸 diff——PATH 上第三方 diff 遮蔽系统 diff 会静默假绿）"
[ -d "$REPO_ROOT/contrib-data" ] || die "env" "生产 contrib-data/ 不存在: $REPO_ROOT/contrib-data"
[ -f "$SUITE/run.sh" ] || die "env" "套件入口缺失: $SUITE/run.sh"
[ -f "$SUITE/lib/write-attribution.sh" ] || die "env" "归属引擎缺失: $SUITE/lib/write-attribution.sh"
# 归属引擎（写入归属定性）：只读生产树；本文件不新增/不删除任何命令位 diff 调用点
# shellcheck source=/dev/null
source "$SUITE/lib/write-attribution.sh"

# 4.P4 前置：进入本文件前先抓 porcelain 基线（任何套件运行之前）
( cd "$REPO_ROOT" && git status --porcelain scripts/contrib </dev/null ) > "$ART/.s4-porcelain.before" 2>&1

# -----------------------------------------------------------------------------
# 4.P1 [det-machine] driver: find contrib-data -type f -exec shasum 前后对比
#   **冻结口径**（父卡 t_23b17603 钉死）：snap_contrib 定义与 `/usr/bin/diff` 调用点逐字保留
#   ——**追加**写入归属定性（卡 t_cbf34542）：富快照 + wa_classify，把「窗口内变更」机械拆成
#   套件写的（suite ⇒ 判红）/ 生产写手写的（external ⇒ 证据行 + PASS）/ 判据面外的（outside-surface ⇒ 证据行）。
# assert: ① 归属完整性（unclassified==0）② 归属对账恒等式（external+suite+outside==total）
#         ③ **核心**：suite==0（套件对生产 contrib-data 零写入）
#         ④ 条件保留：无外部/面外变更时仍断言 diff 行数==0（与改造前逐字节等价）
#         ⑤ 注入模式对照：canary-* ⇒ suite>0 必红；external-append|external-delete|wait-external ⇒ external>=1
# 注入/等待旋钮（env，默认空 = 纯生产态）：
#   S4_P1_INJECT=canary-create|canary-append|external-append|wait-external|canary-delete|external-delete
#   （S4_P1_WAIT_MAX 默认 150s）
#   删除类两值走**两段式**（plant 在快照前 / fire 在 run.sh 后）：窗口内「创建+删除」在前后快照里
#   双双不可见 ⇒ 单段式注入是空转形态（以为测了其实没测）。
# -----------------------------------------------------------------------------
P="4.P1"
WA_REG="$(wa_registry_default "$SUITE")" || die "$P" "归属清单不可解析（wa_registry_default 非零退出）"
[ -s "$WA_REG" ] || die "$P" "归属清单缺失或为空: ${WA_REG}（fail-closed，禁空集静默绿）"

# 注入/等待旋钮 + 注入证据账（`$ART/s4-p1.out` 稍后会被冻结口径的 diff 重定向截断，故先独立累计再并档）
S4_P1_INJECT="${S4_P1_INJECT:-}"
INJ_PATH=""
: > "$ART/.s4-p1-pre.out"
cleanup_inject(){ [ -n "${INJ_PATH}" ] && rm -f "$REPO_ROOT/${INJ_PATH}"; return 0; }
trap cleanup_inject EXIT

snap_contrib(){
  ( cd "$REPO_ROOT" && find contrib-data -type f -print0 | sort -z | xargs -0 shasum -a 256 )
}

# 删除类注入 plant（两段式①）：必须在冻结快照与富快照**之前**植入，否则删除在前后快照里不可见
case "$S4_P1_INJECT" in
  canary-delete) DEL_VAR="canary" ;;
  external-delete) DEL_VAR="external" ;;
  *) DEL_VAR="" ;;
esac
if [ -n "$DEL_VAR" ]; then
  INJ_LINE="$(wa_inject delete-plant "$REPO_ROOT" "$WA_REG" "$DEL_VAR")" || die "$P" "delete-plant 注入失败（variant=${DEL_VAR}）"
  printf '%s\n' "$INJ_LINE" >> "$ART/.s4-p1-pre.out"
  INJ_PATH="$(printf '%s' "$INJ_LINE" | sed -n 's/.* path=\([^ ]*\).*/\1/p')"
  [ -n "$INJ_PATH" ] || die "$P" "delete-plant 证据行未携带可解析 path（注入物无清理面）"
fi

snap_contrib > "$ART/.s4-snap.before" 2>&1
[ -s "$ART/.s4-snap.before" ] || die "$P" "快照为空（contrib-data 无文件或 shasum 失败）"

# 富快照（内容 + 元数据一次承载）+ 窗口时钟；注入为显式 opt-in（每次注入必落 WA-INJECT 证据行）
WIN_T0="$(date +%s)"
wa_snapshot "$REPO_ROOT" "$ART/.s4-wa.before" || die "$P" "富快照失败（contrib-data 缺失 / stat·find 失败）"
case "$S4_P1_INJECT" in
  canary-create|canary-append|external-append)
    INJ_LINE="$(wa_inject "$S4_P1_INJECT" "$REPO_ROOT" "$WA_REG")" || die "$P" "注入失败（mode=${S4_P1_INJECT}）"
    printf '%s\n' "$INJ_LINE" >> "$ART/.s4-p1-pre.out"
    # ⚠ 清理面**只限 canary-create 新建的注入物**：append 两模式的 `path=` 是注册日志本体，
    #   若一并 rm 会删掉整份生产日志（QA 抓出的 Critical，见 state.md 变更日志）。
    if [ "$S4_P1_INJECT" = "canary-create" ]; then
      INJ_PATH="$(printf '%s' "$INJ_LINE" | sed -n 's/.* path=\([^ ]*\).*/\1/p')"
    fi
    ;;
  wait-external|canary-delete|external-delete|'') : ;;
  *) die "$P" "未知 S4_P1_INJECT：${S4_P1_INJECT}（闭集 canary-create|canary-append|external-append|wait-external|canary-delete|external-delete）" ;;
esac

( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/.s4-run1.out" 2>&1
RC_RUN=$?

# wait-external：run.sh 后弹性轮询等**真实生产写手**落笔（只读轮询，不新增任何写面）
if [ "$S4_P1_INJECT" = "wait-external" ]; then
  WAIT_LINE="$(wa_wait_external "$REPO_ROOT" "$ART/.s4-wa.before" "${S4_P1_WAIT_MAX:-150}" 10)"
  WAIT_RC=$?
  printf '%s\n' "$WAIT_LINE" >> "$ART/.s4-p1-pre.out"
  if [ "$WAIT_RC" -gt 1 ]; then
    die "$P" "wait-external 依赖故障 rc=${WAIT_RC}（0=观察到变更 / 1=超时未变更 / 2=参数或快照非法）"
  fi
fi

# 删除类注入 fire（两段式②）：窗口**之内**真删，须在 run.sh 之后、窗口止之前
if [ -n "$DEL_VAR" ]; then
  FIRE_LINE="$(wa_inject delete-fire "$REPO_ROOT" "$WA_REG" "$INJ_PATH" "$DEL_VAR")" || die "$P" "delete-fire 注入失败（variant=${DEL_VAR}）"
  printf '%s\n' "$FIRE_LINE" >> "$ART/.s4-p1-pre.out"
fi
WIN_T1="$(date +%s)"

snap_contrib > "$ART/.s4-snap.after" 2>&1
/usr/bin/diff "$ART/.s4-snap.before" "$ART/.s4-snap.after" > "$ART/s4-p1.out" 2>&1
DIFFN="$(wc -l < "$ART/s4-p1.out" | tr -d ' ')"
wa_snapshot "$REPO_ROOT" "$ART/.s4-wa.after" || die "$P" "富快照失败（after）"
WA_SUM="$(wa_classify "$REPO_ROOT" "$ART/.s4-wa.before" "$ART/.s4-wa.after" "$WA_REG" "$ART/s4-p1-class.out" "$WIN_T0" "$WIN_T1")"
WA_RC=$?
[ "$WA_RC" -eq 0 ] || die "$P" "归属判定失败 rc=${WA_RC}（末行：${WA_SUM}）"
wa_key(){ printf '%s' "$WA_SUM" | tr ' ' '\n' | sed -n "s/^$1=\([0-9-]*\)$/\1/p" | head -n 1; }
WA_TOTAL="$(wa_key total)"
WA_EXTERNAL="$(wa_key external)"
WA_SUITE="$(wa_key suite)"
WA_OUTSIDE="$(wa_key outside)"
WA_UNCLASSIFIED="$(wa_key unclassified)"

# artifact 证据段（先落盘：canary 跑次会在下方判红提前退出，证据必须已在盘上）
# 冻结口径的原始 diff 已在 "$ART/s4-p1.out"（上方重定向），此处并档注入/等待行 + 归属段 + 计数
{
  cat "$ART/.s4-p1-pre.out"
  echo "4.P1 snapshot diff_lines=${DIFFN} files_changed=${WA_TOTAL} external=${WA_EXTERNAL} suite=${WA_SUITE} outside=${WA_OUTSIDE} unclassified=${WA_UNCLASSIFIED}（套件 rc=${RC_RUN}；窗口 ${WIN_T0}..${WIN_T1}；清单 ${WA_REG}；注入 ${S4_P1_INJECT:-none}）"
  cat "$ART/s4-p1-class.out"
  echo "4.P1 引擎末行：${WA_SUM}"
} >> "$ART/s4-p1.out"

# 注入模式对照（先于核心断言：canary 跑次按设计判红，语义在此显式化）
case "$S4_P1_INJECT" in
  canary-create|canary-append|canary-delete)
    ne "$WA_SUITE" 0 "$P 注入模式对照（${S4_P1_INJECT}）：套件写入必须被判红（suite 计数）"
    die "$P" "金丝雀自证：套件写入已被归属引擎捕获（suite=${WA_SUITE}；注入 ${INJ_PATH}）——canary 跑次按设计判红，ACCEPTANCE-FAIL 属预期结论"
    ;;
  external-append|wait-external|external-delete)
    ge "$WA_EXTERNAL" 1 "$P 注入模式对照（${S4_P1_INJECT}）：生产侧写入必须归 external"
    ;;
esac

eq "$WA_UNCLASSIFIED" 0 "$P 归属完整性：每个变更文件都被归类（unclassified）"
eq "$((WA_EXTERNAL + WA_SUITE + WA_OUTSIDE))" "$WA_TOTAL" "$P 归属对账恒等式（external+suite+outside == total）"
eq "$WA_SUITE" 0 "$P 套件对生产 contrib-data 零写入（归属判定 suite 计数）——套件 rc=$RC_RUN"
if [ "$WA_EXTERNAL" -eq 0 ] && [ "$WA_OUTSIDE" -eq 0 ]; then
  eq "$DIFFN" 0 "$P 生产 contrib-data 快照逐字节一致（冻结口径原样：无外部/面外变更时 diff 行数）——套件运行 rc=$RC_RUN"
fi
echo "PASS ${P}（归属判定 suite=0；变更 ${WA_TOTAL} 项（external=${WA_EXTERNAL} outside=${WA_OUTSIDE}）；diff 行数=${DIFFN}；套件 rc=${RC_RUN}）"

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
/usr/bin/diff "$ART/.s4-porcelain.before" "$ART/.s4-porcelain.after" > "$ART/s4-p4.out" 2>&1
PD="$(wc -l < "$ART/s4-p4.out" | tr -d ' ')"
eq "$PD" 0 "$P 套件运行前后 porcelain 新增脏项"
{
  echo "--- porcelain.before ---"; cat "$ART/.s4-porcelain.before"
  echo "--- porcelain.after  ---"; cat "$ART/.s4-porcelain.after"
} >> "$ART/s4-p4.out"
echo "PASS 4.P4（新增脏项=0）"

echo "s4: ALL PASS（4.P1 4.P2 4.P3 4.P4）"
exit 0
