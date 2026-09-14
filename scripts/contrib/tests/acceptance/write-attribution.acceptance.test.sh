#!/usr/bin/env bash
# =============================================================================
# write-attribution.acceptance.test.sh — 验收：s4 4.P1 / t1-04 4.1「写入归属定性」引擎
#
# 依据：state.md `## 设计文档`（含「计划评审实证修正」）/ `## 契约规约` / `## 验收场景`（预注册
#   SSOT，标 [调和] 者以调和版为准）+ $TASK_DIR/context.md 历史知识。本文件为**红队独立验收套件**，
#   仅由设计文档契约驱动；不复制被测实现内容、不引用其行号、不假定其私有成员。
#
# 被测对象（全部**黑盒驱动**，本文件不读取其源码）：
#   A) 归属引擎 `scripts/contrib/tests/lib/write-attribution.sh`
#      — 按契约签名调用 wa_snapshot / wa_classify（子 shell 内 source 后调用，stdout/rc 求值）
#   B) 改造后的 `scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh`
#   C) 改造后的 `scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh`
#      — B/C 仅以 grep 命令位扫描 + 断言行计数（黑盒），不读取其实现逻辑
#
# 覆盖矩阵（reason 覆盖矩阵 + 必覆盖清单 1–6）：
#   S1  registered-append-ok        合规追加（字母表内 + 在窗 ts）
#   S2  alphabet-violation          字母表外追加（marker 文本**不含** S4-P1- 前缀行）
#   S2b canary-marker               新增内容含以 S4-P1- 开头的行 ⇒ 无条件 suite
#   S2c canary-marker 优先级        同窗佐证齐备 ∧ 新增含 S4-P1- 行 ⇒ 仍 suite（先于佐证判定）
#   S3  not-append-only             截断重写
#   S4  inode-changed               mv 替换（内容为前缀追加，仅 inode 变）
#   S5  empty-append                touch（size/hash 不变，仅 mtime 变）
#   S6  registered-append-ok        时间戳边界正例 ts == window_end + 120s
#   S7  timestamp-out-of-window     时间戳边界反例 ts == window_end + 121s
#   S8  no-corroboration            佐证缺失（corroborated-rewrite 无在窗佐证记录）
#   S8b no-corroboration 时序近邻   佐证在窗但 |佐证 ts − 变更文件 mtime| > 30s ⇒ suite
#   S9  created-unallowed|no-corroboration  判据面新建（glob 模式 + 精确路径 双形态）
#   S10 corroborated-ok             佐证齐备（改写 + 佐证日志在窗记录 + Δt ≤ 30s）
#   S11 outside-surface             面外路径（证据行存在、不判失败、不静默丢弃）
#   S12 零变更                      total=0 ∧ rc=0 ∧ 零 per-file 行
#   S13 exit 2 fail-closed          清单缺失 / 空 / NF≠5 / 无捕获组 / mode 非法 /
#                                   corroborated 佐证 :none / 快照缺失 / 窗口非整数
#   S14 恒等式                      每例核 total == external + suite + outside ∧ unclassified == 0
#   M1/M2 mutation 抗性             库副本注入「一律 external」「未注册也放行」→ 同一检查器必转红
#   E1–E3 影子端到端                canary-create / canary-append / external-append 真跑 s4
#   G1–G3 守卫不回归                s4 命令位 /usr/bin/diff == 2、t1-04 == 1、裸 diff == 0、
#                                   各恰 1 行 `-x /usr/bin/diff`；diff-pin-canary 套件仍 rc=0；无 skip 降级
#   N1–N3 断言条数防删锚            s4 4.P1 段 / t1-04 4.1 段断言行数 ≥ 改造前基线（冻结常量）
#
# 所依据的谓词口径版本：state.md `## 验收场景` **第 2 轮定向重审后**的版本，即
#   ① 类别闭集 = 三值 {suite, external, outside-surface}（场景3.P1 / 4.P4 同口径）；
#   ② reason 闭集含 `canary-marker`（新增内容含以 `S4-P1-` 开头的行 ⇒ 无条件 suite，先于佐证判定）；
#   ③ `corroborated-*` 成立需两条同时满足：佐证日志在窗有合规记录 ∧ |佐证 ts − 变更文件 mtime| ≤ 30s；
#   ④ 清单 10 条 + 覆盖守卫三条声明式排除谓词（谓词面归单测 C16，本套件不重复求值）。
#
# 纪律：
#   - 每条断言硬失败（无 SKIP / 无 warn 降级 / 无 `|| true` 宽容 / 无条件放行）
#   - 零仓内写入：临时产物只进 mktemp 目录（EXIT trap 清理）；影子 contrib-data 由本套件创建、
#     退出时删除；**禁**写真实生产 contrib-data；**禁**调用 hermes/gh/claude/tunnel/osascript
#   - 契约模糊处标 CONTRACT_AMBIGUOUS（见文末清单），不推测未声明的私有成员
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  printf 'ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析（%s 非 git 仓 / git 不可用）\n' "$SELF_DIR" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
ENGINE_LIB="$TESTS_ROOT/lib/write-attribution.sh"
S4="$TESTS_ROOT/acceptance/s4-production-zero-touch.acceptance.sh"
T104="$TESTS_ROOT/acceptance/t1-04-isolation-sandbox.acceptance.test.sh"
CANARY="$TESTS_ROOT/acceptance/diff-pin-canary.acceptance.test.sh"

# 改造前冻结基线：HEAD@71b6956（本卡实现提交之前的 main 侧合并点）；断言行数基线由该版本量测。
FROZEN_SHA="71b6956"
S4_REL="scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh"
T104_REL="scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh"
BASE_S4_P1_ASSERTS=2      # 旧版 4.P1 段：`[ -s ... ] || die` + `eq "$DIFFN" 0`
BASE_T104_41_ASSERTS=4    # 旧版 4.1 段：`_fail` ×2 + `assert_eq` ×2

export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$TESTS_ROOT/lib/assert.sh"
t_init "$T_FILE"

WA_SB="$(mktemp -d "${TMPDIR:-/tmp}/acc-wa.XXXXXX")" || {
  printf 'ACCEPTANCE-FAIL[env]: mktemp 失败（无法建立临时工作区）\n' >&2
  exit 1
}
SHADOW="$REPO_ROOT/contrib-data"
SHADOW_CREATED=0
_cleanup() {
  rm -rf "$WA_SB"
  if [ "$SHADOW_CREATED" = "1" ] && [ -d "$SHADOW" ]; then rm -rf "$SHADOW"; fi
}
trap '_cleanup' EXIT

# --- 工具绝对路径（避开 PATH 遮蔽面；context.md：PATH 上第三方 diff 恒 rc=0 零输出）--------
PIN_DIFF=/usr/bin/diff
PIN_DATE=/bin/date
PIN_PGREP=/usr/bin/pgrep
ART="/tmp/autopilot-artifacts"

# =============================================================================
# 通用黑盒驱动 / 解析助手
# =============================================================================

# wa_* 在**子 shell 内** source 后调用（隔离被测库对父 shell 的副作用）
_wa_call() { # <fn> <args...> → rc/stdout 透传
  local fn="$1"
  shift
  # shellcheck source=/dev/null
  ( . "$ENGINE_LIB" >/dev/null 2>&1; "$fn" "$@" )
}
_wa_call_lib() { # <lib> <fn> <args...>
  local lib="$1"
  local fn="$2"
  shift 2
  # shellcheck source=/dev/null
  ( . "$lib" >/dev/null 2>&1; "$fn" "$@" )
}

