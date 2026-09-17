#!/usr/bin/env bash
# =============================================================================
# t9396-stale-realrun.acceptance.test.sh — 卡 t_9396bbf3 红队验收（文件 5/5）
#   S3 真跑真数据（产物3 数据面验收②）：S3.P1 直跑 exit==0 + 产物非空且本轮重写 /
#   S3.P2 信封合法 / S3.P3 复跑 generated_at 严格递增 + mtime 更新（非 fixture 证据）/
#   S3.P4 items 形态 + generated_at 时窗。
# 【设计声明的降级出口】S3.P1 自带条款：「本环境 gh 网络若被会话权限拦截 → 显式失败出口，
#   交陪跑员复跑（BRIEFING §6 要求其独立复跑）」。本会话权限禁真网络 ⇒ 默认路径显式
#   deferred（t_skip + ##REALRUN 标记，绝不静默绿）；陪跑员/QA 复跑：
#     STALE_ACCEPTANCE_REAL_RUN=1 bash scripts/contrib/tests/acceptance/t9396-stale-realrun.acceptance.test.sh
#   可选 T9396_REALRUN_CONTRIB=<dir> 把产物重定向到指定 contrib 目录（缺省按 SSOT 落
#   $HOME/workspace/martin/contrib-data/ 生产位，即验收②的字面口径）。
#
# 【09-18 instrument repair（卡 t_37874900）——D1/D3 修复 + D2 两 opt-in 缝 + 限流归属】
#   - D1 gen_epoch 重写（jq -nr --arg 形态）：此前裸 ISO 串直喂 jq，解析错误不被
#     try/catch 捕获且 stderr 被吞 ⇒ 恒空 ⇒ P3「严格递增」「时窗」永红。现形态：
#     带 Z 走 fromdateiso8601、无 Z 取前 19 字符走 strptime+mktime，垃圾串/空串返回
#     空串（stderr 静默、函数 rc 恒 0）；定义后附离线三态自检 t_case（+3 断言、零网络、
#     真跑路径内留证）。
#   - D3 S3.P1 水位绑定本轮运行：run1 前取产物 mtime(_M0) / sha256(_S0) / 日志行数(_L0)，
#     「产物非空」收紧为 size>0 ∧ mtime 前进 ∧ sha 变更（三条件合取）；「ok 行落日志」
#     收窄到第 _L0+1 行起的本轮新增窗口（产品脚本 scan_log 恒 >> 追加单行）——run1 未
#     重写产物时必判红，根除读全量文件命中遗留产物的 false-green。已知紧边（方向=
#     fail-closed）：run1 与前次写入同秒完成且内容变更 ⇒ mtime 不进位 ⇒ 判红；真跑
#     单轮 ≥ 数秒、前置产物相隔分钟级，实际不可达。
#   - D2 口径 1 等价取证（opt-in）：T9396_REALRUN_EQUIV=1 时 run1 前固化一号样本——
#     来源 ${T9396_REALRUN_EQUIV_JSON:-$JSONF}（既存真实产物），cp -p 存
#     $ART/prev-artifact.json，mtime/sha256/generated_at 在来源上先取（cp 前）。
#     合法性门禁 = 文件非空 ∧ jq -e . 合法 ∧ generated_at 可解析 ∧ mtime 整数且 <T0
#     （≥T0 = 本轮自写）∧ .status=="ok" ∧ .items 为 array；任一不过 ⇒ 「S3.P3 等价样本」
#     判红，绝不静默降级、禁 fixture。过门后 S3.P3「严格递增」「mtime 更新」改用
#     sample1↔run1 跨独立真跑样本求值，两样本 provenance 以 ##EQUIV 行逐条打印
#     （sha256 / mtime / generated_at）；run2 仍照跑一次（「窗口内复跑」谓词在场）。
#   - D2 口径 2 间隔（opt-in）：T9396_REALRUN_RUN2_GAP_S=<整数秒> 控制 run1↔run2 间隔，
#     非整数/空回落 2；缺省 2 = 原行为不变。
#   - 限流归属（≠跳过/≠变绿）：run2 rc≠0 且 signature 命中 ⇒ stdout 打 ##ENV BLOCKED 归属行；
#     「复跑 exit==0」断言照红、##SUMMARY failed 照计、exit 1——红可解释为限流而非判据缺陷。
#     默认路径 P3 递增红 × 同源（未落新产物、sha 同值）时失败文案只陈述可观测事实
#     「本轮 run2 未落新产物：产物 sha256 未变更 ⇒ 两样本同源」（EQUIV 模式同源信号指 run1），
#     与「无法解析为 epoch」文案互斥可分辨；「限流」因果只由 signature 命中后的
#     ##ENV BLOCKED 行承担，FAIL 文案不断言因果。
#   - 09-18 补修轮（陪跑员真跑核验驱动）：signature 从空格形态「secondary rate limit」扩为
#     secondary[- ]rate[- ]limit（连字符/空格两形态）∨ URL 片段
#     rate-limits-for-the-rest-api#about-secondary——真实 403 stderr 是 pretty JSON
#     （documentation_url 在前），经产品脚本 first_err 单行化 + 200 字符截断后，空格形态
#     必被截掉、只剩连字符形态与 URL 片段存活（空格形态恒不命中 = 归属行永不出现）。
#     匹配位置不变（$ART/t9396-realrun-2.out + 本轮新增日志窗口 _L0+1 起，后者留证于
#     $ART/t9396-realrun-2.logwin）。配套 stub 保真度回归门 rt9396-sc10-stubfidelity
#     （落 gitignored 任务目录，不随仓分发）：真实形态 403 stub（pretty JSON、documentation_url
#     在前）驱动全链，断言产品 stdout/stderr 零外泄 + 单条 200 字符截断 FAILED 行 + ##ENV
#     BLOCKED 在场 + FAIL 文案零因果断言。
#   - 缝补：export CONTRIB_DATA_DIR="${CONTRIB_DIR}" —— 断言读位与被测产品脚本写位
#     同步，T9396_REALRUN_CONTRIB 单 env 即完成重定向（此前只改读位=缝错位，调用方被迫
#     双设两 env）；缺省值与产品缺省（$HOME/workspace/martin/contrib-data）同值 ⇒
#     默认路径语义零变化。
#   跑法示例（仪器自检，stub 二进制 + seam 重定向，零真网络零生产写入）：
#     T="$(mktemp -d "${TMPDIR:-/tmp}/t9396-instr.XXXXXX")"; mkdir -p "${T}/contrib/logs"
#     STALE_ACCEPTANCE_REAL_RUN=1 SCAN_LIMIT=90 T9396_REALRUN_CONTRIB="${T}/contrib" \
#       GH_BIN="${T}/stubbin" bash scripts/contrib/tests/acceptance/t9396-stale-realrun.acceptance.test.sh
#   跑法示例（陪跑员跨窗等价取证）：
#     STALE_ACCEPTANCE_REAL_RUN=1 T9396_REALRUN_EQUIV=1 \
#       T9396_REALRUN_EQUIV_JSON="$HOME/workspace/martin/contrib-data/runs/<id>/stale-pr-scan.json" \
#       bash scripts/contrib/tests/acceptance/t9396-stale-realrun.acceptance.test.sh
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT:-}" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析: ${SELF_DIR}" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
SCAN_SH="$REPO_ROOT/scripts/contrib/stale-pr-scan.sh"

