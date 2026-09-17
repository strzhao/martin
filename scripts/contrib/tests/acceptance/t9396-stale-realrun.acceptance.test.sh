#!/usr/bin/env bash
# =============================================================================
# t9396-stale-realrun.acceptance.test.sh — 卡 t_9396bbf3 红队验收（文件 5/5）
#   S3 真跑真数据（产物3 数据面验收②）：S3.P1 直跑 exit==0 + 产物非空 /
#   S3.P2 信封合法 / S3.P3 复跑 generated_at 严格递增 + mtime 更新（非 fixture 证据）/
#   S3.P4 items 形态 + generated_at 时窗。
# 【设计声明的降级出口】S3.P1 自带条款：「本环境 gh 网络若被会话权限拦截 → 显式失败出口，
#   交陪跑员复跑（BRIEFING §6 要求其独立复跑）」。本会话权限禁真网络 ⇒ 默认路径显式
#   deferred（t_skip + ##REALRUN 标记，绝不静默绿）；陪跑员/QA 复跑：
#     STALE_ACCEPTANCE_REAL_RUN=1 bash scripts/contrib/tests/acceptance/t9396-stale-realrun.acceptance.test.sh
#   可选 T9396_REALRUN_CONTRIB=<dir> 把产物重定向到指定 contrib 目录（缺省按 SSOT 落
#   $HOME/workspace/martin/contrib-data/ 生产位，即验收②的字面口径）。
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

t_case "env 前置：gh 在位 + 被测脚本在位"
command -v gh >/dev/null 2>&1 && _pass "gh CLI 在位（$(command -v gh)）" || _fail "env" "gh 不可用——真跑无法执行"
[[ -f "$SCAN_SH" ]] && _pass "被测脚本在位" || _fail "env" "缺失: ${SCAN_SH}（真跑面无法求值）"
mkdir -p "$CONTRIB_DIR/logs" 2>/dev/null || true

gen_epoch() { # <generated_at 字符串> → epoch；不可解析输出空
  local e
  e="$(printf '%s' "$1" | jq -r 'try fromdateiso8601 catch empty' 2>/dev/null || true)"
  if [[ -z "$e" || "$e" == "null" ]]; then
    e="$(printf '%s' "${1:0:19}" | jq -r 'strptime("%Y-%m-%dT%H:%M:%S") | mktime' 2>/dev/null || true)"
  fi
  printf '%s' "$e"
}

# ---------------- S3.P1 ----------------
t_case "S3.P1 直跑真 gh：exit==0 ∧ stale-pr-scan.json size>0（artifact 留 stdout/stderr）"
T0="$(date +%s)"
bash "$SCAN_SH" > "$ART/t9396-realrun-1.out" 2>&1
_rc=$?
assert_exit 0 "$_rc" "直跑 exit==0（rc=${_rc}，明细: $ART/t9396-realrun-1.out）"
[[ -s "$JSONF" ]] && _pass "产物非空: $JSONF" || _fail "S3.P1 产物" "JSON 缺失或为空: $JSONF"
assert_file_contains "$LOGF" "stale-pr-scan ok" "成功 ok 行落日志（§4.4，与 mv 同次运行尾部落笔）"

# ---------------- S3.P2 ----------------
t_case "S3.P2 JSON 合法信封+items"
jq -e . "$JSONF" >/dev/null 2>&1 && _pass "jq rc==0（合法 JSON）" || _fail "S3.P2" "JSON 非法"
_gen1="$(jq -r '.generated_at // empty' "$JSONF" 2>/dev/null || true)"
if [[ -n "$_gen1" ]]; then _pass "generated_at string 在场: $_gen1"; else _fail "S3.P2" "generated_at 缺失"; fi
jq -e '.items | type == "array"' "$JSONF" >/dev/null 2>&1 && _pass "items 是 array" || _fail "S3.P2" "items 非 array"

# ---------------- S3.P3 ----------------
t_case "S3.P3 间隔≥2s 复跑：generated_at 严格递增 ∧ mtime 更新（非 fixture 证据）"
sleep 2
_M1="$(stat -f %m "$JSONF" 2>/dev/null || true)"
bash "$SCAN_SH" > "$ART/t9396-realrun-2.out" 2>&1
_rc=$?
assert_exit 0 "$_rc" "复跑 exit==0"
_M2="$(stat -f %m "$JSONF" 2>/dev/null || true)"
_gen2="$(jq -r '.generated_at // empty' "$JSONF" 2>/dev/null || true)"
_e1="$(gen_epoch "$_gen1")"
_e2="$(gen_epoch "$_gen2")"
if [[ -n "$_e1" && -n "$_e2" ]]; then
  if [[ "$_e2" -gt "$_e1" ]]; then
    _pass "generated_at 严格递增（${_gen1} → ${_gen2}）"
  else
    _fail "S3.P3 递增" "generated_at 未递增: $_gen1 → $_gen2"
  fi
else
  # CONTRACT_AMBIGUOUS: generated_at 时区/格式设计未声明；两种解析皆失败才判红
  _fail "S3.P3 解析" "generated_at 无法解析为 epoch（$_gen1 → ${_gen2}；时区格式待 design 补声明）"
fi
assert_ne "$_M2" "$_M1" "产物 mtime 更新（真重写，非 fixture 复制）"
_tc="$(jq -r '.total_count // empty' "$JSONF" 2>/dev/null || true)"
if [[ "$_tc" =~ ^[0-9]+$ ]]; then
  _pass "复跑 total_count 为整数=${_tc}（同窗可漂移属正常，字段形态稳定）"
else
  _fail "S3.P3 total_count" "非整数: [$_tc]"
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