# 末行计数（契约 stdout 末行：WA total=<n> external=<n> suite=<n> [outside=<n>] unclassified=<n> diff_lines=<n>）
_wa_sum() { # <stdout-file> <key> → 值（缺失=空）
  awk -v k="$2" '
    /^WA / { n=split($0, a, " "); for (i=1;i<=n;i++) { if (index(a[i], k "=") == 1) v=substr(a[i], length(k)+2) } }
    END { if (v != "") print v }' "$1"
}

# 逐 WA-CLASS 行的 reason / class / 计数（契约：WA-CLASS <class> path=<p> reason=<tok> …）
_class_counts() { # <out> → "external suite outside unknown"（文件缺失 ⇒ unknown=1 计一违规）
  if [ ! -f "$1" ]; then
    printf '0 0 0 1'
    return 0
  fi
  awk '/^WA-CLASS / {
      r=""
      for (i=1;i<=NF;i++) { if (index($i,"reason=") == 1) r=substr($i,8) }
      if (r=="registered-append-ok" || r=="corroborated-ok") e++
      else if (r=="not-append-only" || r=="inode-changed" || r=="alphabet-violation" || r=="empty-append" || r=="timestamp-out-of-window" || r=="created-unallowed" || r=="deleted" || r=="no-corroboration" || r=="canary-marker") s++
      else if (r=="outside-surface") o++
      else x++
    }
    END { printf "%d %d %d %d", e+0, s+0, o+0, x+0 }' "$1"
}
_class_line_count() { # <out> → per-file 分类行数（文件缺失 ⇒ -1，令调用方转红）
  if [ ! -f "$1" ]; then
    printf -- '-1'
    return 0
  fi
  awk '/^WA-CLASS /{c++} END{print c+0}' "$1"
}

# 恒等式检查器（**纯谓词**，输出违规清单；空输出 = 全过）
# 覆盖：键齐备 / unclassified==0 / total==行数 / external,suit 计数对齐 / total==external+suite+outside /
#       reason ∈ 闭集 / class↔reason 一致 / 每行含 path
_identity_report() { # <stdout-file> <out-file>
  local so="$1" out="$2" t e s o u d cl cnt ext sui outs x
  if [ ! -f "$so" ]; then printf 'VIOL 引擎 stdout 文件缺失（引擎未产出？）: %s\n' "$so"; fi
  if [ ! -f "$out" ]; then
    printf 'VIOL per-file 分类文件缺失（引擎未产出 <out>？）: %s\n' "$out"
    return 0
  fi
  t="$(_wa_sum "$so" total)"; e="$(_wa_sum "$so" external)"; s="$(_wa_sum "$so" suite)"
  o="$(_wa_sum "$so" outside)"; u="$(_wa_sum "$so" unclassified)"; d="$(_wa_sum "$so" diff_lines)"
  cnt="$(_class_counts "$out")"
  ext="$(printf '%s' "$cnt" | awk '{print $1}')"
  sui="$(printf '%s' "$cnt" | awk '{print $2}')"
  outs="$(printf '%s' "$cnt" | awk '{print $3}')"
  x="$(printf '%s' "$cnt" | awk '{print $4}')"
  cl="$(_class_line_count "$out")"

  [ -n "$t" ] || printf 'VIOL 末行缺 key: total\n'
  [ -n "$e" ] || printf 'VIOL 末行缺 key: external\n'
  [ -n "$s" ] || printf 'VIOL 末行缺 key: suite\n'
  [ -n "$u" ] || printf 'VIOL 末行缺 key: unclassified\n'
  [ -n "$d" ] || printf 'VIOL 末行缺 key: diff_lines\n'
  [ -n "${t:-}" ] && [ -n "${e:-}" ] && [ -n "${s:-}" ] && [ -n "${u:-}" ] && [ -n "${d:-}" ] || return 0

  [ "$u" = "0" ] || printf 'VIOL unclassified=%s（恒等式要求 0）\n' "$u"
  [ "$t" = "$cl" ] || printf 'VIOL total=%s ≠ WA-CLASS 行数=%s（每变更文件恰 1 行）\n' "$t" "$cl"
  [ "$e" = "$ext" ] || printf 'VIOL 末行 external=%s ≠ 分类行 external 数=%s\n' "$e" "$ext"
  [ "$s" = "$sui" ] || printf 'VIOL 末行 suite=%s ≠ 分类行 suite 数=%s\n' "$s" "$sui"
  if [ -n "$o" ]; then
    [ "$o" = "$outs" ] || printf 'VIOL 末行 outside=%s ≠ 分类行 outside 数=%s\n' "$o" "$outs"
  fi
  [ "$t" = "$((e + s + outs))" ] || printf 'VIOL total=%s ≠ external(%s)+suite(%s)+outside(%s)\n' "$t" "$e" "$s" "$outs"
  [ "$x" = "0" ] || printf 'VIOL %s 行的 reason 不在契约闭集内\n' "$x"
  [ "$d" = "0" ] && { [ "$t" = "0" ] || printf 'VIOL diff_lines=0 却 total=%s（零变更应无 per-file 行）\n' "$t"; }
  awk '/^WA-CLASS / {
      cat=$2; r=""; p=""
      for (i=1;i<=NF;i++) { if (index($i,"reason=")==1) r=substr($i,8); if (index($i,"path=")==1) p=substr($i,6) }
      if (r=="registered-append-ok" || r=="corroborated-ok") expc="external"
      else if (r=="outside-surface") expc="outside"
      else if (r=="not-append-only" || r=="inode-changed" || r=="alphabet-violation" || r=="empty-append" || r=="timestamp-out-of-window" || r=="created-unallowed" || r=="deleted" || r=="no-corroboration" || r=="canary-marker") expc="suite"
      else expc="UNKNOWN"
      if (expc=="UNKNOWN") printf "VIOL reason 越界: %s（path=%s）\n", r, p
      else if (expc=="outside") { if (cat!="outside" && cat!="outside-surface") printf "VIOL class/reason 失配: class=%s reason=%s path=%s\n", cat, r, p }
      else if (cat != expc) printf "VIOL class/reason 失配: class=%s reason=%s path=%s\n", cat, r, p
      if (p == "") printf "VIOL 分类行缺 path 字段: %s\n", $0
    }' "$out"
}

# 期望检查器（纯谓词）：指定 path 的分类行必须存在且 reason ∈ 期望集
_expect_report() { # <out> <path> <reason1|reason2|...>
  if [ ! -f "$1" ]; then
    printf 'VIOL 分类文件缺失（无法判定期望行 path=%s）: %s\n' "$2" "$1"
    return 0
  fi
  awk -v wp="$2" -v wr="$3" '
    BEGIN { np=split(wr, rs, "|") }
    /^WA-CLASS / {
      p=""; r=""
      for (i=1;i<=NF;i++) { if (index($i,"path=")==1) p=substr($i,6); if (index($i,"reason=")==1) r=substr($i,8) }
      if (p == wp) {
        found++
        hit=0
        for (j=1;j<=np;j++) { if (r == rs[j]) hit=1 }
        if (hit == 0) printf "VIOL path=%s 的 reason=%s 不在期望集 {%s}\n", p, r, wr
      }
    }
    END { if (found == 0) printf "VIOL 未找到 path=%s 的任何 WA-CLASS 行\n", wp }' "$1"
}