export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/assert.sh
source "$TESTS_ROOT/lib/assert.sh"
t_init "$T_FILE"

if [[ "${STALE_ACCEPTANCE_REAL_RUN:-}" != "1" ]]; then
  t_case "S3.P1/P3 真跑真数据——默认会话（禁真网络）显式 deferred，交陪跑员复跑"
  t_skip "S3.P1 设计降级出口：本会话权限禁真网络，真跑真数据不可求值；复跑=STALE_ACCEPTANCE_REAL_RUN=1 bash <本文件>（BRIEFING §6 陪跑员独立复跑）"
  echo "##REALRUN deferred=1 reason=network-forbidden-session owner=陪跑员/QA 复跑命令=STALE_ACCEPTANCE_REAL_RUN=1 bash $T_FILE"
  t_finish
fi

# ---------------- 真跑路径 ----------------
# 09-17 收口修复（instrument repair）：ART 此前未定义（set -u 下引用即崩），真跑产物无落盘点。
ART="$(mktemp -d "${TMPDIR:-/tmp}/t9396-realrun-art.XXXXXX")"
echo "##REALRUN artifacts dir: $ART"
CONTRIB_DIR="${T9396_REALRUN_CONTRIB:-$HOME/workspace/martin/contrib-data}"
JSONF="$CONTRIB_DIR/stale-pr-scan.json"
LOGF="$CONTRIB_DIR/logs/stale-pr-scan.log"
# 缝补（t_37874900）：断言读位与被测产品脚本写位同步——T9396_REALRUN_CONTRIB 单 env 即
# 完成重定向；缺省值与产品缺省同值 ⇒ 默认路径语义零变化。
export CONTRIB_DATA_DIR="${CONTRIB_DIR}"

