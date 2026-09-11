#!/bin/bash
# sync-autopilot-to-zcode.acceptance.test.sh — 同步脚本 sync-autopilot-to-zcode.sh 黑盒验收（红队）
# 依据：设计契约（命令签名 [--check][--help] / env ZCODE_CLI_HOME+PLUGIN_SOURCE_REPO /
#       目标路径四件套 / 退出码 0|1|2 / stdout 必含行 SOURCE_VERSION|TARGET_VERSION|STATUS /
#       源版本真源 = 源仓 plugin.json .version 动态读取，禁硬编码）
# 谓词映射：P1 sync-stale-fix / P2 check-exit / P3 idempotent / P4 shellcheck /
#           P5 real-home-isolation / P6 fresh-install
# 用法：bash scripts/coder/tests/sync-autopilot-to-zcode.acceptance.test.sh
# 环境覆盖：PLUGIN_SOURCE_REPO（默认 $HOME/workspace/string-claude-code-plugin）
# 本测试只表达设计意图，不读取被测脚本实现；一切调用显式 `bash <script>`。
# 退出码：0 = 全绿；1 = 有硬断言失败；shellcheck 缺失 / 真实 ~/.zcode 观测文件缺失 → 计 SKIP
set -u

[[ -n "${BASH_VERSION:-}" ]] || { echo "must run under bash"; exit 2; }

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$(cd "$TEST_DIR/.." && pwd -P)/sync-autopilot-to-zcode.sh"
PLUGIN_SOURCE_REPO="${PLUGIN_SOURCE_REPO:-$HOME/workspace/string-claude-code-plugin}"
SRC_PLUGIN_JSON="$PLUGIN_SOURCE_REPO/plugins/autopilot/.claude-plugin/plugin.json"
SRC_MANIFEST="$PLUGIN_SOURCE_REPO/.claude-plugin/marketplace.json"

# P5 只读观测目标（真实 ~/.zcode 固定路径，不受测试内 ZCODE_CLI_HOME 覆盖影响）
REAL_IP="$HOME/.zcode/cli/plugins/installed_plugins.json"
REAL_KM="$HOME/.zcode/cli/plugins/known_marketplaces.json"

PASS=0
SKIP=0
RESOLVED_ENT_JSON=""

hash256() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- P5 起点观测（测试一开始即取真实 ~/.zcode 哈希，只读） ---
P5_IP_H0=""
P5_KM_H0=""
[[ -f "$REAL_IP" ]] && P5_IP_H0="$(hash256 "$REAL_IP")"
[[ -f "$REAL_KM" ]] && P5_KM_H0="$(hash256 "$REAL_KM")"

p5_end_check() { # 失败路径也复查真实 home；变化仅打印 FAIL 行返回 1（不递归 fail）
  local rc=0
  if [[ -n "$P5_IP_H0" ]]; then
    if [[ ! -f "$REAL_IP" ]]; then
      printf 'FAIL: P5 —— 真实 installed_plugins.json 在测试中途消失\n'
      rc=1
    elif [[ "$(hash256 "$REAL_IP")" != "$P5_IP_H0" ]]; then
      printf 'FAIL: P5 —— 真实 installed_plugins.json 哈希变化（测试写入了真实 ~/.zcode）\n'
      rc=1
    fi
  fi
  if [[ -n "$P5_KM_H0" ]]; then
    if [[ ! -f "$REAL_KM" ]]; then
      printf 'FAIL: P5 —— 真实 known_marketplaces.json 在测试中途消失\n'
      rc=1
    elif [[ "$(hash256 "$REAL_KM")" != "$P5_KM_H0" ]]; then
      printf 'FAIL: P5 —— 真实 known_marketplaces.json 哈希变化（测试写入了真实 ~/.zcode）\n'
      rc=1
    fi
  fi
  return "$rc"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  p5_end_check || true
  printf 'RESULT: PASS=%d FAIL=1 SKIP=%d\n' "$PASS" "$SKIP"
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$1"
}
skip() {
  SKIP=$((SKIP + 1))
  printf 'SKIP: %s\n' "$1"
}
assert_out_contains() { # <Pxx 描述> <haystack stdout> <needle 字面串>
  printf '%s\n' "$2" | grep -Fq "$3" ||
    fail "$1 —— stdout 缺字面行 [$3]，实际输出：
$2"
  ok "$1"
}

