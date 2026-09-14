#!/bin/bash
# =============================================================================
# unit/write-attribution.sh — 归属引擎规则单测（卡 t_cbf34542；四维套件 unit 维度）
#
# 覆盖（契约「reason 覆盖矩阵」逐条落地 + 第 2 轮重审新增元素）：
#   C1  registered-append-ok        C2  alphabet-violation      C3  not-append-only
#   C4  inode-changed               C5  混合块无块级容错        C6  created-unallowed
#   C7  deleted                     C8  empty-append           C9  时间戳窗口（边界 +120s / 反例 +121s）
#   C10 no-corroboration            C11 corroborated-ok        C12 outside-surface
#   C13/C14/C15 exit 2 fail-closed（清单缺失/空/结构非法/依赖缺失/窗口非整数）
#   C16 覆盖守卫（源码派生写点 ⊆ 清单模式 + 声明式排除谓词 E1/E2/E3 + mutation kill）
#   C17 canary-marker（marker 无条件短路，先于佐证判定）
#   C18 时序近邻（|佐证 ts − 变更文件 mtime| ≤ 30s 为主修）
#   C19/C20 mutation 自证（「一律 external」/「未注册也放行」⇒ 自证转红）
#   C21 wa_selftest 全形态      C22 wa_inject 三模式        C23 wa_wait_external 三态
#   C24 wa_snapshot fail-closed C25 wa_registry_default 覆盖与 fail-closed
#   C26-C35 删除类归属（corroborated-delete）：正例 / 无佐证 / Δt 30s·31s 边界 / marker 路径短路 /
#     锚 fail-closed 三态 / 注入两段式（空转防护 + 自证 rc=2）/ mutation 抗性 / worker 实测三件复现锚 /
#     面外 D 两态 / 混合窗口等值恒等式
#   C36-C40 删除类跨窗所有权链（D-α，D-β 近邻不成立时的第二依据）：R4 生产形态正例（同 stem 四件 ×
#     两个 <TS>）/ 有所有权但写手本窗静默 / 窗口内追加的具名记录不构成所有权（回填旧 ts · 当前 ts 两态）/
#     stem 长度边界 / 混合窗口等值恒等式扩展（D-α 行计入 external）
#
# 纪律：合成树自建（mktemp -d），**不依赖真实 contrib-data**；断言只增不减；无 skip/warn 降级。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
export DIM=unit
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$TESTS_ROOT/lib/assert.sh"
# shellcheck source=/dev/null
source "$TESTS_ROOT/lib/write-attribution.sh"

t_init "$T_FILE"

WA_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wa-unit.XXXXXX")" || {
  echo "UNIT-FAIL[env]: mktemp 失败（无临时工作区，禁静默放行）" >&2
  exit 1
}
trap 'rm -rf "$WA_TMP"' EXIT

t_case "C0 前置：清单可解析（默认路径 / 11 条 / 四模式齐备）"
WA_REG_RC=0
WA_DEF_REG="$(wa_registry_default "$TESTS_ROOT")" || WA_REG_RC=$?
assert_exit "0" "$WA_REG_RC" "C0 wa_registry_default rc=0"
assert_ne "$WA_DEF_REG" "" "C0 wa_registry_default 输出清单路径"
assert_eq "$(basename "$WA_DEF_REG")" "production-writers.tsv" "C0 清单文件名"
WA_LOAD_RC=0
wa__registry_load "$WA_DEF_REG" || WA_LOAD_RC=$?
assert_exit "0" "$WA_LOAD_RC" "C0 清单解析 rc=0"
assert_eq "$WA_R_N" "11" "C0 清单条目数=11（+pending/* 删除面）"
NW_APPEND=0; NW_RW=0; NW_CR=0; NW_DEL=0
for ((i = 0; i < WA_R_N; i++)); do
  case "${WA_R_MODE[$i]}" in
    append-records) NW_APPEND=$((NW_APPEND + 1)) ;;
    corroborated-rewrite) NW_RW=$((NW_RW + 1)) ;;
    corroborated-create) NW_CR=$((NW_CR + 1)) ;;
    corroborated-delete) NW_DEL=$((NW_DEL + 1)) ;;
  esac
done
assert_eq "$NW_APPEND" "4" "C0 append-records 条目=4（collect/notify/execute/l2-ledger）"
assert_eq "$NW_RW" "5" "C0 corroborated-rewrite 条目=5"
assert_eq "$NW_CR" "1" "C0 corroborated-create 条目=1（pending/*）"
assert_eq "$NW_DEL" "1" "C0 corroborated-delete 条目=1（pending/* 删除面）"
assert_eq "$((NW_APPEND + NW_RW + NW_CR + NW_DEL))" "11" "C0 四模式计数之和=11（防未知 mode 静默漏计）"

# -----------------------------------------------------------------------------
# 合成树（全部用例共用；不触碰真实 contrib-data）
# -----------------------------------------------------------------------------
WT="$WA_TMP/tree"
mk_tree() {
  rm -rf "$WT"
  mkdir -p "$WT/repo/contrib-data/logs" "$WT/repo/contrib-data/pending" "$WT/repo/contrib-data/scratch"
  printf 'contrib-data/logs/collect.log\tcollect\tappend-records\t%s\t:none\n' "$WA_ALPHA_C" > "$WT/registry.tsv"
  printf 'contrib-data/logs/notify.log\tnotify\tappend-records\t%s\t:none\n' "$WA_ALPHA_N" >> "$WT/registry.tsv"
  printf 'contrib-data/logs/execute.log\texecute\tappend-records\t%s\t:none\n' "$WA_ALPHA_C" >> "$WT/registry.tsv"
  printf 'contrib-data/state.json\tnotify\tcorroborated-rewrite\t:none\tcontrib-data/logs/notify.log\n' >> "$WT/registry.tsv"
  printf 'contrib-data/pending/*\tnotify\tcorroborated-create\t:none\tcontrib-data/logs/notify.log\n' >> "$WT/registry.tsv"
  # 删除面在后（C/M 仍取首个匹配行 ⇒ create 行语义不变；D 只认本行）
  printf 'contrib-data/pending/*\tnotify\tcorroborated-delete\t:none\tcontrib-data/logs/notify.log\n' >> "$WT/registry.tsv"
  : > "$WT/repo/contrib-data/logs/collect.log"
  : > "$WT/repo/contrib-data/logs/notify.log"
  printf '{"state":"seed"}\n' > "$WT/repo/contrib-data/state.json"
  printf 'seed\n' > "$WT/repo/contrib-data/scratch/note.md"
}
WA_ALPHA_C='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] collect: |^OK$'
WA_ALPHA_N='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] notify: |^OK$'
mk_tree
WT_REG="$WT/registry.tsv"
WA_NOW="$(date +%s)"
WA_T0=$((WA_NOW - 1))
WA_T1=$((WA_NOW + 1))
WA_CLS_NOW="$(date -r "$WA_NOW" +'%Y-%m-%d %H:%M:%S')"
WA_CLS_HI="$(date -r $((WA_T1 + WA_WINDOW_SLACK)) +'%Y-%m-%d %H:%M:%S')"
WA_CLS_OVER="$(date -r $((WA_T1 + WA_WINDOW_SLACK + 1)) +'%Y-%m-%d %H:%M:%S')"

snap_before() { wa_snapshot "$WT/repo" "$WT/before"; }
assert_ge() { # <actual> <下界> [label]（assert.sh 无此形态；计数下界断言用，防 no-op 派生面）
  case "${1:-}" in
    ''|*[!0-9]*) _fail "${3:-}" "非数值 [$1]（期望 >= ${2}）"; return 0 ;;
  esac
  if [ "$1" -ge "$2" ]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual=[$1] < 期望下界=[$2]"
  fi
}
snap_after() { wa_snapshot "$WT/repo" "$WT/after"; }
# wa_sum：最近一次 wa_classify 的末行计数（供计数断言复用）
WA_SUM=""
WA_LAST_OUT="$WT/class.out"
run_classify() { # [registry] [t0] [t1] → stdout 末行；rc 透传
  local reg="${1:-$WT_REG}" t0="${2:-$WA_T0}" t1="${3:-$WA_T1}"
  WA_LAST_OUT="$WT/class.out"
  WA_SUM="$(wa_classify "$WT/repo" "$WT/before" "$WT/after" "$reg" "$WA_LAST_OUT" "$t0" "$t1")"
}
sum_key() { # <键名> → 计数行该键的值（按空格切词后精确匹配 key=value，total 亦适用）
  printf '%s' "$WA_SUM" | tr ' ' '\n' | sed -n "s/^$1=\([0-9-]*\)$/\1/p" | head -n 1
}
cls_line() { grep -m1 '^WA-CLASS ' "$WA_LAST_OUT" 2>/dev/null; }
cls_of() { cls_line | sed -n 's/^WA-CLASS \([^ ]*\) .*/\1/p'; }
reason_of() { cls_line | sed -n 's/.* reason=\([^ ]*\).*/\1/p'; }
cls_count() { wc -l < "$WA_LAST_OUT" | tr -d ' '; }
# 路径定位版（多行窗口下按 path 精确取行；` path=<p> ` 两边界定，防前缀撞名）
cls_line_path() { grep -F -m1 " path=$1 " "$WA_LAST_OUT" 2>/dev/null; }
cls_of_path() { cls_line_path "$1" | sed -n 's/^WA-CLASS \([^ ]*\) .*/\1/p'; }
reason_of_path() { cls_line_path "$1" | sed -n 's/.* reason=\([^ ]*\).*/\1/p'; }

# =============================================================================
t_case "C1 registered-append-ok：注册路径在窗合规追加 ⇒ external"
snap_before
printf '[%s] collect: 合规追加\n' "$WA_CLS_NOW" >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_exit "0" "$?" "C1 wa_classify rc=0"
assert_eq "$(cls_of)" "external" "C1 类别"
assert_eq "$(reason_of)" "registered-append-ok" "C1 reason"
assert_contains "$(cls_line)" "writer=collect" "C1 evidence 含 writer"
assert_contains "$(cls_line)" "records=1" "C1 evidence 含 records"
assert_eq "$(sum_key diff_lines)" "4" "C1 diff 行数（追加 1 行 = 4 行 diff 上下文）"
assert_eq "$(sum_key unclassified)" "0" "C1 unclassified=0"

# =============================================================================
t_case "C2 alphabet-violation：注册路径追加字母表外行 ⇒ suite"
snap_before
printf 'SUITE-LEAK-NOT-A-REGISTERED-SHAPE\n' >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C2 类别"
assert_eq "$(reason_of)" "alphabet-violation" "C2 reason"
assert_eq "$(sum_key suite)" "1" "C2 suite 计数=1"

