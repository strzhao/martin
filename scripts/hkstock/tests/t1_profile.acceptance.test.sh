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
  python3 - "$1" "$2" <<PYEOF
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

# --- EXTRA（2026-09-08 auto-fix 强化，qa-reviewer Important 缺口）：逐字守卫 ---
# EXTRA-desc-verbatim: profile.yaml description 与契约逐字一致（decomposer 路由信号，防 clone/update 漂移）
DESC_EXPECT='理财专家：A股/港股/基金/期货的盘前简报、持仓问答与结构化市场信号。只做信息与信号，不做任何交易执行。'
desc_file="$PROFILE_DIR/profile.yaml"
if [[ ! -f "$desc_file" ]]; then
  fail "EXTRA-desc-verbatim" "profile.yaml 不存在"
else
  desc_got="$(python3 -c "import yaml;print((yaml.safe_load(open('$desc_file',encoding='utf-8')) or {}).get('description',''))" 2>/dev/null)"
  if [[ "$desc_got" == "$DESC_EXPECT" ]]; then
    pass "EXTRA-desc-verbatim"
  else
    fail "EXTRA-desc-verbatim" "description 与契约不一致: got=${desc_got:0:80}"
  fi
fi

# EXTRA-honcho-verbatim: honcho.json 四键逐字（clone_honcho 静默失效 bug 的显式规避件）
HONCHO_JSON="$PROFILE_DIR/honcho.json"
if [[ ! -f "$HONCHO_JSON" ]]; then
  fail "EXTRA-honcho-verbatim" "honcho.json 不存在（clone_honcho bug 规避件缺失）"
else
  if pyjson_ok="$(python3 -c "
import json
d=json.load(open('$HONCHO_JSON',encoding='utf-8'))
assert d.get('enabled') is True and d.get('baseUrl')=='http://127.0.0.1:8000' and d.get('workspace')=='hermes' and d.get('aiPeer')=='hkstock'
print('ok')" 2>&1)" && [[ "$pyjson_ok" == "ok" ]]; then
    pass "EXTRA-honcho-verbatim"
  else
    fail "EXTRA-honcho-verbatim" "honcho.json 四键与契约不一致: ${pyjson_ok:0:120}"
  fi
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
