#!/bin/bash
# gateway_sentinel.sh — contrib gateway 存活哨兵（T6；launchd 每 15min 触发，plist 不随代码装载）
#
# 语义（T6 契约 3 钉死，唯一告警信号 = pgrep 进程死亡）:
#   pgrep exit 0   → gateway 在 → 零动作（零写零日志噪音）
#   pgrep exit 1   → 进程死 → notify.sh event pipeline-failure --key <日期>-gateway-down
#                    （日级幂等：同日恢复不重报，次日自动重报——持续故障跨天可见）
#   pgrep exit ≥2  → 探测自身异常（用法错/权限/缺 binary）→ 只日志，绝不告警
#                    （探针故障不得伪装成被监控对象故障）
#
# KeepAlive 交互说明（为什么只告警不自愈）:
#   gateway 由 launchd 服务 ai.hermes.gateway 托管（KeepAlive=true + ThrottleInterval=30s）——
#   「拉起」已由 launchd 负责：进程死 ~30s 内自动重生。本哨兵只补可观测性：崩溃窗口入账、
#   崩溃循环跨 tick 可见。检测≠送达（已接受限制，记录在案）：gateway down 期间 event 只落
#   events.jsonl 账本，微信送达依赖 gateway 恢复后 operator 班次收班时的 flush 聚合推送（每小时一班）。
#   pgrep pattern 同时命中 stderr_timestamp 包装进程与 gateway 本体（launchd 单元两进程），
#   比单 pid 探测保守——包装进程存活即视为单元存活，降低误报面。
#
# 诊断探针选型记录（防重蹈，重审 BLOCKER 修复）:
#   不用 `hermes kanban list` 作探活信号——它读本地 SQLite 不经 gateway，gateway 死时照样
#   成功（哨兵在核心场景永不报警）。`hermes gateway status` 只作人工诊断，不作告警信号。
#
# 装载（人工步骤，不随代码自动上线——沿 approval-collect 先例）:
#   launchctl bootstrap gui/$(id -u) \
#     ~/workspace/martin/scripts/contrib/com.stringzhao.contrib-gateway-sentinel.plist
#   launchctl print gui/$(id -u)/com.stringzhao.contrib-gateway-sentinel | head -5   # 复核
# 卸载:
#   launchctl bootout gui/$(id -u)/com.stringzhao.contrib-gateway-sentinel
#
# seam: MARTIN_DIR / CONTRIB_DATA_DIR / GATEWAY_PROBE_BIN / GATEWAY_PROBE_PATTERN
# 自身零状态写（除 notify event 入账与日志行）；恒 exit 0（fail-soft，launchd 不重试）
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
GATEWAY_PROBE_BIN="${GATEWAY_PROBE_BIN:-pgrep}"
PROBE_PATTERN="${GATEWAY_PROBE_PATTERN:-hermes.*gateway run}"
LOGDIR="$CONTRIB/logs"
mkdir -p "$LOGDIR" 2>/dev/null || true
LOG="$LOGDIR/sentinel.log"
ts() { date "+%F %T"; }
log() { echo "[$(ts)] sentinel: $*" >>"$LOG" 2>/dev/null || true; }

probe_rc=0
"$GATEWAY_PROBE_BIN" -f "$PROBE_PATTERN" >/dev/null 2>&1 || probe_rc=$?

case "$probe_rc" in
  0)
    :   # 活 → 零动作
    ;;
  1)
    log "gateway 进程死亡（pgrep 无匹配）→ 告警入账"
    bash "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-gateway-down" \
      --summary "hermes gateway 进程死亡（launchd KeepAlive 约 30s 内自动拉起；本条入账保崩溃窗口/持续故障可见，恢复后随小时 flush 送达）" \
      >>"$LOG" 2>&1 || log "notify event 入账异常（下轮 15min 再试，--key 日幂等）"
    ;;
  *)
    log "WARN 探测异常 rc=${probe_rc}（探针=${GATEWAY_PROBE_BIN} pattern=${PROBE_PATTERN}）→ 只日志不告警"
    ;;
esac
exit 0
