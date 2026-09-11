#!/usr/bin/env bash
# =============================================================================
# t6-03-gateway-sentinel.acceptance.test.sh — T6 验收③：gateway 存活哨兵
#   G1  唯一告警信号 = pgrep -f "hermes.*gateway run" 进程死亡（重审 BLOCKER 钉死语义）：
#       pgrep 死 → event（class=pipeline-failure，--key <date>-gateway-down 日级幂等）。
#       「双失败 AND」旧语义突变（kanban list 探活选型错误已删）在本用例必红——探活健康
#       不许否决 pgrep 死亡信号
#   G2  反向钉死：pgrep 活 + hermes 诊断失败 → 零告警（hermes 失败不是信号源）
#   G3  活 → 零动作：零 event + contrib-data 树指纹不变
#   G4  探活异常（pgrep rc>=2）→ 只日志不告警（单语义钉死：探活不参与告警判定）+
#       contrib-data 树指纹不变（契约 3「探测脚本自身零写操作（除 notify event）」严格口径）
#   G5  幂等：同日重复触发同 key 仍恰 1 条 event
#   G6  plist 结构断言：文件存在（恰 1 份）+ plutil -lint 过 + StartInterval=900 +
#       AbandonProcessGroup=true + Label + program 要素（解释器+脚本）；不装载（人工步骤，
#       本测试零 launchctl 断言）
#   G7  隔离：真实仓 events.jsonl 字节数在死→event 用例窗口前后不变（最佳努力）
# 依据：state.md「## 设计文档」§3 + 契约规约 3「哨兵契约：pgrep 进程死 → event（唯一告警
#   信号）；探活/诊断异常 → 只日志不告警；event --key <date>-gateway-down 日级幂等；plist
#   不装载；探测脚本自身零写操作（除 notify event）」+ plist「StartInterval 900 +
#   AbandonProcessGroup=true + plutil -lint 验证入验收」
# CONTRACT_AMBIGUOUS：
#   - plist 落盘目录未钉 → 按 scripts/contrib/（approval plist 先例）为主，repo 根/launchd/
#     contrib 内 launchd/ 为备选；恰 1 份存在即过，0 或 2+ 份红
#   - 「只日志」载体未钉（stdout 或 contrib 外日志）→ G4 断言收在「零告警 + contrib-data
#     零写」；若实现往 contrib-data 内写日志文件则红（与契约 3 字面冲突，回设计对齐）
#   - sentinel 脚本名按设计表钉 scripts/contrib/gateway_sentinel.sh
# 红队纪律：黑盒；每断言硬失败；无 skip。
# Mental Mutation：「双失败」AND 语义复活→G1 红（探活健康时被否决）；kanban list 重新充当
#   告警信号→G2 红；探活异常误入告警→G4 红；key 丢日期（跨日不重报）→G1/G5 红锚；
#   树写状态文件（自记账幂等）→G3/G4 树指纹红；plist 少 StartInterval/AbandonProcessGroup→G6 红。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

SCRIPTS_DIR="$(tests_scripts_dir "$REPO_ROOT/scripts/contrib")"
TODAY="$(date +%F)"
PLIST_NAME="com.stringzhao.contrib-gateway-sentinel"

# ---- 本文件专用工具 ----

run_sentinel() { # [-e K=V]... 透传旋钮给 sb_run
  local snippet='bash "$MARTIN_DIR/scripts/contrib/gateway_sentinel.sh"'
  sb_run "$@" "$snippet"
}

gateway_down_events() { # events.jsonl 中 key=<date>-gateway-down 的条数
  jq -s --arg k "$TODAY-gateway-down" \
    '[.[] | select(.class == "pipeline-failure" and .key == $k)] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

sb_tree_hash() { # $SB_ROOT/contrib-data 内容指纹（相对路径+字节；「零写操作」断言载体）
  # 09-10 契约 3 措辞修订：排除 logs/sentinel.log——哨兵自身日志属合法可观测性写
  # （qa 裁决：「零写操作（除 notify event）」与「探活异常→只日志」自相矛盾，日志落点合法）
  python3 - "$SB_ROOT/contrib-data" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for fn in sorted(filenames):
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root)
        if rel.replace(os.sep, "/") == "logs/sentinel.log":
            continue  # 哨兵自身日志（契约 3 修订：合法可观测性写，不入零写断言）
        h.update(rel.encode())
        with open(p, 'rb') as f:
            h.update(f.read())
print(h.hexdigest())
PYEOF
}