t_case "env 前置：gh 在位 + 被测脚本在位"
command -v gh >/dev/null 2>&1 && _pass "gh CLI 在位（$(command -v gh)）" || _fail "env" "gh 不可用——真跑无法执行"
[[ -f "$SCAN_SH" ]] && _pass "被测脚本在位" || _fail "env" "缺失: ${SCAN_SH}（真跑面无法求值）"
mkdir -p "$CONTRIB_DIR/logs" 2>/dev/null || true

gen_epoch() { # <generated_at 字符串> → epoch；不可解析输出空（stderr 静默、rc 恒 0）
  local e s
  s="$1"
  e="$(jq -nr --arg s "$s" '$s | try fromdateiso8601 catch empty' 2>/dev/null || true)"
  if [[ -z "$e" || "$e" == "null" ]]; then
    e="$(jq -nr --arg s "${s:0:19}" '($s | try strptime("%Y-%m-%dT%H:%M:%S") catch empty) | mktime' 2>/dev/null || true)"
  fi
  printf '%s' "$e"
}

t_case "gen_epoch 离线三态自检（D1 修复回归锚；零网络）"
assert_eq "$(gen_epoch "2026-09-17T19:31:03Z")" "1789673463" "gen_epoch 带 Z 形态 → 1789673463"
assert_eq "$(gen_epoch "2026-09-17T19:31:03")" "1789673463" "gen_epoch 无 Z 形态（取前 19 字符）→ 1789673463"
assert_eq "$(gen_epoch "not-a-timestamp")" "" "gen_epoch 垃圾串 → 空串"

# ---------------- S3.P1 ----------------
t_case "S3.P1 直跑真 gh：exit==0 ∧ stale-pr-scan.json size>0（artifact 留 stdout/stderr）"
# 前置水位（D3 本轮绑定判据）：产物 mtime / sha256 / 日志行数（缺文件 → 空 / 0，fail-soft）
_M0="$(stat -f %m "$JSONF" 2>/dev/null || true)"
_S0="$(shasum -a 256 "$JSONF" 2>/dev/null | awk '{print $1}')"
_L0=0
if [[ -f "$LOGF" ]]; then
  _L0="$(wc -l < "$LOGF" 2>/dev/null | tr -d ' ')"
  case "${_L0}" in
    ''|*[!0-9]*) _L0=0 ;;
  esac
