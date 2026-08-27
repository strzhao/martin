# Hermes 可观测性消费指南(本地观测栈)

> 给 AI 会话与人的排查手册。栈 = origin/main + 本地补丁(`observability-stack` 分支锚定),
> **不入上游**;升级只走 `fetch + rebase`(勿用 `hermes update`,会 reset 抹栈)。
> 观测埋点语义的权威源:`~/workspace/hermes-agent/hermes_cli/forensics.py` + `agent/monitoring/events_sink.py`。

## 30 秒入口

遇到任何 hermes 异常(消息没发、说一半断、疑似限流、定时任务没跑),**先跑**:

```bash
hermes forensics summary --hours 24
```

一条命令给出:遥测健康(停更检测)、事件分布、失败汇总(发送/投递/断路器)、token 当前年龄、下一步深挖提示。
summary 显示异常后,按下表深挖:

| 子命令 | 旗标 | 用途 |
|---|---|---|
| `summary` | `--hours N`(默认 24) | 一命令健康总览(本文入口) |
| `timeline` | `--chat/--job/--turn/--since/--until` | 事件+日志合并时间线(自动去重,排除 poll 噪声) |
| `turn <id>` | — | 单 turn 瀑布:入站 → 分块发送 → 响应 → 结果 |
| `token` | — | weixin token 生命周期 + 失败时年龄分布 |
| `cron` | `--days N`(默认 7) | run × delivery 投递矩阵 + **交叉纠正**(限流误归标注) |
| `breaker` | `--days N`(默认 7) | 断路器 open/close 区间重建 |

全部严格只读(events.db `mode=ro`、executions `immutable=1`);隐藏 `--now <ISO|epoch>` 可固定时钟做重放。

## 排查决策树

| 症状 | 路径 |
|---|---|
| 定时任务没收到 | `summary` → `cron --days 1`(看投递终态+交叉纠正)→ 异常 job 用 `timeline --job <id>` |
| 回复说一半就断 | 从日志找 `[turn:<12hex>]` 标签 → `turn <id>` 看分块瀑布(partial/delivered_chars) |
| 疑似限流/被熔断 | `breaker --days 1` + `timeline --since 2h`;注意 **threshold=1 会把服务端错误误归限流误开**(见盲区) |
| 会话/token 过期 | `token`(当前年龄 + 失败年龄分布);配合 `cron` 交叉纠正确认误归 |
| 遥测停更 | `summary` 的 ⚠ 行 → `pgrep -fl hermes` 查进程 → `git -C ~/workspace/hermes-agent log --oneline -3` 查栈完整性 |

## events.db 数据字典

库:`~/.hermes/telemetry/events.db`(SQLite,delete journal)。表 `events`:
`ts`(epoch 秒)/ `kind` / `turn_id`(12hex)/ `platform` / `chat`(**sink 已截 8 字符**)/ `job_id` / `message_id` / `data`(JSON,脱敏后)。

| kind | 语义 | data 关键字段 |
|---|---|---|
| `send_attempt` | 每次发送尝试 | `chunk/chunks_total/attempt/chars/token_age_h`(刷新后为 null) |
| `send_result` | 发送终态(每 target 每消息 1 条) | `ok/partial/chunks_ok/chunks_total/delivered_chars/attempts/token_age_h/classification` |
| `breaker` | 断路器动作 | open:`state/window_s/threshold/events_in_window`;close:`open_duration_s/extensions/events` |
| `cron_deliver` | cron 投递终态(每 target **恰 1 条**) | `outcome/reason_head(≤80)/timeout_handled` |
| `token_refresh` | 服务端换发 | `prev_age_h/new_age_h` |
| `token_restore` | 进程重启从磁盘恢复(**不重置年龄**) | `restored/issued_at_available` |
| `poll` | 轮询真实成功心跳(1800s 节流) | `ok/last_success/polls` |
| `unknown` | GatewayHealthEvent 键兜底(噪声,可忽略) | — |

`cron_deliver` 六终态:`delivered_live / timeout_assume_delivered / standalone_delivered`(成功)/ `standalone_failed / relay_fail_closed / skipped_shutdown`(失败)。

## 三 sink 分工与日志路由

| sink | 用途 |
|---|---|
| `events.db` | 机器查询/forensics(本文主入口) |
| 纯文本日志 | grep 取证、栈前历史回退 |
| metrics | 未动(上游现状) |

**日志路由表**(`~/.hermes/logs/`):

| 来源 | 写哪里 |
|---|---|
| weixin 平台(发送/分类/断路器/心跳) | `gateway.log` |
| `cron.scheduler` | `agent.log`(**上游只写这里**);栈 T3 起双写 `gateway.log` |
| ERROR 级投递失败 | `errors.log` + `gateway.error.log` |

⚠ **高频坑(08-26 实战踩过)**:gateway.log 里 grep 不到 cron 日志 ≠ 没发生——
若执行进程是**无栈代码**(reset/升级窗口),cron 日志只在 `agent.log`。三个日志都查再下结论。

**判别进程是否带栈**:看日志行有没有 `token_age_h=` 字段(T2 起才有)。无栈进程 = 该窗口观测归零,只能靠 agent.log/errors.log 文本回退。

## 已知盲区(先记着,别当 bug 查)

1. `unknown` 事件:GatewayHealthEvent 原生 `event=` 键被 sink 兜底产生,纯噪声(T6 待过滤)。
2. reset/升级窗口观测归零:代码不在,埋点不在。**升级只走 fetch+rebase**。
3. 断路器 `threshold=1`:任何服务端错误都会误开熔断(把 stale_session 误归限流放大)——框架议题 #35283 族。
4. poll 占比 ~97%:正常现象(1800s 节流心跳),`timeline` 已自动排除。
5. cron 投递遇 `stale_session` 不会主动换发 token——**只有微信入站消息触发服务端换发**;投递失败且 token 高龄时,让用户在微信发条消息即可恢复。

## token TTL 经验参考(非契约,持续校准)

- 08-23 实测过期区间 (22.5, 33.8]h;08-26 进一步收窄至 **(23.6, 24.2]h,疑似精确 24h**。
- `summary`/`token` 只报数值不做判定(TTL 是经验值);消费时自行对照:年龄逼近 23h 且即将有 cron 投递 → 提醒用户发消息换发。

## sqlite3 直查兜底(summary 覆盖不到时)

```bash
# 窗口内 kind 分布
sqlite3 ~/.hermes/telemetry/events.db \
  "SELECT kind, COUNT(*) FROM events WHERE ts > strftime('%s','now','-24 hours') GROUP BY kind ORDER BY 2 DESC;"

# 某事件的完整 data
sqlite3 ~/.hermes/telemetry/events.db \
  "SELECT datetime(ts,'unixepoch','localtime'), data FROM events WHERE kind='cron_deliver' ORDER BY ts DESC LIMIT 5;"

# 跨表:失败投递 + 当时的 token 年龄
sqlite3 ~/.hermes/telemetry/events.db \
  "SELECT datetime(e.ts,'unixepoch','localtime'), e.job_id, json_extract(e.data,'$.outcome'),
          json_extract(s.data,'$.token_age_h')
   FROM events e LEFT JOIN events s ON s.kind='send_result' AND abs(s.ts-e.ts) < 5
   WHERE e.kind='cron_deliver' AND json_extract(e.data,'$.outcome') NOT LIKE '%delivered%';"
```

commit 归属:本指南随 martin 仓 batch-sync;栈代码在 hermes-agent 仓(无 Co-Authored-By trailer)。