PLIST_PATH="" PLIST_COUNT=0
find_plist() { # 候选目录定位（恰 1 份）→ 全局 PLIST_PATH/PLIST_COUNT（当前 shell 执行，勿放命令替换）
  PLIST_PATH=""
  PLIST_COUNT=0
  local cands=() p
  cands+=("$SCRIPTS_DIR/$PLIST_NAME.plist")
  cands+=("$SCRIPTS_DIR/launchd/$PLIST_NAME.plist")
  cands+=("$REPO_ROOT/$PLIST_NAME.plist")
  cands+=("$REPO_ROOT/launchd/$PLIST_NAME.plist")
  for p in "${cands[@]}"; do
    [ -f "$p" ] || continue
    PLIST_COUNT=$((PLIST_COUNT + 1))
    [ -z "$PLIST_PATH" ] && PLIST_PATH="$p"
  done
  return 0
}

# =============================================================================
t_case "G1 pgrep 死 → event（key=<date>-gateway-down）+ 探测形态（-f + 契约 pattern）；探活健康不得否决"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
run_sentinel -e STUB_PGREP_DOWN=1 >/dev/null
assert_eq "$(gateway_down_events)" "1" "3.1 pgrep 死 → 恰 1 条 gateway-down event（探活健康下仍告警=单语义钉死；AND 旧语义必红）"
PROBE="$SB_ROOT/stublog/probe.log"
if [ -s "$PROBE" ]; then
  _pass "3.1 pgrep 探测已发生"
  PL="$(grep '^pgrep|' "$PROBE" | head -1)"
  assert_contains "$PL" "-f" "3.1 pgrep 带 -f（进程匹配模式）"
  assert_contains "$PL" "hermes.*gateway run" "3.1 pgrep pattern=hermes.*gateway run（契约字面）"
else
  _fail "3.1 pgrep 探测已发生" "probe.log 空（sentinel 未调 GATEWAY_PROBE_BIN？）"
fi
sb_cleanup

# =============================================================================
t_case "G2 反向钉死：pgrep 活 + hermes 诊断失败 → 零告警（唯一信号源=pgrep 死亡）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
run_sentinel -e STUB_HERMES_FAIL=1 >/dev/null
assert_eq "$(gateway_down_events)" "0" "3.2 hermes 失败不构成告警信号（kanban list/gateway status 仅诊断）"
sb_cleanup

# =============================================================================
t_case "G5 日级幂等：同日二次触发同 key 仍恰 1 条"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
run_sentinel -e STUB_PGREP_DOWN=1 >/dev/null
run_sentinel -e STUB_PGREP_DOWN=1 >/dev/null
assert_eq "$(gateway_down_events)" "1" "3.3 同日两轮 → event 仍恰 1 条（notify event --key 幂等）"
sb_cleanup

# =============================================================================
t_case "G3 活 → 零动作：零 event + contrib-data 树指纹不变 + 探测确实发生"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
H_BEFORE="$(sb_tree_hash)"
run_sentinel >/dev/null
H_AFTER="$(sb_tree_hash)"
assert_eq "$(gateway_down_events)" "0" "3.4 网关活 → 零告警"
assert_eq "$H_AFTER" "$H_BEFORE" "3.4 contrib-data 树零变化（零动作；状态文件自记账=零写操作契约违背）"
[ -s "$SB_ROOT/stublog/probe.log" ] && _pass "3.4 pgrep 探测已发生" || _fail "3.4 pgrep 探测已发生" "probe.log 空"
sb_cleanup

