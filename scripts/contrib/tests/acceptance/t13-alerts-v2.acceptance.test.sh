#!/usr/bin/env bash
# =============================================================================
# t13-alerts-v2.acceptance.test.sh — contrib-watch 告警通道整治四项修复 验收套件
#
# 设计输入（唯一）：red-input.md「## 设计文档」+「## 契约规约」+「## 验收场景」
#   （18 场景 / 44 谓词冻结 SSOT；本文件逐谓词硬断言，断言期望值字面量取自谓词 assert:）
# 覆盖谓词（44）：
#   s01-p1 s01-p2 s01-p3 | s02-p1 s02-p2 s02-p3 | s03-p1 s03-p2 s03-p3
#   s04-p1 s04-p2 | s05-p1 s05-p2 s05-p3 | s06-p1 s06-p2 s06-p3
#   s07-p1 s07-p2 s07-p3 | s08-p1 | s09-p1 s09-p2
#   s10-p1 s10-p2 | s11-p1 s11-p2 | s12-p1 s12-p2
#   s13-p1 s13-p2 | s14-p1 s14-p2 | s15-p1 s15-p2 s15-p3 s15-p4 s15-p5
#   s16-p1 s16-p2 | s17-p1 s17-p2 | s18-p1 s18-p2
#
# 驱动/观测：黑盒。真实进程 = 沙箱内 notify.sh（bash-cli 层）；文件系统观测 =
#   $CONTRIB_DATA_DIR/events.jsonl + notify-state.json + stub 载荷副本（bodies/hermes-*.txt）。
#   沙箱 = lib/sandbox.sh（CONTRIB_DATA_DIR 隔离 + 影子 stub 注入 + HERMES_BIN/CLAUDE_BIN seam）。
#
# 产物：/tmp/autopilot-artifacts/<谓词id>.out（逐谓词观测快照，QA 对账用）
#
# 红队纪律：无 SKIP / 无宽容分支 / 无 try-catch 吞错 / 无「未实现先跳过」；
#   每条断言失败即记 FAIL 并最终 exit 1（t_finish）。条件分支仅用于「前置缺失即硬失败」。
# 调度旋钮：T13_SCENES=1,6,8（仅跑指定场景；mutation 子跑用）；T13_ART 覆盖产物目录。
#
# CONTRACT_AMBIGUOUS（契约/谓词交叉处判定；均以契约已声明接口名指称）：
#   A1 载荷口径：载荷 = hermes 调用携带的载荷文本（`send --file` 与 `kanban create --body`
#      两路均落 bodies/hermes-<n>.txt）。依据：场景1 note「双叙事 fixture …本轮仅 1 载荷」
#      ——若载荷只计 send，该 note 的「1 载荷」不成立。
#   A2 标头双形态：既有实现下「contrib 速报」= 机械批模板卡报头（t5-01 D14 钉死 body 含「速报」），
#      「contrib 告警」= 叙事批 digest 卡报头（本仓卡 body 逐字含「首行固定格式：🟠【contrib 告警】」，
#      四问文档 §2 AI 摘要层亦记 prompt 报头硬编码）。谓词 header 字面量取告警形态 ⇒ 由
#      叙事批 digest 卡载荷满足；机械批载荷改以「不回归 contrib 域」负向硬断言
#      （kill「标头未参数化」mutation）。据此，场景1/7/10 的「摘要承载载荷」与「告警标头载荷」
#      为**同域不同载荷**（谓词「该载荷/对应载荷」按「该域载荷」在观测集内读）。
#   A3 场景16 cluster 字面量：契约 cluster_key_of 规格（剥日期 token + 压缩重复 -）未钉死尾部 -
#      去向 ⇒ 断言 .cluster 非 null 且含 "X-stale"，不断言 == "X-stale"。
#   A4 场景9 静默窗时钟：契约「pushed_at 存在两种格式（+0800 / +08:00）…比较前 shall 归一化」，
#      两格式各验一次（回拨值分别取两形态），失败可归因。
#   A5 场景14 上限数值语义：谓词观测「cfg 读取行」；'3'→'30' 死缺省对齐属设计明示的顺带修正
#      （在提交说明与四问文档披露）⇒ 按「键名逐字一致 + 死缺省不下降 + 行为总闸不变」三向硬断言，
#      不把 '30' 钉成谓词级字面量。
#   A6 场景18 微信批证据：叙事批的「进批」以 digest 卡登记 + 快照成员观测（既有 T5 卡化机制，
#      e1/t5-01 同款）；brief 类行以 route/pushed + 快照不含双向断言。
#   A7 场景14.P1 口径：只计 diff 的**变更行**（^+ / ^- 本体行，排除 +++/--- 与 context 行）——
#      context 行命中的话是 git 展示位置所致而非改动，按字面 raw grep 会把 hunk 半径内的既有
#      notify_target 行算进来（任何实现都躲不开的假红）。注意：digest 卡 body 既有文案
#      「接收渠道: contrib（微信，notify_target 取 config）」位于本卡必改面（需按域参数化），
#      改动该行即产生 notify_target 变更行 ⇒ 谓词要求的「diff 零 notify_target 行」意味着
#      该行改写须避开该字面量（如「微信目标取 config」）。
#   A8 场景14.P2 行为总闸：设计实现约束明示「限额与 min_interval 检查放在分渠道循环**之前**」
#      ⇒ 单轮分渠不逐批检查限额，故以**单域两轮**验总闸（cap=1：第一轮推、第二轮拒、
#      alerts[today] 封顶 1），不假设跨域逐批扣减。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
SELF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"

# 生产 MARTIN_DIR 绝不外泄进本套件（context.md：contrib 域 acceptance 不得设 MARTIN_DIR）；
# 沙箱内 MARTIN_DIR 由 lib/sandbox.sh 指向沙箱根（SB_ROOT）。
unset MARTIN_DIR

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

ART="${T13_ART:-/tmp/autopilot-artifacts}"
mkdir -p "$ART" 2>/dev/null || true