# =============================================================================
t_case "C3 not-append-only：原地重写（同 inode，前缀不匹配）⇒ suite"
snap_before
printf '[%s] collect: 原地重写\n' "$WA_CLS_NOW" > "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C3 类别"
assert_eq "$(reason_of)" "not-append-only" "C3 reason"

# =============================================================================
t_case "C4 inode-changed：mv 替换式重写（inode 变更）⇒ suite"
snap_before
printf '[%s] collect: mv 整替\n' "$WA_CLS_NOW" > "$WT/repo/contrib-data/logs/collect.log.tmp"
mv "$WT/repo/contrib-data/logs/collect.log.tmp" "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C4 类别"
assert_eq "$(reason_of)" "inode-changed" "C4 reason"

# =============================================================================
t_case "C5 混合块无块级容错：合规行 + 套件行同块 ⇒ suite（套件写入不被生产写入掩蔽）"
snap_before
{
  printf '[%s] collect: 同块合规行\n' "$WA_CLS_NOW"
  printf 'SUITE-LEAK-IN-SAME-BLOCK\n'
} >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C5 类别"
assert_eq "$(reason_of)" "alphabet-violation" "C5 reason（块内任一行越界即违规）"

# =============================================================================
t_case "C6 created-unallowed：append-records 面内新建 ⇒ suite"
snap_before
printf '[%s] execute: 首建\n' "$WA_CLS_NOW" > "$WT/repo/contrib-data/logs/execute.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C6 类别"
assert_eq "$(reason_of)" "created-unallowed" "C6 reason"

# =============================================================================
t_case "C7 deleted：面内路径被删 ⇒ suite（且不中止后续断言）"
snap_before
rm -f "$WT/repo/contrib-data/state.json"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C7 类别"
assert_eq "$(reason_of)" "deleted" "C7 reason"
assert_eq "$(sum_key total)" "1" "C7 total=1"

# =============================================================================
t_case "C8 empty-append：仅追加换行（零字节记录）⇒ suite"
snap_before
printf '\n' >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C8 类别"
assert_eq "$(reason_of)" "empty-append" "C8 reason"

# =============================================================================
t_case "C9 时序窗口边界：+120s 判 external / +121s 判 suite"
snap_before
printf '[%s] collect: 边界同窗\n' "$WA_CLS_HI" >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "external" "C9 边界（恰 window_end+120s）⇒ external"
assert_eq "$(reason_of)" "registered-append-ok" "C9 边界 reason"
snap_before
printf '[%s] collect: 越界\n' "$WA_CLS_OVER" >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C9 反例（window_end+121s）⇒ suite"
assert_eq "$(reason_of)" "timestamp-out-of-window" "C9 反例 reason"

# =============================================================================
t_case "C10 no-corroboration：corroborated-create 面新建但佐证日志无在窗记录 ⇒ suite"
snap_before
printf '{"pending":1}\n' > "$WT/repo/contrib-data/pending/n1.json"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C10 类别"
assert_eq "$(reason_of)" "no-corroboration" "C10 reason"
assert_contains "$(cls_line)" "Δt=none" "C10 失败态 evidence 带 Δt（无在窗记录 ⇒ none）"
assert_contains "$(cls_line)" "ts=none" "C10 失败态 evidence 带 ts（无在窗记录 ⇒ none）"

# =============================================================================
t_case "C11 corroborated-ok：佐证日志在窗且与 mtime 近邻 ⇒ external"
printf '[%s] notify: 佐证落笔（近邻）\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
snap_before
printf '{"pending":2}\n' > "$WT/repo/contrib-data/pending/n2.json"
snap_after
run_classify
assert_eq "$(cls_of)" "external" "C11 类别"
assert_eq "$(reason_of)" "corroborated-ok" "C11 reason"
assert_contains "$(cls_line)" "Δt=" "C11 evidence 含 Δt"

# =============================================================================
t_case "C12 outside-surface：判据面外路径变更 ⇒ outside-surface（证据行，不判失败）"
snap_before
printf 'outside change\n' > "$WT/repo/contrib-data/scratch/note.md"
snap_after
run_classify
assert_eq "$(cls_of)" "outside-surface" "C12 类别"
assert_eq "$(reason_of)" "outside-surface" "C12 reason"
assert_eq "$(sum_key outside)" "1" "C12 outside 计数键存在且=1"
assert_eq "$(sum_key suite)" "0" "C12 面外变更不判红"

# =============================================================================
t_case "C13 exit 2：清单缺失 ⇒ fail-closed（禁回退默认清单）"
snap_before
snap_after
MISSING_REG="$WA_TMP/no-such-registry.tsv"
run_classify "$MISSING_REG"
assert_exit "2" "$?" "C13 清单缺失 rc=2"
# 空路径不经 run_classify（其默认值语义会把空串当缺省），显式直调以验证「空 registry 参数」路径
WA_LAST_OUT="$WT/class.out"
WA_SUM="$(wa_classify "$WT/repo" "$WT/before" "$WT/after" "" "$WA_LAST_OUT" "$WA_T0" "$WA_T1" 2>/dev/null)"
assert_exit "2" "$?" "C13 空路径 rc=2"

# =============================================================================
t_case "C14 exit 2：清单为空文件 ⇒ fail-closed（禁空集静默绿）"
: > "$WA_TMP/empty-registry.tsv"
snap_before
snap_after
run_classify "$WA_TMP/empty-registry.tsv"
assert_exit "2" "$?" "C14 空清单 rc=2"

# =============================================================================
t_case "C15 exit 2：结构非法 / 无捕获组 / 依赖缺失 / 窗口非整数"
printf 'contrib-data/x.log\tw\tappend-records\t^foo\n' > "$WA_TMP/bad-nf.tsv"
snap_before
snap_after
run_classify "$WA_TMP/bad-nf.tsv"
assert_exit "2" "$?" "C15 字段数=4 rc=2"
printf 'contrib-data/x.log\tw\tappend-records\t^nogroup$\t:none\n' > "$WA_TMP/bad-grp.tsv"
run_classify "$WA_TMP/bad-grp.tsv"
assert_exit "2" "$?" "C15 字母表无捕获组 rc=2"
printf 'contrib-data/x.log\tw\tbogus-mode\t^X$\t:none\n' > "$WA_TMP/bad-mode.tsv"
run_classify "$WA_TMP/bad-mode.tsv"
assert_exit "2" "$?" "C15 mode 越出闭集 rc=2"
printf 'contrib-data/x.json\tw\tcorroborated-rewrite\t:none\t:none\n' > "$WA_TMP/bad-corr.tsv"
run_classify "$WA_TMP/bad-corr.tsv"
assert_exit "2" "$?" "C15 corroborated-* 佐证为 :none rc=2"
WA_SAVE_DIFF="$WA_DEP_DIFF"
WA_DEP_DIFF="$WA_TMP/no-such-diff"
run_classify "$WT_REG"
assert_exit "2" "$?" "C15 依赖缺失（diff 不可执行）rc=2"
WA_DEP_DIFF="$WA_SAVE_DIFF"
run_classify "$WT_REG" "notanint" "$WA_T1"
assert_exit "2" "$?" "C15 窗口参数非整数 rc=2"

# =============================================================================
# 覆盖守卫（C16）：源码派生写点 ⊆ 清单模式
# -----------------------------------------------------------------------------
# 派生面：清单 writer 列反查到的写手脚本（清单条目路径的 basename 在 scripts/{contrib,approval}
#   /*.sh 中命中）∪ 这些脚本的字面调用者（一层）。
# 写点：脚本内 `$CONTRIB/…` / `${CONTRIB}/…` / `$CONTRIB_DATA_DIR/…` 字面量（经一层以上变量
#   解析：赋值链按变量名长度降序代入，防 `$LOG` 吃掉 `$LOG_DIR` 前缀），归一为 contrib-data 相对后缀。
# 三条**声明式排除谓词**（判据面边界，非宽容）：
#   E1 瞬时槽位：basename 以 `.` 开头，或含 `.tmp` / `.new`
#      —— 反例即「一次调用内自建自删」的槽位（`.rq-item.tmp` / `$flight.tmp` / `.hermes-down`），
#         其生命周期终结由生产者 `rm` 显式表达，不属生产数据面。
#   E2 运行期产物：路径含 `/runs/` 段
#      —— 一次性卡产物（deep-check verdict / BRANCH.md），非账本数据。
#   E3 判据面外数据文件（显式短名单 + 逐条理由）：`logs/sentinel.log`（独立 plist 写手；本机 `ts`
#      命令缺失 ⇒ 实际形态不可测，append-records 会假红）、`inventory.json`（forge 流水线）、
#      `goods-metrics.json`（auto-gate）、`kanban-flight-digest.json`（notify 会 `rm` 的飞行槽位）、
#      `logs/launchd*.log`（launchd 直写，无脚本写手）。
# 残余缺口（如实披露）：新增**独立**写手脚本（不在清单 writer 列、也未被清单写手调用，例如新装
#   plist 的脚本）不被派生面覆盖 ⇒ 需人工带理由扩 E3 名单或清单（每次扩展都是显式动作）。
wa_guard_diff() { # <contrib_dir> <approval_dir> <registry> <out_file> → 0 / 2；差集写 <out_file>
  local cdir="$1" adir="$2" reg="$3" outp="$4"
  wa__registry_load "$reg" || return 2
  local live="" callees="" pat="" seg="" f="" d="" c="" s=""
  local i=0
  for ((i = 0; i < WA_R_N; i++)); do
    pat="${WA_R_PAT[$i]}"
    seg="${pat##*/}"
    if [ "$seg" = "*" ]; then seg="${pat%/*}"; seg="${seg##*/}"; fi
    for d in "$cdir" "$adir"; do
      for f in "$d"/*.sh; do
        [ -e "$f" ] || continue
        grep -q -- "/${seg}" "$f" 2>/dev/null && live="$live$f
"
      done
    done
  done
  live="$(printf '%s' "$live" | sort -u | sed '/^$/d')"
  for f in $live; do
    for s in $(grep -oE 'scripts/(contrib|approval)/[a-z0-9_.-]+\.sh' "$f" 2>/dev/null | sed 's|.*/||' | sort -u); do
      for d in "$cdir" "$adir"; do
        [ -f "$d/$s" ] && callees="$callees$d/$s
"
      done
    done
  done
  callees="$(printf '%s' "$callees" | sort -u | sed '/^$/d')"
  local cand_file="$WA_TMP/guard.cands"
  : > "$cand_file"
  for f in $live $callees; do
    wa_guard_candidates "$f" "$cand_file"
  done
  local cands="" hit=""
  cands="$(sort -u "$cand_file" | sed '/^$/d')"
  : > "$outp"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    hit=""
    for ((i = 0; i < WA_R_N; i++)); do
      # shellcheck disable=SC2254
      case "$c" in ${WA_R_PAT[$i]}) hit=1; break ;; esac
    done
    [ -n "$hit" ] || printf '%s\n' "$c" >> "$outp"
  done < <(printf '%s\n' "$cands")
  WA_G_N_CAND="$(printf '%s\n' "$cands" | sed '/^$/d' | wc -l | tr -d ' ')"
  WA_G_N_LIVE="$(printf '%s\n' "$live" | sed '/^$/d' | wc -l | tr -d ' ')"
  WA_G_N_CALLEE="$(printf '%s\n' "$callees" | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'WA-GUARD candidates=%s uncovered=%s live=%s callees=%s e1=%s e2=%s e3=%s\n' \
    "$WA_G_N_CAND" "$(sed '/^$/d' "$outp" | wc -l | tr -d ' ')" "$WA_G_N_LIVE" "$WA_G_N_CALLEE" \
    "$(grep -c '^E1$' "$WA_G_CNT_FILE" 2>/dev/null || printf 0)" \
    "$(grep -c '^E2$' "$WA_G_CNT_FILE" 2>/dev/null || printf 0)" \
    "$(grep -c '^E3$' "$WA_G_CNT_FILE" 2>/dev/null || printf 0)" >&2
  return 0
}