_absent_report() { # <out> <path> → 该 path 若存在分类行则报违规
  if [ ! -f "$1" ]; then
    printf 'VIOL 分类文件缺失（无法判定缺席 path=%s）: %s\n' "$2" "$1"
    return 0
  fi
  awk -v wp="$2" '
    /^WA-CLASS / {
      p=""
      for (i=1;i<=NF;i++) { if (index($i,"path=")==1) p=substr($i,6) }
      if (p == wp) printf "VIOL path=%s 不应出现分类行\n", p
    }' "$1"
}

# =============================================================================
# 合成树（形态学全表）——自建仓根 + 自建清单，不依赖真实 contrib-data
# =============================================================================
SYN_ROOT=""; SNAP_B=""; SNAP_A=""; R_RC=""; R_SO=""; R_OUT=""
SYN_REG="$WA_SB/registry.tsv"
TSTAMP_RE='([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})'
ALPHA_APP="^\\[${TSTAMP_RE}\\] app: |^OK\$"

{
  printf 'contrib-data/logs/app.log\tapp\tappend-records\t%s\t:none\n' "$ALPHA_APP"
  printf 'contrib-data/state.json\tappstate\tcorroborated-rewrite\t%s\tcontrib-data/logs/app.log\n' "$ALPHA_APP"
  printf 'contrib-data/newdir/*\tappnew\tcorroborated-create\t%s\tcontrib-data/logs/app.log\n' "$ALPHA_APP"
  printf 'contrib-data/newfile.json\tappnew2\tcorroborated-create\t%s\tcontrib-data/logs/app.log\n' "$ALPHA_APP"
} > "$SYN_REG"

_syn_before() { # <tag> → 建合成仓根 + before 快照
  local tag="$1" rc
  SYN_ROOT="$WA_SB/syn.$tag"
  mkdir -p "$SYN_ROOT/contrib-data/logs" "$SYN_ROOT/contrib-data/newdir" "$SYN_ROOT/contrib-data/scratch"
  printf '[2026-01-01 00:00:00] app: seed-a\n' > "$SYN_ROOT/contrib-data/logs/app.log"
  printf '[2026-01-01 00:00:01] app: seed-b\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
  printf '{"state":"seed"}\n' > "$SYN_ROOT/contrib-data/state.json"
  printf 'draft\n' > "$SYN_ROOT/contrib-data/scratch/draft.md"
  SNAP_B="$WA_SB/$tag.before.snap"
  SNAP_A="$WA_SB/$tag.after.snap"
  _wa_call wa_snapshot "$SYN_ROOT" "$SNAP_B" > "$WA_SB/$tag.snapb.out" 2>&1
  rc=$?
  [ "$rc" = "0" ] || _fail "前置 wa_snapshot(before) rc=0" "rc=$rc tag=${tag}；合成树快照失败"
  [ -s "$SNAP_B" ] || _fail "前置 快照非空" "tag=${tag}；快照为空 ${SNAP_B}"
}

_syn_after() { # <tag> <t0> <t1> [registry] → after 快照 + classify，设 R_RC/R_SO/R_OUT
  local tag="$1" t0="$2" t1="$3" reg="${4:-$SYN_REG}" rc
  R_SO="$WA_SB/$tag.classify.out"
  R_OUT="$WA_SB/$tag.wa-class"
  _wa_call wa_snapshot "$SYN_ROOT" "$SNAP_A" > "$WA_SB/$tag.snapa.out" 2>&1
  rc=$?
  [ "$rc" = "0" ] || _fail "前置 wa_snapshot(after) rc=0" "rc=$rc tag=$tag"
  _wa_call wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$reg" "$R_OUT" "$t0" "$t1" > "$R_SO" 2>&1
  R_RC=$?
}

# 组合检查器（纯谓词）：rc + 恒等式 + 期望行；输出违规清单（空 = 通过）
_case_report() { # <rc> <want-rc> <so> <out> <path> <reasons>
  local rc="$1" want="$2" so="$3" out="$4" p="$5" r="$6" digest=""
  [ -f "$so" ] && digest="$(tr '\n' '|' < "$so")"
  [ "$rc" = "$want" ] || printf 'VIOL wa_classify rc=%s 期望 %s；引擎输出=[%s]\n' "$rc" "$want" "$digest"
  _identity_report "$so" "$out"
  _expect_report "$out" "$p" "$r"
}

# 组合断言：rc + 恒等式 + 期望行
_case_asserts() { # <tag> <want-rc> [<path> <reasons>] ...
  local tag="$1" want="$2" rep digest=""
  shift 2
  [ -f "$R_SO" ] && digest="$(tr '\n' '|' < "$R_SO")"
  assert_eq "$R_RC" "$want" "${tag} wa_classify rc 期望 ${want}；引擎输出=[${digest}]"
  rep="$(_identity_report "$R_SO" "$R_OUT")"
  assert_eq "$rep" "" "$tag 账目恒等式 total==external+suite+outside ∧ unclassified==0"
  while [ "$#" -gt 0 ]; do
    rep="$(_expect_report "$R_OUT" "$1" "$2")"
    assert_eq "$rep" "" "$tag 分类行 path=$1 reason∈{$2}"
    shift 2
  done
}

# =============================================================================
t_case "S0 环境前置：引擎库存在且可 source（契约 API 可调用）"
if [ ! -f "$ENGINE_LIB" ]; then
  _fail "前置 引擎库存在" "缺失: ${ENGINE_LIB}；归属引擎未交付"
  t_finish
fi
[ -x "$PIN_DIFF" ] || { _fail "前置 /usr/bin/diff" "缺失（pin 绝对路径前提）"; t_finish; }
[ -x "$PIN_DATE" ] || { _fail "前置 /bin/date" "缺失"; t_finish; }
_wa_call wa_registry_default "$TESTS_ROOT" > "$WA_SB/reg-default.out" 2>/dev/null
REG_DEFAULT_RC=$?
assert_eq "$REG_DEFAULT_RC" "0" "S0 wa_registry_default rc=0（API 可达）"
assert_ne "$(awk 'NF{n=1} END{print n+0}' "$WA_SB/reg-default.out")" "0" \
  "S0 wa_registry_default stdout 给出清单路径（非空）"

NOW="$("$PIN_DATE" +%s)"
W0=$((NOW - 300))
W1="$NOW"

# =============================================================================
t_case "S1 registered-append-ok：合规追加（字母表内 + 在窗时间戳）→ external"
_syn_before s1
S1T="$("$PIN_DATE" +%s)"
printf '[%s] app: tick-1\n' "$("$PIN_DATE" -r "$S1T" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
# 边界：追加块含一条字母表内无时间戳记录（^OK$）也不得整体判红
printf 'OK\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s1 "$((S1T - 60))" "$S1T"
_case_asserts "S1" "0" "contrib-data/logs/app.log" "registered-append-ok"

# =============================================================================
t_case "S2 alphabet-violation：注册路径追加字母表外行（非 S4-P1- marker）→ suite"
_syn_before s2
printf 'WA-ALPHABET-OUT-OF-SET line\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s2 "$W0" "$W1"
_case_asserts "S2" "0" "contrib-data/logs/app.log" "alphabet-violation"

# =============================================================================
t_case "S2b canary-marker：新增内容含以 S4-P1- 开头的行 ⇒ 无条件 suite"
_syn_before s2b
printf 'S4-P1-CANARY-MARKER injected-by-suite\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s2b "$W0" "$W1"
_case_asserts "S2b" "0" "contrib-data/logs/app.log" "canary-marker"