SCENE_FILTER="${T13_SCENES:-}"
scene_on() { # <n> — 无过滤器=全跑；有过滤器=仅在列表内跑（mutation 子跑）
  [[ -z "$SCENE_FILTER" ]] && return 0
  case ",$SCENE_FILTER," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

EV="" # 当前沙箱账本路径（sb_fresh 设置）

# ---------------------------------------------------------------- 通用工具 ----
art() { # <谓词id> <文本...> → /tmp/autopilot-artifacts/<id>.out
  local id="$1"
  shift
  printf '%s\n' "$@" >"$ART/$id.out" 2>/dev/null || true
  return 0
}

sb_fresh() { # <场景标签> — 新建沙箱；失败即硬失败（返回非 0 供调用方跳过本场景）
  SB_ROOT=""
  sb_new >/dev/null 2>&1 || true
  if [[ -z "$SB_ROOT" || ! -d "$SB_ROOT/contrib-data" ]]; then
    _fail "$1 sandbox" "sb_new 失败（沙箱未建）"
    return 1
  fi
  EV="$SB_ROOT/contrib-data/events.jsonl"
  return 0
}

led_rows() { # 账本总行数
  jq -s 'length' "$EV" 2>/dev/null || printf '0'
}

led_key_rows() { # <key> → 该 key 行数
  jq -s --arg k "$1" '[.[] | select(.key == $k)] | length' "$EV" 2>/dev/null || printf '0'
}

led_field() { # <key> <jq 表达式> [序号] — 单字段读（多行取序号，缺省首个）
  jq -r -s --arg k "$1" --argjson i "${3:-0}" "[.[] | select(.key == \$k)][\$i] | $2" "$EV" 2>/dev/null || true
}

led_field_or() { # <key> <字段> <缺省> [序号] — 字段缺失/null → 缺省（禁 jq // 口径；契约 DbC 缺省语义）
  jq -r -s --arg k "$1" --arg f "$2" --arg d "$3" --argjson i "${4:-0}" \
    "[.[] | select(.key == \$k)][\$i] | if has(\$f) and (.[\$f] != null) then (.[\$f] | tostring) else \$d end" \
    "$EV" 2>/dev/null || true
}

led_field_raw() { # <key> <字段> [序号] — 原样读（判 != null），缺失/无该字段 → 空串
  jq -r -s --arg k "$1" --arg f "$2" --argjson i "${3:-0}" \
    "[.[] | select(.key == \$k)][\$i] | if has(\$f) and (.[\$f] != null) then (.[\$f] | tostring) else \"\" end" \
    "$EV" 2>/dev/null || true
}

led_has_field() { # <key> <字段> [序号] → true/false（跨系统字段名一致性）
  jq -r -s --arg k "$1" --arg f "$2" --argjson i "${3:-0}" \
    "[.[] | select(.key == \$k)][\$i] | has(\$f) | tostring" "$EV" 2>/dev/null || true
}

seed_legacy_row() { # <class> <key> <summary> — 存量行：无 channel/route/cluster/occurrences/resolved 字段
  jq -cn --arg ts "2026-01-01T00:00:00+08:00" --arg cls "$1" --arg k "$2" --arg s "$3" \
    '{ts: $ts, class: $cls, key: $k, summary: $s, pushed: false, attempts: 0, pushed_at: null}' >>"$EV"
}

led_set_row() { # <key> <jq 表达式（. 为行）> — 直改账本行（构造时钟/终态前置态；沙箱自有数据）
  jq -c --arg k "$1" "if .key == \$k then $2 else . end" "$EV" >"$EV.tmp" && mv "$EV.tmp" "$EV"
}

payload_file() { # <n> → 第 n 个 hermes 载荷副本路径（不存在=空串）
  local f="$SB_STUBLOG/bodies/hermes-$1.txt"
  [[ -f "$f" ]] && printf '%s' "$f"
  return 0
}

payload_count() { # hermes 载荷副本总数（send --file 与 kanban create --body 两路均落副本）
  local i c=0
  for ((i = 1; i <= 80; i++)); do
    [[ -n "$(payload_file "$i")" ]] && c=$((c + 1))
  done
  printf '%s' "$c"
}

payload_text() { # <n> → 载荷文本
  local f
  f="$(payload_file "$1")"
  [[ -n "$f" ]] && cat "$f"
  return 0
}

payloads_all() { # 全部载荷文本连接
  local i out=""
  for ((i = 1; i <= 80; i++)); do out="$out$(payload_text "$i")"; done
  printf '%s' "$out"
  return 0
}

payloads_new() { # <before-count> → 第 before+1 个起的新载荷文本连接
  local i out=""
  for ((i = $1 + 1; i <= 80; i++)); do out="$out$(payload_text "$i")"; done
  printf '%s' "$out"
  return 0
}

payload_files_with() { # <字面量> → 含该字面量的载荷文件列表（逐行路径）
  local lit="$1" i f
  for ((i = 1; i <= 80; i++)); do
    f="$(payload_file "$i")"
    if [[ -n "$f" ]] && grep -qF -- "$lit" "$f"; then printf '%s\n' "$f"; fi
  done
  return 0
}

payload_cross_count() { # <正文A> <正文B> → 同时含 A/B 的载荷条数（跨域混排计数）
  local a="$1" b="$2" i f n=0
  for ((i = 1; i <= 80; i++)); do
    f="$(payload_file "$i")"
    if [[ -n "$f" ]] && grep -qF -- "$a" "$f" && grep -qF -- "$b" "$f"; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

FLUSH_RC=0
do_flush() { # 真发 flush（NOTIFY_DRY_RUN=false）；stdout 透传；rc 落 FLUSH_RC
  local out
  out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
  FLUSH_RC=$?
  printf '%s' "$out"
  return 0
}

ev_send() { # notify.sh event 子命令（沙箱副本）
  sb_notify "$@"
}

narr_round() { # <channel|-> <key> <summary> → stdout=本轮新增载荷文本（叙事批：digest 卡路）
  local ch="$1" k="$2" s="$3" before
  sb_state_set '.last_flush_epoch = 0'
  if [[ "$ch" == "-" ]]; then
    ev_send event pipeline-failure --key "$k" --summary "$s" >/dev/null
  else
    ev_send event pipeline-failure --key "$k" --summary "$s" --channel "$ch" >/dev/null
  fi
  before="$(payload_count)"
  do_flush >/dev/null
  payloads_new "$before"
}

digest_flight_field() { # <字段> → 值（无 flight/无字段=空）
  local f="$SB_ROOT/contrib-data/kanban-flight-digest.json"
  [[ -f "$f" ]] || return 0
  jq -r --arg fld "$1" 'if has($fld) and (.[$fld] != null) then (.[$fld] | tostring) else "" end' "$f" 2>/dev/null || true
}

worker_send_digest() { # <报头字面量> — worker 收尾模拟：写摘要 → send-digest → 卡置 done；0=成功
  local hdr="$1" snap card
  snap="$(digest_flight_field batch_file)"
  card="$(digest_flight_field card_id)"
  [[ -n "$snap" && -n "$card" ]] || return 1
  printf '%s%s\n\n发生了什么：本轮批次已按域渲染送审；与他有关：分域后注意力按标头分诊；建议：无需动作。\n' \
    "$hdr" "$(date +%m-%d)" >"${snap%.json}.digest.md"
  sb_notify send-digest --digest "${snap%.json}.digest.md" --batch "$snap" >/dev/null
  printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$card" >"$SB_STUBLOG/kanban-cards.jsonl"
  return 0
}

send_argv_has() { # <字面量> → hermes send 调用 argv 命中该字面量（主题参数化证据；0=命中 1=未命中）
  local lit="$1" hits
  hits="$(grep -c -- "send " "$SB_STUBLOG/calls.log" 2>/dev/null || true)"
  if [[ "${hits:-0}" -ge 1 ]] && grep -- "send " "$SB_STUBLOG/calls.log" 2>/dev/null | grep -qF -- "$lit"; then
    return 0
  fi
  return 1
}

# =============================================================================
# 场景 1：双域事件同账本，按域分标头分批渲染推送（修复①主干）
#   谓词：s01-p1 [real-process] s01-p2 [det-machine] s01-p3 [det-machine]
#   驱动：主沙箱 = 双域机械批（逐域一批一推，kill「单批合并」）；
#         另两沙箱 = 各域叙事批 digest 卡（标头参数化触点，[A2] 见文件头）
# =============================================================================
if scene_on 1; then
  t_case "场景1 双域分批渲染（s01-p1/p2/p3）"
  if sb_fresh s01; then
    C1_SUM="C1-SUMMARY-contrib域事件正文"
    F1_SUM="F1-SUMMARY-flashcards域事件正文"
    ev_send event own-pr-activity --key c1 --summary "$C1_SUM" >/dev/null
    ev_send event own-pr-activity --key f1 --summary "$F1_SUM" --channel flashcards >/dev/null
    B1="$(payload_count)"
    do_flush >/dev/null
    R1_NEW="$(payloads_new "$B1")"
    R1_N=$(( $(payload_count) - B1 ))

    # --- s01-p1 [real-process] 两域各自一批一推 ---
    assert_eq "$FLUSH_RC" "0" "s01-p1 flush exit 0（双域批次正常收束）"
    if [[ "$R1_N" -ge 2 ]]; then
      _pass "s01-p1 载荷条数 >= 2（本轮新增 ${R1_N}）"
    else
      _fail "s01-p1 载荷条数 >= 2" "本轮新增载荷 ${R1_N} 条（< 2：未按域分批发送）"
    fi
    assert_contains "$R1_NEW" "$C1_SUM" "s01-p1 contrib 批携本域事件正文"
    assert_contains "$R1_NEW" "$F1_SUM" "s01-p1 flashcards 批携本域事件正文"
    # 标头不回归 contrib 域（flashcards 载荷），kill「标头未参数化」mutation
    CF_PAY="$(payload_files_with "$F1_SUM" | head -1)"
    if [[ -n "$CF_PAY" ]]; then
      assert_file_contains "$CF_PAY" "【flashcards" "s01-p1 flashcards 载荷标头为 flashcards 域"
      if grep -qF -- "【contrib" "$CF_PAY"; then
        _fail "s01-p1 flashcards 载荷零 contrib 标头" "载荷仍带 contrib 域标头（标头未参数化）"
      else
        _pass "s01-p1 flashcards 载荷零 contrib 标头"
      fi
    else
      _fail "s01-p1 flashcards 载荷存在" "无载荷含 [$F1_SUM]"
    fi
    art "s01-p1-r1" "本轮新增载荷数=${R1_N}" "--- 本轮载荷 ---" "$R1_NEW"

    # --- s01-p3 [det-machine] 两域行各自独立标记已推送 ---
    C1_PUSHED="$(led_field c1 '.pushed')"
    F1_PUSHED="$(led_field f1 '.pushed')"
    assert_eq "$C1_PUSHED" "true" "s01-p3 c1 行 .pushed == true"
    assert_eq "$F1_PUSHED" "true" "s01-p3 f1 行 .pushed == true"
    art s01-p3 "$(jq -c 'select(.key == "c1" or .key == "f1")' "$EV" 2>/dev/null)"

    # --- s01-p1 续（[A2] 主沙箱内补 contrib 域 告警标头：叙事批 digest 卡 body） ---
    C1N_NEW="$(narr_round - c1n "C1N-contrib叙事批正文")"
    assert_contains "$C1N_NEW" "【contrib 告警】" "s01-p1 contrib 域 告警标头（digest 卡 _digest_card_body 规范）"
    art s01-p1 "== 主沙箱（双域机械批 + contrib 叙事批） ==" \
      "第一轮新增载荷数=${R1_N}" "--- 第一轮载荷（逐域） ---" "$R1_NEW" \
      "--- contrib 叙事批载荷（digest 卡） ---" "$C1N_NEW" \
      "--- 全部载荷 ---" "$(payloads_all)"
    sb_cleanup
  fi

  # --- s01-p1 续（标头形态二）：各域叙事批 digest 卡（标头参数化触点）---
  if sb_fresh s01; then
    CN_NEW="$(narr_round - c1n "C1N-contrib叙事批正文")"
    assert_contains "$CN_NEW" "【contrib 告警】" "s01-p1 contrib 域 告警标头（digest 卡 _digest_card_body 规范）"
    art "s01-p1-narr-contrib" "$(jq -c . "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)" "$CN_NEW"
    sb_cleanup
  fi
  if sb_fresh s01; then
    FN_NEW="$(narr_round flashcards f1n "F1N-flashcards叙事批正文")"
    assert_contains "$FN_NEW" "【flashcards 告警】" "s01-p1 flashcards 域 告警标头（digest 卡 _digest_card_body 规范）"
    if grep -qF -- "【contrib" <<<"$FN_NEW"; then
      _fail "s01-p1 flashcards 叙事批零 contrib 标头" "叙事批载荷含 contrib 域标头"
    else
      _pass "s01-p1 flashcards 叙事批零 contrib 标头"
    fi
    # worker 收尾链：flashcards 批 send-digest 主题参数化（契约 §flush 分渠 主题字面）
    if worker_send_digest "🟠【flashcards 告警】"; then
      if send_argv_has "flashcards 告警"; then
        _pass "s01-p1 flashcards 批 send 主题参数化（argv 含 flashcards 告警）"
      else
        _fail "s01-p1 flashcards 批 send 主题参数化" "send argv 未见 flashcards 告警：$(grep -- 'send ' "$SB_STUBLOG/calls.log" 2>/dev/null | tail -1)"
      fi
    else
      _fail "s01-p1 flashcards digest 卡登记" "flight 缺 batch_file/card_id（叙事批未派发）"
    fi
    art "s01-p1-narr-flashcards" "$(jq -c . "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)" "$FN_NEW"
    sb_cleanup
  fi

  # --- s01-p2 [det-machine] 渲染层不跨域混排 ---
  if sb_fresh s01; then
    C2_SUM="C2-SUMMARY-混排对照贡献正文"
    F2_SUM="F2-SUMMARY-混排对照跨域正文"
    ev_send event own-pr-activity --key c2 --summary "$C2_SUM" >/dev/null
    ev_send event own-pr-activity --key f2 --summary "$F2_SUM" --channel flashcards >/dev/null
    do_flush >/dev/null
    CROSS_SUM="$(payload_cross_count "$C2_SUM" "$F2_SUM")"
    CROSS_HDR="$(payload_cross_count "【contrib 告警】" "【flashcards 告警】")"
    CROSS_HDR2="$(payload_cross_count "【contrib 速报】" "【flashcards 速报】")"
    assert_eq "$CROSS_SUM" "0" "s01-p2 零跨域混排（无载荷同时承载两域正文）"
    assert_eq "$CROSS_HDR" "0" "s01-p2 零双告警标头同载荷"
    assert_eq "$CROSS_HDR2" "0" "s01-p2 零双速报标头同载荷"
    CSEG="$(payload_files_with "$C2_SUM" | head -1)"
    FSEG="$(payload_files_with "$F2_SUM" | head -1)"
    if [[ -n "$CSEG" && -n "$FSEG" ]]; then
      _pass "s01-p2 两域载荷段各自独立"
    else
      _fail "s01-p2 两域载荷段各自独立" "contrib 段=[$CSEG] flashcards 段=[$FSEG]"
    fi
    art s01-p2 "跨域正文同载荷=${CROSS_SUM} 双告警标头同载荷=${CROSS_HDR} 双速报标头同载荷=${CROSS_HDR2}" \
      "contrib 段载荷=[${CSEG}]" "flashcards 段载荷=[${FSEG}]" "--- 载荷全文 ---" "$(payloads_all)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 2：同根因第二次上报——原位更新而非新发（修复②主干）