fi
# D2 口径 1（opt-in）：EQUIV=1 ⇒ run1 前固化一号样本（provenance 在来源上先取，cp 前）
_eq_on=0
_eq_ok=0
_eq_src=""
_eq_sha=""
_eq_m1=""
_eq_gen=""
_eq_e=""
if [[ "${T9396_REALRUN_EQUIV:-}" == "1" ]]; then
  _eq_on=1
  _eq_src="${T9396_REALRUN_EQUIV_JSON:-$JSONF}"
  _eq_sha="$(shasum -a 256 "$_eq_src" 2>/dev/null | awk '{print $1}')"
  _eq_m1="$(stat -f %m "$_eq_src" 2>/dev/null || true)"
  _eq_gen="$(jq -r '.generated_at // empty' "$_eq_src" 2>/dev/null || true)"
  _eq_e="$(gen_epoch "$_eq_gen")"
  cp -p "$_eq_src" "$ART/prev-artifact.json" 2>/dev/null || true
fi
T0="$(date +%s)"
if [[ "${_eq_on}" == "1" ]]; then
  # 合法性门禁（任一不过 ⇒ 判红，禁静默降级禁 fixture）：非空 ∧ 合法 JSON ∧
  # generated_at 可解析 ∧ mtime 整数且 <T0（≥T0 = 本轮自写）∧ status==ok ∧ items array
  _why=""
  [[ -s "$_eq_src" ]] || _why="${_why}文件缺失或为空;"
  if [[ -s "$_eq_src" ]] && ! jq -e . "$_eq_src" >/dev/null 2>&1; then
    _why="${_why}JSON 非法;"
  fi
  [[ -n "$_eq_e" ]] || _why="${_why}generated_at 不可解析;"
  case "${_eq_m1}" in
    ''|*[!0-9]*) _why="${_why}mtime 非整数;" ;;
    *) [[ "${_eq_m1}" -lt "$T0" ]] || _why="${_why}mtime≥T0（本轮自写）;" ;;
  esac
  if [[ -s "$_eq_src" ]]; then
    jq -e '.status == "ok"' "$_eq_src" >/dev/null 2>&1 || _why="${_why}status 非 ok;"
    jq -e '.items | type == "array"' "$_eq_src" >/dev/null 2>&1 || _why="${_why}items 非 array;"
  fi
  if [[ -z "$_why" ]]; then
    _eq_ok=1
    echo "##EQUIV sample1=${_eq_src} sha256=${_eq_sha} mtime=${_eq_m1} generated_at=${_eq_gen}"
  else
    _fail "S3.P3 等价样本" "一号样本不可用: src=${_eq_src} sha256=${_eq_sha} mtime=${_eq_m1} generated_at=${_eq_gen}(epoch=${_eq_e}) 违规:${_why}"
  fi
fi

bash "$SCAN_SH" > "$ART/t9396-realrun-1.out" 2>&1
_rc=$?
_M1="$(stat -f %m "$JSONF" 2>/dev/null || true)"
_S1="$(shasum -a 256 "$JSONF" 2>/dev/null | awk '{print $1}')"
assert_exit 0 "$_rc" "直跑 exit==0（rc=${_rc}，明细: $ART/t9396-realrun-1.out）"
# 「产物非空」收紧：size>0 ∧ mtime 前进 ∧ sha 变更（三条件合取，绑定本轮运行窗口）
if [[ -s "$JSONF" && "${_M1}" != "${_M0}" && "${_S1}" != "${_S0}" ]]; then
  _pass "产物非空: ${JSONF}（本轮重写实证 mtime=[${_M0}→${_M1}] sha256=[${_S0:0:12}→${_S1:0:12}]）"
else
  _fail "S3.P1 产物" "产物缺失/为空/未在本轮重写: ${JSONF}（mtime=[${_M0}→${_M1}] sha256=[${_S0:0:12}→${_S1:0:12}]）"
fi
# 「ok 行落日志」收窄到本轮新增窗口（第 _L0+1 行起；FAILED 行不含该子串，正/负样本可分）
_okwin=""
if [[ -f "$LOGF" ]]; then
  _okwin="$(tail -n +$((_L0 + 1)) "$LOGF" 2>/dev/null || true)"