# =============================================================================
t_case "S2c canary-marker 优先级：佐证齐备 ∧ 新增含 S4-P1- 行 ⇒ 仍判 suite（先于佐证判定）"
_syn_before s2c
S2CT="$("$PIN_DATE" +%s)"
printf 'S4-P1-CANARY-MARKER on-corroborated-path\n' >> "$SYN_ROOT/contrib-data/state.json"
printf '[%s] app: corroborating-tick\n' "$("$PIN_DATE" -r "$S2CT" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s2c "$((S2CT - 300))" "$S2CT"
_case_asserts "S2c" "0" \
  "contrib-data/state.json" "canary-marker" \
  "contrib-data/logs/app.log" "registered-append-ok"

# =============================================================================
t_case "S3 not-append-only：截断重写 → suite"
_syn_before s3
printf '[%s] app: rewritten\n' "$("$PIN_DATE" -r "$W1" '+%Y-%m-%d %H:%M:%S')" > "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s3 "$W0" "$W1"
_case_asserts "S3" "0" "contrib-data/logs/app.log" "not-append-only"

# =============================================================================
t_case "S4 inode-changed：mv 替换（内容为前缀追加，仅 inode 变）→ suite"
_syn_before s4
cp "$SYN_ROOT/contrib-data/logs/app.log" "$WA_SB/s4.repl"
printf '[%s] app: appended\n' "$("$PIN_DATE" -r "$W1" '+%Y-%m-%d %H:%M:%S')" >> "$WA_SB/s4.repl"
mv "$WA_SB/s4.repl" "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s4 "$W0" "$W1"
_case_asserts "S4" "0" "contrib-data/logs/app.log" "inode-changed"

# =============================================================================
t_case "S5 empty-append：touch（内容不变，仅 mtime 变）→ suite"
_syn_before s5
sleep 1
touch "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s5 "$W0" "$W1"
_case_asserts "S5" "0" "contrib-data/logs/app.log" "empty-append"

# =============================================================================
t_case "S6 时间戳边界正例：ts == window_end + 120s → external"
_syn_before s6
B1="$("$PIN_DATE" +%s)"
printf '[%s] app: edge-plus-120\n' "$("$PIN_DATE" -r "$((B1 + 120))" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s6 "$((B1 - 300))" "$B1"
_case_asserts "S6" "0" "contrib-data/logs/app.log" "registered-append-ok"

# =============================================================================
t_case "S7 时间戳边界反例：ts == window_end + 121s → suite(timestamp-out-of-window)"
_syn_before s7
B2="$("$PIN_DATE" +%s)"
printf '[%s] app: edge-plus-121\n' "$("$PIN_DATE" -r "$((B2 + 121))" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s7 "$((B2 - 300))" "$B2"
_case_asserts "S7" "0" "contrib-data/logs/app.log" "timestamp-out-of-window"

# =============================================================================
t_case "S8 no-corroboration：corroborated-rewrite 改写但佐证日志无在窗记录 → suite"
_syn_before s8
printf '{"state":"changed-without-corroboration"}\n' > "$SYN_ROOT/contrib-data/state.json"
_syn_after s8 "$W0" "$W1"
_case_asserts "S8" "0" "contrib-data/state.json" "no-corroboration"

# =============================================================================
t_case "S8b no-corroboration（时序近邻）：佐证在窗但 |佐证 ts − 变更文件 mtime| > 30s → suite"
_syn_before s8b
S8T="$("$PIN_DATE" +%s)"
printf '{"state":"late-corroboration"}\n' > "$SYN_ROOT/contrib-data/state.json"
printf '[%s] app: corroborating-late\n' "$("$PIN_DATE" -r "$S8T" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
touch -t "$("$PIN_DATE" -r "$((S8T - 120))" '+%Y%m%d%H%M.%S')" "$SYN_ROOT/contrib-data/state.json"
_syn_after s8b "$((S8T - 300))" "$S8T"
_case_asserts "S8b" "0" "contrib-data/state.json" "no-corroboration"
assert_ne "$(awk '/WA-CLASS /{ if (index($0,"Δt=") > 0) c++ } END{print c+0}' "$R_OUT")" "0" \
  "S8b 佐证判定的 evidence 行带 Δt=<n>s（第 2 轮口径「evidence 行带 Δt」；见 CONTRACT_AMBIGUOUS ⑤）"

# =============================================================================
t_case "S9 created-unallowed/no-corroboration：判据面新建（glob 模式 + 精确路径）→ suite"
_syn_before s9
printf 'marker\n' > "$SYN_ROOT/contrib-data/newdir/marker.txt"
printf '{"fresh":true}\n' > "$SYN_ROOT/contrib-data/newfile.json"
_syn_after s9 "$W0" "$W1"
_case_asserts "S9" "0" \
  "contrib-data/newdir/marker.txt" "created-unallowed|no-corroboration" \
  "contrib-data/newfile.json" "created-unallowed|no-corroboration"

# =============================================================================
t_case "S10 corroborated-ok：改写 + 佐证日志在窗记录 + Δt ≤ 30s → external"
_syn_before s10
S10T="$("$PIN_DATE" +%s)"
printf '{"state":"changed-with-corroboration"}\n' > "$SYN_ROOT/contrib-data/state.json"
printf '[%s] app: corroborating-tick\n' "$("$PIN_DATE" -r "$S10T" '+%Y-%m-%d %H:%M:%S')" >> "$SYN_ROOT/contrib-data/logs/app.log"
_syn_after s10 "$((S10T - 300))" "$S10T"
_case_asserts "S10" "0" \
  "contrib-data/state.json" "corroborated-ok" \
  "contrib-data/logs/app.log" "registered-append-ok"
assert_ne "$(awk '/WA-CLASS /{ if (index($0,"Δt=") > 0) c++ } END{print c+0}' "$R_OUT")" "0" \
  "S10 佐证判定的 evidence 行带 Δt=<n>s"

# =============================================================================
t_case "S11 outside-surface：面外路径变更落证据行、不判失败、不静默丢弃"
_syn_before s11
printf 'draft-more\n' >> "$SYN_ROOT/contrib-data/scratch/draft.md"
_syn_after s11 "$W0" "$W1"
_case_asserts "S11" "0" "contrib-data/scratch/draft.md" "outside-surface"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S11 面外变更不得计入 suite（不判失败）"
assert_eq "$(_wa_sum "$R_SO" outside)" "1" "S11 面外变更计入 outside 计数"

# =============================================================================
t_case "S12 零变更：total=0 ∧ diff_lines=0 ∧ rc=0 ∧ 零 per-file 行"
_syn_before s12
_syn_after s12 "$W0" "$W1"
assert_eq "$R_RC" "0" "S12 零变更 rc=0"
assert_eq "$(_wa_sum "$R_SO" total)" "0" "S12 total=0"
assert_eq "$(_wa_sum "$R_SO" diff_lines)" "0" "S12 diff_lines=0"
assert_eq "$(_wa_sum "$R_SO" external)" "0" "S12 external=0"
assert_eq "$(_wa_sum "$R_SO" suite)" "0" "S12 suite=0"
assert_eq "$(_wa_sum "$R_SO" unclassified)" "0" "S12 unclassified=0"
assert_eq "$(_class_line_count "$R_OUT")" "0" "S12 零变更无 per-file 分类行"
assert_eq "$(_identity_report "$R_SO" "$R_OUT")" "" "S12 零变更账目恒等式"