# 一切脚本调用显式 bash（防双 shell 二象性）；ZCODE_CLI_HOME 沙箱化
run_sync() { # $1=zcode_home；其余为被测脚本参数；stdout 由调用方捕获
  local zhome="$1"
  shift
  ZCODE_CLI_HOME="$zhome" PLUGIN_SOURCE_REPO="$PLUGIN_SOURCE_REPO" bash "$SCRIPT" "$@"
}

resolve_entity_plugin_json() { # $1=实体目录 → RESOLVED_ENT_JSON；契约路径优先，zcode 实际布局兜底
  local d="$1"
  if [[ -f "$d/plugin.json" ]]; then
    RESOLVED_ENT_JSON="$d/plugin.json"
  elif [[ -f "$d/.claude-plugin/plugin.json" ]]; then
    RESOLVED_ENT_JSON="$d/.claude-plugin/plugin.json"
  else
    return 1
  fi
}

# 临时沙箱：mktemp 模板 X 串在末尾（macOS 硬约束）；trap 清理
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sync-autopilot-acceptance.XXXXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
ZHOME1="$TMP_ROOT/home-stale"
ZHOME2="$TMP_ROOT/home-fresh"

echo "== sync-autopilot-to-zcode 黑盒验收（源仓动态版本） =="

# --- GATE: 前置存在性 + 动态真源（版本/pluginCount 禁硬编码） ---
[[ -f "$SCRIPT" ]] || fail "GATE 被测同步脚本不存在: $SCRIPT"
ok "GATE 被测同步脚本存在: $SCRIPT"
[[ -f "$SRC_PLUGIN_JSON" ]] || fail "GATE 源 plugin.json 不存在: $SRC_PLUGIN_JSON"
SRC_VER="$(jq -r '.version' "$SRC_PLUGIN_JSON")"
[[ -n "$SRC_VER" && "$SRC_VER" != "null" ]] || fail "GATE 源版本不可读: $SRC_PLUGIN_JSON .version=[$SRC_VER]"
ok "GATE 源版本动态读取: $SRC_VER"
[[ -f "$SRC_MANIFEST" ]] || fail "GATE 源仓 manifest 不存在: $SRC_MANIFEST"
PLUGIN_COUNT="$(jq '.plugins | length' "$SRC_MANIFEST")"
[[ "$PLUGIN_COUNT" =~ ^[0-9]+$ ]] || fail "GATE 源 manifest plugins 长度不可读: [$PLUGIN_COUNT]"
ok "GATE 源 manifest pluginCount 期望值动态读取: $PLUGIN_COUNT"
SRC_REPO_ALT="$(cd "$PLUGIN_SOURCE_REPO" 2>/dev/null && pwd -P)" || SRC_REPO_ALT="$PLUGIN_SOURCE_REPO"

