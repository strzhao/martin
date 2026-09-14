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

t_case "C0 前置：清单可解析（默认路径 / 10 条 / 三模式齐备）"
WA_REG_RC=0
WA_DEF_REG="$(wa_registry_default "$TESTS_ROOT")" || WA_REG_RC=$?
assert_exit "0" "$WA_REG_RC" "C0 wa_registry_default rc=0"
assert_ne "$WA_DEF_REG" "" "C0 wa_registry_default 输出清单路径"
assert_eq "$(basename "$WA_DEF_REG")" "production-writers.tsv" "C0 清单文件名"
WA_LOAD_RC=0
wa__registry_load "$WA_DEF_REG" || WA_LOAD_RC=$?
assert_exit "0" "$WA_LOAD_RC" "C0 清单解析 rc=0"
assert_eq "$WA_R_N" "10" "C0 清单条目数=10（第 2 轮裁决 +l2-ledger 后）"
NW_APPEND=0; NW_RW=0; NW_CR=0
for ((i = 0; i < WA_R_N; i++)); do
  case "${WA_R_MODE[$i]}" in
    append-records) NW_APPEND=$((NW_APPEND + 1)) ;;
    corroborated-rewrite) NW_RW=$((NW_RW + 1)) ;;
    corroborated-create) NW_CR=$((NW_CR + 1)) ;;
  esac
done
assert_eq "$NW_APPEND" "4" "C0 append-records 条目=4（collect/notify/execute/l2-ledger）"
assert_eq "$NW_RW" "5" "C0 corroborated-rewrite 条目=5"
assert_eq "$NW_CR" "1" "C0 corroborated-create 条目=1（pending/*）"

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
assert_eq "$(grep -c '^WA-SELFTEST ok' "$WA_TMP/selftest.out" | tr -d ' ')" "21" "C21 自证 ok 计数=21（19 形态 + 2 计数断言）"

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

t_finish