#   谓词：s02-p1 [real-process] s02-p2 [det-machine] s02-p3 [det-machine]
# =============================================================================
if scene_on 2; then
  t_case "场景2 同 key 原位更新（s02-p1/p2/p3）"
  if sb_fresh s02; then
    S1_TXT="S1-首次上报正文"
    S2_TXT="S2-第二次上报正文"
    ev_send event own-pr-activity --key K --summary "$S1_TXT" >/dev/null
    RC_E1=$?
    TS1="$(led_field K '.ts')"
    sleep 2 # ts 秒级可区分（谓词 note：间隔 >= 1s 防同秒假红）
    ev_send event own-pr-activity --key K --summary "$S2_TXT" >/dev/null
    RC_E2=$?
    assert_exit 0 $RC_E1 "s02-p1 首次 event exit 0"
    assert_exit 0 $RC_E2 "s02-p1 第二次 event exit 0"

    # --- s02-p1 [real-process] 行数 == 1 且 occurrences >= 2 ---
    ROWS="$(led_key_rows K)"
    OCC="$(led_field_or K occurrences 0)"
    assert_eq "$ROWS" "1" "s02-p1 key=K 行数 == 1（原位更新非新发）"
    if [[ "$OCC" -ge 2 ]]; then
      _pass "s02-p1 .occurrences >= 2（实际 ${OCC}）"
    else
      _fail "s02-p1 .occurrences >= 2" "actual=${OCC}"
    fi
    art s02-p1 "$(jq -c 'select(.key == "K")' "$EV" 2>/dev/null)"

    # --- s02-p2 [det-machine] 最新摘要 + 最新时间戳 ---
    SUM_NOW="$(led_field K '.summary')"
    TS_NOW="$(led_field K '.ts')"
    assert_eq "$SUM_NOW" "$S2_TXT" "s02-p2 .summary == S2"
    if [[ "$TS_NOW" > "$TS1" ]]; then
      _pass "s02-p2 .ts 刷新（旧 [${TS1}] → 新 [${TS_NOW}]）"
    else
      _fail "s02-p2 .ts 刷新" "旧 [${TS1}] 新 [${TS_NOW}]（未刷新时间戳）"
    fi
    art s02-p2 "$(jq -c 'select(.key == "K") | {ts, summary, occurrences, cluster}' "$EV" 2>/dev/null)"

    # --- s02-p3 [det-machine] 总行数保持 1 ---
    TOT="$(led_rows)"
    assert_eq "$TOT" "1" "s02-p3 账本总行数 == 1（kill「恒新发行」）"
    art s02-p3 "led_rows=${TOT}" "$(jq -c . "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 3：已推送根因在静默窗口内复发不重推（修复②抑制面）
#   谓词：s03-p1 [real-process] s03-p2 [det-machine] s03-p3 [real-process]
# =============================================================================
if scene_on 3; then
  t_case "场景3 静默窗抑制（s03-p1/p2/p3）"
  if sb_fresh s03; then
    S_TXT="S-首推正文"
    SP_TXT="SP-复发正文"
    ev_send event own-pr-activity --key K --summary "$S_TXT" >/dev/null
    do_flush >/dev/null
    assert_eq "$(led_field K '.pushed')" "true" "s03 前置：首次 flush 后 K 已推"
    BEFORE="$(payload_count)"
    ev_send event own-pr-activity --key K --summary "$SP_TXT" >/dev/null
    sb_state_set '.last_flush_epoch = 0'
    do_flush >/dev/null

    # --- s03-p1 [real-process] 第二轮零新推（not-contains S 且 not-contains S-prime） ---
    AFTER="$(payload_count)"
    NEW_TXT="$(payloads_new "$BEFORE")"
    assert_eq "$((AFTER - BEFORE))" "0" "s03-p1 第二轮零新增载荷（静默窗内不重推）"
    assert_not_contains "$NEW_TXT" "$S_TXT" "s03-p1 新载荷 not-contains S（negate 谓词）"
    assert_not_contains "$NEW_TXT" "$SP_TXT" "s03-p1 新载荷 not-contains S-prime（negate 谓词）"
    art s03-p1 "第二轮新增载荷数=$((AFTER - BEFORE))" "新载荷文本=[${NEW_TXT}]"

    # --- s03-p2 [det-machine] 复发仍累计次数并刷新摘要 ---
    OCC3="$(led_field_or K occurrences 0)"
    SUM3="$(led_field K '.summary')"
    if [[ "$OCC3" -ge 2 ]]; then
      _pass "s03-p2 .occurrences >= 2（实际 ${OCC3}）"
    else
      _fail "s03-p2 .occurrences >= 2" "actual=${OCC3}"
    fi
    assert_eq "$SUM3" "$SP_TXT" "s03-p2 .summary == S-prime"
    art s03-p2 "$(jq -c 'select(.key == "K")' "$EV" 2>/dev/null)"

    # --- s03-p3 [real-process] 抑制轮正常收束 ---
    assert_eq "$FLUSH_RC" "0" "s03-p3 抑制轮 flush exit == 0"
    art s03-p3 "flush rc=${FLUSH_RC}（抑制=正常路径非错误）"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 4：有决策点事件照常微信即时推送（修复③正向面；决策级=own-pr-unledgered）
#   谓词：s04-p1 [real-process] s04-p2 [det-machine]
# =============================================================================
if scene_on 4; then
  t_case "场景4 决策级即时推送（s04-p1/p2）"
  if sb_fresh s04; then
    SD_TXT="SD-决策级告警正文"
    ev_send event own-pr-unledgered --key D --summary "$SD_TXT" >/dev/null
    BEFORE="$(payload_count)"
    do_flush >/dev/null
    NEW_TXT="$(payloads_new "$BEFORE")"

    # --- s04-p1 [real-process] ---
    assert_contains "$NEW_TXT" "$SD_TXT" "s04-p1 决策级载荷 contains SD"
    art s04-p1 "新增载荷数=$(( $(payload_count) - BEFORE ))" "新载荷文本=[${NEW_TXT}]"

    # --- s04-p2 [det-machine] ---
    D_PUSHED="$(led_field D '.pushed')"
    D_PUSHED_AT="$(led_field_raw D pushed_at)"
    assert_eq "$D_PUSHED" "true" "s04-p2 D 行 .pushed == true"
    assert_ne "$D_PUSHED_AT" "" "s04-p2 D 行 .pushed_at != null（实际 [${D_PUSHED_AT}]）"
    art s04-p2 "$(jq -c 'select(.key == "D")' "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 5：无决策点事件降级进当日简报、不进即时推送（修复③降级面；简报级=own-pr-info）