wa_guard_candidates() { # <脚本> <输出文件>：追加该脚本的判据面候选；E1/E2/E3 命中追加到 WA_G_CNT_FILE
  local f="$1" outp="$2" raw="" m="" suffix="" last=""
  raw="$(awk '
    { raw[NR] = $0 }
    END {
      nv = 0
      for (pass = 1; pass <= 5; pass++) {
        for (i = 1; i <= NR; i++) {
          line = raw[i]
          if (line !~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/) continue
          sub(/^[ \t]*/, "", line)
          eq = index(line, "=")
          name = substr(line, 1, eq - 1)
          val = substr(line, eq + 1)
          sub(/^"/, "", val); sub(/"$/, "", val)
          sub(/^'\''/, "", val); sub(/'\''$/, "", val)
          if (name in known) continue
          for (k = 1; k <= nv; k++) ord[k] = k
          for (k = 1; k <= nv; k++)
            for (m2 = k + 1; m2 <= nv; m2++)
              if (length(vars[ord[m2]]) > length(vars[ord[k]])) { t2 = ord[k]; ord[k] = ord[m2]; ord[m2] = t2 }
          for (k = 1; k <= nv; k++) {
            gsub("[$][{]" vars[ord[k]] "[}]", vals[ord[k]], val)
            gsub("[$]" vars[ord[k]], vals[ord[k]], val)
          }
          if (val ~ /[$]CONTRIB/ || val ~ /[$]CONTRIB_DATA_DIR/) {
            nv++; vars[nv] = name; vals[nv] = val; known[name] = 1
          }
        }
      }
      for (i = 1; i <= NR; i++) txt = txt raw[i] "\n"
      for (k = 1; k <= nv; k++) ord2[k] = k
      for (k = 1; k <= nv; k++)
        for (m2 = k + 1; m2 <= nv; m2++)
          if (length(vars[ord2[m2]]) > length(vars[ord2[k]])) { t2 = ord2[k]; ord2[k] = ord2[m2]; ord2[m2] = t2 }
      for (k = 1; k <= nv; k++) {
        gsub("[$][{]" vars[ord2[k]] "[}]", vals[ord2[k]], txt)
        gsub("[$]" vars[ord2[k]], vals[ord2[k]], txt)
      }
      while (match(txt, /[$][{]?CONTRIB(_DATA_DIR)?[}]?\/[A-Za-z0-9_.\/${}*-]+/)) {
        print substr(txt, RSTART, RLENGTH)
        txt = substr(txt, RSTART + RLENGTH)
      }
    }' "$f" | sort -u)"
  for m in $raw; do
    suffix="$(printf '%s' "$m" | sed 's/^[$][{]\{0,1\}CONTRIB\(_DATA_DIR\)\{0,1\}[}]\{0,1\}\///')"
    suffix="$(printf '%s' "$suffix" | sed -E 's/[$][{][^}]*[}]/*/g; s/[$][A-Za-z_][A-Za-z0-9_]*/*/g')"
    [ -n "$suffix" ] || continue
    last="${suffix##*/}"
    case "$last" in
      *.*) : ;;
      *) continue ;;
    esac
    case "$suffix" in
      .*|*/.*|*.tmp*|*.new*) printf 'E1\n' >> "$WA_G_CNT_FILE"; continue ;;
      runs/*|*/runs/*) printf 'E2\n' >> "$WA_G_CNT_FILE"; continue ;;
    esac
    case "contrib-data/$suffix" in
      contrib-data/logs/sentinel.log|contrib-data/inventory.json|contrib-data/goods-metrics.json|contrib-data/kanban-flight-digest.json|contrib-data/logs/launchd*.log)
        printf 'E3\n' >> "$WA_G_CNT_FILE"
        continue
        ;;
    esac
    printf '%s\n' "contrib-data/$suffix" >> "$outp"
  done
}

t_case "C16a 覆盖守卫：源码派生写点 ⊆ 清单模式（差集为空）"
WA_G_CNT_FILE="$WA_TMP/guard.cnt"
: > "$WA_G_CNT_FILE"
WA_G_N_CAND=0; WA_G_N_LIVE=0; WA_G_N_CALLEE=0
GUARD_RC=0
wa_guard_diff "$REPO_ROOT/scripts/contrib" "$REPO_ROOT/scripts/approval" "$WA_DEF_REG" "$WA_TMP/guard.diff" 2>"$WA_TMP/guard.err" || GUARD_RC=$?
assert_exit "0" "$GUARD_RC" "C16a 守卫运行 rc=0"
assert_eq "$(<"$WA_TMP/guard.diff")" "" "C16a 差集为空（派生写点全部被清单覆盖）"
assert_ge "$WA_G_N_CAND" "13" "C16a 派生候选数 >=13（防 no-op 派生面；下界而非等值：新增已注册写点不应误报）"
assert_ge "$(grep -c '^E1$' "$WA_G_CNT_FILE")" "1" "C16a E1 瞬时槽位谓词命中 >=1（.rq-item.tmp / ready-queue.json.tmp / budget.json.tmp）"
assert_ge "$(grep -c '^E2$' "$WA_G_CNT_FILE")" "1" "C16a E2 运行期产物谓词命中 >=1（runs/deep-check/**）"
assert_ge "$(grep -c '^E3$' "$WA_G_CNT_FILE")" "1" "C16a E3 面外数据文件谓词命中 >=1（goods-metrics.json / kanban-flight-digest.json）"
assert_ge "$WA_G_N_LIVE" "5" "C16a 反查到的写手脚本 >=5（清单 writer 列 → 源码命中）"
assert_file_contains "$WA_TMP/guard.err" "WA-GUARD candidates=13" "C16a 守卫计数行落 stderr（可审计）"

t_case "C16b 覆盖守卫 mutation kill：删清单一行 ⇒ 差集非空（必红）"
grep -v '^contrib-data/logs/approval-collect.log' "$WA_DEF_REG" > "$WA_TMP/reg-minus-one.tsv"
assert_ne "$(wc -l < "$WA_TMP/reg-minus-one.tsv" | tr -d ' ')" "$(wc -l < "$WA_DEF_REG" | tr -d ' ')" "C16b 变体清单确少一行"
: > "$WA_G_CNT_FILE"
wa_guard_diff "$REPO_ROOT/scripts/contrib" "$REPO_ROOT/scripts/approval" "$WA_TMP/reg-minus-one.tsv" "$WA_TMP/guard-b.diff" 2>/dev/null
assert_contains "$(<"$WA_TMP/guard-b.diff")" "contrib-data/logs/approval-collect.log" "C16b 删行后该路径成未覆盖候选（守卫可被 kill）"

t_case "C16c 覆盖守卫 mutation kill：往写手脚本注入新写点 ⇒ 差集非空（必红）"
MUTDIR="$WA_TMP/mut"
rm -rf "$MUTDIR"
mkdir -p "$MUTDIR/contrib" "$MUTDIR/approval"
cp "$REPO_ROOT"/scripts/contrib/*.sh "$MUTDIR/contrib/" 2>/dev/null
cp "$REPO_ROOT"/scripts/approval/*.sh "$MUTDIR/approval/" 2>/dev/null
printf '%s\n' 'printf "%s\n" injected >> "$CONTRIB/leaked-artifact.json"' >> "$MUTDIR/contrib/notify.sh"
: > "$WA_G_CNT_FILE"
wa_guard_diff "$MUTDIR/contrib" "$MUTDIR/approval" "$WA_DEF_REG" "$WA_TMP/guard-c.diff" 2>/dev/null
assert_contains "$(<"$WA_TMP/guard-c.diff")" "contrib-data/leaked-artifact.json" "C16c 注入写点成为未覆盖候选（守卫可被 kill）"

t_case "C16d 覆盖守卫未 mutate 对照：同一副本目录（未注入）差集仍空"
rm -rf "$MUTDIR/clean"
mkdir -p "$MUTDIR/clean/contrib" "$MUTDIR/clean/approval"
cp "$REPO_ROOT"/scripts/contrib/*.sh "$MUTDIR/clean/contrib/" 2>/dev/null
cp "$REPO_ROOT"/scripts/approval/*.sh "$MUTDIR/clean/approval/" 2>/dev/null
: > "$WA_G_CNT_FILE"
wa_guard_diff "$MUTDIR/clean/contrib" "$MUTDIR/clean/approval" "$WA_DEF_REG" "$WA_TMP/guard-d.diff" 2>/dev/null
assert_eq "$(<"$WA_TMP/guard-d.diff")" "" "C16d 未注入副本差集为空（排除「副本目录本身致红」假阳）"

# =============================================================================
t_case "C17 canary-marker：S4-P1- 前缀行无条件短路（先于形态/佐证判定）"
snap_before
printf '%sAPPEND epoch=0\n' "$WA_MARKER_PREFIX" >> "$WT/repo/contrib-data/logs/collect.log"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C17 追加 marker ⇒ suite"
assert_eq "$(reason_of)" "canary-marker" "C17 追加 marker reason"
printf '[%s] notify: 近邻佐证\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
snap_before
printf '%smode=canary-create epoch=0\n' "$WA_MARKER_PREFIX" > "$WT/repo/contrib-data/pending/canary.json"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C17 marker 文件（有佐证）仍判 suite"
assert_eq "$(reason_of)" "canary-marker" "C17 marker 短路先于佐证判定"

# =============================================================================
t_case "C18 时序近邻主修：佐证记录在窗但距 mtime >30s ⇒ 不成立（no-corroboration）"
WA_FAR_TS="$(date -r $((WA_NOW + 90)) +'%Y-%m-%d %H:%M:%S')"
: > "$WT/repo/contrib-data/logs/notify.log"
printf '[%s] notify: 远邻佐证\n' "$WA_FAR_TS" >> "$WT/repo/contrib-data/logs/notify.log"
snap_before
printf '{"pending":3}\n' > "$WT/repo/contrib-data/pending/n3.json"
snap_after
run_classify
assert_eq "$(cls_of)" "suite" "C18 远邻佐证 ⇒ suite"
assert_eq "$(reason_of)" "no-corroboration" "C18 reason"
assert_contains "$(cls_line)" "Δt=" "C18 失败态 evidence 带 Δt（可算则给差值）"
assert_not_contains "$(cls_line)" "Δt=none" "C18 失败态 Δt 非 none（存在在窗记录，只是超出近邻）"
# 同一条记录若挪到近邻位置则成立（正例对照，防「恒不成立」）
printf '[%s] notify: 近邻佐证\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
snap_before
printf '{"pending":4}\n' > "$WT/repo/contrib-data/pending/n4.json"
snap_after
run_classify
assert_eq "$(cls_of)" "external" "C18 对照：近邻佐证 ⇒ external"
assert_eq "$(reason_of)" "corroborated-ok" "C18 对照 reason"

# =============================================================================
t_case "C19 mutation 自证：引擎被注入「一律 external」⇒ wa_selftest 转红"
MUT_A="$WA_TMP/mut-a.sh"
sed 's/WA_CLS="suite"/WA_CLS="external"/' "$TESTS_ROOT/lib/write-attribution.sh" > "$MUT_A"
assert_eq "$(grep -c 'WA_CLS="external"' "$MUT_A" | tr -d ' ')" "2" "C19 变体注入生效（suite 已被改写为 external：原 external 1 处 + 注入 1 处）"
DRV_A="$WA_TMP/drv-a.sh"
{
  printf '#!/bin/bash\nset -u\n'
  printf 'source %s\n' "$MUT_A"
  printf 'wa_selftest "$1"\n'
} > "$DRV_A"
bash "$DRV_A" "$WA_TMP" > "$WA_TMP/mut-a.out" 2>&1
assert_ne "$?" "0" "C19 mutation A 后自证 rc≠0（恒真形态被 kill）"
assert_file_contains "$WA_TMP/mut-a.out" "WA-SELFTEST FAIL" "C19 mutation A 自证输出含 FAIL"

t_case "C20 mutation 自证：引擎被注入「未注册也放行」⇒ wa_selftest 转红"
MUT_B="$WA_TMP/mut-b.sh"
sed 's/WA_CLS="outside-surface"/WA_CLS="external"/' "$TESTS_ROOT/lib/write-attribution.sh" > "$MUT_B"
assert_eq "$(grep -c 'WA_CLS="outside-surface"' "$MUT_B" | tr -d ' ')" "0" "C20 变体注入生效（outside-surface 类名已被改写为 external）"
DRV_B="$WA_TMP/drv-b.sh"
{
  printf '#!/bin/bash\nset -u\n'
  printf 'source %s\n' "$MUT_B"
  printf 'wa_selftest "$1"\n'
} > "$DRV_B"
bash "$DRV_B" "$WA_TMP" > "$WA_TMP/mut-b.out" 2>&1
assert_ne "$?" "0" "C20 mutation B 后自证 rc≠0（未注册放行被 kill）"
assert_file_contains "$WA_TMP/mut-b.out" "WA-SELFTEST FAIL" "C20 mutation B 自证输出含 FAIL"

# =============================================================================
t_case "C21 wa_selftest 全形态自证（未 mutate 基线 rc=0）"
bash -c 'source "$1"; wa_selftest "$2"' _ "$TESTS_ROOT/lib/write-attribution.sh" "$WA_TMP" > "$WA_TMP/selftest.out" 2>&1
assert_exit "0" "$?" "C21 基线自证 rc=0"
assert_file_contains "$WA_TMP/selftest.out" "WA-SELFTEST PASS" "C21 自证输出 PASS 行"
assert_eq "$(grep -c '^WA-SELFTEST ok' "$WA_TMP/selftest.out" | tr -d ' ')" "32" "C21 自证 ok 计数=32（26 形态 + 6 计数断言）"

# =============================================================================
t_case "C22 wa_inject 三模式（含注入物自证与可清爽删除）"
INJ_T="$WA_TMP/inj"
rm -rf "$INJ_T"
mkdir -p "$INJ_T/repo/contrib-data/logs" "$INJ_T/repo/contrib-data/pending"
cp "$WT_REG" "$INJ_T/registry.tsv"
: > "$INJ_T/repo/contrib-data/logs/collect.log"
CANARY_OUT="$(wa_inject canary-create "$INJ_T/repo" "$INJ_T/registry.tsv")"
assert_exit "0" "$?" "C22 canary-create rc=0"
assert_contains "$CANARY_OUT" "WA-INJECT mode=canary-create" "C22 canary-create evidence 行"
CANARY_PATH="$(printf '%s' "$CANARY_OUT" | sed -n 's/.* path=\([^ ]*\).*/\1/p')"
assert_ne "$CANARY_PATH" "" "C22 canary-create 输出 path"
assert_contains "$(head -n 1 "$INJ_T/repo/$CANARY_PATH" 2>/dev/null)" "$WA_MARKER_PREFIX" "C22 注入物首行含 marker 前缀（短路可达）"
rm -f "$INJ_T/repo/$CANARY_PATH"
assert_eq "$(ls "$INJ_T/repo/contrib-data/pending" | wc -l | tr -d ' ')" "0" "C22 canary-create 清理后零残留"
APP_OUT="$(wa_inject canary-append "$INJ_T/repo" "$INJ_T/registry.tsv")"
assert_exit "0" "$?" "C22 canary-append rc=0"
assert_contains "$APP_OUT" "WA-INJECT mode=canary-append" "C22 canary-append evidence 行"
: > "$INJ_T/repo/contrib-data/logs/collect.log"
EXT_OUT="$(wa_inject external-append "$INJ_T/repo" "$INJ_T/registry.tsv")"
assert_exit "0" "$?" "C22 external-append rc=0"
assert_contains "$EXT_OUT" "WA-INJECT mode=external-append" "C22 external-append evidence 行"
assert_eq "$(wc -l < "$INJ_T/repo/contrib-data/logs/collect.log" | tr -d ' ')" "1" "C22 external-append 追加恰 1 行"
wa_inject bogus-mode "$INJ_T/repo" "$INJ_T/registry.tsv" >/dev/null 2>&1
assert_exit "2" "$?" "C22 未知 mode rc=2"