# =============================================================================
t_case "S13 fail-closed：清单缺失/空/NF≠5/无捕获组/mode 非法/佐证 :none/快照缺失/窗口非整数 → exit 2"
_syn_before s13
_syn_after s13 "$W0" "$W1"
S13_SO="$R_SO"; S13_OUT="$R_OUT"

: > "$WA_SB/reg.empty.tsv"
printf 'contrib-data/logs/app.log\tapp\tappend-records\t%s\n' "$ALPHA_APP" > "$WA_SB/reg.nf4.tsv"
printf 'contrib-data/logs/app.log\tapp\tappend-records\t^OK$\t:none\n' > "$WA_SB/reg.nogroup.tsv"
printf 'contrib-data/logs/app.log\tapp\tfrobnicate\t%s\t:none\n' "$ALPHA_APP" > "$WA_SB/reg.badmode.tsv"
printf 'contrib-data/state.json\tappstate\tcorroborated-rewrite\t%s\t:none\n' "$ALPHA_APP" > "$WA_SB/reg.conone.tsv"

_fc_case() { # <tag> <expected-rc> <before-snap> <registry> <t0> <t1>
  local tag="$1" want="$2" bs="$3" reg="$4" t0="$5" t1="$6" rc so out
  so="$WA_SB/$tag.classify.out"
  out="$WA_SB/$tag.wa-class"
  _wa_call wa_classify "$SYN_ROOT" "$bs" "$SNAP_A" "$reg" "$out" "$t0" "$t1" > "$so" 2>&1
  rc=$?
  assert_eq "$rc" "$want" "${tag} fail-closed rc 期望 ${want}；禁静默绿"
}

_fc_case "S13a 清单缺失" "2" "$SNAP_B" "$WA_SB/no-such-registry.tsv" "$W0" "$W1"
_fc_case "S13b 清单空" "2" "$SNAP_B" "$WA_SB/reg.empty.tsv" "$W0" "$W1"
_fc_case "S13c NF≠5" "2" "$SNAP_B" "$WA_SB/reg.nf4.tsv" "$W0" "$W1"
_fc_case "S13d 无捕获组" "2" "$SNAP_B" "$WA_SB/reg.nogroup.tsv" "$W0" "$W1"
_fc_case "S13e mode 非法" "2" "$SNAP_B" "$WA_SB/reg.badmode.tsv" "$W0" "$W1"
_fc_case "S13f corroborated 佐证 :none" "2" "$SNAP_B" "$WA_SB/reg.conone.tsv" "$W0" "$W1"
_fc_case "S13g 快照缺失" "2" "$WA_SB/no-such-snapshot.snap" "$SYN_REG" "$W0" "$W1"
_fc_case "S13h 窗口非整数" "2" "$SNAP_B" "$SYN_REG" "abc" "$W1"
assert_eq "$(_identity_report "$S13_SO" "$S13_OUT")" "" "S13 对照：同输入 + 合法清单 rc=0 且恒等式成立（防「恒 exit 2」假通过）"

# =============================================================================
t_case "M1 mutation 抗性：库副本注入「一律 external」→ 同一形态结果必与正确版不同"
MUT_LIB="$WA_SB/mut-lib.sh"
cp "$ENGINE_LIB" "$MUT_LIB"
sed 's/suite/external/g' "$ENGINE_LIB" > "$MUT_LIB"

# 先造 S2 形态（字母表外追加）的 before/after 快照，供两版引擎共用同一输入
_syn_before m1
printf 'WA-ALPHABET-OUT-OF-SET line\n' >> "$SYN_ROOT/contrib-data/logs/app.log"
_wa_call wa_snapshot "$SYN_ROOT" "$SNAP_A" > /dev/null 2>&1

M1_C_SO="$WA_SB/m1.correct.out"; M1_C_OUT="$WA_SB/m1.correct.wa"
_wa_call wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M1_C_OUT" "$W0" "$W1" > "$M1_C_SO" 2>&1
M1_C_RC=$?
M1_M_SO="$WA_SB/m1.mut.out"; M1_M_OUT="$WA_SB/m1.mut.wa"
_wa_call_lib "$MUT_LIB" wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M1_M_OUT" "$W0" "$W1" > "$M1_M_SO" 2>&1
M1_M_RC=$?

M1_REP_C="$(_case_report "$M1_C_RC" "0" "$M1_C_SO" "$M1_C_OUT" "contrib-data/logs/app.log" "alphabet-violation")"
assert_eq "$M1_REP_C" "" "M1 正确版：字母表外追加 → suite(alphabet-violation)"
M1_REP_M="$(_case_report "$M1_M_RC" "0" "$M1_M_SO" "$M1_M_OUT" "contrib-data/logs/app.log" "alphabet-violation")"
if [ -n "$M1_REP_M" ]; then M1_KILLED=1; else M1_KILLED=0; fi
assert_eq "$M1_KILLED" "1" "M1 mutation「一律 external」被 kill（同一 case 检查器在注入版上转红）"
M1_DIFF="same"
if [ "$M1_C_RC" != "$M1_M_RC" ]; then M1_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M1_C_SO")" != "$(awk 'NF{n=$0} END{print n}' "$M1_M_SO")" ]; then M1_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M1_C_OUT")" != "$(awk 'NF{n=$0} END{print n}' "$M1_M_OUT")" ]; then M1_DIFF="diff"; fi
assert_eq "$M1_DIFF" "diff" "M1 注入后同一形态结果与正确版不同（mutation 确实生效）"

# 检查器自身抗 no-op：对**人为构造的错误输出**必须转红（防「检查器恒绿」）
printf 'WA total=1 external=1 suite=0 outside=0 unclassified=0 diff_lines=2\n' > "$WA_SB/noop.sum"
printf 'WA-CLASS external path=contrib-data/logs/app.log reason=alphabet-violation bytes_added=9\n' > "$WA_SB/noop.cls"
NOOP_REP="$(_identity_report "$WA_SB/noop.sum" "$WA_SB/noop.cls")"
if [ -n "$NOOP_REP" ]; then NOOP_KILL=1; else NOOP_KILL=0; fi
assert_eq "$NOOP_KILL" "1" "M1 检查器自证：class/reason 失配的人造输出必须被检出（非恒绿）"

# =============================================================================
t_case "M2 mutation 抗性：库副本注入「未注册也放行」→ 面外形态结果必与正确版不同"
MUT2_LIB="$WA_SB/mut2-lib.sh"
sed 's/outside-surface/external/g' "$ENGINE_LIB" > "$MUT2_LIB"

_syn_before m2
printf 'draft-more\n' >> "$SYN_ROOT/contrib-data/scratch/draft.md"
_wa_call wa_snapshot "$SYN_ROOT" "$SNAP_A" > /dev/null 2>&1

M2_C_SO="$WA_SB/m2.correct.out"; M2_C_OUT="$WA_SB/m2.correct.wa"
_wa_call wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M2_C_OUT" "$W0" "$W1" > "$M2_C_SO" 2>&1
M2_C_RC=$?
M2_M_SO="$WA_SB/m2.mut.out"; M2_M_OUT="$WA_SB/m2.mut.wa"
_wa_call_lib "$MUT2_LIB" wa_classify "$SYN_ROOT" "$SNAP_B" "$SNAP_A" "$SYN_REG" "$M2_M_OUT" "$W0" "$W1" > "$M2_M_SO" 2>&1
M2_M_RC=$?

