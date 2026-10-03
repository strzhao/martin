# 港股信号取数路径取舍推荐（t_b9a01d43，2026-10-03）

## 结论

**推荐方案 2：mktd `daily` 增加港股分支**（5 位纯数字 symbol → 补零归一化复用 `normalize_hk_symbol` → akshare `stock_hk_daily`）。若不批 mktd 契约增量，fallback = 方案 1b（martin 侧直连 akshare），代价见对比表。

## 问题（两 bug + 一口径发现，均已实证）

1. **Bug 1（本报告主题）**：`signal_review.py` 对所有 symbol 一律调 `mktd daily <symbol>`；港股代码（00700/00175/01024）被 mktd `normalize_a_symbol` 拒绝——实测报 `mktd: 无法识别的 A 股标的: 00700`、exit≠0 → 脚本得 `[]` → 信号 undetermined。mktd 契约 §2 本就只锚定 `daily` 为 A 股日K，港股仅有 `mktd hk` 实时快照（无日K）。生产实证：窗口 31 条方向性信号 30 条港股，全部取数失败。
2. **Bug 2（已修，非本报告范围）**：mktd daily JSON records 实际键为 `timestamp`/`price`，脚本只找 `date`/`close` 系键 → A 股也解析不出。本卡 T1 已按契约插入 fallback 键（既有键全保留），301308 已验证可解析出 (date, close) 升序序列。
3. **口径发现（非 bug，影响验收预期）**：31 条方向性信号全部 position(T+20)，最老 2026-09-14，截至 10-03 无一条到期（T+20≈28 个日历日）→ 即使 Bug 1 修完，本期命中率仍几乎全 undetermined，最早 10 月中下旬起逐步可判。这是预期行为，不是修复失败。

## 两案对比

| | 方案 1b：martin 直连 akshare `stock_hk_daily` | 方案 2：mktd daily 增港股分支 |
|---|---|---|
| 改动位置 | martin 仓 signal_review.py | mktdata 仓（martin 侧零改动） |
| 取数通道 | 破坏「只经 mktd 取数」架构惯例，第一处破口 | 保持单一取数通道，契约内能力增量 |
| 限流治理 | martin 自担 akshare 限流，与 mktd 侧双处治理、必然漂移 | 复用 mktd 既有 `rate_limit_qps` 匀速限流 |
| 缓存 | martin 自建或裸连（重复拉取） | 复用 mktd 既有 SQLite 缓存 |
| 依赖性质 | signal_review.py「零第三方依赖」声明作废 | martin 仍零三方依赖 |
| 港股日K能力 | akshare 现成 | 同一数据源，封装进 mktd |

## 推荐理由（方案 2）

- 「只经 mktd 取数」是 martin 侧已声明的架构边界（脚本自述零三方依赖、行情统一走 mktd 子进程）。1b 是对边界的第一次破坏，且 hkstock 后续每个取数消费方都要重复踩同一步。
- 限流与缓存是 mktd 已封装好的机制（契约 §3）；1b 让同一数据源两仓各治理一次限流，QPS 口径必然漂移——港股信号复盘是批量取数（一次 30+ symbol），恰是限流最敏感的形态。
- 契约 §6「原则上不改」针对的是既有锚定语义的翻案；本项是**能力增量**（`daily` 新增港股分支），不改 A 股 daily 既有行为一字一句，属增量不是翻案。

## 落地前置条件（缺一不动）

1. **用户拍板**（mktd 契约变更授权点；用户 10-06 回）。
2. mktdata CONTRACT.md §2 增能力增量条目：`daily` 接受 5 位纯数字 → 补零归一化（`normalize_hk_symbol`）→ `stock_hk_daily`；§3 机制沿用条目（限流/缓存照旧）。
3. mktd tests/ 补港股分支用例，含归一化边界（`700` vs `00700` vs `0700`）。
4. martin 侧零改动即受益（港股信号自动走通 fetch 路径）；signal_review.py 无需新代码。

**Fallback（用户不批）**：方案 1b 落 signal_review.py——需同步撤回头注释「零第三方依赖」声明，并接受限流双处治理；改动前先用最小探针验证 akshare `stock_hk_daily` 的真实返回字段（防重蹈 Bug 2 字段名错映射）。

## 事实锚

- `~/workspace/mktdata/CONTRACT.md` §2（daily 仅锚定 A 股日K；港股仅 `mktd hk` 实时快照无日K）/ §3（rate_limit_qps + SQLite 缓存机制）/ §6（契约稳定性约定）——2026-10-03 只读取证，mktdata 仓零改动。
- 运行时实测 `mktd daily 301308 --format json`：顶层 `{"cache","count","cmd","days","records":[...]}`，records 元素 `{"symbol":"sz301308","price":312.0,"timestamp":"2026-09-28","open","high","low","volume"}`。
- 运行时实测 `mktd daily 00700`：`mktd: 无法识别的 A 股标的: 00700`。