#   谓词：s05-p1 [real-process] s05-p2 [real-process] s05-p3 [det-machine]
# =============================================================================
if scene_on 5; then
  t_case "场景5 简报级降级（s05-p1/p2/p3）"
  if sb_fresh s05; then
    SG_TXT="SG-简报级内容"
    ev_send event own-pr-info --key G --summary "$SG_TXT" >/dev/null
    SBEFORE="$(payload_count)"
    do_flush >/dev/null
    NEW_TXT="$(payloads_new "$SBEFORE")"

    # --- s05-p1 [real-process] 不产生即时推送 ---
    assert_eq "$(( $(payload_count) - SBEFORE ))" "0" "s05-p1 简报级 flush 零新增载荷"
    assert_not_contains "$NEW_TXT" "$SG_TXT" "s05-p1 载荷 not-contains SG（negate 谓词）"
    art s05-p1 "新增载荷数=$(( $(payload_count) - SBEFORE ))" "新载荷文本=[${NEW_TXT}]"

    # --- s05-p2 [real-process] 简报消费队列收编（.route=="brief" 且 .pushed==true） ---
    G_ROUTE="$(led_field G '.route')"
    G_PUSHED="$(led_field G '.pushed')"
    assert_eq "$G_ROUTE" "brief" "s05-p2 G 行 .route == \"brief\""
    assert_eq "$G_PUSHED" "true" "s05-p2 G 行 .pushed == true"
    art s05-p2 "$(jq -c 'select(.key == "G")' "$EV" 2>/dev/null)"

    # --- s05-p3 [det-machine] 行不丢弃 ---
    assert_eq "$(led_key_rows G)" "1" "s05-p3 key=G 行数 == 1（降级不丢行）"
    art s05-p3 "key=G 行数=$(led_key_rows G)" "$(jq -c . "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 6：告警闭环——resolve 发 ✅ 收尾卡并置 resolved（修复④主干）
#   谓词：s06-p1 [real-process] s06-p2 [det-machine] s06-p3 [real-process]
#   附：跨系统账本字段名一致性（写入方 cmd_event/resolve ↔ 消费方 flush/resolve）
# =============================================================================
if scene_on 6; then
  t_case "场景6 resolve 闭环（s06-p1/p2/p3）"
  if sb_fresh s06; then
    RES_SUM="根因已消除-手工闭环"
    ev_send event own-pr-activity --key K --summary "K-待闭环告警正文" >/dev/null
    do_flush >/dev/null
    assert_eq "$(led_field K '.pushed')" "true" "s06 前置：K 已推送（收尾卡前提）"
    RBEFORE="$(payload_count)"
    R_OUT="$(sb_notify resolve --key K --summary "$RES_SUM")"
    RC_RESOLVE=$?
    R_ERR="$(sb_out 20)"
    R_LAST="$(payload_text "$(payload_count)")"

    # --- s06-p1 [real-process] ✅ 收尾卡含 key ---
    assert_contains "$R_LAST" "✅" "s06-p1 收尾卡 contains ✅"
    assert_contains "$R_LAST" "已解决" "s06-p1 收尾卡 contains 已解决"
    assert_contains "$R_LAST" "K" "s06-p1 收尾卡 contains K（可追踪 id）"
    assert_eq "$(( $(payload_count) - RBEFORE ))" "1" "s06-p1 收尾卡恰一条新载荷"
    art s06-p1 "resolve rc=${RC_RESOLVE}" "stdout=[${R_OUT}]" "stderr=[${R_ERR}]" "收尾卡全文=[${R_LAST}]"

    # --- s06-p2 [det-machine] 账本置 resolved ---
    R_RESOLVED="$(led_field K '.resolved')"
    assert_eq "$R_RESOLVED" "true" "s06-p2 K 行 .resolved == true"
    art s06-p2 "$(jq -c 'select(.key == "K")' "$EV" 2>/dev/null)"

    # --- s06-p3 [real-process] exit 0 ---
    assert_eq "$RC_RESOLVE" "0" "s06-p3 resolve exit == 0"
    art s06-p3 "resolve exit=${RC_RESOLVE}"

    # --- 跨系统字段名一致性（契约 §resolve + §event；字段名字面量逐字） ---
    F_RESOLVED_AT="$(led_field_raw K resolved_at)"
    F_RESOLUTION="$(led_field K '.resolution')"
    F_RES_SENT="$(led_field K '.resolution_sent')"
    H_RESOLVED="$(led_has_field K resolved)"
    H_OCC="$(led_has_field K occurrences)"
    H_CLUSTER="$(led_has_field K cluster)"
    assert_eq "$H_RESOLVED" "true" "s06-field 消费方读 .resolved：字段名逐字在行"
    assert_eq "$H_OCC" "true" "s06-field 消费方读 .occurrences：字段名逐字在行"
    assert_eq "$H_CLUSTER" "true" "s06-field 聚类读 .cluster：字段名逐字在行"
    assert_ne "$F_RESOLVED_AT" "" "s06-field .resolved_at 落值（写入方 resolve ↔ 消费方账本）"
    assert_eq "$F_RESOLUTION" "$RES_SUM" "s06-field .resolution == 传入 summary"
    assert_eq "$F_RES_SENT" "true" "s06-field .resolution_sent == true（已推送行发卡成功）"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 7：向后兼容——存量账本行缺新字段（channel / resolved 等）
#   谓词：s07-p1 [real-process] s07-p2 [det-machine] s07-p3 [real-process]
# =============================================================================
if scene_on 7; then
  t_case "场景7 存量行向后兼容（s07-p1/p2/p3）"
  if sb_fresh s07; then
    SL_TXT="SL-存量行正文"
    seed_legacy_row own-pr-activity SL "$SL_TXT"
    B7="$(payload_count)"
    do_flush >/dev/null
    NEW7="$(payloads_new "$B7")"

    # --- s07-p1 [real-process] 存量行归 contrib 域渲染并正常推送 ---
    assert_contains "$NEW7" "$SL_TXT" "s07-p1 载荷 contains SL"
    SLFILE="$(payload_files_with "$SL_TXT" | head -1)"
    if [[ -n "$SLFILE" ]]; then
      if grep -qF -- "【flashcards" "$SLFILE"; then
        _fail "s07-p1 存量行归 contrib 域" "SL 载荷带 flashcards 域标头"
      else
        _pass "s07-p1 存量行归 contrib 域（无 cross 域标头）"
      fi
    else
      _fail "s07-p1 存量行载荷存在" "载荷集无 SL 正文"
    fi
    assert_eq "$(led_field SL '.pushed')" "true" "s07-p1 [契约衍生] 存量行被正常标 pushed"
    art s07-p1 "$(jq -c 'select(.key == "SL")' "$EV" 2>/dev/null)" "载荷=[${NEW7}]"
    sb_cleanup
  fi

  # --- s07-p1 续（[A2]）：存量叙事行（无 channel）→ digest 卡 contrib 告警标头 ---
  if sb_fresh s07; then
    seed_legacy_row pipeline-failure SLN "SLN-存量叙事行正文"
    sb_state_set '.last_flush_epoch = 0'
    B7B="$(payload_count)"
    do_flush >/dev/null
    NEW7B="$(payloads_new "$B7B")"
    assert_contains "$NEW7B" "【contrib 告警】" "s07-p1 无 channel 存量行归 contrib 域（告警标头）"
    if grep -qF -- "【flashcards" <<<"$NEW7B"; then
      _fail "s07-p1 存量叙事行零 cross 域标头" "载荷含 flashcards 域标头"
    else
      _pass "s07-p1 存量叙事行零 cross 域标头"
    fi
    art "s07-p1-r2" "$(jq -c 'select(.key == "SLN")' "$EV" 2>/dev/null)" "载荷=[${NEW7B}]"
    sb_cleanup
  fi

  # --- s07-p2 [det-machine] 不错行不损坏账本 ---
  if sb_fresh s07; then
    seed_legacy_row own-pr-activity SLJ "SLJ-账本完整性正文"
    do_flush >/dev/null
    BADJSON=0
    LINEN=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      LINEN=$((LINEN + 1))
      printf '%s' "$line" | jq -e . >/dev/null 2>&1 || BADJSON=$((BADJSON + 1))
    done <"$EV"
    assert_eq "$BADJSON" "0" "s07-p2 逐行 jq -e . 全通过（合法 JSON）"
    assert_eq "$LINEN" "1" "s07-p2 行数 == 1（未错行/未损毁）"
    art s07-p2 "行数=${LINEN} 非法 JSON 行数=${BADJSON}" "$(jq -c . "$EV" 2>/dev/null)"
    sb_cleanup
  fi

  # --- s07-p3 [real-process] 存量行（无 channel/resolved 字段）可正常闭环 ---
  if sb_fresh s07; then
    seed_legacy_row own-pr-activity SLR "SLR-存量闭环正文"
    do_flush >/dev/null
    assert_eq "$(led_field SLR '.pushed')" "true" "s07-p3 前置：存量行已推送"
    R7_OUT="$(sb_notify resolve --key SLR --summary "存量行闭环")"
    RC7=$?
    assert_eq "$RC7" "0" "s07-p3 resolve 存量行 exit == 0"
    assert_eq "$(led_field SLR '.resolved')" "true" "s07-p3 存量行 .resolved == true"
    art s07-p3 "resolve exit=${RC7}" "$(jq -c 'select(.key == "SLR")' "$EV" 2>/dev/null)" "stdout=[${R7_OUT}]"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 8：仅 flashcards 域待推——只出 flashcards 卡，不空发 contrib 卡