M2_REP_C="$(_case_report "$M2_C_RC" "0" "$M2_C_SO" "$M2_C_OUT" "contrib-data/scratch/draft.md" "outside-surface")"
assert_eq "$M2_REP_C" "" "M2 正确版：面外路径 → outside-surface"
M2_REP_M="$(_case_report "$M2_M_RC" "0" "$M2_M_SO" "$M2_M_OUT" "contrib-data/scratch/draft.md" "outside-surface")"
if [ -n "$M2_REP_M" ]; then M2_KILLED=1; else M2_KILLED=0; fi
assert_eq "$M2_KILLED" "1" "M2 mutation「未注册也放行」被 kill（同一 case 检查器在注入版上转红）"
M2_DIFF="same"
if [ "$M2_C_RC" != "$M2_M_RC" ]; then M2_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M2_C_SO")" != "$(awk 'NF{n=$0} END{print n}' "$M2_M_SO")" ]; then M2_DIFF="diff"; fi
if [ "$(awk 'NF{n=$0} END{print n}' "$M2_C_OUT")" != "$(awk 'NF{n=$0} END{print n}' "$M2_M_OUT")" ]; then M2_DIFF="diff"; fi
assert_eq "$M2_DIFF" "diff" "M2 注入后同一形态结果与正确版不同（mutation 确实生效）"

# =============================================================================
# 影子端到端：lane 内自建影子 contrib-data（生产同构 fixture），真跑 s4 三注入模式
# =============================================================================
E2E_OK=0
t_case "E0 影子前置：lane 内不得预置 contrib-data（本套件禁写生产 contrib-data）"
if [ -e "$SHADOW" ]; then
  _fail "E2E 影子前置" "$SHADOW 已存在 —— 拒绝在其上做注入式实跑（可能为生产数据；本套件禁写生产 contrib-data）"
else
  E2E_OK=1
  _pass "E2E 影子前置：${SHADOW} 不存在，可由本套件建立影子树"
fi

if [ "$E2E_OK" = "1" ]; then
  mkdir -p "$SHADOW/logs" "$SHADOW/pending" "$SHADOW/runs"
  SHADOW_CREATED=1
fi

_seed_shadow() { # 幂等重建影子树（生产同构 fixture）
  local now i ts
  mkdir -p "$SHADOW/logs" "$SHADOW/pending" "$SHADOW/runs"
  now="$("$PIN_DATE" +%s)"
  : > "$SHADOW/logs/approval-collect.log"
  i=40
  while [ "$i" -ge 1 ]; do
    ts="$("$PIN_DATE" -r "$((now - i * 90))" '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] approval-collect: rq-20260913-109787: 无提交（no_submission 待决态），继续等待\n' "$ts" >> "$SHADOW/logs/approval-collect.log"
    i=$((i - 1))
  done
  printf '[%s] notify: shadow-fixture\n' "$("$PIN_DATE" '+%Y-%m-%d %H:%M:%S')" > "$SHADOW/logs/notify.log"
  printf '{"state":"shadow"}\n' > "$SHADOW/notify-state.json"
  printf '{"version":1,"items":[]}\n' > "$SHADOW/ready-queue.json"
  printf '{"limits":{"week":3,"day":1},"days":{},"weeks":{},"probes":{}}\n' > "$SHADOW/budget.json"
  : > "$SHADOW/events.jsonl"
}
_shadow_files() { ( cd "$REPO_ROOT" && find contrib-data -type f 2>/dev/null | LC_ALL=C sort ); }

_s4_busy() { # 并发 s4 探测：**命令位**匹配（避免命中他卡 claude -p 提示词文本里的同名串；
  # 相对路径调用 / 跨 checkout 调用一律命中——/tmp/autopilot-artifacts 是跨 checkout 共享的）
  "$PIN_PGREP" -f '[b]ash[[:space:]].*s4-production-zero-touch\.acceptance\.sh' >/dev/null 2>&1
}
_wait_quiet() { # <secs> → 0=静默；1=仍忙
  local max="$1" waited=0
  while [ "$waited" -lt "$max" ]; do
    _s4_busy || return 0
    sleep 5
    waited=$((waited + 5))
  done
  _s4_busy && return 1
  return 0
}

