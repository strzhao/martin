#!/bin/bash
# heartbeat.sh — contrib operator 班卡心跳（hermes cron no-agent，每小时）
#
# 钳夹纪律：本脚本只做一件事——拉起当小时 operator 班卡；无状态、无私有信号量，
# 幂等键 shift-YYYYMMDD-HH 天然去重（重跑同小时=返回已有卡 id）；operator 单飞由
# --resources shift:contrib 在 dispatcher 侧保证（上一班未收工则本班排队）。
# 失败语义：kanban create 失败=本轮无班（下小时自然重试），绝不循环重试。
# 装载：hermes cron（no-agent），计划 2 * * * *；卸载即停（旧 run-watch 并行期互不干扰）。
# 部署：cron 只认 ~/.hermes/scripts/ 下的相对路径——改本文件后须 cp 到 ~/.hermes/scripts/contrib-heartbeat.sh（本仓为唯一真源）。
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
生效面（B 波起全量）：①感知——gh issue list 增量（与 triage 列/已有卡集合差 → 新 [sig] 卡）+ himalaya 未读 GitHub 通知分诊（坑位见 skill §4.4，不确定只建卡不动邮箱）；②分诊 triage 收件箱最老优先三路；③守候——scheduled 到期 [watch]、own-PR（gh pr list --author strzhao）动静、rq awaiting 项 premise 推前实查；④对外只起草提案（L2 链落笔）。
暂缓：深检（swarm 接线明日验证后开；W37 配额 30/30 本就回血前不可用）。
收尾：journal 四行契约 + complete 双传。"

env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
  "$HB" kanban --board contrib create \
  --assignee contrib --skill contrib-operator \
  --resources shift:contrib --idempotency-key "$KEY" \
  --created-by heartbeat \
  "operator shift ${KEY#shift-}" --body "$BODY" >/dev/null 2>&1 && echo "ok ${KEY}" || echo "skip/fail ${KEY}"

# L2 链事件 flush（旧 run-watch flush 段退役后由心跳顺带承载；幂等，内部自带限额/去重）
bash "${MARTIN:-$HOME/workspace/martin}/scripts/contrib/notify.sh" flush >>"${HOME}/workspace/martin/contrib-data/logs/heartbeat-flush.log" 2>&1 || true

# [watch] 到期唤醒钳夹（零判断：scheduled 卡上有 operator 落的机器行 `watch-due: YYYY-MM-DD`，
# 到期即 unblock 交 dispatcher；未到期不动。schedule 是终态停放无唤醒 actor——operator 12 班
# 源码实证 kanban_db.py:3767-3790 + dispatch _lane_rows，缺口由本钳夹闭合）
DB="$HOME/.hermes/kanban/boards/contrib/kanban.db"
due_ids="$(sqlite3 "file:${DB}?mode=ro" \
  "select distinct t.id from tasks t join task_comments c on c.task_id=t.id
   where t.status='scheduled' and c.body like '%watch-due:%'
   and substr(trim(replace(c.body,char(13),'')), instr(trim(replace(c.body,char(13),'')),'watch-due:')+11, 10) <= date('now','localtime')" 2>/dev/null || true)"
if [[ -n "$due_ids" ]]; then
  while IFS= read -r wid; do
    [[ -n "$wid" ]] || continue
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
      "$HB" kanban --board contrib unblock "$wid" --reason "watch-due 到期唤醒（心跳钳夹）" >/dev/null 2>&1 || true
  done <<<"$due_ids"
fi