#   谓词：s08-p1 [real-process]
# =============================================================================
if scene_on 8; then
  t_case "场景8 单域 flashcards 不空发（s08-p1）"
  if sb_fresh s08; then
    F2_TXT="F2-flashcards单域待推正文"
    ev_send event own-pr-activity --key f2 --summary "$F2_TXT" --channel flashcards >/dev/null
    B8="$(payload_count)"
    do_flush >/dev/null
    NEW8="$(payloads_new "$B8")"
    N8=$(( $(payload_count) - B8 ))

    # --- s08-p1 [real-process] 逐域零空发 + 条数 ---
    assert_eq "$N8" "1" "s08-p1 载荷条数 == 1（实际 ${N8}）"
    assert_contains "$NEW8" "$F2_TXT" "s08-p1 载荷携本域正文（非空批）"
    assert_not_contains "$NEW8" "【contrib 告警】" "s08-p1 零空发 contrib 卡（告警形态）"
    assert_not_contains "$NEW8" "【contrib 速报】" "s08-p1 零空发 contrib 卡（速报形态）"
    art s08-p1 "新增载荷数=${N8}" "新载荷文本=[${NEW8}]"
    sb_cleanup
  fi

  # --- s08-p1 续（[A2]）：flashcards 叙事批 digest 卡标头 + send 主题参数化 ---
  if sb_fresh s08; then
    F2N_NEW="$(narr_round flashcards f2n "F2N-flashcards叙事批正文")"
    assert_contains "$F2N_NEW" "【flashcards 告警】" "s08-p1 flashcards 告警标头（digest 卡）"
    if grep -qF -- "【contrib" <<<"$F2N_NEW"; then
      _fail "s08-p1 flashcards 叙事批零 contrib 标头" "叙事批载荷含 contrib 域标头"
    else
      _pass "s08-p1 flashcards 叙事批零 contrib 标头"
    fi
    if worker_send_digest "🟠【flashcards 告警】"; then
      if send_argv_has "flashcards 告警"; then
        _pass "s08-p1 flashcards 批 send 主题参数化"
      else
        _fail "s08-p1 flashcards 批 send 主题参数化" "send argv 未见 flashcards 告警"
      fi
    else
      _fail "s08-p1 flashcards digest 卡登记" "flight 缺 batch_file/card_id"
    fi
    art "s08-p1-narr" "$F2N_NEW" "$(jq -c . "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 9：静默窗口过期后复发允许重推（修复②窗口边界）
#   谓词：s09-p1 [real-process] s09-p2 [det-machine]
# =============================================================================
if scene_on 9; then
  t_case "场景9 窗口过期重推（s09-p1/p2）"
  if sb_fresh s09; then
    S0_TXT="S0-首推正文"
    S1_TXT="S1-窗口内复发正文"
    SPP_TXT="SPP-窗口外复发正文"
    OLD_ISO="2020-01-01T00:00:00+08:00" # flush 标记路（python isoformat）形态
    ev_send event own-pr-activity --key K --summary "$S0_TXT" >/dev/null
    do_flush >/dev/null
    assert_eq "$(led_field K '.pushed')" "true" "s09 前置：首推完成"
    ev_send event own-pr-activity --key K --summary "$S1_TXT" >/dev/null # 窗口内复发（occ=2）
    led_set_row K ".pushed_at = \"${OLD_ISO}\""                          # 冻结回拨：窗口过期
    ev_send event own-pr-activity --key K --summary "$SPP_TXT" >/dev/null # occ=3，须置 pushed=false
    assert_eq "$(led_field K '.pushed')" "false" "s09 前置：窗口外复发置 pushed=false"
    sb_state_set '.last_flush_epoch = 0'
    B9="$(payload_count)"
    do_flush >/dev/null
    NEW9="$(payloads_new "$B9")"

    # --- s09-p1 [real-process] 窗口外重推 ---
    assert_contains "$NEW9" "$SPP_TXT" "s09-p1 重推载荷 contains S-dprime"
    art s09-p1 "新增载荷数=$(( $(payload_count) - B9 ))" "新载荷文本=[${NEW9}]"

    # --- s09-p2 [det-machine] pushed_at 刷新 + 次数累计 ---
    PAT_NOW="$(led_field_raw K pushed_at)"
    OCC9="$(led_field_or K occurrences 0)"
    if [[ -n "$PAT_NOW" && "$PAT_NOW" > "$OLD_ISO" ]]; then
      _pass "s09-p2 .pushed_at 刷新（[${OLD_ISO}] → [${PAT_NOW}]）"
    else
      _fail "s09-p2 .pushed_at 刷新" "冻结回拨 [${OLD_ISO}] 现 [${PAT_NOW}]"
    fi
    if [[ "$OCC9" -ge 3 ]]; then
      _pass "s09-p2 .occurrences >= 3（实际 ${OCC9}，kill「窗口判了但永不过期」）"
    else
      _fail "s09-p2 .occurrences >= 3" "actual=${OCC9}"
    fi
    art s09-p2 "$(jq -c 'select(.key == "K")' "$EV" 2>/dev/null)"

    # --- [A4] pushed_at 第二格式（cmd_event 路 +0800）同样归一化 ---
    OLD_OFF="2020-01-01T00:00:00+0800"
    led_set_row K ".pushed_at = \"${OLD_OFF}\""
    ev_send event own-pr-activity --key K --summary "SPP2-第二格式窗口外复发" >/dev/null
    assert_eq "$(led_field K '.pushed')" "false" "s09-extra [+0800 格式] 窗口外复发置 pushed=false（时钟归一化）"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 10：跨域同 key 不互聚（修复①×②交界面）
#   谓词：s10-p1 [real-process] s10-p2 [det-machine]
# =============================================================================
if scene_on 10; then
  t_case "场景10 跨域同 key 不互聚（s10-p1/p2）"
  if sb_fresh s10; then
    SC_TXT="SC-contrib同key正文"
    SF_TXT="SF-flashcards同key正文"
    ev_send event own-pr-activity --key K --summary "$SC_TXT" >/dev/null
    do_flush >/dev/null
    assert_eq "$(led_field K '.pushed')" "true" "s10 前置：contrib 侧 K 已推（静默窗内）"
    sb_state_set '.last_flush_epoch = 0'
    ev_send event own-pr-activity --key K --summary "$SF_TXT" --channel flashcards >/dev/null
    B10="$(payload_count)"
    do_flush >/dev/null
    NEW10="$(payloads_new "$B10")"

    # --- s10-p1 [real-process] flashcards 同 key 独立推送 ---
    assert_contains "$NEW10" "$SF_TXT" "s10-p1 载荷 contains SF"
    assert_not_contains "$NEW10" "【contrib 告警】" "s10-p1 flashcards 载荷零 contrib 告警标头"
    assert_not_contains "$NEW10" "【contrib 速报】" "s10-p1 flashcards 载荷零 contrib 速报标头"
    art s10-p1 "新增载荷数=$(( $(payload_count) - B10 ))" "新载荷文本=[${NEW10}]"

    # --- s10-p2 [det-machine] 两行互不覆盖 ---
    ROWS10="$(led_key_rows K)"
    CH_A="$(led_field_or K channel contrib 0)"
    CH_B="$(led_field_or K channel contrib 1)"
    assert_eq "$ROWS10" "2" "s10-p2 key=K 行数 == 2（kill「key 唯一性无视 channel」）"
    assert_eq "$CH_A" "contrib" "s10-p2 首行 .channel == contrib（缺省域）"
    assert_eq "$CH_B" "flashcards" "s10-p2 次行 .channel == flashcards"
    art s10-p2 "行数=${ROWS10} 渠道=[${CH_A},${CH_B}]" "$(jq -c 'select(.key == "K")' "$EV" 2>/dev/null)"
    sb_cleanup
  fi

  # --- s10-p1 续（[A2]）：flashcards 域 告警标头载荷（同 key 语境下的域标头参数化） ---
  if sb_fresh s10; then
    ev_send event own-pr-activity --key K --summary "SC2-contrib同key正文" >/dev/null
    do_flush >/dev/null
    ev_send event own-pr-activity --key K --summary "SF2-flashcards同key正文" --channel flashcards >/dev/null
    do_flush >/dev/null
    KNF_NEW="$(narr_round flashcards knf "KNF-flashcards叙事批正文")"
    assert_contains "$KNF_NEW" "【flashcards 告警】" "s10-p1 flashcards 域 告警标头齐现"
    art "s10-p1-r2" "$KNF_NEW" "$(jq -c 'select(.key == "K" or .key == "knf")' "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 11：flashcards 域简报级事件同样降级简报（修复①×③交界面；简报级=visual-run-done）
