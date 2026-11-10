#!/bin/bash
# t3_redline.acceptance.test.sh — T3 红线总检静态扫描（场景 11.P4/12.P2/12.P3/13.P1-13.P4/14.P1-14.P3）
# 口径：driver 范围=脚本+数据产物+cron 体+配置；排除 SOUL/文档声明文本（约束 8）。
# 12.P1（期货摘要 real-process）与 10.P2 在简报产物验证，不在本文件。
# 用法：bash scripts/hkstock/tests/t3_redline.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
HK_PROFILE="$HOME/.hermes/profiles/hkstock"
CRON_JOBS="$HOME/.hermes/cron/jobs.json"

FAIL_COUNT=0
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { printf 'PASS %s\n' "$1"; }

# 11.P4 — 信号与复盘产物零下单关键词
HITS=$(grep -rniE "下单|委托|撤单|open position|submit order" "$MARTIN_ROOT/hkstock-data/" 2>/dev/null | wc -l | tr -d ' ')
[ "$HITS" -eq 0 ] && pass "11.P4-signal-noexec" || { fail "11.P4-signal-noexec" "hkstock-data/ 命中 $HITS"; grep -rniE "下单|委托|撤单|open position|submit order" "$MARTIN_ROOT/hkstock-data/" 2>/dev/null | head -5; }

# 12.P2 — hkstock 域对 quant-futures 引用零写操作（范围=脚本+指令+数据产物，排除声明文本与本 driver 自引用）
QF_HITS=$(grep -rn "quant-futures" "$MARTIN_ROOT/scripts/hkstock" 2>/dev/null | grep -v "acceptance.test.sh" | \
  grep -viE "纯读|只读|绝不|不写|不触" | \
  grep -E "git (commit|push)|>>? *(/Users/stringzhao/workspace/)?quant-futures|tee |rm -|mv |cp " | wc -l | tr -d ' ')
[ "$QF_HITS" -eq 0 ] && pass "12.P2-qf-readonly" || fail "12.P2-qf-readonly" "写操作命中 $QF_HITS"

# 12.P3 — hkstock 可执行产物（脚本+信号产物+简报产物）零下单关键词（范围排除声明文本与 driver 自引用）
EXEC_HITS=$( { grep -rniE "下单|委托|撤单|open position|submit order" \
                 --exclude="*.acceptance.test.sh" "$MARTIN_ROOT/scripts/hkstock" "$MARTIN_ROOT/hkstock-data" 2>/dev/null | \
                 grep -viE "(不|禁止|零|无)[^。]{0,8}(下单|委托|撤单)"; } | wc -l | tr -d ' ')
[ "$EXEC_HITS" -eq 0 ] && pass "12.P3-exec-noexec" || fail "12.P3-exec-noexec" "命中 $EXEC_HITS"

# 13.P1 — hkstock profile 配置零 cc lane 特征（排除 skill hub 缓存等非配置产物）
CC_HITS=$(grep -rnE '\-cc|claude-run|CC claim' "$HK_PROFILE/config.yaml" "$HK_PROFILE/skills" --include="*.yaml" --include="*.json" --exclude-dir=".hub" 2>/dev/null | wc -l | tr -d ' ')
[ "$CC_HITS" -eq 0 ] && pass "13.P1-no-cclane" || { fail "13.P1-no-cclane" "命中 $CC_HITS"; grep -rnE '\-cc|claude-run|CC claim' "$HK_PROFILE/config.yaml" "$HK_PROFILE/skills" --include="*.yaml" --include="*.json" --exclude-dir=".hub" 2>/dev/null | head -5; }

# 13.P2 — hkstock 可执行产物 + cron 体零 claude -p 无头调用（排除 driver 自引用）
CR_HITS=$( { grep -rn "claude -p\|claude-run" --exclude="*.acceptance.test.sh" "$MARTIN_ROOT/scripts/hkstock" 2>/dev/null;
             grep -io "claude -p\|claude-run" "$CRON_JOBS" 2>/dev/null; } | wc -l | tr -d ' ')
[ "$CR_HITS" -eq 0 ] && pass "13.P2-no-clauderun" || fail "13.P2-no-clauderun" "命中 $CR_HITS"

# 13.P3 — 外发通道审计：hkstock 脚本零裸 send 直推（外发点=cron deliver+notify-subscribe，载荷均为 AI 产物）
SEND_HITS=$(grep -rnE "hermes send|send_message|sendmsg" --exclude="*.acceptance.test.sh" "$MARTIN_ROOT/scripts/hkstock" 2>/dev/null | wc -l | tr -d ' ')
[ "$SEND_HITS" -eq 0 ] && pass "13.P3-no-raw-send" || fail "13.P3-no-raw-send" "脚本内直推命中 $SEND_HITS"

# 13.P4 — gate.sh 实跑 exit ∈ {0,2}
set +e
GATE_OUT=$(bash "$MARTIN_ROOT/scripts/contrib/tests/gate.sh" 2>&1)
GATE_RC=$?
set -e 2>/dev/null || true
if [ "$GATE_RC" -eq 0 ] || [ "$GATE_RC" -eq 2 ]; then
  pass "13.P4-gate-exit ($GATE_RC)"
else
  fail "13.P4-gate-exit" "exit=$GATE_RC"; printf '%s\n' "$GATE_OUT" | tail -10
fi

# 14.P1 — 简报与复盘 cron 并存
BOTH=$(grep -c "hkstock-morning-brief\|hkstock-signal-review" "$CRON_JOBS" 2>/dev/null)
if [ "$BOTH" -ge 2 ]; then pass "14.P1-cron-both"; else fail "14.P1-cron-both" "jobs.json 命中 $BOTH"; fi

# 14.P2 — default SOUL 路由表 hkstock 与 life 并存
SOUL="$HOME/.hermes/SOUL.md"
if grep -q "hkstock" "$SOUL" && grep -q "life" "$SOUL"; then pass "14.P2-route-table"; else fail "14.P2-route-table" "SOUL.md 缺 hkstock/life 行"; fi

# 14.P3 — 持仓数据文件不入 git（校验器/测试文件名含 holdings 属误报，只查数据文件）
if git -C "$MARTIN_ROOT" ls-files | grep -qE "holdings\.(yaml|yml|json|csv)|hkstock-data/.*holdings"; then fail "14.P3-git-clean" "持仓数据文件在追踪列表"; else pass "14.P3-git-clean"; fi

printf '\n%s\n' "FAIL_COUNT=$FAIL_COUNT"
exit "$([ "$FAIL_COUNT" -eq 0 ] && echo 0 || echo 1)"
