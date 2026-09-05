#!/bin/bash
# contract-drift.sh — Tier S：对外 API 契约漂移守卫（场景11.P1）
# 断言两个 SKILL.md（hermes 侧 contrib-l2 + martin 侧 contrib-watch）引用的
# rq.sh / notify.sh 子命令 ⊆ 被测脚本 case 分支实现集合。删名/改名 = FAIL。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
MARTIN_REPO="$(cd "$TESTS_ROOT/../../.." && pwd)"
export DIM=static

source "$TESTS_ROOT/lib/assert.sh"
TARGET="$(tests_scripts_dir "$TARGET_DEFAULT")"
t_init "contract-drift.sh"

RQ_SCRIPT="$TARGET/rq.sh"
NOTIFY_SCRIPT="$TARGET/notify.sh"
SKILL_HERMES="${HOME:-$MARTIN_REPO}/.hermes/skills/github/hermes-contrib-l2/SKILL.md"
SKILL_MARTIN="$MARTIN_REPO/.claude/skills/contrib-watch/SKILL.md"

# --- 从被测脚本提取 case 分支实现集合 ---
dispatch_labels() { # <script> → case "$cmd" in 顶层分支标签
  sed -n '/^case "\$cmd" in/,/^esac/p' "$1" \
    | grep -E '^  [a-z|-]+\)' | sed 's/^[[:space:]]*//; s/).*//' | tr '|' '\n' | sort -u
}

budget_labels() { # <script> → cmd_budget 内 reserve/refund/check/status 子分支
  sed -n '/^cmd_budget()/,/^}/p' "$1" \
    | grep -E '^    [a-z|-]+\)' | sed 's/^[[:space:]]*//; s/).*//' | sort -u
}

rq_labels="$(dispatch_labels "$RQ_SCRIPT")
$(budget_labels "$RQ_SCRIPT")"
notify_labels="$(dispatch_labels "$NOTIFY_SCRIPT")"

t_case "被测脚本 case 分支集合非空"
if [[ -n "$rq_labels" && -n "$notify_labels" ]]; then
  _pass "rq.sh $(printf '%s ' $rq_labels)| notify.sh $(printf '%s ' $notify_labels)"
else
  _fail "case 分支集合" "rq_labels=[${rq_labels:-空}] notify_labels=[${notify_labels:-空}]"
fi

# --- 从 SKILL.md 提取引用的子命令 ---
refs_of() { # <file> → 引用的 "rq.sh X" / "notify.sh X" 子命令（去重）
  grep -oE '(rq|notify)\.sh [a-z-]+' "$1" 2>/dev/null | awk '{print $2}' | sort -u
}
budget_refs_of() { # <file> → budget 子命令引用
  grep -oE 'rq\.sh budget [a-z-]+' "$1" 2>/dev/null | awk '{print $3}' | sort -u
}

check_refs() { # <skill 文件> — 引用子命令必须 ⊆ 实现 case 分支集合
  local file="$1" src
  src="$(basename "$(dirname "$file")")"
  local missing=0 ref
  for ref in $(refs_of "$file"); do
    if [[ "$ref" == "budget" ]]; then
      continue # budget 子命令单独核
    fi
    if printf '%s\n%s' "$rq_labels" "$notify_labels" | grep -qx "$ref"; then
      _pass "ref [$ref] from $src"
    else
      _fail "ref [$ref] 无实现" "$src 引用 rq.sh/notify.sh [$ref]，但被测脚本无此 case 分支（对外 API 漂移）"
      missing=1
    fi
  done
  for ref in $(budget_refs_of "$file"); do
    if printf '%s' "$rq_labels" | grep -qx "$ref"; then
      _pass "ref [budget $ref] from $src"
    else
      _fail "ref [budget $ref] 无实现" "$src 引用 rq.sh budget [$ref]，但被测脚本无此子分支（对外 API 漂移）"
      missing=1
    fi
  done
  return $missing
}

t_case "hermes 侧 SKILL.md（contrib-l2，微信审批环）引用 ⊆ 实现"
if [[ -f "$SKILL_HERMES" ]]; then
  check_refs "$SKILL_HERMES"
else
  t_skip "hermes 侧 SKILL.md 不在默认位置（${SKILL_HERMES}）"
fi

t_case "martin 侧 SKILL.md（contrib-watch skill）引用 ⊆ 实现"
if [[ -f "$SKILL_MARTIN" ]]; then
  check_refs "$SKILL_MARTIN"
else
  _fail "SKILL.md 缺失" "$SKILL_MARTIN"
fi

t_case "scan_gate.sh --drain / scan_gate 入口引用存在"
if grep -qF -- '--drain' "$TARGET/scan_gate.sh"; then
  _pass "scan_gate --drain 实现"
else
  _fail "scan_gate --drain" "SKILL.md 引用的手动兜底入口缺失"
fi

t_finish