_run_timeout() { # <secs> <outfile> <cmd...> → 124=超时
  local secs="$1" out="$2" waited=0 pid rc
  shift 2
  "$@" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

_e2e_case() { # <mode> → 设 E_RC / E_EV / E_BEFORE / E_AFTER
  local mode="$1"
  local ev="$WA_SB/e2e.$mode.ev"
  local before after
  _seed_shadow
  before="$(_shadow_files)"
  mkdir -p "$ART"
  : > "$ART/s4-p1.out"
  _run_timeout 900 "$WA_SB/e2e.$mode.out" env MARTIN_DIR="$REPO_ROOT" S4_P1_INJECT="$mode" bash "$S4"
  E_RC=$?
  after="$(_shadow_files)"
  {
    printf '%s\n' "=== stdout/stderr ==="
    awk '{print}' "$WA_SB/e2e.$mode.out"
    printf '%s\n' "=== artifact $ART/s4-p1.out ==="
    [ -f "$ART/s4-p1.out" ] && awk '{print}' "$ART/s4-p1.out"
  } > "$ev"
  E_EV="$ev"
  E_BEFORE="$before"
  E_AFTER="$after"
}

t_case "E1 影子实跑 canary-create：套件在判据面新建无佐证文件 → 4.P1 必判红 + 零残留"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E1 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case canary-create
    assert_ne "$E_RC" "0" "E1 canary-create 进程退出码 ≠ 0（判据必须红）"
    assert_ne "$(awk '/ACCEPTANCE-FAIL/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E1 输出含 ACCEPTANCE-FAIL（金丝雀注入被判红）"
    assert_ne "$(awk '/WA-CLASS suite /{n++} END{print n+0}' "$E_EV")" "0" \
      "E1 存在 WA-CLASS suite 分类行（套件写入被指认）"
    assert_ne "$(awk '/WA-CLASS (suite|external|outside|outside-surface) /{n=1} END{print n+0}' "$E_EV")" "0" \
      "E1 分类行形态可解析（WA-CLASS <class> …）"
    assert_ne "$(awk '/no-corroboration|created-unallowed|canary-marker/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E1 判红 reason ∈ {canary-marker, created-unallowed, no-corroboration}"
    assert_eq "$E_AFTER" "$E_BEFORE" "E1 canary 注入物零残留（运行后影子文件集与运行前一致）"
    assert_ne "$(awk '/WA-INJECT/{n=1} END{print n+0}' "$E_EV")" "0" "E1 注入落 WA-INJECT evidence 行（可追责）"
  fi
else
  _fail "E1 影子前置" "影子 contrib-data 未建立（$SHADOW 已存在，拒绝注入式实跑）"
fi

t_case "E2 影子实跑 external-append：合规追加（模拟生产写手）→ 4.P1 PASS ∧ external≥1"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E2 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case external-append
    assert_ne "$(awk '/PASS 4\.P1/{n=1} END{print n+0}' "$E_EV")" "0" "E2 4.P1 PASS（外部写入不误红）"
    E2_EXT="$(awk '/WA total=/{ for (i=1;i<=NF;i++) { if (index($i,"external=") == 1) v=substr($i,10) } } END{ print v }' "$E_EV")"
    E2_EXT="${E2_EXT:-0}"
    if [ "$E2_EXT" -ge 1 ]; then E2_EXT_OK=1; else E2_EXT_OK=0; fi
    assert_eq "$E2_EXT_OK" "1" "E2 external 计数 ≥ 1（实得 ${E2_EXT}）"
    assert_ne "$(awk '/WA-CLASS external .*registered-append-ok/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E2 external 分类行 reason=registered-append-ok"
    E2_SUI="$(awk '/WA total=/{ for (i=1;i<=NF;i++) { if (index($i,"suite=") == 1) v=substr($i,7) } } END{ print v }' "$E_EV")"
    E2_SUI="${E2_SUI:-1}"
    assert_eq "$E2_SUI" "0" "E2 套件写入数 suite=0（4.P1 核心断言口径）"
    E2_UNCL="$(awk '/WA total=/{ for (i=1;i<=NF;i++) { if (index($i,"unclassified=") == 1) v=substr($i,14) } } END{ print v }' "$E_EV")"
    E2_UNCL="${E2_UNCL:-1}"
    assert_eq "$E2_UNCL" "0" "E2 unclassified=0（归属完整性）"
    assert_ne "$(awk '/WA total=/{n=1} END{print n+0}' "$E_EV")" "0" "E2 引擎末行计数行落盘（可 grep）"
  fi
else
  _fail "E2 影子前置" "影子 contrib-data 未建立（拒绝注入式实跑）"
fi

t_case "E3 影子实跑 canary-append：注册路径追加字母表外行 → 4.P1 必判红 ∧ 同 path 无 external 行"
if [ "$E2E_OK" = "1" ]; then
  if ! _wait_quiet 300; then
    _fail "E3 并发前置" "检测到并发 s4 进程；共享 artifact 根 ${ART} 禁并发"
  else
    _e2e_case canary-append
    assert_ne "$E_RC" "0" "E3 canary-append 进程退出码 ≠ 0（判据必须红）"
    assert_ne "$(awk '/WA-CLASS suite .*(alphabet-violation|canary-marker)/{n=1} END{print n+0}' "$E_EV")" "0" \
      "E3 存在 WA-CLASS suite reason ∈ {canary-marker, alphabet-violation}（套件写入被指认）"
    E3_SCNT="$(awk '/WA-CLASS suite /{n++} END{print n+0}' "$E_EV")"
    E3_ECNT="$(awk '/WA-CLASS external /{n++} END{print n+0}' "$E_EV")"
    if [ "$E3_SCNT" -ge 1 ] && [ "$E3_ECNT" = "0" ]; then E3_OK=1; else E3_OK=0; fi
    assert_eq "$E3_OK" "1" "E3 suite ≥ 1（实得 ${E3_SCNT}）∧ 无同窗 external 行（实得 ${E3_ECNT}；套件写入优先定性）"
  fi
else
  _fail "E3 影子前置" "影子 contrib-data 未建立（拒绝注入式实跑）"
fi

if [ "$SHADOW_CREATED" = "1" ]; then
  rm -rf "$SHADOW"
  SHADOW_CREATED=0
fi

t_case "E4 影子树零残留：实跑结束不得在仓内留下影子 contrib-data"
if [ -e "$SHADOW" ]; then
  _fail "E4 影子树已清理" "${SHADOW} 仍存在（本套件退出后必须零仓内残留）"
else
  _pass "E4 影子树已清理（${SHADOW} 不存在）"
fi

# =============================================================================
# 守卫不回归（黑盒：grep 命令位；口径与 diff-pin-canary C5/C7 一致）
# =============================================================================
NAKED_RE='(^|[;&|(]|[$][(])[[:space:]]*diff([[:space:]]|[;&|)<]|$)'
PIN_RE='(^|[;&|(]|[$][(])[[:space:]]*/usr/bin/diff([[:space:]]|[;&|)<]|$)'

t_case "G1 守卫不回归：s4 命令位 pin==2 / t1-04==1 / 裸 diff==0 / 各恰 1 行 -x /usr/bin/diff"
_g_scan() { # <file> <tag> <expect-pin>
  local f="$1" tag="$2" exp="$3" n p g
  if [ ! -f "$f" ]; then
    _fail "$tag 被测文件存在" "缺失: $f"
    return 0
  fi
  n="$(awk -v re="$NAKED_RE" '$0 ~ re {c++} END{print c+0}' "$f")"
  p="$(awk -v re="$PIN_RE" '$0 ~ re {c++} END{print c+0}' "$f")"
  g="$(awk '/-x[[:space:]]+\/usr\/bin\/diff/{c++} END{print c+0}' "$f")"
  assert_eq "$n" "0" "$tag 命令位裸 diff 调用数=0"
  assert_eq "$p" "$exp" "$tag 命令位 /usr/bin/diff 调用点数=${exp}"
  assert_eq "$g" "1" "$tag 恰 1 行 \`-x /usr/bin/diff\` fail-closed 前置"
}
_g_scan "$S4" "G1 ② s4" "2"
_g_scan "$T104" "G1 ② t1-04" "1"

t_case "G2 守卫套件 diff-pin-canary 整体仍 rc=0（含 hkstock t2_guard 回归）"
if [ -f "$CANARY" ]; then
  _run_timeout 600 "$WA_SB/g2.canary.out" bash "$CANARY"
  G2_RC=$?
  assert_eq "$G2_RC" "0" "G2 diff-pin-canary.acceptance.test.sh rc=0"
  assert_ne "$(awk '/##SUMMARY|FAIL /{n=1} END{print n+0}' "$WA_SB/g2.canary.out")" "0" \
    "G2 守卫套件有实际输出（非同构空跑）"
else
  _fail "G2 守卫套件存在" "缺失: $CANARY"
fi

t_case "G3 归属引擎零仓内写入：s4/t1-04 的 4.P1/4.1 段无 skip / 无 \`|| true\` 宽容"
# 段界锚（黑盒；冻结 driver 的既有段标与 `P=` 标签）
_sec_extract() { # <src> <start-re> <end-re> <outfile> → 0=成功
  awk -v s="$2" -v e="$3" '
    !inb { if ($0 ~ s) inb=1; else next }
    inb { print; n++; if (n > 1 && $0 ~ e) { found=1; exit } }
    END { if (found != 1) exit 1 }' "$1" > "$4"
}

S4_SEC="$WA_SB/s4.sec.txt"
T104_SEC="$WA_SB/t104.sec.txt"
_sec_extract "$S4" '(^P="4\.P1")|(4\.P1 \[det-machine\])' '(^P="4\.P2")|(4\.P2 \[det-machine\])' "$S4_SEC"
S4_SEC_RC=$?
_sec_extract "$T104" '(^t_case "4\.1)|(^#[[:space:]]*4\.1 )' '(^t_case "4\.2)|(^#[[:space:]]*4\.2 )' "$T104_SEC"
T104_SEC_RC=$?
assert_eq "$S4_SEC_RC" "0" "G3 s4 4.P1 段界可提取（段标 P=\"4.P1\"/\"4.P2\" 或 4.P1/4.P2 [det-machine] 注释）"
assert_eq "$T104_SEC_RC" "0" "G3 t1-04 4.1 段界可提取（段标 t_case \"4.1\"/\"4.2\"）"
S4_BAD="$(awk '/t_skip|_skip[ ]|\|\|[[:space:]]*true/{c++} END{print c+0}' "$S4_SEC")"
T104_BAD="$(awk '/t_skip|_skip[ ]|\|\|[[:space:]]*true/{c++} END{print c+0}' "$T104_SEC")"
assert_eq "$S4_BAD" "0" "G3 s4 4.P1 段无 skip / 无 || true"
assert_eq "$T104_BAD" "0" "G3 t1-04 4.1 段无 skip / 无 || true"

# =============================================================================
# 断言条数防删锚（新版 ≥ 改造前冻结基线；黑盒文本计数，不通读实现）
# =============================================================================
# 断言行计数规则：段内匹配 `eq|ne|ge|assert_eq|assert_ne|assert_ge|assert_exit|
# assert_contains|assert_true|_fail|fail|die` 的**标识符 token** 逐次计数。
_count_asserts() { # <file> → 计数
  awk '{
      n=split($0, a, /[^A-Za-z_]/)
      for (i=1;i<=n;i++) {
        if (a[i] == "eq" || a[i] == "ne" || a[i] == "ge" || a[i] == "assert_eq" || a[i] == "assert_ne" || a[i] == "assert_ge" || a[i] == "assert_exit" || a[i] == "assert_contains" || a[i] == "assert_true" || a[i] == "_fail" || a[i] == "fail" || a[i] == "die") c++
      }
    }
    END { print c+0 }' "$1"
}

