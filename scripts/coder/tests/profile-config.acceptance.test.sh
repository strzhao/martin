#!/bin/bash
# profile-config.acceptance.test.sh — coder profile 配置契约 + hermes CLI 生效验证（红队验收）
# 依据：设计文档「配置契约」+「生效验证（hermes CLI 实态）」+ profile 四件套文件存在性
# 用法：bash profile-config.acceptance.test.sh
# 环境覆盖：HERMES_HOME（默认 ~/.hermes，供 fixture/沙箱复跑）
# 退出码：0 = 全绿；1 = 有硬断言失败；hermes CLI 类检查失败仅计 SKIP（设计规则 6）
set -u

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
PROFILE_DIR="$HERMES_ROOT/profiles/coder"
CODER_CONFIG="$PROFILE_DIR/config.yaml"
GLOBAL_CONFIG="$HERMES_ROOT/config.yaml"
DELEGATE_SKILL="$HERMES_ROOT/skills/coder-delegate/SKILL.md"

PASS=0
SKIP=0

fail() {
  printf 'FAIL: %s\n' "$1"
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
assert_file() { # <path> <契约点>
  [[ -f "$1" ]] || fail "$2 —— 文件不存在: $1"
  ok "$2"
}

echo "== coder profile 配置契约验收 =="

# --- C1: profile 四件套文件存在性 ---
if [[ -d "$PROFILE_DIR" ]]; then
  ok "profile 目录存在: $PROFILE_DIR"
else
  fail "profile 目录不存在: $PROFILE_DIR"
fi
assert_file "$CODER_CONFIG" "profiles/coder/config.yaml 存在"
assert_file "$PROFILE_DIR/SOUL.md" "profiles/coder/SOUL.md 存在"
assert_file "$PROFILE_DIR/profile.yaml" "profiles/coder/profile.yaml 存在"
assert_file "$PROFILE_DIR/skills/claude-run/SKILL.md" "profiles/coder/skills/claude-run/SKILL.md 存在"

# --- C2: coder-delegate SKILL 存在 + frontmatter name ---
assert_file "$DELEGATE_SKILL" "skills/coder-delegate/SKILL.md 存在"
head -n 10 "$DELEGATE_SKILL" | grep -qE '^name:[[:space:]]*coder-delegate[[:space:]]*$' ||
  fail "coder-delegate SKILL frontmatter 缺 'name: coder-delegate'（前 10 行）"
ok "coder-delegate SKILL frontmatter 含 name: coder-delegate"

# --- C3: coder config.yaml — toolsets 恰为 [hermes-cli, kanban, terminal] ---
cfg="$(cat "$CODER_CONFIG")"
ts_line="$(printf '%s\n' "$cfg" | grep -E '^[[:space:]]*toolsets:' | head -n 1)"
[[ -n "$ts_line" ]] || fail "coder config.yaml 缺 toolsets 键"
if [[ "$ts_line" == *'['* ]]; then
  items="${ts_line#*\[}"
  items="${items%%\]*}"
  norm="$(printf '%s' "$items" | tr ',' '\n' | tr -d ' "' | sort | tr '\n' ' ')"
else
  norm="$(printf '%s\n' "$cfg" | awk '
    /^[[:space:]]*toolsets:/ { inblk = 1; next }
    inblk && /^[[:space:]]*-/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/[[:space:]]/, "")
      gsub(/"/, "")
      print
      next
    }
    inblk && /^[[:space:]]*[^[:space:]#-]/ { inblk = 0 }
  ' | sort | tr '\n' ' ')"
fi
[[ "$norm" == "hermes-cli kanban terminal " ]] ||
  fail "toolsets 恰为 [hermes-cli, kanban, terminal]，实际归一化结果: [$norm]"
ok "toolsets 恰为 [hermes-cli, kanban, terminal]"

# --- C4: agent.max_turns >= 120（真实数值比较） ---
max_turns="$(printf '%s\n' "$cfg" | grep -E '^[[:space:]]*max_turns:' | head -n 1 | grep -oE '[0-9]+')"
[[ -n "$max_turns" ]] || fail "coder config.yaml 缺 max_turns 数值"
[[ "$max_turns" -ge 120 ]] || fail "agent.max_turns=${max_turns}，要求 >= 120"
ok "agent.max_turns=$max_turns >= 120"

# --- C5: model.default 非空 ---
model_default="$(printf '%s\n' "$cfg" | awk '
  /^model:$/ { f = 1; next }
  f && /^[^[:space:]#]/ { exit }
  f && /^[[:space:]]+default:/ {
    sub(/^[[:space:]]*default:[[:space:]]*/, "")
    gsub(/"/, "")
    print
    exit
  }
')"
[[ -n "$model_default" ]] || fail "model.default 为空或缺失（要求非空）"
ok "model.default 非空: $model_default"

# --- C6: 全局 config kanban.max_in_progress == 3 ---
[[ -f "$GLOBAL_CONFIG" ]] || fail "全局配置缺失: $GLOBAL_CONFIG"
kanban_sec="$(awk '/^kanban:/{f = 1; next} f && /^[^[:space:]#]/{exit} f {print}' "$GLOBAL_CONFIG")"
[[ -n "$kanban_sec" ]] || fail "全局 config.yaml 缺 kanban: 段"
mip="$(printf '%s\n' "$kanban_sec" | grep -E '^[[:space:]]*max_in_progress:' | head -n 1 | grep -oE '[0-9]+')"
[[ -n "$mip" ]] || fail "kanban 段缺 max_in_progress"
[[ "$mip" -eq 3 ]] || fail "kanban.max_in_progress=${mip}，要求 == 3"
ok "kanban.max_in_progress == 3"

# --- C7: kanban.max_in_progress_per_profile == 1（单个 int，全局每-profile 上限）---
# ⚠️ 运行时实证（09-08）：gateway/kanban_watchers.py:1391 对此键做 int() 校验，
# 字典形态会被拒绝 ignoring——契约不得写成 {coder: 1} 形态。
pp="$(printf '%s\n' "$kanban_sec" | grep -E '^[[:space:]]*max_in_progress_per_profile:' | head -n 1 | sed -E 's/.*max_in_progress_per_profile:[[:space:]]*//' | tr -d '"')"
[[ -n "$pp" ]] || fail "kanban 段缺 max_in_progress_per_profile"
[[ "$pp" =~ ^[0-9]+$ ]] || fail "max_in_progress_per_profile=[$pp]，要求单个 int（字典形态运行时不接受）"
[[ "$pp" -eq 1 ]] || fail "max_in_progress_per_profile=${pp}，要求 == 1"
ok "max_in_progress_per_profile == 1（int，每 profile 串行）"

# --- C8: kanban.auto_decompose 保持 false ---
ad="$(printf '%s\n' "$kanban_sec" | grep -E '^[[:space:]]*auto_decompose:' | head -n 1 | sed -E 's/.*auto_decompose:[[:space:]]*//' | tr -d '"')"
[[ "$ad" == "false" ]] || fail "kanban.auto_decompose=[$ad]，要求保持 false"
ok "kanban.auto_decompose == false"

# --- 生效验证（hermes CLI 实态；命令失败 → SKIP 非致命） ---
if command -v hermes >/dev/null 2>&1; then
  out="$(hermes profile list 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    skip "hermes profile list 失败(rc=$rc) — 生效验证跳过"
  else
    printf '%s\n' "$out" | grep -qw coder ||
      fail "hermes profile list 输出不含 coder（实态）: $out"
    ok "hermes profile list 含 coder"
  fi

  out="$(hermes config get kanban 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    skip "hermes config get kanban 失败(rc=$rc) — 生效验证跳过"
  else
    printf '%s\n' "$out" | grep -Eq 'max_in_progress:[[:space:]]*3([^0-9]|$)' ||
      fail "hermes config get kanban 未体现 max_in_progress: 3"
    ok "hermes config get kanban 体现 max_in_progress: 3"
    printf '%s\n' "$out" | grep -Eq 'max_in_progress_per_profile:[[:space:]]*1$' ||
      fail "hermes config get kanban 未体现 max_in_progress_per_profile: 1"
    ok "hermes config get kanban 体现 max_in_progress_per_profile: 1"
  fi
else
  skip "hermes 不在 PATH — 生效验证（profile list / config get）跳过"
fi

printf 'RESULT: PASS=%d FAIL=0 SKIP=%d\n' "$PASS" "$SKIP"
exit 0