fi
if [[ "${_okwin}" == *"stale-pr-scan ok"* ]]; then
  _pass "成功 ok 行落日志（§4.4，与 mv 同次运行尾部落笔；本轮窗口=自第 $((_L0 + 1)) 行起）"
else
  _fail "成功 ok 行落日志（§4.4，与 mv 同次运行尾部落笔）" "本轮新增日志行（第 $((_L0 + 1)) 行起）未出现 [stale-pr-scan ok]"
fi

# ---------------- S3.P2 ----------------
t_case "S3.P2 JSON 合法信封+items"
jq -e . "$JSONF" >/dev/null 2>&1 && _pass "jq rc==0（合法 JSON）" || _fail "S3.P2" "JSON 非法"
_gen1="$(jq -r '.generated_at // empty' "$JSONF" 2>/dev/null || true)"
if [[ -n "$_gen1" ]]; then _pass "generated_at string 在场: $_gen1"; else _fail "S3.P2" "generated_at 缺失"; fi
jq -e '.items | type == "array"' "$JSONF" >/dev/null 2>&1 && _pass "items 是 array" || _fail "S3.P2" "items 非 array"

# ---------------- S3.P3 ----------------
t_case "S3.P3 间隔≥2s 复跑：generated_at 严格递增 + mtime 更新（非 fixture 证据）"
# D2 口径 2（opt-in）：间隔秒数可调；非整数/空回落 2（整数语义零变化，缺省 2 = 原行为）
_gap="${T9396_REALRUN_RUN2_GAP_S:-2}"
case "${_gap}" in
  ''|*[!0-9]*) _gap=2 ;;
esac
sleep "${_gap}"
_M1="$(stat -f %m "$JSONF" 2>/dev/null || true)"
bash "$SCAN_SH" > "$ART/t9396-realrun-2.out" 2>&1
_rc=$?
assert_exit 0 "$_rc" "复跑 exit==0"
# 限流归属（≠跳过/≠变绿）：signature 命中于两处通道——run2 输出文件 或 本轮新增日志窗口。
# 09-18 补修轮（陪跑员真跑核验驱动）：真实 403 的 stderr 是 pretty JSON（documentation_url 在前），
# 经产品脚本 first_err 压单行 + 200 字符截断后，message 里的空格形态「secondary rate limit」被截掉
# （真实日志行逐字实测：空格形态 0 命中 / 连字符 1 命中 / rate-limits-for-the-rest-api 1 命中），
# 只剩连字符形态 secondary-rate-limit（藏在 about-secondary-rate-limits）与 URL 片段存活 ⇒
# 判据必须接受两形态 ∨ URL 片段，否则归属行在真实限流下永不出现。匹配位置不变（run2 输出 +
# 本轮新增日志窗口，后者留证 $ART/t9396-realrun-2.logwin），只扩匹配形态。
_rl_re='secondary[- ]rate[- ]limit'
_rl_docfx='rate-limits-for-the-rest-api#about-secondary'
_rl_hit() { # <file> → rc0：命中真实 403 取证任一形态（连字符/空格 ∨ documentation_url 片段）
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -Eq "${_rl_re}" "$f" 2>/dev/null && return 0
  grep -qF "${_rl_docfx}" "$f" 2>/dev/null
}
if [[ "${_rc}" -ne 0 ]]; then
  _sig=0
  tail -n +$((_L0 + 1)) "$LOGF" > "$ART/t9396-realrun-2.logwin" 2>/dev/null || true
  if _rl_hit "$ART/t9396-realrun-2.out" || _rl_hit "$ART/t9396-realrun-2.logwin"; then
    _sig=1
  fi
  if [[ "${_sig}" == "1" ]]; then
    echo "##ENV BLOCKED run2 exit=${_rc} signature=secondary-rate-limit attribution=限流（判据可求值，非判据缺陷）"
  fi