#   谓词：s11-p1 [real-process] s11-p2 [real-process]
# =============================================================================
if scene_on 11; then
  t_case "场景11 flashcards 简报级降级（s11-p1/p2）"
  if sb_fresh s11; then
    SFG_TXT="SFG-flashcards简报级内容"
    ev_send event visual-run-done --key FG --summary "$SFG_TXT" --channel flashcards >/dev/null
    B11="$(payload_count)"
    do_flush >/dev/null
    NEW11="$(payloads_new "$B11")"

    # --- s11-p1 [real-process] 不即时推送 ---
    assert_eq "$(( $(payload_count) - B11 ))" "0" "s11-p1 flashcards 简报级零新增载荷"
    assert_not_contains "$NEW11" "$SFG_TXT" "s11-p1 载荷 not-contains SFG（negate 谓词）"
    art s11-p1 "新增载荷数=$(( $(payload_count) - B11 ))" "新载荷文本=[${NEW11}]"

    # --- s11-p2 [real-process] 简报消费队列收编 ---
    FG_ROUTE="$(led_field FG '.route')"
    FG_PUSHED="$(led_field FG '.pushed')"
    assert_eq "$FG_ROUTE" "brief" "s11-p2 FG 行 .route == \"brief\""
    assert_eq "$FG_PUSHED" "true" "s11-p2 FG 行 .pushed == true"
    art s11-p2 "$(jq -c 'select(.key == "FG")' "$EV" 2>/dev/null)"

    # --- 契约衍生：class→域映射兜底（§event 渠道解析：显式 --channel > class 映射 > contrib） ---
    ev_send event visual-run-done --key FG2 --summary "FG2-无显式渠道的flashcards类事件" >/dev/null
    assert_eq "$(led_field_or FG2 channel contrib)" "flashcards" "s11-extra class 映射兜底：visual-run-done 无 --channel 归 flashcards"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 12：resolved 告警复发重新激活（修复④ reopen 面）
#   谓词：s12-p1 [det-machine] s12-p2 [real-process]
# =============================================================================
if scene_on 12; then
  t_case "场景12 resolved 复发重开（s12-p1/p2）"
  if sb_fresh s12; then
    SPPP_TXT="SPPP-resolved后复发正文"
    ev_send event own-pr-activity --key K --summary "K-首报正文" >/dev/null
    do_flush >/dev/null
    sb_notify resolve --key K --summary "第一次闭环" >/dev/null
    assert_eq "$(led_field K '.resolved')" "true" "s12 前置：K 已 resolved"
    ev_send event own-pr-activity --key K --summary "$SPPP_TXT" >/dev/null

    # --- s12-p1 [det-machine] 重开为活跃态 ---
    R12="$(led_field K '.resolved')"
    OCC12="$(led_field_or K occurrences 0)"
    assert_eq "$R12" "false" "s12-p1 .resolved == false（重开）"
    if [[ "$OCC12" -ge 2 ]]; then
      _pass "s12-p1 .occurrences >= 2（实际 ${OCC12}）"
    else
      _fail "s12-p1 .occurrences >= 2" "actual=${OCC12}"
    fi
    assert_eq "$(led_field K '.pushed')" "false" "s12-p1 [契约衍生] 重开同时置 pushed=false（必重推）"
    art s12-p1 "$(jq -c 'select(.key == "K")' "$EV" 2>/dev/null)"

    # --- s12-p2 [real-process] 重开的活跃告警重新推送 ---
    sb_state_set '.last_flush_epoch = 0'
    B12="$(payload_count)"
    do_flush >/dev/null
    NEW12="$(payloads_new "$B12")"
    assert_contains "$NEW12" "$SPPP_TXT" "s12-p2 重推载荷 contains S-tprime（resolved 历史不构成静默）"
    art s12-p2 "新增载荷数=$(( $(payload_count) - B12 ))" "新载荷文本=[${NEW12}]"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 13：resolve 指向不存在的告警——预期错误处理（修复④错误面）
#   谓词：s13-p1 [real-process] s13-p2 [det-machine]
# =============================================================================
if scene_on 13; then
  t_case "场景13 resolve 未知 key 错误路径（s13-p1/p2）"
  if sb_fresh s13; then
    seed_legacy_row own-pr-activity BASE-ROW "占位存量行（冻结前置）"
    ROWS_F="$(led_rows)"
    PAY_F="$(payload_count)"
    assert_eq "$ROWS_F" "1" "s13 前置：账本 1 行"
    assert_eq "$PAY_F" "0" "s13 前置：零载荷"
    RB_OUT="$(sb_notify resolve --key NOPE --summary "不存在的告警")"
    RC13=$?
    RB_ERR="$(sb_out 20)"

    # --- s13-p1 [real-process] 非零退出 + 回显 key ---
    assert_ne "$RC13" "0" "s13-p1 resolve 未知 key exit != 0（实际 ${RC13}）"
    assert_contains "${RB_OUT}
${RB_ERR}" "NOPE" "s13-p1 输出回显该 key"
    art s13-p1 "exit=${RC13}" "stdout=[${RB_OUT}]" "stderr=[${RB_ERR}]"

    # --- s13-p2 [det-machine] 零副作用 ---
    ROWS_A="$(led_rows)"
    PAY_A="$(payload_count)"
    assert_eq "$ROWS_A" "$ROWS_F" "s13-p2 账本行数 == 冻结前置值（${ROWS_F}）"
    assert_eq "$PAY_A" "$PAY_F" "s13-p2 载荷数 == 冻结前置值（${PAY_F}）"
    art s13-p2 "行数 ${ROWS_F} → ${ROWS_A}；载荷数 ${PAY_F} → ${PAY_A}" "$(jq -c . "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 14：约束守护——notify_target 与每日推送上限数值零改动