# =============================================================================
t_case "C23 wa_wait_external 三态（超时 / 观察到变更 / 参数非法）"
WAIT_T="$WA_TMP/wait"
rm -rf "$WAIT_T"
mkdir -p "$WAIT_T/repo/contrib-data/logs"
printf 'x\n' > "$WAIT_T/repo/contrib-data/logs/a.log"
wa_snapshot "$WAIT_T/repo" "$WAIT_T/before"
WAIT_OUT1="$(wa_wait_external "$WAIT_T/repo" "$WAIT_T/before" 1 1)"
assert_exit "1" "$?" "C23 零变更 ⇒ rc=1（超时未变更）"
assert_contains "$WAIT_OUT1" "changed=0" "C23 超时 evidence 行"
wa_wait_external "$WAIT_T/repo" "$WAIT_T/before" 1 0 >/dev/null 2>&1
assert_exit "2" "$?" "C23 poll_sec=0 ⇒ rc=2（参数非法）"
wa_wait_external "$WAIT_T/repo" "$WAIT_T/before" "abc" >/dev/null 2>&1
assert_exit "2" "$?" "C23 max_sec 非整数 ⇒ rc=2"
wa_wait_external "$WAIT_T/repo" "$WAIT_T/no-before" 1 1 >/dev/null 2>&1
assert_exit "2" "$?" "C23 快照缺失 ⇒ rc=2"
wa_wait_external "$WAIT_T/repo" "$WAIT_T/before" 20 1 > "$WAIT_T/wait2.out" 2>&1 &
WAIT_PID=$!
sleep 1
printf 'appended\n' >> "$WAIT_T/repo/contrib-data/logs/a.log"
wait "$WAIT_PID"
assert_exit "0" "$?" "C23 窗口内变更 ⇒ rc=0"
assert_file_contains "$WAIT_T/wait2.out" "changed=1" "C23 命中 evidence 行"

# =============================================================================
t_case "C24 wa_snapshot 富快照（5 列 / 排序 / fail-closed）"
SNAP_T="$WA_TMP/snap"
rm -rf "$SNAP_T"
mkdir -p "$SNAP_T/repo/contrib-data/logs"
printf 'a\n' > "$SNAP_T/repo/contrib-data/logs/a.log"
printf 'b\n' > "$SNAP_T/repo/contrib-data/b.txt"
wa_snapshot "$SNAP_T/repo" "$SNAP_T/s1"
assert_exit "0" "$?" "C24 快照 rc=0"
assert_eq "$(wc -l < "$SNAP_T/s1" | tr -d ' ')" "2" "C24 快照行数=文件数"
assert_eq "$(awk -F'\t' 'NF!=5' "$SNAP_T/s1" | wc -l | tr -d ' ')" "0" "C24 每行恰 5 列"
awk -F'\t' '{print $5}' "$SNAP_T/s1" > "$SNAP_T/paths"
sort "$SNAP_T/paths" > "$SNAP_T/paths.sorted"
assert_eq "$(sed -n '1p' "$SNAP_T/paths.sorted")" "contrib-data/b.txt" "C24 路径按字节序排序（首行）"
assert_eq "$(sed -n '2p' "$SNAP_T/paths.sorted")" "contrib-data/logs/a.log" "C24 路径按字节序排序（次行）"
assert_eq "$(awk -F'\t' '{print $1}' "$SNAP_T/s1" | sed -n '1p')" "$(shasum -a 256 "$SNAP_T/repo/contrib-data/b.txt" | awk '{print $1}')" "C24 sha256 与 shasum 复算一致（首行 = contrib-data/b.txt）"
wa_snapshot "$SNAP_T/no-such-repo" "$SNAP_T/s2" >/dev/null 2>&1
assert_exit "2" "$?" "C24 contrib-data 缺失 ⇒ rc=2（禁空快照）"

