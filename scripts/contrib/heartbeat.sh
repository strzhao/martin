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

# ── 钳夹读取器（两个钳夹共用；2026-09-13 结构件，同形两处一次收敛）──────────
# 为什么需要这一层（实查证据，勿删注释）：
#   ① 读取：本 board 库是 WAL（文件头 18/19 字节 = 02 02）。`-wal` **不在场时刻**（dispatcher 按
#      tick 开关库、不常驻持有；clean close 后 sidecar 仍在、此时 `mode=ro` rc=0，别按「静止态必失败」记）
#      `sqlite3 "file:<DB>?mode=ro"` rc=14 `unable to open database file`，旧写法 `2>/dev/null || true`
#      把它吞成空串 = 静默失败（用无 sidecar 的库副本可复现；`?immutable=1` 不依赖 sidecar、
#      任何状态下都不报 rc=14——快照语义见 ④）。
#   ② 失败不再无声：rc != 0 追加一行到 logs/heartbeat-clamp.log。
#   ③ 到期窗口先过日期形状守卫：token 首次出现后 10 字符必须 glob `YYYY-MM-DD`。散文里复述该
#      token 会被取到（实测误命中 [draft] t_8bc51715 的窗口 `[ 行请编排层 unb]`，首字符空格
#      0x20 字典序 < 数字 0x32 ⇒ 恒判「已到期」⇒ 每次心跳误唤醒一张非到期卡）。
#   ④ 快照语义（红队 Q8 实证 09-13，勿按「WAL 一致当前态」读）：`?immutable=1` **忽略 `-wal`**——
#      写者持库造出非空 WAL 时，读到的是「最后一次 checkpoint 的快照」（该形态实测报 `no such table`；
#      plain / `mode=ro` 同刻正确）。⇒ 本次修复把读取语义从「WAL 一致当前态」换成「快照」；对钳夹 1
#      （日粒度）/ 钳夹 2（30 分钟宽限），失效形态 = **延迟 ≤1 个心跳周期、非错判**（下一轮自愈）。
#   ⑤ 漏账可见（09-13 收口）：命中 token 但窗口不过形状守卫的行此前被静默丢弃；现在 SQL 给这类行打
#      `|len=<n> first=0x<hh>` 标签，`_clamp_read` 各落一行 `clamp parse SKIP <id> win=[…]`（只记形状
#      元信息、不复述窗口原文——防日志被粘回 blocked 卡评论后反被钳夹自己误读）。
#   ⑥ 三态可判（读日志即可）：无行 = 读到 0 张 / `clamp read FAILED` = 读断 / `clamp parse SKIP` = 有
#      token 但格式坏 / `woke` / `unblock FAILED` = 调用结果。
DB="$HOME/.hermes/kanban/boards/contrib/kanban.db"
CLAMP_LOG="$HOME/workspace/martin/contrib-data/logs/heartbeat-clamp.log"

# $1 = SQL。stdout = 合法 id 行（无命中则空）。
# SQL 可用 `|len=… first=0x…` 标签标注「形状不过」的行（见 ⑤）：这类行落 SKIP 漏账日志、不进 stdout。
_clamp_read() {
  local raw rc line tid note
  raw="$(sqlite3 "file:${DB}?immutable=1" "$1" 2>&1)"; rc=$?
  if [[ "$rc" != 0 ]]; then
    printf '%s clamp read FAILED rc=%s: %s\n' "$(date '+%F %T')" "$rc" "$raw" >>"$CLAMP_LOG"
    return 0
  fi
  while IFS= read -r line; do
    tid="${line%%|*}"; note="${line#"$tid"}"
    [[ "$tid" =~ ^t_[0-9a-f]+$ ]] || continue
    if [[ -n "$note" ]]; then
      printf '%s clamp parse SKIP %s win=[%s]\n' "$(date '+%F %T')" "$tid" "${note#|}" >>"$CLAMP_LOG"
    else
      printf '%s\n' "$tid"
    fi
  done <<<"$raw"
}

# ── 钳夹 1：[watch] 到期唤醒（到期即 unblock 交 dispatcher；未到期不动）──
# schedule 是终态停放无唤醒 actor——operator 12 班源码实证 kanban_db.py:3481-3522 unblock_task
# 是唯一 re-gate 路 + dispatch 只枚举 ready/review，缺口由本钳夹闭合。
watch_sql="with w as (
   select t.id as id,
     substr(trim(replace(c.body,char(13),'')), instr(trim(replace(c.body,char(13),'')),'watch-due:')+11, 10) as due
   from tasks t join task_comments c on c.task_id=t.id
   where t.status in ('scheduled','blocked') and c.body like '%watch-due:%'),
 g as (select id, due, due glob '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' as ok from w)
 select distinct id || case when ok then '' else '|len=' || length(due) || ' first=0x' || hex(substr(due,1,1)) end
 from g
 where coalesce(ok,0)=0 or due <= date('now','localtime')"
due_ids="$(_clamp_read "$watch_sql")"
if [[ -n "$due_ids" ]]; then
  while IFS= read -r wid; do
    [[ -n "$wid" ]] || continue
    if env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
      "$HB" kanban --board contrib unblock "$wid" --reason "watch-due 到期唤醒（心跳钳夹）" >/dev/null 2>&1; then
      printf '%s woke %s\n' "$(date '+%F %T')" "$wid" >>"$CLAMP_LOG"
    else
      printf '%s unblock FAILED %s\n' "$(date '+%F %T')" "$wid" >>"$CLAMP_LOG"
    fi
  done <<<"$due_ids"
fi

# ── 钳夹 2：分诊收口（triage 里 [sig] 卡已有 `triage-verdict:` 判定评论且超过 30 分钟宽限，
# = operator 已落判、worker 无跨卡终态权（kernel 作用域隔离）——由本钳夹代行归档。
# 判决是 AI 的（评论机器行），落笔是钳夹的——与 L2「agent 起草链落笔」同构）──
cutoff=$(( $(date +%s) - 1800 ))
sweep_sql="select distinct t.id from tasks t join task_comments c on c.task_id=t.id
   where t.status='triage' and t.title like '[sig]%' and c.body like '%triage-verdict:%'
   and c.created_at <= ${cutoff}"
sweep_ids="$(_clamp_read "$sweep_sql")"
if [[ -n "$sweep_ids" ]]; then
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
    "$HB" kanban --board contrib archive $sweep_ids >>"$CLAMP_LOG" 2>&1 || true
fi