fi
_M2="$(stat -f %m "$JSONF" 2>/dev/null || true)"
_gen2="$(jq -r '.generated_at // empty' "$JSONF" 2>/dev/null || true)"
_S2="$(shasum -a 256 "$JSONF" 2>/dev/null | awk '{print $1}')"
_e1="$(gen_epoch "$_gen1")"
_e2="$(gen_epoch "$_gen2")"
if [[ "${_eq_on}" == "1" ]]; then
  # EQUIV=1 恒打印 sample2（本轮 run1 产物真值；值取 run1 后即时水位，不随 run2 覆盖漂移）
  echo "##EQUIV sample2=${JSONF} sha256=${_S1} mtime=${_M1} generated_at=${_gen1}"
fi
# 样本对选择：EQUIV=1 且一号样本过门 ⇒ sample1↔run1（跨独立真跑）；否则 run1↔run2
if [[ "${_eq_on}" == "1" && "${_eq_ok}" == "1" ]]; then
  _inc_a="${_eq_e}"
  _inc_b="${_e1}"
  _inc_desc="sample1(${_eq_gen}) → run1(${_gen1})"
  _mt_x="${_M1}"
  _mt_y="${_eq_m1}"
  _same_a="${_S1}"
  _same_b="${_eq_sha}"
  _same_who="run1"
else
  _inc_a="${_e1}"
  _inc_b="${_e2}"
  _inc_desc="${_gen1} → ${_gen2}"
  _mt_x="${_M2}"
  _mt_y="${_M1}"
  _same_a="${_S2}"
  _same_b="${_S1}"
  _same_who="run2"
fi
if [[ -n "${_inc_a}" && -n "${_inc_b}" ]]; then
  if [[ "${_inc_b}" -gt "${_inc_a}" ]]; then
    _pass "generated_at 严格递增（${_inc_desc}）"
  else
    if [[ "${_same_a}" == "${_same_b}" && -n "${_same_a}" ]]; then
      _fail "S3.P3 递增" "generated_at 未递增: ${_inc_desc}；本轮 ${_same_who} 未落新产物：产物 sha256 未变更（sha256=${_same_a}）⇒ 两样本同源"
    else
      _fail "S3.P3 递增" "generated_at 未递增: ${_inc_desc}"
    fi
  fi
else
  _fail "S3.P3 解析" "generated_at 无法解析为 epoch（${_inc_desc}）"
fi
assert_ne "${_mt_x}" "${_mt_y}" "产物 mtime 更新（真重写，非 fixture 复制）"
_tc="$(jq -r '.total_count // empty' "$JSONF" 2>/dev/null || true)"
if [[ "${_tc}" =~ ^[0-9]+$ ]]; then
  _pass "复跑 total_count 为整数=${_tc}（同窗可漂移属正常，字段形态稳定）"
else
  _fail "S3.P3 total_count" "非整数: [${_tc}]"
fi

# ---------------- S3.P4 ----------------
t_case "S3.P4 items 形态：空 ∨ 全部 number 正整数且含上游真实字段；generated_at 时窗"
jq -e '.items == [] or ([.items[] | (.number | type == "number" and . > 0)] | all)' "$JSONF" >/dev/null 2>&1 \
  && _pass "items 空 ∨ 全部 number 正整数" || _fail "S3.P4" "items 形态不合规"
jq -e '.items == [] or ([.items[] | has("title") and has("author") and has("url")] | all)' "$JSONF" >/dev/null 2>&1 \
  && _pass "元素含上游真实字段 title/author/url" || _fail "S3.P4" "缺上游真实字段"
_e="$(gen_epoch "$_gen2")"
_now="$(date +%s)"
_lo=$((T0 - 90))
_hi=$((_now + 10))
if [[ -n "$_e" ]] && [[ "$_e" -ge "$_lo" && "$_e" -le "$_hi" ]]; then
  _pass "generated_at ∈ [t0-90s, now+10s]"
else
  _fail "S3.P4 时窗" "generated_at=[$_gen2] epoch=[$_e] 窗口=[$_lo,$_hi]"
fi

t_finish