t_case "N0 计数器自证：合成语料计数精确（防 no-op 计数器恒绿）"
printf 'eq a b\neq c d\ndie "x"\n[ -f y ] || _fail t "m"\nassert_eq 1 1\nNE x y\neq_x y z\nassert_eq_extra 1 2\n' > "$WA_SB/count.corpus"
# 命中：eq, eq, die, _fail, assert_eq ⇒ 5；NE（大写≠ne）/ eq_x / assert_eq_extra 均不得命中
assert_eq "$(_count_asserts "$WA_SB/count.corpus")" "5" \
  "N0 计数器对合成语料取 5（token 级精确；NE / eq_x / assert_eq_extra 不得命中）"

t_case "N1 s4 4.P1 段断言行数 ≥ 改造前基线（冻结常量 + 冻结文本自证）"
S4_NOW="$(_count_asserts "$S4_SEC")"
if git -C "$REPO_ROOT" cat-file -e "$FROZEN_SHA^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" show "$FROZEN_SHA:$S4_REL" > "$WA_SB/s4.frozen.txt" 2>/dev/null
  _sec_extract "$WA_SB/s4.frozen.txt" '(^P="4\.P1")|(4\.P1 \[det-machine\])' '(^P="4\.P2")|(4\.P2 \[det-machine\])' "$WA_SB/s4.frozen.sec"
  FROZEN_S4_N="$(_count_asserts "$WA_SB/s4.frozen.sec")"
  assert_eq "$FROZEN_S4_N" "$BASE_S4_P1_ASSERTS" "N1 冻结文本自证：旧版 4.P1 段行数 == 基线 ${BASE_S4_P1_ASSERTS}（计数器口径有效）"
else
  _fail "N1 冻结文本可取" "git show ${FROZEN_SHA}:${S4_REL} 不可用（基线无法自证，拒静默降级）"
fi
if [ "$S4_NOW" -ge "$BASE_S4_P1_ASSERTS" ]; then S4_ANCHOR=1; else S4_ANCHOR=0; fi
assert_eq "$S4_ANCHOR" "1" "N1 新版 s4 4.P1 段断言行数 ${S4_NOW} ≥ 基线 ${BASE_S4_P1_ASSERTS}"

t_case "N2 t1-04 4.1 段断言行数 ≥ 改造前基线（冻结常量 + 冻结文本自证）"
T104_NOW="$(_count_asserts "$T104_SEC")"
if git -C "$REPO_ROOT" cat-file -e "$FROZEN_SHA^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" show "$FROZEN_SHA:$T104_REL" > "$WA_SB/t104.frozen.txt" 2>/dev/null
  _sec_extract "$WA_SB/t104.frozen.txt" '(^t_case "4\.1)|(^#[[:space:]]*4\.1 )' '(^t_case "4\.2)|(^#[[:space:]]*4\.2 )' "$WA_SB/t104.frozen.sec"
  FROZEN_T104_N="$(_count_asserts "$WA_SB/t104.frozen.sec")"
  assert_eq "$FROZEN_T104_N" "$BASE_T104_41_ASSERTS" "N2 冻结文本自证：旧版 4.1 段行数 == 基线 ${BASE_T104_41_ASSERTS}（计数器口径有效）"
else
  _fail "N2 冻结文本可取" "git show ${FROZEN_SHA}:${T104_REL} 不可用（基线无法自证，拒静默降级）"
fi
if [ "$T104_NOW" -ge "$BASE_T104_41_ASSERTS" ]; then T104_ANCHOR=1; else T104_ANCHOR=0; fi
assert_eq "$T104_ANCHOR" "1" "N2 新版 t1-04 4.1 段断言行数 ${T104_NOW} ≥ 基线 ${BASE_T104_41_ASSERTS}"

t_case "N3 本套件零 SKIP（无降级通道）"
assert_eq "$T_SKIPPED" "0" "N3 本套件 emitted SKIP == 0"

t_finish

# =============================================================================
# CONTRACT_AMBIGUOUS（契约未声明/两处不一致，按已声明形态从宽求值，不推测私有成员）：
#  1) 末行计数字段：`## 契约规约` 写作 `WA total= external= suite= unclassified= diff_lines=`
#     （无 outside=），而 `## 设计文档` 的 API 段写作含 `outside=`。本套件以 **per-file 分类行计数**
#     为 outside 的求值源（恒等式用分类行计数），末行 outside= 若存在则另作一致性断言。
#  2) outside 类别的类别 token：第 2 轮口径定为三值闭集 {suite, external, outside-surface}，
#     而分类枚举段落写作 `outside` 类。本套件对 reason=outside-surface 行接受
#     class ∈ {outside-surface, outside}（别名容忍，避免纯拼写对撞）；reason 恒须为 outside-surface。
#  3) 注入模式命名：`## 验收场景` 场景2 步骤写 `S4_P1_INJECT=canary-file`，谓词与实现计划写
#     `canary-create`。本套件按实现计划/谓词取 `canary-create`（若实现只认 canary-file，则注入为空操作，
#     本套件 E1 的分类行断言会转红并暴露该不一致）。
#  4) `canary-append` 的注入目标路径：设计仅写「往注册路径追加」，未点名具体路径。本套件不钉死路径，
#     而断言「存在 suite ∧ reason ∈ {canary-marker, alphabet-violation} ∧ 同窗无 external 行」。
#  5) `Δt=<n>s` 的落点：第 2 轮口径写「evidence 行带 Δt=<n>s」，未指明是仅成立路径还是全部
#     corroborated-* 行。黑盒实测（本套件编写期）：Δt∈{0,5,29}s ⇒ `external … corroborated-ok
#     writer=… Δt=<n>s`；Δt∈{31,120,1200}s ⇒ `suite … no-corroboration writer=…`（**无 Δt 字段**）。
#     本套件按口径字面「evidence 行带 Δt」对两态均硬断言（S8b 因此会红，直至失败路径补 Δt 字段）；
#     该缺口已如实上报，不属推测的私有成员。
#  6) `canary-marker` 与 `outside-surface` 的竞合：第 2 轮口径写「无条件 suite」，未声明面外路径上出现
#     S4-P1- 行时的优先级。本套件不就该组合求值（避免推测未声明的交互），仅覆盖判据面内两态
#     （S2b 无佐证、S2c 佐证齐备）。
#  7) 段界锚：4.P1/4.1 段落的提取依赖既有段标（`P="4.P1"`/`4.P1 [det-machine]`、`t_case "4.1"/"4.2"`）。
#     设计声明冻结 driver 逐字保留；若段标被重命名，G3/N1/N2 会显式转红（段界不可提取）而非静默放宽。
# =============================================================================