# --- P1 fixture: 版本落后假缓存（0.0.9 + 陈旧 marketplace.json + known 注册表） ---
mkdir -p "$ZHOME1/plugins/cache/autopilot/autopilot/0.0.9" "$ZHOME1/plugins/marketplaces/autopilot"
printf 'stale entity placeholder\n' > "$ZHOME1/plugins/cache/autopilot/autopilot/0.0.9/PLACEHOLDER.txt"
cat > "$ZHOME1/plugins/installed_plugins.json" <<EOF
{"plugins":[{"id":"autopilot@autopilot","name":"autopilot","marketplace":"autopilot","version":"0.0.9","installPath":"$ZHOME1/plugins/cache/autopilot/autopilot/0.0.9","installedAt":"2026-01-01T00:00:00.000Z","scope":"user"}]}
EOF
cat > "$ZHOME1/plugins/known_marketplaces.json" <<EOF
{"version":1,"marketplaces":[{"id":"autopilot","name":"autopilot","source":{"source":"directory","path":"$PLUGIN_SOURCE_REPO"},"description":"fixture","addedAt":"2026-01-01T00:00:00.000Z","pluginCount":1,"lastUpdated":"2026-01-01T00:00:00.000Z"}]}
EOF
printf '{"name":"stale"}' > "$ZHOME1/plugins/marketplaces/autopilot/marketplace.json"
fok=1
jq empty "$ZHOME1/plugins/installed_plugins.json" >/dev/null 2>&1 || fok=0
jq empty "$ZHOME1/plugins/known_marketplaces.json" >/dev/null 2>&1 || fok=0
[[ "$fok" -eq 1 ]] || fail "P1 stale fixture JSON 构造非法"
ok "P1 stale fixture 构造完成（0.0.9 假缓存 + pluginCount=1 + 陈旧 marketplace.json）"
ZHOME1_ALT="$(cd "$ZHOME1" 2>/dev/null && pwd -P)" || ZHOME1_ALT="$ZHOME1"

# --- P2a: stale fixture 上 --check → exit 1 + OUT_OF_SYNC + TARGET 0.0.9 ---
chk_out="$(run_sync "$ZHOME1" --check)"
chk_rc=$?
[[ "$chk_rc" -eq 1 ]] || fail "P2 stale --check 退出码期望 1，实际 $chk_rc"
ok "P2 stale --check exit 1（差异=1）"
assert_out_contains "P2 stale --check stdout 含 STATUS: OUT_OF_SYNC" "$chk_out" "STATUS: OUT_OF_SYNC"
assert_out_contains "P2 stale --check stdout 含 TARGET_VERSION: 0.0.9" "$chk_out" "TARGET_VERSION: 0.0.9"
assert_out_contains "P2 stale --check stdout 含 SOURCE_VERSION: $SRC_VER" "$chk_out" "SOURCE_VERSION: $SRC_VER"

# --- P1: 默认同步修复 stale → SYNCED + 四件套全部对齐源仓 ---
sync_out="$(run_sync "$ZHOME1")"
sync_rc=$?
[[ "$sync_rc" -eq 0 ]] || fail "P1 默认同步退出码期望 0，实际 $sync_rc"
ok "P1 默认同步 exit 0"
assert_out_contains "P1 stdout 含 STATUS: SYNCED" "$sync_out" "STATUS: SYNCED"
assert_out_contains "P1 stdout 含 SOURCE_VERSION: $SRC_VER" "$sync_out" "SOURCE_VERSION: $SRC_VER"
printf '%s\n' "$sync_out" | grep -q 'TARGET_VERSION:' ||
  fail "P1 stdout 缺 TARGET_VERSION: 行，实际输出：
$sync_out"
ok "P1 stdout 含 TARGET_VERSION: 行"

ENT_DIR="$ZHOME1/plugins/cache/autopilot/autopilot/$SRC_VER"
[[ -d "$ENT_DIR" ]] || fail "P1 实体目录不存在: $ENT_DIR"
ok "P1 实体目录存在: cache/autopilot/autopilot/$SRC_VER/"
resolve_entity_plugin_json "$ENT_DIR" ||
  fail "P1 实体 plugin.json 缺失（$ENT_DIR/plugin.json 与 .claude-plugin/plugin.json 均不存在）"