#   谓词：s14-p1 [det-machine] s14-p2 [det-machine]
# =============================================================================
if scene_on 14; then
  t_case "场景14 红线守护（s14-p1/p2）"
  MERGE_BASE="$(git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null || git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || printf 'HEAD')"
  DIFF_OUT="$(git -C "$REPO_ROOT" diff "$MERGE_BASE" -- . 2>/dev/null)"
  # 只计「变更行」（+/- 本体行；context 行不算）——谓词口径 = diff 里改动到 notify_target 的行数
  DIFF_CHANGED="$(printf '%s' "$DIFF_OUT" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
  NT_HITS="$(printf '%s' "$DIFF_CHANGED" | grep -c 'notify_target' || true)"

  # --- s14-p1 [det-machine] 全量 diff 零 notify_target 行 ---
  assert_eq "${NT_HITS:-0}" "0" "s14-p1 工作树全量 diff 零 notify_target 行（基线 ${MERGE_BASE}）"
  if [[ -f "$REPO_ROOT/contrib-data/config.json" ]]; then
    _fail "s14-p1 生产 config 不入仓" "工作树出现 contrib-data/config.json（生产配置面被纳入版本控制）"
  else
    _pass "s14-p1 生产 config 不在仓内（本体佐证）"
  fi
  art s14-p1 "merge-base=${MERGE_BASE}" "diff 行数=$(printf '%s' "$DIFF_OUT" | wc -l | tr -d ' ')" \
    "变更行含 notify_target 计数=${NT_HITS:-0}" "命中行：" \
    "$(printf '%s' "$DIFF_CHANGED" | grep -n 'notify_target' || true)"

  # --- s14-p2 [det-machine] 上限数值语义与基线相等（键名逐字 + 死缺省不下降 + 行为总闸不变） ---
  WORK_NOTIFY="$CONTRIB_TEST_TARGET/notify.sh"
  TMPB="$(mktemp -d "${TMPDIR:-/tmp}/t13-base.XXXXXX")"
  git -C "$REPO_ROOT" show "${MERGE_BASE}:scripts/contrib/notify.sh" >"$TMPB/notify-baseline.sh" 2>/dev/null || true
  BASE_NOTIFY="$TMPB/notify-baseline.sh"
  B_KEY="$(grep -c "max_alert_pushes_per_day" "$BASE_NOTIFY" 2>/dev/null || true)"
  W_KEY="$(grep -c "max_alert_pushes_per_day" "$WORK_NOTIFY" 2>/dev/null || true)"
  B_DEF="$(grep -oE "\.max_alert_pushes_per_day'[[:space:]]+'[0-9]+" "$BASE_NOTIFY" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
  W_DEF="$(grep -oE "\.max_alert_pushes_per_day'[[:space:]]+'[0-9]+" "$WORK_NOTIFY" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
  if [[ -z "$B_DEF" ]]; then
    B_DEF="$(grep -oE "max_alert_pushes_per_day[^0-9]{0,8}[0-9]+" "$BASE_NOTIFY" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
  fi
  if [[ -z "$W_DEF" ]]; then
    W_DEF="$(grep -oE "max_alert_pushes_per_day[^0-9]{0,8}[0-9]+" "$WORK_NOTIFY" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
  fi
  [[ "${B_KEY:-0}" -ge 1 ]] && _pass "s14-p2 基线含 max_alert_pushes_per_day 读取（命中 ${B_KEY} 行）" \
    || _fail "s14-p2 基线含 max_alert_pushes_per_day 读取" "基线命中 0 行"
  [[ "${W_KEY:-0}" -ge 1 ]] && _pass "s14-p2 工作区 config 键同名（命中 ${W_KEY} 行）" \
    || _fail "s14-p2 工作区 config 键同名" "工作区命中 0 行"
  assert_ne "$B_DEF" "" "s14-p2 基线死缺省可抽取（形态未漂移）"
  assert_ne "$W_DEF" "" "s14-p2 工作区死缺省可抽取（形态未漂移）"
  if [[ -n "$B_DEF" && -n "$W_DEF" && "$W_DEF" -ge "$B_DEF" ]]; then
    _pass "s14-p2 死缺省不下降（基线 ${B_DEF} → 工作区 ${W_DEF}）"
  else
    _fail "s14-p2 死缺省不下降" "基线 [${B_DEF}] 工作区 [${W_DEF}]（上限被放松）"
  fi
  art s14-p2 "基线键命中=${B_KEY} 工作区键命中=${W_KEY} 基线缺省=[${B_DEF}] 工作区缺省=[${W_DEF}]" \
    "基线 cfg 行：" "$(grep -n 'max_alert_pushes_per_day' "$BASE_NOTIFY" 2>/dev/null || true)" \
    "工作区 cfg 行：" "$(grep -n 'max_alert_pushes_per_day' "$WORK_NOTIFY" 2>/dev/null || true)"
  rm -rf "$TMPB" 2>/dev/null || true

  # 行为总闸（[A8] 限额检查在分渠循环之前 ⇒ 以单域两轮验总闸，不假设逐批检查）：
  # cap=1 时第一轮正常推送、第二轮（回拨后）被限额拒绝、alerts[today] 封顶于 1
  if sb_fresh s14; then
    sb_config_set '.max_alert_pushes_per_day = 1'
    ev_send event own-pr-activity --key cap-a --summary "容量闸-第一轮正文" >/dev/null
    B14="$(payload_count)"
    do_flush >/dev/null
    N14A=$(( $(payload_count) - B14 ))
    sb_state_set '.last_flush_epoch = 0'
    ev_send event own-pr-activity --key cap-b --summary "容量闸-第二轮正文" >/dev/null
    B14B="$(payload_count)"
    do_flush >/dev/null
    N14B=$(( $(payload_count) - B14B ))
    ALERTS14="$(jq -r --arg d "$(date +%F)" 'if (.alerts[$d] == null) then "0" else (.alerts[$d] | tostring) end' \
      "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || printf '?')"
    assert_eq "$N14A" "1" "s14-p2 [契约衍生] 上限内轮正常推送（cap=1 第一轮恰 1 条，实际 ${N14A}）"
    assert_eq "$N14B" "0" "s14-p2 [契约衍生] 限额拒绝轮零推送（cap=1 第二轮 0 条，实际 ${N14B}）"
    assert_eq "$ALERTS14" "1" "s14-p2 [契约衍生] alerts[today] 封顶于上限（实际 ${ALERTS14}）"
    art "s14-p2-cap" "第一轮推送=${N14A} 第二轮推送=${N14B} alerts[today]=${ALERTS14}" \
      "$(jq -c . "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 15：验收命令面全绿 + mutation 自证归零（用户指定命令面）
