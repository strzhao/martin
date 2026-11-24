# 取数速查（health-bridge MCP）

## 连接

- MCP 服务器名 `health-bridge`。工具全名是 `mcp__health_bridge__<工具名>`，例如 `mcp__health_bridge__get_sleep_report`。下文省略前缀。
- 全部只读。数据 = 本机 receiver 的 SQLite 真源。用户时区 `Asia/Shanghai`。

## 先看有什么

- `get_bridge_status`：库内计数、最近同步时间。怀疑数据断流先看这里。
- `list_synced_metrics`：每个指标现有多少条、起止时间。没有的指标就是没采到，别硬算。

## 睡眠（按本地日界，优先用）

- `get_sleep_report`：某个「醒来日」的全部睡眠段，含碎片睡眠和小睡。早班看昨夜：`timezone: "Asia/Shanghai"`，`local_date` 传**今天**（醒来那天就是今天），或直接省略（默认 = 查询时刻的本地今天）；`include_intervals: false`。
- `get_latest_sleep_period`：某个时刻之前最近的一段睡眠。参数 `timezone` + `reference_time`（UTC 时刻）。

## 恢复与活动指标

- 稀疏指标（`resting_heart_rate`、`heart_rate_variability_sdnn`、`skin_temperature`、`respiratory_rate`）用 `get_timeseries`：参数 `type_codes`（数组）+ `start_time` / `end_time`（UTC，`YYYY-MM-DDTHH:MM:SSZ`，左闭右开）。单次最多 500 点，超出会标 `truncated`；这类指标量小，7 天够用。
- 已经过完的天的合计用 `get_daily_summary`（参数 `start_date` / `end_date`，`YYYY-MM-DD`，左闭右开）。样本特别密的指标（如 `energy`）在 `get_timeseries` 里会被 500 点截断，只能靠它。
- 锻炼用 `get_workouts`：`start_date` / `end_date`，左闭右开。
- 晚班要看**今天**的负荷：今天还没过完，日汇总里没有今天。改用 `get_timeseries` 取今天这段（`exercise_time`、`steps` 量小，够用），锻炼看 `get_workouts`。

## 日界陷阱

- 按天的三个工具（`get_daily_summary`、`get_workouts`、`get_sleep_summary`）切的是 **UTC 日**，不是本地日：`start_date="2026-11-23"`、`end_date="2026-11-24"` 查的是 UTC 的 11-23。起止同一天返回空。
- 本地一天（11-23 00:00 ~ 24:00，+08:00）对应 UTC `11-22T16:00Z ~ 11-23T16:00Z`，横跨两个 UTC 日。要某个**本地日**的量，别用按天的工具，用 `get_timeseries` 取 `start_time=<本地日 00:00 对应的 UTC>`、`end_time=<次日 00:00 对应的 UTC>`，自己加总。超过 500 点加不了的指标，就用按天工具的结果，并在结论里注明这是 UTC 日界的近似。
- 时间参数只认 UTC 的 `Z` 结尾格式，不接受带偏移的本地时间。

## 指标码

采集端会增减指标，以 `list_synced_metrics` 的实时结果为准。睡眠是会话不是样本，不在 `get_timeseries` 里。