ENT_PLUGIN_JSON="$RESOLVED_ENT_JSON"
ok "P1 实体 plugin.json 存在: ${ENT_PLUGIN_JSON#$ZHOME1/}"
ent_ver="$(jq -r '.version' "$ENT_PLUGIN_JSON")"
[[ "$ent_ver" == "$SRC_VER" ]] || fail "P1 实体 plugin.json .version=[$ent_ver] 期望 [$SRC_VER]"
ok "P1 实体 plugin.json .version == 源版本 $SRC_VER"

IP_JSON="$ZHOME1/plugins/installed_plugins.json"
ip_n="$(jq '[.plugins[] | select(.id == "autopilot@autopilot")] | length' "$IP_JSON")"
[[ "$ip_n" == "1" ]] || fail "P1 installed_plugins.json autopilot@autopilot 条目数期望 1，实际 $ip_n"
ok "P1 installed_plugins.json autopilot@autopilot 条目唯一"
ip_ver="$(jq -r '[.plugins[] | select(.id == "autopilot@autopilot")][0].version' "$IP_JSON")"
[[ "$ip_ver" == "$SRC_VER" ]] || fail "P1 installed 版本=[$ip_ver] 期望 [$SRC_VER]"
ok "P1 installed_plugins.json 条目 version == 源版本 $SRC_VER"
ip_path="$(jq -r '[.plugins[] | select(.id == "autopilot@autopilot")][0].installPath' "$IP_JSON")"
exp_a="$ZHOME1/plugins/cache/autopilot/autopilot/$SRC_VER"
exp_b="$ZHOME1_ALT/plugins/cache/autopilot/autopilot/$SRC_VER"
[[ "$ip_path" == "$exp_a" || "$ip_path" == "$exp_b" ]] ||
  fail "P1 installPath=[$ip_path] 期望 [$exp_a]（或 realpath 形态 $exp_b）"
ok "P1 installPath 指向新版本实体目录"

KM_JSON="$ZHOME1/plugins/known_marketplaces.json"
km_n="$(jq '[.marketplaces[] | select(.id == "autopilot")] | length' "$KM_JSON")"
[[ "$km_n" == "1" ]] || fail "P1 known_marketplaces.json id=autopilot 条目数期望 1，实际 $km_n"
ok "P1 known_marketplaces.json autopilot 条目唯一"
km_path="$(jq -r '[.marketplaces[] | select(.id == "autopilot")][0].source.path' "$KM_JSON")"
[[ "$km_path" == "$PLUGIN_SOURCE_REPO" || "$km_path" == "$SRC_REPO_ALT" ]] ||
  fail "P1 known source.path=[$km_path] 期望 [$PLUGIN_SOURCE_REPO]（或 realpath 形态 $SRC_REPO_ALT）"
ok "P1 known_marketplaces.json source.path == 源仓"
km_pc="$(jq '[.marketplaces[] | select(.id == "autopilot")][0].pluginCount' "$KM_JSON")"
[[ "$km_pc" == "$PLUGIN_COUNT" ]] || fail "P1 known pluginCount=[$km_pc] 期望 [$PLUGIN_COUNT]（源 manifest plugins 长度）"
ok "P1 known_marketplaces.json pluginCount == 源 manifest plugins 长度 $PLUGIN_COUNT"

TGT_MANIFEST="$ZHOME1/plugins/marketplaces/autopilot/marketplace.json"
cmp -s "$TGT_MANIFEST" "$SRC_MANIFEST" ||
  fail "P1 marketplaces/autopilot/marketplace.json 与源仓 manifest 不逐字节一致（cmp -s 失败）"
ok "P1 marketplace.json 与源仓 manifest 逐字节一致（cmp -s）"

for jf in "$ENT_PLUGIN_JSON:$SRC_VER 实体" "$TGT_MANIFEST:manifest" "$KM_JSON:known_marketplaces" "$IP_JSON:installed_plugins"; do
  f="${jf%%:*}"
  label="${jf#*:}"
  jq empty "$f" >/dev/null 2>&1 || fail "P1 目标 JSON 结构非法（jq empty 失败）: $label — $f"
  ok "P1 目标 JSON jq empty 通过: $label"
