# Hermes 可观测性审计 — 问题挖掘与取证能力缺口(2026-08-23)

> 三层信息对齐:源码现状(3 路并行审计)× 08-23 微信事故实战取证缺口 × 上游社区 issue 版图。
> 目的:为 hermes 共建确定「最值得补的日志/洞察」,issue-first、影响面优先。

## TL;DR

Hermes 可观测性现状一句话:**内容取证强、遥测取证弱;日志是人类格式、结构化遥测全在 opt-in 侧翼**。

- SQLite 状态层是极强的事后内容取证库(全量 transcript + 工具参数/结果全文 + 软删除保留 + FTS5),但 timing/latency/错误分类/事件审计全部不落库,只能靠日志目录重建。
- 日志是纯文本(全仓库无 JSON formatter),毫秒精度但无时区,6.4% 装饰行混入,无任何关联 ID——08-23 事故取证全程靠「毫秒邻接 + chat_id 前 8 位 + 文件 mtime」三方手工 join。
- 上游已有 5 个 observability/logging issue **open 且无 PR 占坑**(#6741/#75458/#89155/#90115/#24690),与实战缺口高度重合——这是 08-14 FTS PR 之后最好的贡献弹药库。

---

## 一、现状盘点:三层可观测架构

### 1. 纯文本日志层(常开)— `hermes_logging.py`

| 维度 | 现状 |
|---|---|
| 格式 | `%(asctime)s %(levelname)s[session_tag] %(name)s: %(message)s`(hermes_logging.py:85);**全仓库无 JSON formatter** |
| session 关联 | thread-local `[session_id]` tag 经全局 LogRecord factory 注入(:183-212)——**机制已存在,可扩展 turn_id** |
| 分文件 | agent.log(catch-all INFO+)/gateway.log(gateway.* 组件过滤)/errors.log(WARNING+)/gui.log;**cron.scheduler 落 agent.log 不落 gateway.log**(COMPONENT_PREFIXES :236-252) |
| rotation | RotatingFileHandler 5MB×3;异步 QueueHandler 单线程写;gateway.error.log(launchd stderr)**无 rotation** |
| 脱敏 | RedactingFormatter 全局常开(~50 vendor prefix、JWT、E.164 等,head-6/tail-4) |
| 故障取证 | faulthandler(SIGUSR2 全线程 dump)、deadline watchdog、shutdown watchdog JSON dump |

已有遥测亮点(别低估):
- **每次 API 调用 INFO 行含完整 usage + latency + cache%**:`API call #%d: model=%s provider=%s in=%d out=%d total=%d latency=%.1fs cache=…`(conversation_loop.py:4180)——外部项目 TokenTelemetry 就在正则解析这一行(#6642 评论)
- **工具时长有日志**:`tool %s completed (%.2fs, %d chars)` / `tool %s failed (%.2fs): %s`(tool_executor.py:1426/1428),duration_ms 同步给 post_tool_call hook
- 压缩全链路遥测(context_compressor),但 **log-only JSON,不落库**

### 2. SQLite 状态层(常开,最富结构化数据)— `state.db` schema v26

内容取证能力(强):
- `messages` 全量:工具参数全文(tool_calls JSON)+ 结果全文(54KB 级)+ reasoning + api_content 字节级 sidecar
- rewind/compaction **软删除保留**(active=0 / compacted=1,rewind 注释明言 "for forensic inspection")
- FTS5 三索引(unicode61/trigram/CJK bigram),压缩行仍可搜
- delegation/delivery 台账(async_delegations / delivery_obligations)
- session 级:end_reason、token 五桶累计、cost、压缩健康计数器

遥测盲区(弱,全部 0/12665 行实测):
| 缺口 | 实证 |
|---|---|
| per-call/per-turn token 时序 | 只有 session 累计 + (model,task) 聚合的 first_seen/last_seen 包络 |
| `messages.token_count` | **死列**,live 路径从不写(仅 portability 写) |
| `effect_disposition` | **死列**,run_agent.py:2341 flush 时漏传 |
| 工具 duration/status/error_type | 只进 in-process hook,不持久化 |
| 错误一等记录 | 无 is_error 列;4308/6543 工具行靠文本模式识别;API 错误只有 request_dump_*.json 磁盘文件 |
| per-message 模型归属 | 无列;session 中途 /model 切换不可见 |
| 压缩审计表 | 无;compression_attempt 遥测 dict 富数据 log-only |
| export 盲区 | `sessions export` 默认 active-only,**压缩/rewind 行被排除,「完整导出」≠取证导出** |

### 3. opt-in 侧翼通道(默认全关)

- OTLP export:16 个 gateway 健康 gauge + WARNING+ 日志桥接(内容替换为 "gateway diagnostic");**无 rate limit/断路器状态/token 年龄/发送失败指标**
- shared_metrics 本地 SQLite 计数器(model_route/task_run/tool_call/approval/skill)
- NeMo Relay hooks 面
- `hermes logs` CLI(正则解析纯文本)、dashboard `/api/logs` `/api/usage`、`/insights`(agent/insights.py)、`hermes debug share`

---

## 二、08-23 实战取证暴露的缺口(证据驱动)

按「系统缺 X → 被迫手工 Y → 补什么变 trivial」:

| # | 系统缺失 | 实战手工操作 | 补什么 |
|---|---|---|---|
| 1 | **无 turn/request 关联 ID** | 毫秒时间戳邻接 + chat_id 前 8 位跨 agent.log/gateway.log/errors.log 三方 join | turn_id 注入每行(机制已有:session_tag LogRecord factory);至少 inbound 行带 message_id(run.py:19014 现只打文本预览) |
| 2 | **token 无 issued_at/expires_at** | TTL 22.5–33.8h = mint 日志行 × token 文件 mtime × executions.db 三方 join | token JSON 存时间戳;或每次发送尝试都记 token age(代码已算 age,只在失败行打) |
| 3 | **错误分类结论覆盖真因** | 真因 WARNING(ret=-2 prepare failed)1-4ms 后被错误结论 ERROR(rate limited)覆盖;grep ERROR 拿到错的;executions.db 记 completed 空 error;jobs.json 单槽 last_delivery_error 被 cron list 渲染成 "⚠ rate limited"(08-14 起同错) | 分类决策一行化:`errcode=X → classified stale-session (not rate-limit) 依据=字面量`;executions 增投递 outcome 与 run outcome 分离 |
| 4 | **成功路径零日志** | 差分实验:手工 baseline(wc -l=9105 + 时间 + mtime)→ 触发 → 只读增量;服务端换发 token 靠手工 diff 两个备份文件 | per-send 成功 + latency INFO;refresh 行带触发原因(inbound/reconnect) |
| 5 | **断路器 CLOSE 是 DEBUG**(weixin.py:1864) | open→close 区间不可重建 | CLOSE 升 INFO,带 open 时长 + 吞掉的事件数;threshold=1 默认仍待修(根因,另案) |
| 6 | **多 chunk 部分投递无日志** | 事故(a)「说一半断」在 gateway.log 零痕迹(chunk 成功不打,失败不带 n/m) | chunk index/total、已送达字符数、SendResult.partial 标记 |
| 7 | **媒体发送不检查响应码**(weixin.py:2279-2375) | body 级 -14/-2 会被记成功 | _send_file 补 ret/errcode 检查,对齐文本路径 :1917 |
| 8 | **cron 投递日志分裂两文件** | scheduler 决策(agent.log)× adapter(gateway.log)只能按时间戳 join;job_id 不进 adapter 行 | COMPONENT_PREFIXES 加 cron.*;adapter 行带 job_id |
| 9 | **无 poll 心跳** | 入站健康 = 「没有 poll error」反推;typing 探针 2.5s 回复下不可判 | 低频 poll last-success 心跳(带时间戳) |
| 10 | **5 种时间格式并存** | 本地无时区 ms / ISO+08:00 μs / epoch s / epoch REAL / epoch 厘秒手工换算 | 统一 ms + 时区(#89155 已提) |
| 11 | **纯文本混装饰行** | 592/9272 行(6.4%)banner/emoji 行会打断严格 parser;gateway.error.log 部分行无时间戳 | JSON opt-in formatter(#75458 已提);stdout banner 与日志分离 |
| 12 | **rotation 依赖运气** | gateway.log 5-8 月历史只因量小没触 5MB cap;agent.log.1 已在 08-16 截断 | 取证时段保留策略/或日志落 DB |
| 13 | **WAL DB 第三方打不开** | immutable=1 只读(有 stale 风险),叠加 WAL-reset 腐败警告(#69784 家族)劝退现场分析 | 官方只读快照工具(如 sqlite_safe_read.py 已上游化,推广) |
| 14 | gateway PID/uptime 不在日志 | ps + gateway-starts.log 裸 epoch + delivery_obligations 厘秒三方对 | 启动 banner 记 pid + start epoch |

另:weixin.py 代码内已有 #77368/#79851/#83993 引用的 diagnostic 遗迹(`[diagnostic]` 原始响应行、`_is_stale_session_ret` 消歧、`_ilink_api_counts` 配额归因)——**上游认可这条链路的取证需求,继续在这条线上提 PR 有先例可循**。注意代码注释 TTL "~21-24h" 与实测 22.5–33.8h 有出入,可顺手 reconcile。

---

## 三、上游 issue 版图(2026-08-23 核实)

### 无人占坑(open 且无关联 PR)——机会区

| Issue | 内容 | 评论 | 与实战缺口对应 |
|---|---|---|---|
| **#6741** | 结构化 session trace(start_ts/end_ts + duration_ms + 父子 ID + 瀑布图 demo) | 4 | 缺口 1/§二.5(DB 无 timing);人类原声需求 |
| **#75458** | 日志格式标准化、机器可解析、production-ready | 0 | 缺口 11 |
| **#89155** | config 驱动格式:ms 时间戳、线程 ID、logger name、per-file level | 0 | 缺口 10 |
| **#90115** | MCP wire-frame opt-in JSON-RPC tap(mcpsnoop 模式) | 0 | 独立 |
| **#24690** | gateway/platforms **129 处 print() 换正规 logging** | 0 | 缺口 11 同族;机械量大,适合分批推 |
| #6642(伞) | 统一遥测:latency/cost/outcome 分类学 | 多 | 挂靠点,别直接做伞 |

社区先例(评论里):TokenTelemetry(外置仪表盘,靠解析 agent.log 文本行)、hermes-telemetry 插件(hook 面抓 per-call)——**证明需求真实存在且核心未满足**。

### 已有 PR 排队(勿撞车)

#65074(file logging opt-out →#65097/#44270)、#91348(RedactingFormatter 崩溃→#91352)、#88895(gateway.error.log rotation + Slack 重连刷屏→#89170/#89536)、#61409(日志注入→#61411)、#55341(stale handler level→#55342 salvage 路径)、#59997(EIO→#60012)、#57749(dashboard-auth rotation→#57750)、#59061(root 级脱敏→#59162 salvage)、#83750(API_SERVER 静默拒绝→#83826)。

---

## 四、缺口 → 贡献切入点映射(优先级)

**第一梯队:实战缺口 × issue 已存在 × 无 PR × 改动小**

1. **turn_id / message_id 进日志行**(#6741 子集 + #75458 前置)
   - 落点:hermes_logging.py LogRecord factory 已有 session_tag 机制,正交扩展;run.py:19014 补 message_id
   - 治:08-23 取证最痛的跨文件 join
2. **错误分类决策一行化 + weixin 补 error_kind**
   - 落点:base.py:2565 `classify_send_error` 词表已有(rate_limited 等),weixin 从不设置;`_is_stale_session_ret` 分类后打一行依据
   - 治:「错误结论覆盖真因」(事故 b 根因链)
3. **投递结果一等化:chunk n/m + partial 标记 + 成功 latency**
   - 治:事故 a「说一半断」零日志
4. **cron.scheduler 归入 gateway.log 组件前缀 + adapter 行带 job_id + 投递 outcome 与 run outcome 分离**
   - 治:双文件 join + executions.db 说谎

**第二梯队:schema 层(#6741 主体)**

5. per-call 时序持久化(messages 增 duration_ms/model 或 events 表;顺手修 token_count、effect_disposition 两个死列)
6. compaction 审计落表(compression_attempt dict 已富,只是 log-only)

**第三梯队:格式层(#75458/#89155)**

7. `logging.format: json` opt-in formatter
8. 时间戳统一 ms + 时区

**第四梯队:独立/机械**

9. #24690 print()→logging(分批,sweeper 式推进)
10. #90115 MCP frame tap

**路径建议**:按 hermes-contribution.md 结论——issue 先行。1/2/3/4 都可以先发「带 08-23 取证证据的 issue」(时间线图 + 手工 join 的痛苦展示),再挂小而正交的 PR;weixin diagnostic 先例(#77368/#79851/#83993)证明这条链路的 PR 上游会收。#35283(微信限流族)重开弹药与本清单第 2/3 条天然同轴。

---

## 附:审计方法

4 路并行 Explore agent:①日志基础设施(103 tool uses)②SQLite 状态层(108)③网关链路逐决策点(61)④事故取证包反推(40);上游 gh CLI 核实 issue/PR 占坑。源码引用均为 file:line 可复核。