# =============================================================================
t_case "C25 wa_registry_default 覆盖与 fail-closed"
assert_exit "2" "$(wa_registry_default "" >/dev/null 2>&1; echo $?)" "C25 缺参数且无覆盖 ⇒ rc=2"
export WA_REGISTRY="$WA_DEF_REG"
assert_eq "$(wa_registry_default "$TESTS_ROOT")" "$WA_DEF_REG" "C25 有效 WA_REGISTRY 覆盖生效"
export WA_REGISTRY="$WA_TMP/no-such.tsv"
assert_eq "$(wa_registry_default "$TESTS_ROOT" 2>/dev/null)" "" "C25 无效覆盖 ⇒ stdout 为空（fail-closed，不回退默认）"
assert_exit "2" "$(WA_REGISTRY="$WA_TMP/no-such.tsv" bash -c 'source "$1"; wa_registry_default "$2"; exit $?' _ "$TESTS_ROOT/lib/write-attribution.sh" "$TESTS_ROOT" >/dev/null 2>&1; echo $?)" "C25 无效覆盖 ⇒ rc=2"
unset WA_REGISTRY

# =============================================================================
# 删除类归属（corroborated-delete）：锚 = after 富快照侧车里的**父目录 mtime**
# -----------------------------------------------------------------------------
# 证据合取：路径 ∈ 删除面（显式 opt-in 行）∧ 锚可取 ∧ 佐证日志在窗合规记录 ∧ |记录 ts − 锚| ≤ 30s。
# 既有 `deleted` 语义（无删除面行的 mode 内删除）逐字保留。
# =============================================================================
t_case "C26 删除类正例：删除面内路径被删 + 父目录锚近邻佐证 ⇒ external/corroborated-delete-ok"
# 佐证记录在 snap_before **之前**落盘 ⇒ notify.log 在窗口内零变更（唯一变更=被删文件）
printf '[%s] notify: 删除类佐证落笔\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
printf '{"digest":"ok"}\n' > "$WT/repo/contrib-data/pending/gone-ok.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/gone-ok.json"
snap_after
run_classify
assert_exit "0" "$?" "C26 wa_classify rc=0"
assert_eq "$(cls_of_path contrib-data/pending/gone-ok.json)" "external" "C26 类别（删除面 + 近邻佐证）"
assert_eq "$(reason_of_path contrib-data/pending/gone-ok.json)" "corroborated-delete-ok" "C26 reason"
assert_contains "$(cls_line_path contrib-data/pending/gone-ok.json)" "writer=notify" "C26 evidence 含 writer"
assert_contains "$(cls_line_path contrib-data/pending/gone-ok.json)" "dir_mtime=" "C26 evidence 含目录锚"
assert_not_contains "$(cls_line_path contrib-data/pending/gone-ok.json)" "dir_mtime=none" "C26 锚确实取到（非降级路径）"
assert_not_contains "$(cls_line_path contrib-data/pending/gone-ok.json)" "Δt=none" "C26 佐证记录确实在窗（非空转）"
assert_eq "$(sum_key suite)" "0" "C26 删除类放行后 suite=0"
assert_eq "$(sum_key external)" "1" "C26 external=1（窗口内唯一变更）"

# =============================================================================
t_case "C27 删除类反例：删除面内路径被删但无在窗近邻佐证 ⇒ suite/no-delete-corroboration"
# 「在窗」与「近邻」是两个必要条件：记录取 +90s（落在窗口松弛带内、但距锚 >30s）⇒ 必须判红
WA_DEL_FAR_TS="$(date -r $((WA_NOW + 90)) +'%Y-%m-%d %H:%M:%S')"
: > "$WT/repo/contrib-data/logs/notify.log"
printf '[%s] notify: 删除类远邻佐证\n' "$WA_DEL_FAR_TS" >> "$WT/repo/contrib-data/logs/notify.log"
printf '{"digest":"nocorr"}\n' > "$WT/repo/contrib-data/pending/gone-nocorr.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/gone-nocorr.json"
snap_after
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-nocorr.json)" "suite" "C27 类别（近邻不成立）"
assert_eq "$(reason_of_path contrib-data/pending/gone-nocorr.json)" "no-delete-corroboration" "C27 reason"
assert_contains "$(cls_line_path contrib-data/pending/gone-nocorr.json)" "dir_mtime=" "C27 失败态仍写目录锚（可审计：锚有值、佐证缺席）"
assert_not_contains "$(cls_line_path contrib-data/pending/gone-nocorr.json)" "dir_mtime=none" "C27 锚本身可取（区别于锚缺失降级路径）"

# =============================================================================
t_case "C28 近邻边界二值对照：Δt=30s ⇒ external / Δt=31s ⇒ suite（同路径同操作，仅锚位移）"
# 锚构造（R-8）：真实 rm 产生真锚 → touch -t 把**目录** mtime 设为指定时刻（对文件无效）→ 采 after 快照
WA_DEL_TS="$(date '+%Y-%m-%d %H:%M:%S')"
WA_DEL_REC="$(date -j -f "%Y-%m-%d %H:%M:%S" "$WA_DEL_TS" +%s)"
: > "$WT/repo/contrib-data/logs/notify.log"
printf '[%s] notify: 边界锚佐证\n' "$WA_DEL_TS" >> "$WT/repo/contrib-data/logs/notify.log"
printf '{"digest":"b30"}\n' > "$WT/repo/contrib-data/pending/gone-b30.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/gone-b30.json"
touch -t "$(date -r $((WA_DEL_REC + 30)) +%Y%m%d%H%M.%S)" "$WT/repo/contrib-data/pending"
snap_after
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-b30.json)" "external" "C28 边界（Δ 恰 30s）⇒ external"
assert_eq "$(reason_of_path contrib-data/pending/gone-b30.json)" "corroborated-delete-ok" "C28 边界 reason"
assert_contains "$(cls_line_path contrib-data/pending/gone-b30.json)" "Δt=30s" "C28 证据行 Δt 是实测 30s（非恒零/常量）"
printf '{"digest":"b31"}\n' > "$WT/repo/contrib-data/pending/gone-b31.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/gone-b31.json"
touch -t "$(date -r $((WA_DEL_REC + 31)) +%Y%m%d%H%M.%S)" "$WT/repo/contrib-data/pending"
snap_after
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-b31.json)" "suite" "C28 反例（Δ=31s）⇒ suite"
assert_eq "$(reason_of_path contrib-data/pending/gone-b31.json)" "no-delete-corroboration" "C28 反例 reason"

# =============================================================================
t_case "C29 删除类 marker 路径短路：近邻佐证齐备仍判 suite/canary-marker（先于一切）"
printf '[%s] notify: marker 删除短路佐证\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
printf '%smode=delete-plant\n' "$WA_MARKER_PREFIX" > "$WT/repo/contrib-data/pending/${WA_MARKER_PREFIX}gone.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/${WA_MARKER_PREFIX}gone.json"
snap_after
run_classify
assert_eq "$(cls_of_path "contrib-data/pending/${WA_MARKER_PREFIX}gone.json")" "suite" "C29 marker 路径删除 ⇒ suite"
assert_eq "$(reason_of_path "contrib-data/pending/${WA_MARKER_PREFIX}gone.json")" "canary-marker" "C29 reason=canary-marker（短路优先于佐证判定）"
assert_eq "$(sum_key external)" "0" "C29 佐证齐备也不得放行（短路不可绕）"

# =============================================================================
t_case "C30 锚 fail-closed 三态：侧车缺 / 父目录缺行 / mtime 非十进制 ⇒ suite（且锚可取时必 external）"
WA_D30="$WT/repo/contrib-data/pending/gone-anchor.json"
WA_D30_BAK="$WA_TMP/c30-after.dirs.bak"
printf '[%s] notify: 锚可用性对照佐证\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
printf '{"digest":"anchor"}\n' > "$WA_D30"
snap_before
rm -f "$WA_D30"
snap_after
cp "$WT/after.dirs" "$WA_D30_BAK"
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-anchor.json)" "external" "C30 对照：锚可取 ⇒ external（防「恒红」的假 fail-closed）"
# ① 侧车缺失
rm -f "$WT/after.dirs"
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-anchor.json)" "suite" "C30① 侧车缺失 ⇒ suite"
assert_eq "$(reason_of_path contrib-data/pending/gone-anchor.json)" "no-delete-corroboration" "C30① reason"
assert_contains "$(cls_line_path contrib-data/pending/gone-anchor.json)" "dir_mtime=none" "C30① 锚缺失显式落 dir_mtime=none"
# ② 侧车在但父目录无行
awk -F'\t' 'BEGIN { OFS = "\t" } $5 != "contrib-data/pending"' "$WA_D30_BAK" > "$WT/after.dirs"
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-anchor.json)" "suite" "C30② 父目录不在目录表 ⇒ suite"
assert_contains "$(cls_line_path contrib-data/pending/gone-anchor.json)" "dir_mtime=none" "C30② 锚缺失显式落 dir_mtime=none"
# ③ 侧车在但 mtime 非法
awk -F'\t' 'BEGIN { OFS = "\t" } { if ($5 == "contrib-data/pending") $3 = "notanepoch"; print }' "$WA_D30_BAK" > "$WT/after.dirs"
run_classify
assert_eq "$(cls_of_path contrib-data/pending/gone-anchor.json)" "suite" "C30③ mtime 非十进制 ⇒ suite"
assert_contains "$(cls_line_path contrib-data/pending/gone-anchor.json)" "dir_mtime=none" "C30③ 锚缺失显式落 dir_mtime=none"
cp "$WA_D30_BAK" "$WT/after.dirs"