done

# --- P2b: P1 同步完成后 --check → exit 0 + IN_SYNC ---
chk2_out="$(run_sync "$ZHOME1" --check)"
chk2_rc=$?
[[ "$chk2_rc" -eq 0 ]] || fail "P2 同步后 --check 退出码期望 0，实际 $chk2_rc"
ok "P2 同步后 --check exit 0"
assert_out_contains "P2 同步后 --check stdout 含 STATUS: IN_SYNC" "$chk2_out" "STATUS: IN_SYNC"

# --- P3: 幂等 —— 二次默认同步 UP_TO_DATE + 四文件哈希不变 + --check 仍 0 ---
H1_MAN="$(hash256 "$TGT_MANIFEST")"
H1_IP="$(hash256 "$IP_JSON")"
H1_KM="$(hash256 "$KM_JSON")"
[[ -f "$ENT_PLUGIN_JSON" ]] || fail "P3 首跑后实体 plugin.json 不存在: $ENT_PLUGIN_JSON"
H1_ENT="$(hash256 "$ENT_PLUGIN_JSON")"
ok "P3 首跑后四目标文件哈希已记录（manifest+双注册表+实体 plugin.json）"
sync2_out="$(run_sync "$ZHOME1")"
sync2_rc=$?
[[ "$sync2_rc" -eq 0 ]] || fail "P3 第二次默认同步退出码期望 0，实际 $sync2_rc"
ok "P3 第二次默认同步 exit 0"
assert_out_contains "P3 第二次同步 stdout 含 STATUS: UP_TO_DATE" "$sync2_out" "STATUS: UP_TO_DATE"
[[ "$(hash256 "$TGT_MANIFEST")" == "$H1_MAN" ]] || fail "P3 manifest 哈希在二次同步后变化（不幂等）"
ok "P3 manifest 哈希前后一致"
[[ "$(hash256 "$IP_JSON")" == "$H1_IP" ]] || fail "P3 installed_plugins.json 哈希在二次同步后变化（不幂等）"
ok "P3 installed_plugins.json 哈希前后一致"
[[ "$(hash256 "$KM_JSON")" == "$H1_KM" ]] || fail "P3 known_marketplaces.json 哈希在二次同步后变化（不幂等）"
ok "P3 known_marketplaces.json 哈希前后一致"
[[ -f "$ENT_PLUGIN_JSON" ]] || fail "P3 实体 plugin.json 在第二次同步后消失"
[[ "$(hash256 "$ENT_PLUGIN_JSON")" == "$H1_ENT" ]] || fail "P3 实体 plugin.json 哈希在二次同步后变化（不幂等）"
ok "P3 实体 plugin.json 哈希前后一致"
chk3_rc=0
run_sync "$ZHOME1" --check >/dev/null || chk3_rc=$?
[[ "$chk3_rc" -eq 0 ]] || fail "P3 幂等后 --check 退出码期望 0，实际 $chk3_rc"
ok "P3 幂等后再跑 --check 仍 exit 0"

# --- P4: shellcheck -S warning 零告警零输出（不在 PATH 计 SKIP） ---
if command -v shellcheck >/dev/null 2>&1; then
  sc_out="$(shellcheck -S warning "$SCRIPT" 2>&1)"
  sc_rc=$?
  [[ "$sc_rc" -eq 0 ]] || fail "P4 shellcheck -S warning 退出码 $sc_rc，输出：
$sc_out"
  [[ -z "$sc_out" ]] || fail "P4 shellcheck 有输出：
$sc_out"
  ok "P4 shellcheck -S warning 零告警零输出"
else
  skip "P4 shellcheck 不在 PATH — 跳过（不 FAIL）"
fi