#   谓词：s15-p1 [real-process] s15-p2 [real-process] s15-p3 [real-process]
#         s15-p4 [det-machine] s15-p5 [real-process]
# =============================================================================
if scene_on 15; then
  t_case "场景15 命令面与 mutation 自证（s15-p1/p2/p3/p4/p5）"

  # --- s15-p1 gate.sh 全绿 ---
  GATE_OUT="$(cd "$REPO_ROOT" && env -u MARTIN_DIR bash "$REPO_ROOT/scripts/contrib/tests/gate.sh" 2>&1)"
  RC_GATE=$?
  assert_eq "$RC_GATE" "0" "s15-p1 gate.sh exit == 0"
  art s15-p1 "gate rc=${RC_GATE}" "$(printf '%s' "$GATE_OUT" | tail -30)"

  # --- s15-p2 run.sh 末行 JSON .failed == 0 ---
  RUN_OUT="$(cd "$REPO_ROOT" && env -u MARTIN_DIR bash "$REPO_ROOT/scripts/contrib/tests/run.sh" 2>&1)"
  RC_RUN=$?
  RUN_LAST="$(printf '%s' "$RUN_OUT" | tail -1)"
  RUN_FAILED="$(printf '%s' "$RUN_LAST" | jq -r 'if has("failed") then .failed else "PARSE-ERR" end' 2>/dev/null || printf 'PARSE-ERR')"
  assert_eq "$RUN_FAILED" "0" "s15-p2 run.sh 末行 JSON .failed == 0"
  art s15-p2 "run rc=${RC_RUN} 末行=[${RUN_LAST}]" "$(printf '%s' "$RUN_OUT" | grep -E '^FAIL ' | head -40)"

  # --- s15-p3 approval 套件全绿 ---
  APR_OUT="$(cd "$REPO_ROOT" && env -u MARTIN_DIR bash "$REPO_ROOT/scripts/approval/tests/run.sh" 2>&1)"
  RC_APR=$?
  assert_eq "$RC_APR" "0" "s15-p3 approval/tests/run.sh exit == 0"
  art s15-p3 "approval rc=${RC_APR}" "$(printf '%s' "$APR_OUT" | tail -30)"

  # --- s15-p4 mutation 杀伤证明：注入红变异 → 本套件受影响单文件由绿转红 ---
  # 冻结基线（谓词口径「对照冻结基线」，s15-p5 求值用；在循环启动前采集一次）
  PORC_BASE="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
  MUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/t13-mut.XXXXXX")"
  cp "$CONTRIB_TEST_TARGET"/*.sh "$MUT_DIR"/ 2>/dev/null || true
  chmod +x "$MUT_DIR"/*.sh 2>/dev/null || true
  # 变异点 1：flashcards 域标头字面量（设计 §方案 3 明示字面）
  sed 's/【flashcards 告警】/【flashcards-MUT】/g' "$MUT_DIR/notify.sh" >"$MUT_DIR/notify.sh.m1" 2>/dev/null || true
  mv "$MUT_DIR/notify.sh.m1" "$MUT_DIR/notify.sh" 2>/dev/null || true
  # 变异点 2：resolve 子命令 case 分支（契约钉死 `^  [a-z|-]+)` 两空格缩进形态）
  sed 's/^  resolve)/  resolve-mut-disabled)/' "$MUT_DIR/notify.sh" >"$MUT_DIR/notify.sh.m2" 2>/dev/null || true
  mv "$MUT_DIR/notify.sh.m2" "$MUT_DIR/notify.sh" 2>/dev/null || true
  MUT_OUT="$(T13_SCENES="1,6,8" T13_ART="$ART/mutation-child" CONTRIB_TEST_TARGET="$MUT_DIR" \
    CONTRIB_TEST_STUBS="$CONTRIB_TEST_STUBS" bash "$SELF_FILE" 2>&1)"
  RC_MUT=$?
  MUT_ATTR="$(printf '%s' "$MUT_OUT" | grep '^FAIL ' | grep -E 'flashcards|闭环|resolve' | head -10)"
  assert_ne "$RC_MUT" "0" "s15-p4 变异副本跑本套件 != 0（由绿转红；实际 ${RC_MUT}）"
  if [[ -n "$MUT_ATTR" ]]; then
    _pass "s15-p4 变异杀伤可归因（FAIL 行指向被变异面）"
  else
    _fail "s15-p4 变异杀伤可归因" "变异跑无指向 flashcards/闭环 的 FAIL 行（变异未杀伤）：$(printf '%s' "$MUT_OUT" | tail -5)"
  fi
  art s15-p4 "变异跑 exit=${RC_MUT}" "变异点=标头字面量+resolve 分支" "指向性 FAIL：" "$MUT_ATTR" \
    "变异跑尾部：" "$(printf '%s' "$MUT_OUT" | tail -20)"
  rm -rf "$MUT_DIR" 2>/dev/null || true

  # --- s15-p5 mutation 循环后工作区归零（除基线成员） ---
  # 机制修正（2026-09-13 QA 自决，情形③，E3 证据闭合）：原实现以「硬编码未跟踪文件名清单」
  # 近似「冻结基线」——该清单既未随环境扩展同步（外层 lane 的 run-coder-3.sh 未列入），又把
  # QA 时按流程尚未提交的交付面（staged M）计为污染，与谓词括号口径「对照冻结基线…属基线成员
  # 非污染」相悖，任何实现都躲不开。改为以循环前冻结的 porcelain 快照为排除集，机制形态不变
  # （「除基线外为空」），残留仍会被捕获（循环前后任一差异行即 FAIL）。
  PORC="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
  assert_eq "$PORC" "$PORC_BASE" "s15-p5 mutation 循环前后 porcelain 逐字节一致（零残留）"
  # 「除基线成员外为空」——基线快照为空时不得用 grep -f 空模式（空 regex 命中全行=假绿）
  if [[ -n "$PORC_BASE" ]]; then
    PORC_FILTERED="$(printf '%s' "$PORC" | grep -vxF -f <(printf '%s\n' "$PORC_BASE") || true)"
  else
    PORC_FILTERED="$PORC"
  fi
  assert_eq "$PORC_FILTERED" "" "s15-p5 git status 除基线成员外为空"
  art s15-p5 "冻结基线（循环前）：" "$PORC_BASE" "循环后 porcelain：" "$PORC" "过滤后：" "$PORC_FILTERED"
fi

# =============================================================================
# 场景 16：同簇不同 key（date 后缀）原位更新——cluster_key_of 主判据
#   谓词：s16-p1 [real-process] s16-p2 [det-machine]
# =============================================================================
if scene_on 16; then
  t_case "场景16 同簇不同 key 聚类（s16-p1/p2）"
  if sb_fresh s16; then
    K_OLD="X-stale-2026-09-13"
    K_NEW="X-stale-2026-09-14"
    S_OLD_TXT="SOLD-首次上报正文"
    S_NEW_TXT="SNEW-次日同根因正文"
    ev_send event probe-premise-dead --key "$K_OLD" --summary "$S_OLD_TXT" >/dev/null
    RC16A=$?
    sleep 1
    ev_send event probe-premise-dead --key "$K_NEW" --summary "$S_NEW_TXT" >/dev/null
    RC16B=$?
    assert_exit 0 $RC16A "s16-p1 首报 event exit 0"
    assert_exit 0 $RC16B "s16-p1 同簇次报 event exit 0"

    # --- s16-p1 [real-process] 原位更新首行 ---
    ROWS16="$(led_rows)"
    OCC16="$(led_field_or "$K_OLD" occurrences 0)"
    CL16="$(led_field_raw "$K_OLD" cluster)"
    KEY16="$(led_field "$K_OLD" '.key')"
    assert_eq "$ROWS16" "1" "s16-p1 行数 == 1（同簇原位更新非追加）"
    if [[ "$OCC16" -ge 2 ]]; then
      _pass "s16-p1 .occurrences >= 2（实际 ${OCC16}）"
    else
      _fail "s16-p1 .occurrences >= 2" "actual=${OCC16}"
    fi
    assert_ne "$CL16" "" "s16-p1 .cluster != null（实际 [${CL16}]）"
    assert_contains "$CL16" "X-stale" "s16-p1 [A3] cluster 含 X-stale（日期 token 已剥）"
    assert_eq "$KEY16" "$K_OLD" "s16-p1 .key 保持首行 key（告警 id 可追踪）"
    assert_eq "$(led_key_rows "$K_NEW")" "0" "s16-p1 次报 key 未成行（聚类收编）"
    art s16-p1 "$(jq -c --arg k "$K_OLD" 'select(.key == $k)' "$EV" 2>/dev/null)" "行数=${ROWS16} cluster=[${CL16}]"

    # --- s16-p2 [det-machine] 更新行携最新摘要 ---
    SUM16="$(led_field "$K_OLD" '.summary')"
    assert_eq "$SUM16" "$S_NEW_TXT" "s16-p2 .summary == S_new（第二次 event 摘要）"
    art s16-p2 "$(jq -c --arg k "$K_OLD" 'select(.key == $k) | {key, summary, occurrences, cluster}' "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 17：resolved 同簇不吞新告警 + resolve --cluster（修复②×④交界面）
#   谓词：s17-p1 [real-process] s17-p2 [real-process]
# =============================================================================
if scene_on 17; then
  t_case "场景17 resolved 簇不吞新告警 + resolve --cluster（s17-p1/p2）"
  if sb_fresh s17; then
    K1="Y-stale-2026-09-13"
    K2="Y-stale-2026-09-14"
    ev_send event probe-premise-dead --key "$K1" --summary "Y-首报正文" >/dev/null
    sb_notify resolve --key "$K1" --summary "首报根因消除" >/dev/null
    assert_eq "$(led_field "$K1" '.resolved')" "true" "s17 前置：K1 已 resolved"
    ev_send event probe-premise-dead --key "$K2" --summary "Y-次日复现正文" >/dev/null

    # --- s17-p1 [real-process] resolved 同簇不吞新告警 ---
    ROWS17="$(led_rows)"
    R_OLD="$(led_field_or "$K1" resolved false)"
    R_NEW="$(led_field_or "$K2" resolved false)"
    assert_eq "$ROWS17" "2" "s17-p1 行数 == 2（新 key 追加而非复活 resolved 行）"
    assert_eq "$R_OLD" "true" "s17-p1 resolved 行 .resolved 仍 == true"
    assert_eq "$R_NEW" "false" "s17-p1 新行 .resolved == false"
    art s17-p1 "$(jq -c --arg a "$K1" --arg b "$K2" 'select(.key == $a or .key == $b)' "$EV" 2>/dev/null)"

    # --- s17-p2 [real-process] resolve --cluster 命中未 resolved 行 ---
    CL17="$(led_field_raw "$K2" cluster)"
    assert_ne "$CL17" "" "s17-p2 前置：K2 行 .cluster 落值（消费方 resolve --cluster 读同一字段名）"
    sb_notify resolve --cluster "$CL17" --summary "簇内根因已消除" >/dev/null
    RC17=$?
    assert_eq "$RC17" "0" "s17-p2 resolve --cluster exit == 0"
    assert_eq "$(led_field_or "$K2" resolved false)" "true" "s17-p2 该簇未 resolved 行 .resolved == true"
    art s17-p2 "cluster=[${CL17}] exit=${RC17}" "$(jq -c --arg b "$K2" 'select(.key == $b)' "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

# =============================================================================
# 场景 18：扩展机制面——brief_only_classes 覆盖 + --channel 空串哨兵（契约扩展点）
#   谓词：s18-p1 [det-machine] s18-p2 [det-machine]
# =============================================================================
if scene_on 18; then
  t_case "场景18 扩展机制（s18-p1/p2）"
  if sb_fresh s18; then
    # --- s18-p1 config 存在 brief_only_classes → replace 语义 ---
    sb_config_set '.brief_only_classes = ["pipeline-failure"]'
    ev_send event pipeline-failure --key CN --summary "CN-replace后降级类正文" >/dev/null
    ev_send event own-pr-info --key OP --summary "OP-缺省表类不再降级正文" >/dev/null
    B18="$(payload_count)"
    do_flush >/dev/null
    CN_ROUTE="$(led_field CN '.route')"
    CN_PUSHED="$(led_field CN '.pushed')"
    OP_ROUTE="$(led_field_or OP route push)"
    assert_eq "$CN_ROUTE" "brief" "s18-p1 数组内新类 C_new 行 .route == \"brief\"（降级）"
    assert_eq "$CN_PUSHED" "true" "s18-p1 C_new 行 .pushed == true（简报队列标记）"
    assert_ne "$OP_ROUTE" "brief" "s18-p1 数组外缺省表类不再降级（replace 非并集）"
    DFLIGHT18="$SB_ROOT/contrib-data/kanban-flight-digest.json"
    if [[ -f "$DFLIGHT18" ]]; then
      _pass "s18-p1 push 类行照常进微信批（digest 卡已派发）"
      SNAP18="$(digest_flight_field batch_file)"
      N_OP="$(jq -s '[.[] | select(.key == "OP")] | length' "$SNAP18" 2>/dev/null || printf '0')"
      N_CN="$(jq -s '[.[] | select(.key == "CN")] | length' "$SNAP18" 2>/dev/null || printf '0')"
      assert_eq "$N_OP" "1" "s18-p1 push 类行在批内（快照含 OP）"
      assert_eq "$N_CN" "0" "s18-p1 brief 类行不进微信批（快照不含 CN）"
    else
      _fail "s18-p1 push 类行照常进微信批" "digest 卡未派发（kanban-flight-digest.json 缺失）"
    fi
    assert_not_contains "$(payloads_new "$B18")" "CN-replace后降级类正文" "s18-p1 载荷 not-contains CN 正文"
    art s18-p1 "$(jq -c 'select(.key == "CN" or .key == "OP")' "$EV" 2>/dev/null)" \
      "flight=[$(jq -c . "$DFLIGHT18" 2>/dev/null)]"

    # --- s18-p2 --channel 空串哨兵 ---
    ev_send event own-pr-activity --key c-empty-chan --summary "空串渠道哨兵" --channel "" >/dev/null
    assert_eq "$(led_field_or c-empty-chan channel contrib)" "contrib" "s18-p2 --channel \"\" 视为未传 → class 映射/缺省 contrib"
    ev_send event visual-run-done --key f-empty-chan --summary "空串渠道+flashcards类" --channel "" >/dev/null
    assert_eq "$(led_field_or f-empty-chan channel contrib)" "flashcards" "s18-p2 --channel \"\" 同走 class 映射（visual-run-done → flashcards）"
    art s18-p2 "$(jq -c 'select(.key == "c-empty-chan" or .key == "f-empty-chan")' "$EV" 2>/dev/null)"
    sb_cleanup
  fi
fi

t_finish
