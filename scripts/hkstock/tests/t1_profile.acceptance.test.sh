#!/bin/bash
# t1_profile.acceptance.test.sh — hkstock profile 五件套契约验收（红队，黑盒）
# 覆盖谓词：1.P1 / 1.P2 / 1.P3 / 1.P4
# 依据：设计文档「profile 契约」：
#   - ~/.hermes/profiles/hkstock/ 存在；hermes profile list 含 hkstock
#   - config.yaml 可被 yaml.safe_load 且 model 配置非空
#   - SOUL.md 含「理财」/hkstock 且不含「生活助理」「大众点评」（clone 残留检测）
#   - toolsets 含 terminal
# 用法：bash t1_profile.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
PROFILE_DIR="$HERMES_ROOT/profiles/hkstock"
CONFIG_YAML="$PROFILE_DIR/config.yaml"
SOUL_MD="$PROFILE_DIR/SOUL.md"

# 解析 hermes 可执行文件（PATH 优先，回落标准安装路径）
HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
[[ -z "$HERMES_BIN" && -x "$HOME/.local/bin/hermes" ]] && HERMES_BIN="$HOME/.local/bin/hermes"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

# python3 + PyYAML 内联断言（环境依赖，见 context.md「测试命令」约定）
pyyaml() { # <yaml-path> <python-expression-on-'data'>
  python3 - "$1" <<PYEOF
import sys, yaml
try:
    data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("PARSE_ERROR:", e)
    sys.exit(3)
result = eval(sys.argv[2])
sys.exit(0 if result else 1)
PYEOF
}

echo "== t1_profile: hkstock profile 契约验收 =="

# --- 前置：profile 目录存在 ---
[[ -d "$PROFILE_DIR" ]] || { fail "PRE" "profile 目录不存在: $PROFILE_DIR"; printf 'RESULT: FAIL=1\n'; exit 1; }

# --- 1.P1: hermes profile list contains hkstock ---
if [[ -n "$HERMES_BIN" ]]; then
  p1_out="$("$HERMES_BIN" profile list 2>&1)"
  p1_rc=$?
  if [[ $p1_rc -ne 0 ]]; then
    fail "1.P1" "hermes profile list 退出码 $p1_rc，输出: ${p1_out:0:300}"
  elif printf '%s' "$p1_out" | grep -q 'hkstock'; then
    pass "1.P1"
  else
    fail "1.P1" "hermes profile list 输出不含 hkstock: ${p1_out:0:300}"
  fi
else
  fail "1.P1" "hermes CLI 不可用（PATH 与 ~/.local/bin/hermes 均未找到）"
fi

# --- 1.P2: config.yaml 存在 ∧ 可被 yaml.safe_load ∧ model 配置非空 ---
if [[ ! -f "$CONFIG_YAML" ]]; then
  fail "1.P2" "config.yaml 不存在: $CONFIG_YAML"
else
  if pyyaml "$CONFIG_YAML" "data is not None"; then
    :
  else
    fail "1.P2" "config.yaml 无法被 yaml.safe_load 解析"
  fi
  if pyyaml "$CONFIG_YAML" "data.get('model') not in (None, '', {}, [])"; then
    pass "1.P2"
  else
    fail "1.P2" "config.yaml 的 model 配置为空或缺失"
  fi
fi

# --- 1.P3: SOUL.md 含「理财」或 hkstock ∧ 不含「生活助理」∧ 不含「大众点评」 ---
if [[ ! -f "$SOUL_MD" ]]; then
  fail "1.P3" "SOUL.md 不存在: $SOUL_MD"
else
  soul="$(cat "$SOUL_MD")"
  if printf '%s' "$soul" | grep -q '理财' || printf '%s' "$soul" | grep -q 'hkstock'; then
    :
  else
    fail "1.P3" "SOUL.md 既不含「理财」也不含 hkstock"
  fi
  if printf '%s' "$soul" | grep -q '生活助理'; then
    fail "1.P3" "SOUL.md 含 clone 残留「生活助理」"
  fi
  if printf '%s' "$soul" | grep -q '大众点评'; then
    fail "1.P3" "SOUL.md 含 clone 残留「大众点评」"
  fi
  if [[ $FAIL_COUNT -eq 0 ]]; then
    pass "1.P3"
  fi
fi

# --- 1.P4: config.yaml toolsets 含 terminal ---
if [[ ! -f "$CONFIG_YAML" ]]; then
  fail "1.P4" "config.yaml 不存在，无法检查 toolsets"
else
  if pyyaml "$CONFIG_YAML" "'terminal' in (data.get('toolsets') or [])"; then
    pass "1.P4"
  else
    fail "1.P4" "config.yaml toolsets 不含 terminal"
  fi
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
