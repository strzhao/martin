#!/bin/bash
# heartbeat.sh — contrib operator 班卡心跳（hermes cron no-agent，每小时）
#
# 钳夹纪律：本脚本只做一件事——拉起当小时 operator 班卡；无状态、无私有信号量，
# 幂等键 shift-YYYYMMDD-HH 天然去重（重跑同小时=返回已有卡 id）；operator 单飞由
# --resources shift:contrib 在 dispatcher 侧保证（上一班未收工则本班排队）。
# 失败语义：kanban create 失败=本轮无班（下小时自然重试），绝不循环重试。
# 装载：hermes cron（no-agent），计划 2 * * * *；卸载即停（旧 run-watch 并行期互不干扰）。
set -u
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
if [[ -z "${HEARTBEAT_KANBAN:-}" ]]; then
  HB="$(ls -t "${HOME}"/.nvm/versions/node/*/bin/hermes 2>/dev/null | head -1 || true)"
else
  HB="${HEARTBEAT_KANBAN}"
fi
HB="${HB:-hermes}"
HB_DIR="$(dirname "${HB}")"
export PATH="${HB_DIR}:${PATH}"

KEY="shift-$(date +%Y%m%d-%H)"
BODY="operator 班卡。本班流程按 contrib-operator skill 执行（survey→分诊→造/路由→journal）。
当前生效面（迁移期 A 波）：本班主任务 = 分诊 contrib board triage 列存量 [sig] 信号卡（最老优先，三路：出手/[watch]/放行）；深潜取证一律起 [q] 卡委派；判断与放行理由全落卡 + contrib-data/ops-journal.md。
边界：新命中 gh survey 暂不启用（B 波交接）；deepcheck/通知/own-PR 盯梢仍由旧管道负责（C/D 波交接前勿重复处理）；对外动作只起草提案（L2 链落笔）。"

env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
  "$HB" kanban --board contrib create \
  --assignee contrib --skill contrib-operator \
  --resources shift:contrib --idempotency-key "$KEY" \
  --created-by heartbeat \
  "operator shift ${KEY#shift-}" --body "$BODY" >/dev/null 2>&1 && echo "ok ${KEY}" || echo "skip/fail ${KEY}"
