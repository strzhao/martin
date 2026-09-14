#!/bin/bash
# contrib-flush.sh — contrib 域确定性每小时调用面（flush + watch-due 到期巡检）
#
# 宿主：hermes cron job `3e5c6e23e260`（「contrib-operator 班次（cron agent）」）的 `script` 字段。
#   该 job 每 tick（2 * * * *）先以 bash 跑本脚本，stdout 注入班次 agent 的 prompt 作上下文。
# 缺口（2026-09-14，卡 t_6457f433）：flush 的唯一自动调用者原本是班次 LLM 的收班契约（概率性）——
#   漏跑一次（09-14 02:0x 实证：rc=0、零输出、账本零新增、pending 原样）告警即永久挂账且无本地提示。
# 缺口（2026-09-14，卡 t_cc4c9fcd）：到期唤醒 actor 随心跳钳夹退役而消失（`scheduled`/`blocked`
#   两侧 kernel 都不自醒，唯一唤醒动作 = 某个 actor 调 unblock）⇒ 本 harness 顺带承载
#   `scripts/contrib/watch-due-patrol.sh`（同一 tick 面，零新 job / 零新 plist / 零新字段）。
# 契约（改前先读）：
#   1. **永远 exit 0** —— cron 里脚本非零退出会污染 job，而班次 agent 仍须照常开跑；
#   2. **stdout ≤2 行** —— 它是注入班次 prompt 的上下文，不许可 dump（细节落 $LOG / 巡检器日志）；
#      常态 1 行（`flush ok`），巡检器有唤醒/读失败时至多再 1 行；
#   3. 内层 `timeout 120` 兜住卡死；无 timeout 可执行文件时降级为无护栏并如实报告；
#   4. 幂等安全网不在本脚本内（notify.sh 自带 /tmp 锁 + min_interval + 当日限额，
#      多调用者无害、双发已被吸收）——勿在此重复实现；
#   5. 巡检器自身亦永远 exit 0、stdout ≤1 行、细节落 `contrib-data/logs/watch-due-patrol.log`。
# 回退：删本文件末尾两行巡检调用（#2 行 + `[ -f ]` 行）即回到纯 flush 面；
#      再回退 flush 面 = cron job `3e5c6e23e260` 的 `script` 字段清回空串 + 删本文件。
# 部署：真源 = scripts/contrib/contrib-flush.sh；部署副本 = ~/.hermes/scripts/contrib-flush.sh
#      （cp + diff 双向逐字节一致；部署面回退命令见上）。
set -uo pipefail

MARTIN="$HOME/workspace/martin"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
LOG="$HOME/.hermes/logs/contrib-flush.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# PATH 三级解析（cron/launchd 环境极简；09-06 实证：nvm 装的 CLI 在此 rc=127）
PATH_BASE="/usr/bin:/bin:/usr/sbin:/sbin"
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  [ -d "$d" ] && PATH_BASE="$d:$PATH_BASE"
done
node_bin="$(ls -td "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | head -1 || true)"
if [ -n "$node_bin" ] && [ -x "$node_bin/node" ]; then
  PATH_BASE="$node_bin:$PATH_BASE"   # hermes/tunnel 是 npm 包装脚本时需 node 本体可达
fi
PATH="$PATH_BASE:$PATH"; export PATH

if [ ! -f "$NOTIFY" ]; then
  printf 'flush skip: notify.sh 不可达（%s）\n' "$NOTIFY"
  exit 0
fi

cd "$MARTIN" 2>/dev/null || true
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
if [ -n "$TIMEOUT_BIN" ]; then
  out="$("$TIMEOUT_BIN" 120 bash "$NOTIFY" flush 2>&1)"; rc=$?
else
  out="$(bash "$NOTIFY" flush 2>&1)"; rc=$?
fi

{
  printf '%s flush rc=%s\n' "$(date '+%F %T')" "$rc"
  [ -n "$out" ] && printf '%s\n' "$out"
} >> "$LOG" 2>/dev/null || true

if [ "$rc" -eq 0 ]; then
  if [ -n "$TIMEOUT_BIN" ]; then
    printf 'flush ok\n'
  else
    printf 'flush ok（无 timeout 护栏）\n'
  fi
else
  printf 'flush rc=%s（告警保留待下轮重试）\n' "$rc"
fi

# ── watch-due 到期巡检（同一确定性 tick 面：cron tick 即巡检；stdout 携带本 tick 唤醒的卡）──
PATROL="$MARTIN/scripts/contrib/watch-due-patrol.sh"
[ -f "$PATROL" ] && bash "$PATROL"

exit 0