# =============================================================================
t_case "C31 删除类注入两段式：plant（快照前）+ fire（窗口内）· 自证失败 rc=2 · 空转防护"
D31="$WA_TMP/del-inj"
rm -rf "$D31"
mkdir -p "$D31/repo/contrib-data/logs" "$D31/repo/contrib-data/pending"
cp "$WT_REG" "$D31/registry.tsv"
: > "$D31/repo/contrib-data/logs/notify.log"
PLANT_C="$(wa_inject delete-plant "$D31/repo" "$D31/registry.tsv" canary)"
assert_exit "0" "$?" "C31 delete-plant(canary) rc=0"
assert_eq "$(printf '%s\n' "$PLANT_C" | grep -c '^WA-INJECT')" "1" "C31 plant 恰 1 行 WA-INJECT（调用方按单行解析 path）"
assert_contains "$PLANT_C" "mode=delete-plant" "C31 plant evidence 行含 mode"
assert_contains "$PLANT_C" "variant=canary" "C31 plant evidence 行含 variant"
P31_C="$(printf '%s' "$PLANT_C" | sed -n 's/.* path=\([^ ]*\).*/\1/p')"
assert_ne "$P31_C" "" "C31 plant 输出可解析 path"
assert_eq "$(printf '%s' "$P31_C" | wc -l | tr -d ' ')" "0" "C31 解析结果单行（多行会致调用方 rm 面失效）"
assert_contains "$(head -n 1 "$D31/repo/$P31_C" 2>/dev/null)" "$WA_MARKER_PREFIX" "C31 canary 注入物首行含 marker（路径短路可达）"
# 空转防护：plant 必须在 before 快照里可见（否则「以为测了其实没测」）
snap_present() { WA_P="$2" awk -F'\t' 'BEGIN { d = ENVIRON["WA_P"] } $5 == d { n++ } END { print n + 0 }' "$1"; }
wa_snapshot "$D31/repo" "$D31/before"
assert_eq "$(snap_present "$D31/before" "$P31_C")" "1" "C31 plant 后快照必含该路径（空转防护）"
FIRE_C="$(wa_inject delete-fire "$D31/repo" "$D31/registry.tsv" "$P31_C" canary)"
assert_exit "0" "$?" "C31 delete-fire(canary) rc=0"
assert_eq "$(printf '%s\n' "$FIRE_C" | grep -c '^WA-INJECT')" "1" "C31 fire 恰 1 行 WA-INJECT"
assert_contains "$FIRE_C" "mode=delete-fire" "C31 fire evidence 行含 mode"
[ -e "$D31/repo/$P31_C" ] && _fail "C31 fire 后注入物消失" "仍存在: $P31_C" || _pass "C31 fire 后注入物消失（真删）"
assert_eq "$(wc -l < "$D31/repo/contrib-data/logs/notify.log" | tr -d ' ')" "0" "C31 canary 变体不落佐证记录（仅真删）"
# 幂等/自证：目标已不存在 ⇒ rc=2
wa_inject delete-fire "$D31/repo" "$D31/registry.tsv" "$P31_C" canary >/dev/null 2>&1
assert_exit "2" "$?" "C31 重复 fire（目标已不存在）rc=2"
# external 变体全链：plant → before 快照 → fire（落佐证 + 真删）→ after 快照 → 判 external
PLANT_E="$(wa_inject delete-plant "$D31/repo" "$D31/registry.tsv" external)"
assert_exit "0" "$?" "C31 delete-plant(external) rc=0"
assert_contains "$PLANT_E" "variant=external" "C31 external plant evidence 行"
P31_E="$(printf '%s' "$PLANT_E" | sed -n 's/.* path=\([^ ]*\).*/\1/p')"
assert_ne "$P31_E" "" "C31 external plant 输出可解析 path"
case "${P31_E##*/}" in "${WA_MARKER_PREFIX}"*) _fail "C31 external 注入物无 marker 前缀" "实得 ${P31_E##*/}" ;; *) _pass "C31 external 注入物无 marker 前缀（不触发短路）" ;; esac
wa_snapshot "$D31/repo" "$D31/before"
assert_eq "$(snap_present "$D31/before" "$P31_E")" "1" "C31 external plant 后快照必含该路径（空转防护）"
D31_T0="$(date +%s)"
D31_T1=$((D31_T0 + 1))
wa_inject delete-fire "$D31/repo" "$D31/registry.tsv" "$P31_E" external >/dev/null || _fail "C31 delete-fire(external) rc=0" "非零退出"
wa_snapshot "$D31/repo" "$D31/after"
D31_SUM="$(wa_classify "$D31/repo" "$D31/before" "$D31/after" "$D31/registry.tsv" "$D31/class.out" "$((D31_T0 - 1))" "$D31_T1")"
assert_exit "0" "$?" "C31 external 变体全链 wa_classify rc=0"
assert_contains "$(grep -F -m1 " path=$P31_E " "$D31/class.out")" "reason=corroborated-delete-ok" "C31 external 变体 ⇒ 删除类正例成立"
assert_eq "$(printf '%s' "$D31_SUM" | tr ' ' '\n' | sed -n 's/^suite=\([0-9-]*\)$/\1/p' | head -n 1)" "0" "C31 external 变体全链 suite=0"
# 自证失败 rc=2（未知 variant / 缺 path / 非本引擎植入物 / 非删除面路径）
wa_inject delete-plant "$D31/repo" "$D31/registry.tsv" bogus >/dev/null 2>&1
assert_exit "2" "$?" "C31 delete-plant 未知 variant rc=2"
wa_inject delete-fire "$D31/repo" "$D31/registry.tsv" "$P31_C" bogus >/dev/null 2>&1
assert_exit "2" "$?" "C31 delete-fire 未知 variant rc=2"
wa_inject delete-fire "$D31/repo" "$D31/registry.tsv" "" canary >/dev/null 2>&1
assert_exit "2" "$?" "C31 delete-fire 缺 path rc=2"
printf 'x\n' > "$D31/repo/contrib-data/pending/not-ours.json"
wa_inject delete-fire "$D31/repo" "$D31/registry.tsv" contrib-data/pending/not-ours.json canary >/dev/null 2>&1
assert_exit "2" "$?" "C31 delete-fire 目标非本引擎植入物 rc=2（防注入器被误用删生产文件）"
[ -f "$D31/repo/contrib-data/pending/not-ours.json" ] && _pass "C31 非植入物未被删除（守卫有效）" || _fail "C31 非植入物未被删除" "文件被删，守卫失效"
rm -f "$D31/repo/contrib-data/pending/not-ours.json"

# =============================================================================
t_case "C32 mutation 抗性：删除分支被改成「一律 external」⇒ wa_selftest 转红"
MUT_D="$WA_TMP/mut-d.sh"
sed -e 's/wa__r_suite "deleted"/wa__r_external "deleted"/' \
    -e 's/wa__r_suite "no-delete-corroboration"/wa__r_external "no-delete-corroboration"/' \
    "$TESTS_ROOT/lib/write-attribution.sh" > "$MUT_D"
assert_eq "$(grep -c 'wa__r_external "no-delete-corroboration"' "$MUT_D" | tr -d ' ')" "2" "C32 变异体注入生效（两处 no-delete-corroboration 均被改写为 external）"
assert_eq "$(grep -c 'wa__r_suite "deleted"' "$MUT_D" | tr -d ' ')" "0" "C32 变异体注入生效（deleted 已被改写为 external）"
DRV_D="$WA_TMP/drv-d.sh"
{
  printf '#!/bin/bash\nset -u\n'
  printf 'source %s\n' "$MUT_D"
  printf 'wa_selftest "$1"\n'
} > "$DRV_D"
bash "$DRV_D" "$WA_TMP" > "$WA_TMP/mut-d.out" 2>&1
assert_ne "$?" "0" "C32 变异体自证 rc≠0（D 一律 external 被 kill；既有 case 12 与新增删除形态双重覆盖）"
assert_file_contains "$WA_TMP/mut-d.out" "WA-SELFTEST FAIL" "C32 变异体自证输出含 FAIL"

# =============================================================================
t_case "C33 worker 实测三件复现锚：digest-<TS> 三件被登记写手删除 ⇒ 三行 external（两个 <TS> 跑两轮）"
WA_CZ_T0=1789351195
WA_CZ_T1=1789351485
WA_CZ_ANCHOR=1789351483
WA_CZ_REC=1789351474
WA_CZ_TS="$(date -r "$WA_CZ_REC" +'%Y-%m-%d %H:%M:%S')"
for WA_CZ_TAG in 20260914-090949 20260914-100442; do
  : > "$WT/repo/contrib-data/logs/notify.log"
  printf '[%s] notify: digest 卡已建 t_680024e5\n' "$WA_CZ_TS" >> "$WT/repo/contrib-data/logs/notify.log"
  printf '{"digest":1}\n' > "$WT/repo/contrib-data/pending/digest-$WA_CZ_TAG.json"
  printf 'body\n' > "$WT/repo/contrib-data/pending/digest-$WA_CZ_TAG.body.md"
  printf '{"card":1}\n' > "$WT/repo/contrib-data/pending/digest-$WA_CZ_TAG.card.json"
  snap_before
  rm -f "$WT/repo/contrib-data/pending/digest-$WA_CZ_TAG.json" \
        "$WT/repo/contrib-data/pending/digest-$WA_CZ_TAG.body.md" \
        "$WT/repo/contrib-data/pending/digest-$WA_CZ_TAG.card.json"
  # 锚构造（R-8）：真实 rm 产生真锚 ⇒ touch -t 把**目录** mtime 钉到实测锚 1789351483（10:04:43）
  touch -t "$(date -r "$WA_CZ_ANCHOR" +%Y%m%d%H%M.%S)" "$WT/repo/contrib-data/pending"
  snap_after
  run_classify "$WT_REG" "$WA_CZ_T0" "$WA_CZ_T1"
  for WA_CZ_EXT in json body.md card.json; do
    WA_CZ_P="contrib-data/pending/digest-$WA_CZ_TAG.$WA_CZ_EXT"
    assert_eq "$(cls_of_path "$WA_CZ_P")" "external" "C33 [$WA_CZ_TAG] $(basename "$WA_CZ_P") 类别=external"
    assert_eq "$(reason_of_path "$WA_CZ_P")" "corroborated-delete-ok" "C33 [$WA_CZ_TAG] $(basename "$WA_CZ_P") reason"
    assert_contains "$(cls_line_path "$WA_CZ_P")" "writer=notify" "C33 [$WA_CZ_TAG] $(basename "$WA_CZ_P") writer=notify"
    assert_contains "$(cls_line_path "$WA_CZ_P")" "Δt=9s" "C33 [$WA_CZ_TAG] $(basename "$WA_CZ_P") Δt=9s（实测锚 − 记录）"
    assert_contains "$(cls_line_path "$WA_CZ_P")" "dir_mtime=$WA_CZ_ANCHOR" "C33 [$WA_CZ_TAG] $(basename "$WA_CZ_P") 锚十进制作证"
  done
  assert_eq "$(sum_key external)" "3" "C33 [$WA_CZ_TAG] external=3（三件全放行）"
  assert_eq "$(sum_key suite)" "0" "C33 [$WA_CZ_TAG] suite=0（本轮要消除的假红）"
  assert_eq "$(sum_key total)" "3" "C33 [$WA_CZ_TAG] total=3（窗口内唯一变更=三件）"