# =============================================================================
t_case "G4 探活异常（rc=3）→ 只日志不告警：零 event + contrib-data 树指纹不变"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
cat > "$SB_ROOT/bin/pgrep" <<'EOF'
#!/bin/bash
printf 'pgrep|anomaly-rc3\n' >> "${STUB_LOG_DIR:-/nonexistent}/probe.log"
exit 3
EOF
chmod +x "$SB_ROOT/bin/pgrep"
H_BEFORE="$(sb_tree_hash)"
run_sentinel >/dev/null
H_AFTER="$(sb_tree_hash)"
assert_eq "$(gateway_down_events)" "0" "3.5 探活异常 → 零告警（单语义钉死：探活不参与告警判定）"
assert_eq "$H_AFTER" "$H_BEFORE" "3.5 contrib-data 树零变化（只日志=不落任何状态/日志文件入账本目录）"
sb_cleanup

# =============================================================================
t_case "G6 plist 结构：恰 1 份 + plutil -lint 过 + StartInterval=900 + AbandonProcessGroup=true + Label + program 要素"
find_plist
assert_eq "$PLIST_COUNT" "1" "3.6 plist 恰 1 份（CONTRACT_AMBIGUOUS：目录未钉，候选=contrib/launchd/repo 根）"
if [ -n "$PLIST_PATH" ] && [ -f "$PLIST_PATH" ]; then
  if plutil -lint "$PLIST_PATH" >/dev/null 2>&1; then
    _pass "3.6 plutil -lint 过"
  else
    _fail "3.6 plutil -lint 过" "$(plutil -lint "$PLIST_PATH" 2>&1 | head -2)"
  fi
  JSON="$(plutil -convert json -o - "$PLIST_PATH" 2>/dev/null)"
  if [ -n "$JSON" ] && printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    assert_eq "$(printf '%s' "$JSON" | jq -r '.Label // ""')" "$PLIST_NAME" "3.6 Label=$PLIST_NAME"
    assert_eq "$(printf '%s' "$JSON" | jq -r '.StartInterval // 0')" "900" "3.6 StartInterval=900（每 15min）"
    assert_eq "$(printf '%s' "$JSON" | jq -r '.AbandonProcessGroup // false')" "true" "3.6 AbandonProcessGroup=true（防御性，收割坑旗标）"
    ARGS="$(printf '%s' "$JSON" | jq -r '(.ProgramArguments // []) | join(" ")')"
    PROG="$(printf '%s' "$JSON" | jq -r '.Program // ""')"
    assert_contains "${ARGS}${PROG}" "gateway_sentinel.sh" "3.6 program 要素引用 gateway_sentinel.sh"
    FIRST="$(printf '%s' "$JSON" | jq -r '(.ProgramArguments // [])[0] // ""')"
    case "$(basename "$FIRST")" in
      bash|zsh|sh|gateway_sentinel.sh) _pass "3.6 解释器/直exec 要素成立（${FIRST})" ;;
      *) case "$PROG" in *gateway_sentinel.sh*) _pass "3.6 Program 直指脚本（shebang exec 形态）" ;; *) _fail "3.6 解释器要素" "ProgramArguments[0]=[$FIRST] Program=[$PROG]" ;; esac ;;
    esac
  else
    _fail "3.6 plist 可解析为 JSON" "plutil -convert json 失败（plist 结构损坏？）"
  fi
else
  _fail "3.6 plist 存在" "$PLIST_NAME.plist 未产出（候选目录均无）"
fi

# =============================================================================
t_case "G7 隔离：真实仓 events.jsonl 在死→event 窗口前后字节数不变（零真实外发）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
REAL="$REPO_ROOT/contrib-data/events.jsonl"
SZ_BEFORE="na"
[ -f "$REAL" ] && SZ_BEFORE="$(wc -c < "$REAL" | tr -d ' ')"
run_sentinel -e STUB_PGREP_DOWN=1 >/dev/null
if [ "$SZ_BEFORE" = "na" ]; then
  _pass "3.7 真实仓 events.jsonl 不存在（零污染平凡真）"
else
  SZ_AFTER="$(wc -c < "$REAL" | tr -d ' ')"
  assert_eq "$SZ_AFTER" "$SZ_BEFORE" "3.7 真实仓账本字节数不变（窗口对比；并行写入致红先排查再重跑）"
fi
assert_eq "$(gateway_down_events)" "1" "3.7 前置自证：event 落在沙箱账本"
sb_cleanup

t_finish