# --- P6: 全新空 ZCODE_CLI_HOME → 默认同步 SYNCED + --check 0 + 四件套齐备 ---
mkdir -p "$ZHOME2/plugins"
f_out="$(run_sync "$ZHOME2")"
f_rc=$?
[[ "$f_rc" -eq 0 ]] || fail "P6 全新安装默认同步退出码期望 0，实际 $f_rc"
ok "P6 全新安装默认同步 exit 0"
assert_out_contains "P6 stdout 含 STATUS: SYNCED" "$f_out" "STATUS: SYNCED"
assert_out_contains "P6 stdout 含 SOURCE_VERSION: $SRC_VER" "$f_out" "SOURCE_VERSION: $SRC_VER"
printf '%s\n' "$f_out" | grep -q 'TARGET_VERSION:' ||
  fail "P6 stdout 缺 TARGET_VERSION: 行，实际输出：
$f_out"
ok "P6 stdout 含 TARGET_VERSION: 行"
fchk_rc=0
run_sync "$ZHOME2" --check >/dev/null || fchk_rc=$?
[[ "$fchk_rc" -eq 0 ]] || fail "P6 全新安装后 --check 退出码期望 0，实际 $fchk_rc"
ok "P6 全新安装后 --check exit 0"

F_IP="$ZHOME2/plugins/installed_plugins.json"
F_KM="$ZHOME2/plugins/known_marketplaces.json"
F_MAN="$ZHOME2/plugins/marketplaces/autopilot/marketplace.json"
F_ENT_DIR="$ZHOME2/plugins/cache/autopilot/autopilot/$SRC_VER"
resolve_entity_plugin_json "$F_ENT_DIR" ||
  fail "P6 实体 plugin.json 缺失（$F_ENT_DIR/plugin.json 与 .claude-plugin/plugin.json 均不存在）"
F_ENT="$RESOLVED_ENT_JSON"
for jf in "$F_ENT:实体 plugin.json" "$F_MAN:manifest" "$F_KM:known_marketplaces" "$F_IP:installed_plugins"; do
  f="${jf%%:*}"
  label="${jf#*:}"
  [[ -f "$f" ]] || fail "P6 四件套缺失: $label — $f"
  ok "P6 四件套齐备: $label"
done
for jf in "$F_ENT:实体 plugin.json" "$F_MAN:manifest" "$F_KM:known_marketplaces" "$F_IP:installed_plugins"; do
  f="${jf%%:*}"
  label="${jf#*:}"
  jq empty "$f" >/dev/null 2>&1 || fail "P6 目标 JSON 结构非法（jq empty 失败）: $label — $f"
  ok "P6 目标 JSON jq empty 通过: $label"
done

# --- P5 收口: 真实 ~/.zcode 哈希前后一致（只读观测，全程未写真实 home） ---
if [[ -n "$P5_IP_H0" ]]; then
  [[ -f "$REAL_IP" ]] || fail "P5 真实 installed_plugins.json 在测试中途消失"
  [[ "$(hash256 "$REAL_IP")" == "$P5_IP_H0" ]] || fail "P5 真实 installed_plugins.json 哈希前后不一致（测试写入了真实 ~/.zcode）"
  ok "P5 真实 installed_plugins.json 哈希前后一致（未被写）"
else
  skip "P5 真实 installed_plugins.json 不存在 — 观测跳过"
fi
if [[ -n "$P5_KM_H0" ]]; then
  [[ -f "$REAL_KM" ]] || fail "P5 真实 known_marketplaces.json 在测试中途消失"
  [[ "$(hash256 "$REAL_KM")" == "$P5_KM_H0" ]] || fail "P5 真实 known_marketplaces.json 哈希前后不一致（测试写入了真实 ~/.zcode）"
  ok "P5 真实 known_marketplaces.json 哈希前后一致（未被写）"
else
  skip "P5 真实 known_marketplaces.json 不存在 — 观测跳过"
fi

printf 'RESULT: PASS=%d FAIL=0 SKIP=%d\n' "$PASS" "$SKIP"
exit 0