done

# =============================================================================
t_case "C34 面外删除两态：无 marker ⇒ outside-surface；有 marker ⇒ suite/canary-marker（R-1 谓词）"
printf 'x\n' > "$WT/repo/contrib-data/scratch/o1.md"
snap_before
rm -f "$WT/repo/contrib-data/scratch/o1.md"
snap_after
run_classify
assert_eq "$(cls_of_path contrib-data/scratch/o1.md)" "outside-surface" "C34 面外删除（无 marker）⇒ outside-surface"
assert_eq "$(reason_of_path contrib-data/scratch/o1.md)" "outside-surface" "C34 reason"
assert_eq "$(sum_key suite)" "0" "C34 不误计 suite"
assert_eq "$(sum_key external)" "0" "C34 不冒领 external"
printf '%soutside-delete\n' "$WA_MARKER_PREFIX" > "$WT/repo/contrib-data/scratch/${WA_MARKER_PREFIX}o2.json"
snap_before
rm -f "$WT/repo/contrib-data/scratch/${WA_MARKER_PREFIX}o2.json"
snap_after
run_classify
assert_eq "$(cls_of_path "contrib-data/scratch/${WA_MARKER_PREFIX}o2.json")" "suite" "C34 面外删除（有 marker）⇒ suite"
assert_eq "$(reason_of_path "contrib-data/scratch/${WA_MARKER_PREFIX}o2.json")" "canary-marker" "C34 marker 路径短路面内面外同"

# =============================================================================
t_case "C35 混合窗口等值恒等式：4 external + 1 suite + 1 outside（含 D 类）· 三类和==total==窗口差集"
: > "$WT/repo/contrib-data/logs/notify.log"
printf '[%s] notify: 混合窗口佐证\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$WT/repo/contrib-data/logs/notify.log"
printf '{"mix":1}\n' > "$WT/repo/contrib-data/pending/mix-d1.json"
printf '{"mix":2}\n' > "$WT/repo/contrib-data/pending/mix-d2.json"
printf '{"mix":3}\n' > "$WT/repo/contrib-data/pending/mix-d3.json"
printf 'seed\n' > "$WT/repo/contrib-data/scratch/mix-out.md"
snap_before
printf '%smode=mix-suite\n' "$WA_MARKER_PREFIX" > "$WT/repo/contrib-data/pending/mix-suite.json"
rm -f "$WT/repo/contrib-data/pending/mix-d1.json" "$WT/repo/contrib-data/pending/mix-d2.json" "$WT/repo/contrib-data/pending/mix-d3.json"
printf '[%s] collect: 混合窗口追加\n' "$WA_CLS_NOW" >> "$WT/repo/contrib-data/logs/collect.log"
printf 'outside change\n' > "$WT/repo/contrib-data/scratch/mix-out.md"
snap_after
run_classify
WA_MIX_N="$(awk -F'\t' 'NR == FNR { b[$5] = $0; next } { a[$5] = $0 }
  END { n = 0
    for (p in b) if (!(p in a)) n++
    for (p in a) { if (!(p in b)) n++; else if (a[p] != b[p]) n++ }
    print n }' "$WT/before" "$WT/after")"
assert_eq "$WA_MIX_N" "6" "C35 窗口差集=6（防空转：注入面确实发生了 6 个文件变更）"
assert_eq "$(sum_key external)" "4" "C35 external=4（3 删除 + 1 追加）"
assert_eq "$(sum_key suite)" "1" "C35 suite=1（marker 新建）"
assert_eq "$(sum_key outside)" "1" "C35 outside=1（面外改写）"
assert_eq "$(sum_key total)" "$WA_MIX_N" "C35 total==窗口差集文件数（等值，非 >=）"
assert_eq "$(( $(sum_key external) + $(sum_key suite) + $(sum_key outside) ))" "$(sum_key total)" "C35 三类和==total（删除不走旁路）"
assert_eq "$(sum_key unclassified)" "0" "C35 unclassified=0"
assert_eq "$(cls_of_path contrib-data/pending/mix-d1.json)" "external" "C35 删除类逐文件唯一正确归类（d1）"
assert_eq "$(reason_of_path contrib-data/pending/mix-d2.json)" "corroborated-delete-ok" "C35 删除类逐文件唯一正确归类（d2）"
assert_eq "$(cls_of_path contrib-data/pending/mix-suite.json)" "suite" "C35 marker 新建 = suite"
assert_eq "$(cls_of_path contrib-data/scratch/mix-out.md)" "outside-surface" "C35 面外改写 = outside-surface"
assert_eq "$(cls_of_path contrib-data/logs/collect.log)" "external" "C35 追加 = external"

# =============================================================================
# 删除类跨窗所有权链（D-α）：D-β 近邻不成立时，追加「窗口前字节区有具名记录 ∧ 写手本窗活跃」这一依据。
# -----------------------------------------------------------------------------
# 所有权 = 佐证日志里一条合规记录的**起始字节偏移 < 该日志在 before 快照中的 size**（结构事实）；
# 活跃度 = 同一日志有 ts ∈ [t0−120s, t1+120s] 的合规记录。两者同时成立才放行（否则 suite，fail-closed）。
# 本组用例的夹具：具名记录取 now−5400（远窗口带外，只作所有权）；活跃记录取 now+90（在窗带内、
# 但与真 rm 产生的锚相距 90s > 30s ⇒ D-β 恒不成立 ⇒ 真正考验 D-α）。
# =============================================================================
WA_DA_OWN_TS="$(date -r $((WA_NOW - 5400)) +'%Y-%m-%d %H:%M:%S')"
WA_DA_ACT_TS="$(date -r $((WA_NOW + 90)) +'%Y-%m-%d %H:%M:%S')"
wa_da_log() { printf '%s' "$WT/repo/contrib-data/logs/notify.log"; }
wa_da_off_of() { # <子串> → 该子串所在合规行的起始字节偏移（grep -b；机械核对「窗口前字节区」）
  LC_ALL=C grep -bE "$WA_ALPHA_N" "$(wa_da_log)" 2>/dev/null | LC_ALL=C grep -F -m1 "$1" | sed -n 's/^\([0-9]*\):.*/\1/p'
}

t_case "C36 跨窗所有权链正例（R4 生产形态：同 stem 四件 · 两个 <TS> 两轮）⇒ external/ownership-delete-ok"
for WA_DA_TAG in 20260914-090949 20260914-100442; do
  WA_DA_STEM="digest-$WA_DA_TAG"
  : > "$(wa_da_log)"
  # 构造序（R-8 同族）：① 具名记录先落盘 ⇒ ② 采 before 快照 ⇒ ③ 窗口内真 rm 四件 ⇒ ④ 采 after 快照
  printf '[%s] notify: digest 卡已建 t_da（snapshot=…/pending/%s.json，idem=…）\n' "$WA_DA_OWN_TS" "$WA_DA_STEM" >> "$(wa_da_log)"
  for WA_DA_EXT in json body.md card.json digest.md; do
    printf '{"digest":"r4"}\n' > "$WT/repo/contrib-data/pending/$WA_DA_STEM.$WA_DA_EXT"
  done
  snap_before
  WA_DA_BSIZE="$(wa__snap_field "$WT/before" "contrib-data/logs/notify.log" 2)"
  for WA_DA_EXT in json body.md card.json digest.md; do
    rm -f "$WT/repo/contrib-data/pending/$WA_DA_STEM.$WA_DA_EXT"
  done
  # 窗口内写手活跃：落一条在窗记录（不具名）⇒ 该追加自身是 external/registered-append-ok
  printf '[%s] notify: digest 卡已建 t_new（snapshot=…/pending/digest-20260914-110839.json，idem=…）\n' "$WA_DA_ACT_TS" >> "$(wa_da_log)"
  snap_after
  run_classify
  assert_exit "0" "$?" "C36 [$WA_DA_TAG] wa_classify rc=0"
  for WA_DA_EXT in json body.md card.json digest.md; do
    WA_DA_P="contrib-data/pending/$WA_DA_STEM.$WA_DA_EXT"
    assert_eq "$(cls_of_path "$WA_DA_P")" "external" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") 类别=external"
    assert_eq "$(reason_of_path "$WA_DA_P")" "ownership-delete-ok" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") reason=ownership-delete-ok"
    assert_contains "$(cls_line_path "$WA_DA_P")" "writer=notify" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") writer=notify"
    assert_contains "$(cls_line_path "$WA_DA_P")" "owner=$WA_DA_STEM" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") owner= 四件共同 stem"
    assert_contains "$(cls_line_path "$WA_DA_P")" "owner_ts=$WA_DA_OWN_TS" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") owner_ts= 写手日志真实记录时间戳"
    assert_contains "$(cls_line_path "$WA_DA_P")" "owner_log=contrib-data/logs/notify.log" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") owner_log= 承载日志"
    assert_contains "$(cls_line_path "$WA_DA_P")" "act_ts=$WA_DA_ACT_TS" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") act_ts= 窗口带内活跃记录"
    assert_not_contains "$(cls_line_path "$WA_DA_P")" "Δt=9s" "C36 [$WA_DA_TAG] $(basename "$WA_DA_P") 非 D-β 路径（近邻确实不成立）"
  done
  # 机械核对「该记录位于窗口前字节区」：具名记录起始字节偏移 < before 快照里该日志的 size
  WA_DA_OFF="$(wa_da_off_of "$WA_DA_STEM")"
  assert_ne "$WA_DA_OFF" "" "C36 [$WA_DA_TAG] 具名记录起始字节偏移可测（grep -b）"
  if [ "$WA_DA_OFF" -lt "$WA_DA_BSIZE" ]; then
    _pass "C36 [$WA_DA_TAG] 具名记录位于窗口前字节区 offset=$WA_DA_OFF < before size=$WA_DA_BSIZE"
  else
    _fail "C36 [$WA_DA_TAG] 具名记录位于窗口前字节区" "offset=$WA_DA_OFF >= size=$WA_DA_BSIZE"
  fi
  assert_eq "$(sum_key external)" "5" "C36 [$WA_DA_TAG] external=5（四件删除 + 窗口内活跃追加）"
  assert_eq "$(sum_key suite)" "0" "C36 [$WA_DA_TAG] suite=0（本轮要消除的假红）"
  assert_eq "$(sum_key total)" "5" "C36 [$WA_DA_TAG] total=5（窗口差集=四件 + 追加）"
done

# =============================================================================
t_case "C37 所有权在但写手本窗静默（窗口带内零记录）⇒ suite/no-delete-corroboration"
WA_DA_STEM="digest-20260914-235959"
: > "$(wa_da_log)"
printf '[%s] notify: digest 卡已建 t_da（snapshot=…/pending/%s.json，idem=…）\n' "$WA_DA_OWN_TS" "$WA_DA_STEM" >> "$(wa_da_log)"
printf '{"digest":"silent"}\n' > "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
snap_after
run_classify
WA_DA_P="contrib-data/pending/$WA_DA_STEM.json"
assert_eq "$(cls_of_path "$WA_DA_P")" "suite" "C37 类别（写手本窗静默 ⇒ 活跃度不成立）"
assert_eq "$(reason_of_path "$WA_DA_P")" "no-delete-corroboration" "C37 reason"
assert_contains "$(cls_line_path "$WA_DA_P")" "owner=$WA_DA_STEM" "C37 失败态仍写 owner=（审计：所有权在）"
assert_contains "$(cls_line_path "$WA_DA_P")" "act=none" "C37 失败态写 act=none（活跃度缺席）"
assert_contains "$(cls_line_path "$WA_DA_P")" "ts=none" "C37 D-β 亦无在窗记录（Δ/ts 皆 none）"
assert_eq "$(sum_key suite)" "1" "C37 suite=1"
assert_eq "$(sum_key external)" "0" "C37 external=0（所有权单独不足以放行）"

# =============================================================================
t_case "C38 窗口内追加的具名记录不构成所有权（回填旧 ts / 当前 ts 两态）⇒ suite"
# 态 A：回填旧时间戳。该追加自身另被既有 append 分支判 suite/timestamp-out-of-window（双重覆盖）
WA_DA_STEM="digest-20260914-235958"
: > "$(wa_da_log)"
printf '[%s] notify: 本窗活跃记录（不具名）\n' "$WA_DA_ACT_TS" >> "$(wa_da_log)"
printf '{"digest":"forged-a"}\n' > "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
snap_before
printf '[%s] notify: digest 卡已建 t_da（snapshot=…/pending/%s.json，回填旧时间戳）\n' "$WA_DA_OWN_TS" "$WA_DA_STEM" >> "$(wa_da_log)"
rm -f "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
snap_after
run_classify
WA_DA_P="contrib-data/pending/$WA_DA_STEM.json"
assert_eq "$(cls_of_path "$WA_DA_P")" "suite" "C38A 类别（窗口内追加的具名记录不是所有权）"
assert_eq "$(reason_of_path "$WA_DA_P")" "no-delete-corroboration" "C38A reason"
assert_contains "$(cls_line_path "$WA_DA_P")" "owner=$WA_DA_STEM" "C38A 失败态 owner= 有值（具名记录确实存在，只是不在窗口前字节区）"
assert_contains "$(cls_line_path "$WA_DA_P")" "act=$WA_DA_ACT_TS" "C38A 失败态 act= 有值（写手本窗活跃，放行仍需所有权）"
assert_eq "$(cls_of_path contrib-data/logs/notify.log)" "suite" "C38A 该追加自身判 suite（双重覆盖）"
assert_eq "$(reason_of_path contrib-data/logs/notify.log)" "timestamp-out-of-window" "C38A 追加自身 reason=timestamp-out-of-window"
assert_eq "$(sum_key suite)" "2" "C38A suite=2（被删物 + 伪造追加）"
assert_eq "$(sum_key external)" "0" "C38A external=0"
# 态 B：当前时间戳。锚钉到 now−90（touch -t 作用在**目录**上）⇒ D-β 近邻不成立，本态只考验字节区规则
WA_DA_STEM="digest-20260914-235957"
: > "$(wa_da_log)"
printf '{"digest":"forged-b"}\n' > "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
snap_before
printf '[%s] notify: digest 卡已建 t_da（snapshot=…/pending/%s.json，当前时间戳）\n' "$WA_CLS_NOW" "$WA_DA_STEM" >> "$(wa_da_log)"
rm -f "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
touch -t "$(date -r $((WA_NOW - 90)) +%Y%m%d%H%M.%S)" "$WT/repo/contrib-data/pending"
snap_after
run_classify
WA_DA_P="contrib-data/pending/$WA_DA_STEM.json"
assert_eq "$(cls_of_path "$WA_DA_P")" "suite" "C38B 类别（窗口内追加的具名记录不是所有权）"
assert_eq "$(reason_of_path "$WA_DA_P")" "no-delete-corroboration" "C38B reason"
assert_contains "$(cls_line_path "$WA_DA_P")" "owner=$WA_DA_STEM" "C38B 失败态 owner= 有值"
assert_contains "$(cls_line_path "$WA_DA_P")" "act=$WA_CLS_NOW" "C38B 失败态 act= 有值（在窗记录）"
assert_eq "$(cls_of_path contrib-data/logs/notify.log)" "external" "C38B 追加形态合规 ⇒ 自身判 external（看起来像写手记录）"
assert_eq "$(reason_of_path contrib-data/logs/notify.log)" "registered-append-ok" "C38B 追加自身 reason=registered-append-ok"
assert_eq "$(sum_key suite)" "1" "C38B suite=1（被删物）"
assert_eq "$(sum_key external)" "1" "C38B external=1（仅那条形态合规的追加；被删物未放行）"
assert_eq "$(sum_key total)" "2" "C38B total=2"

# =============================================================================
t_case "C39 stem 长度边界：恰 WA_OWNER_MIN_STEM 适用 / 短一位不适用（fail-closed）"
assert_eq "$WA_OWNER_MIN_STEM" "8" "C39 常量 WA_OWNER_MIN_STEM=8"
WA_DA_S8="stem-008"
WA_DA_S7="stem-00"
: > "$(wa_da_log)"
printf '[%s] notify: 具名记录 %s / %s\n' "$WA_DA_OWN_TS" "$WA_DA_S8" "$WA_DA_S7" >> "$(wa_da_log)"
printf '[%s] notify: 本窗活跃记录（不具名）\n' "$WA_DA_ACT_TS" >> "$(wa_da_log)"
printf '{"stem":8}\n' > "$WT/repo/contrib-data/pending/$WA_DA_S8.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/$WA_DA_S8.json"
snap_after
run_classify
assert_eq "$(cls_of_path "contrib-data/pending/$WA_DA_S8.json")" "external" "C39 恰 8 字符 stem ⇒ 所有权适用"
assert_eq "$(reason_of_path "contrib-data/pending/$WA_DA_S8.json")" "ownership-delete-ok" "C39 边界正例 reason"
printf '{"stem":7}\n' > "$WT/repo/contrib-data/pending/$WA_DA_S7.json"
snap_before
rm -f "$WT/repo/contrib-data/pending/$WA_DA_S7.json"
snap_after
run_classify
assert_eq "$(cls_of_path "contrib-data/pending/$WA_DA_S7.json")" "suite" "C39 短一位（7 字符）stem ⇒ 所有权不适用"
assert_eq "$(reason_of_path "contrib-data/pending/$WA_DA_S7.json")" "no-delete-corroboration" "C39 边界反例 reason"
assert_contains "$(cls_line_path "contrib-data/pending/$WA_DA_S7.json")" "owner=$WA_DA_S7" "C39 失败态 owner= 仍写实际 stem（审计）"
assert_eq "$(sum_key external)" "0" "C39 短 stem 不得冒领 external（子串命中不算所有权）"

# =============================================================================
t_case "C40 混合窗口等值恒等式扩展：D-α 行计入 external · 三类和==total==窗口差集"
WA_DA_STEM="mixdigest-20260914"
: > "$(wa_da_log)"
printf '[%s] notify: digest 卡已建 t_da（snapshot=…/pending/%s.json，idem=…）\n' "$WA_DA_OWN_TS" "$WA_DA_STEM" >> "$(wa_da_log)"
printf '{"mix":6}\n' > "$WT/repo/contrib-data/pending/$WA_DA_STEM.json"
printf '{"mix":7}\n' > "$WT/repo/contrib-data/pending/$WA_DA_STEM.body.md"
printf 'seed\n' > "$WT/repo/contrib-data/scratch/mix-out2.md"
snap_before
rm -f "$WT/repo/contrib-data/pending/$WA_DA_STEM.json" "$WT/repo/contrib-data/pending/$WA_DA_STEM.body.md"
printf '[%s] notify: 本窗活跃记录（不具名）\n' "$WA_DA_ACT_TS" >> "$(wa_da_log)"
printf '%smode=mix-suite2\n' "$WA_MARKER_PREFIX" > "$WT/repo/contrib-data/pending/mix-suite2.json"
printf 'outside change\n' > "$WT/repo/contrib-data/scratch/mix-out2.md"
snap_after
run_classify
WA_DA_MIX_N="$(awk -F'\t' 'NR == FNR { b[$5] = $0; next } { a[$5] = $0 }
  END { n = 0
    for (p in b) if (!(p in a)) n++
    for (p in a) { if (!(p in b)) n++; else if (a[p] != b[p]) n++ }
    print n }' "$WT/before" "$WT/after")"
assert_eq "$WA_DA_MIX_N" "5" "C40 窗口差集=5（2 删除 + 1 追加 + 1 新建 + 1 面外改写）"
assert_eq "$(sum_key external)" "3" "C40 external=3（2 条 D-α 删除 + 1 条追加）"
assert_eq "$(sum_key suite)" "1" "C40 suite=1（marker 新建）"
assert_eq "$(sum_key outside)" "1" "C40 outside=1（面外改写）"
assert_eq "$(sum_key total)" "$WA_DA_MIX_N" "C40 total==窗口差集文件数（等值，非 >=）"
assert_eq "$(( $(sum_key external) + $(sum_key suite) + $(sum_key outside) ))" "$(sum_key total)" "C40 三类和==total（D-α 行不计旁路）"
assert_eq "$(sum_key unclassified)" "0" "C40 unclassified=0"
assert_eq "$(cls_of_path "contrib-data/pending/$WA_DA_STEM.json")" "external" "C40 D-α 删除逐文件归类（json）"
assert_eq "$(reason_of_path "contrib-data/pending/$WA_DA_STEM.body.md")" "ownership-delete-ok" "C40 D-α 删除逐文件归类（body.md）"
assert_eq "$(cls_of_path contrib-data/pending/mix-suite2.json)" "suite" "C40 marker 新建 = suite"
assert_eq "$(cls_of_path contrib-data/scratch/mix-out2.md)" "outside-surface" "C40 面外改写 = outside-surface"
assert_eq "$(cls_of_path contrib-data/logs/notify.log)" "external" "C40 追加 = external"

t_finish
