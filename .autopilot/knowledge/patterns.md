# 工程模式与教训

## 2026-06-18 — 限流反复发作根因：typing 高频累积（成功不打日志）+ cooldown 只防"限流后"不防"限流前" + 可观测性缺失

<!-- tags: api, rate-limit, debugging, messaging-adapter, typing, observability, hermes -->

**场景**：限流问题第 5 次修复。前 4 次都修"限流后善后"（cooldown 门控、retry 对齐），从未碰"为什么限流"。诊断历经"流式新消息→interim 思考片段→typing"三轮推断（前两次被代码 + 用户实测推翻——微信直接模式 raise 跳过流式；用户从没见过思考片段），最终靠 **3 分钟日志空白**（typing 成功不打 INFO）+ 代码机制（`_keep_typing` while True）+ reproducer 坐实：**typing 高频累积**。

**教训**：
1. **后台定时器（typing/keepalive）成功时不打日志，是隐藏的限流源**。排查时"限流窗口内的日志空白"本身就是线索——某高频调用成功不打日志。审计所有 `while True` 后台循环的调用频率，不只看失败日志。
2. **cooldown 门控只防"限流后"（`_rate_limited_until` 已设），不防"限流前"高频累积**。typing 每 3s 打 86 次，在限流**前**就打满配额。治本要对调用源加**主动上限**（`_typing_max_calls`），而非只靠限流后 cooldown。
3. **错误码分类逻辑要基于实测，不能靠注释假设**：`_is_stale_session_ret` 把 `ret=-2 + 空 errmsg` 当 session expired → tokenless retry → 在已限流时多打一次 → 升级成真限流（放大器）。实测 retry 后仍 -2 = rate limit，非 stale token。日志实证 14/14 关联。
4. **可观测性缺失是反复排查的元凶**。typing/sendmessage 成功不打日志，限流时日志不知触发源 → 三轮推断。治本：内建调用计数（per-run 重置，`on_processing_start`）+ 限流实锤 WARNING（"sendmessage #N / typing #N 触发"）。**投入可观测性 << 反复排查成本**——这是本次最重要的元教训。

**证据**：
- gateway.log `19:32:21→19:35:22` 整整 3 分钟空白（typing 成功不打 INFO），突然 session expired + rate limited
- `_keep_typing`（base.py:1978）`while True` 每 `_typing_interval_seconds` 调 `send_typing` → iLink sendtyping，260s 任务 ≈ 86 次
- `_is_stale_session_ret`（weixin.py:138-145）把 ret=-2+空 errmsg 当 session expired，全天 14 次 session expired 100% 紧跟 rate limit
- 修复（commit 2053ad7de）：typing 总次数上限（`_typing_max_calls=30`，间隔 5s 对齐 spec §7.2）+ 移除 `_is_stale_session_ret` 误判（真 -14 仍 tokenless retry）+ 结论必达有界重试（`_send_with_retry` rate limit 分支等待 cooldown 重试）+ iLink 调用计数（`on_processing_start` per-run 重置）+ 限流实锤 WARNING
- 关联 [[2026-06-17]]（cooldown 门控，本次补"限流前"主动上限）[[2026-06-13]]（DEBUG 后台定时器消耗配额，本次深化 typing 是隐藏源）

**修复模板**（typing 高频限流根治）：
```python
# ❌ 只防限流后：typing 在限流前 86 次打满配额
def send_typing(self, chat_id):
    if time.time() < self._rate_limited_until: return  # 只防限流后
    await _send_typing(...)  # 限流前每 3s 打，86 次打满

# ✅ 主动上限 + 可观测性：从源头控配额 + 实锤日志
def __init__(self):
    self._typing_max_calls = 30           # 主动上限（限流前就控）
    self._ilink_typing_count = 0          # per-run 计数（实锤用）
async def on_processing_start(self, event):  # run 开始重置 → #N 是 per-run
    self._ilink_typing_count = 0
async def _keep_typing(self, ...):
    _count = 0
    while True:
        if _count >= self._typing_max_calls: return  # 主动上限
        await self.send_typing(...)  # 内部 _ilink_typing_count += 1
        _count += 1
```

**红队 test harness 教训**（顺带）：`@patch("base.asyncio.sleep")` 会污染全局 asyncio.sleep（base.asyncio 即 asyncio 模块），破坏 `asyncio.wait_for` 调度 + 让 drive 的 sleep 也被 mock。正确做法：用极小 interval（0.001）+ 真实时钟，而非 patch sleep 加速；只数 TYPING_START 排除 finally stop_typing 的 TYPING_STOP。

## 2026-06-17 — 限流 cooldown 门控须 sleep 后重新检查时间（mock-sleep 测试盲区）

<!-- tags: api, rate-limit, testing, asyncio, messaging-adapter, debugging -->

**场景**：异步消息适配器（如微信 iLink）用 `await asyncio.sleep(remaining)` 实现"限流冷却期内挂起等待，过期后再发"的门控。单元测试按项目惯例 `@patch asyncio.sleep`（AsyncMock，立即返回）加速，但不 mock `time.time` 推进真实时间。

**教训**：sleep-based 等待依赖 sleep 的"真实阻塞"副作用来阻止后续调用。当 sleep 被 mock 立即返回时，门控失效——代码继续执行并打外部 API，再次触发限流，形成自激振荡。**正确的门控必须在 sleep 返回后重新检查 `time.time() < deadline`，若仍在冷却期则不调用外部 API（返回失败/跳过）**。同一 bug 的另一根因：限流冷却状态字段（`_rate_limited_until`）只在 typing 路径检查、发送主路径不检查，冷却形同虚设——门控必须在所有对外调用入口生效。

**证据**：
- Hermes weixin.send() 入口最初只 `if now < _rate_limited_until: await asyncio.sleep(remaining)` 后继续——红队 mock-sleep 测试发现冷却期内 `_send_message` delta=1（风暴未止息）
- 加 sleep 后 re-check 守卫（仍冷却则返回失败不打 iLink）后 delta==0，4 个核心谓词（S1.P1/P3、S3.P1、S6.P1）转绿
- 现有 30 个单元测试挡不住第4次复发，因为只验证单函数行为，未覆盖"send 入口门控 + stream_consumer 跨层重试"整条链路——**限流类 bug 必须用跨层集成测试 + 调用计数 delta==0 谓词验收，单元测试不够**

**修复模板**：
```python
# ❌ 只 sleep 后继续：mock-sleep 下门控失效，继续打 API 再次限流
if time.time() < self._rate_limited_until:
    await asyncio.sleep(self._rate_limited_until - time.time())
# 继续调外部 API...

# ✅ sleep 后重新检查，仍冷却则不打 API（生产/测试都正确）
if time.time() < self._rate_limited_until:
    await asyncio.sleep(self._rate_limited_until - time.time())
    if time.time() < self._rate_limited_until:
        return SendResult(success=False, error="[RATE_LIMITED] deferred")
# 生产：sleep 真实阻塞→过期→继续；测试：sleep mock→re-check 守卫阻止打 API
```

## 2026-06-13 — DEBUG 级别的后台定时器静默消耗 API 限流配额

<!-- tags: api, rate-limit, debugging, heartbeat, messaging-adapter -->

**场景**：排查 API 限流（rate limit）问题时，主业务请求（如发送消息）被限流，但用户的使用频率正常，无明显高并发。

**教训**：当 API 客户端有后台定时器（如 typing 指示器、keepalive、心跳）以 DEBUG 日志级别运行时，这些调用可能在日志中完全不可见，但仍然计入 API 限流配额。长时间运行的任务（如 LLM 推理 5 分钟）会产生数百次后台 API 调用，耗尽配额后再发起的主业务请求必然被限流。排查限流问题时，应优先审计所有后台定时器/静默活动，而非仅检查用户可见的业务调用。

**证据**：
- Hermes Agent WeChat 适配器：`_keep_typing()` 每 2s 调用 `send_typing()`，失败仅记 DEBUG 日志；一次 268s agent run 产生 134 次 `sendtyping` API 调用，加上 12 次 `sendmessage`，一小时超 730 次 iLink API 调用
- 日志中首次限流（`ret=-2`）发生在 agent 响应就绪前 30s，说明 typing 而非主回复触发了限流
- 修复：`send_typing` 添加 `_rate_limited_until` 冷却检查，限流期间跳过 typing，切断配额消耗

## 2026-06-11 — TypeScript fetch body 类型冲突：RequestInit.body 与强类型请求体

<!-- tags: typescript, fetch, nodejs, tsc -->

**场景**：在 TypeScript 中封装 HTTP API 调用时，`fetch` 的 `RequestInit.body` 类型为 `BodyInit | null`，无法直接传入强类型的请求体对象（如 `ChatCompletionRequest`），即使实际运行时 `JSON.stringify` 已将其转为 string。

**教训**：不要用 `RequestInit` 作为参数类型再扩展 `body?: unknown`——两者的 `body` 类型会冲突。正确的做法是使用 `Record<string, unknown>` 中间变量构建请求参数，最后 `as RequestInit` 传给 `fetch`。

**证据**：
```
src/lib/api.ts(83,72): error TS2322: Type 'ChatCompletionRequest' is not assignable to type 'BodyInit | null | undefined'.
```
修复：将 `{ headers, body: JSON.stringify(body), signal } as RequestInit` 改为先构建 `Record<string, unknown>` 再 cast。

**修复模板**：
```typescript
// ❌ 错误：RequestInit & { body?: unknown } 的 body 仍冲突
async function apiFetch(path: string, options: RequestInit & { body?: unknown }) { ... }

// ✅ 正确：独立类型 + Record 中间变量 + as cast
async function apiFetch(path: string, options: { method?: string; body?: unknown; signal?: AbortSignal }) {
  const init: Record<string, unknown> = { headers, signal: controller.signal };
  if (options.body !== undefined) init.body = JSON.stringify(options.body);
  const res = await fetch(url, init as RequestInit);
}
```

---

## 2026-07-16 — 改 hermes display 平台默认值要追到 display_config.py tier 系统，run.py default= 是末端 no-op 陷阱

<!-- tags: hermes, display, config, contribution, no-op, tier-system, plan-reviewer -->

**场景**：想给微信/QQ 等"无编辑能力平台"默认关 `interim_assistant_messages`。第一反应改 `gateway/run.py:15991` 的 `_resolve_gateway_display_bool(..., default=...)`。plan-reviewer（独立读代码）+ 实测发现是 **no-op**——上游 `display_config.py` 早已把微信归入 `_TIER_LOW`（interim=False），`default=` 是 4 层查找链最末端、被 tier 提前命中、永不到达。差点提交一个"改前后无差异"的 PR（必被 reviewer 拒）。

**教训**：
1. **`resolve_display_setting` 是 4 层查找链**：①`display.platforms.<p>.<k>`（显式平台 override）→ ②`display.<k>`（全局）→ ③`_PLATFORM_DEFAULTS[platform]`（tier 系统，display_config.py:106）→ ④`_GLOBAL_DEFAULTS` → 最后才调用方传的 `default=` 参数。**改平台默认值的正确位置是 ③（tier 系统），不是 run.py 调用方的 `default=`。**
2. **实测优先于读代码推断**：`.venv/bin/python -c "from gateway.display_config import resolve_display_setting; print(resolve_display_setting({}, 'weixin', 'interim_assistant_messages'))"` 直接看真实默认值（→False），比顺着 run.py 一路读更快证伪。改默认值前先实测当前值。
3. **plan-reviewer（独立子 agent 读代码）能救命**：编排器只追溯到 run.py 就以为是 `default=` 生效；审查 agent 才发现 display_config.py tier 系统更上游。复杂/开源贡献必须有独立审查层。
4. **用户 config 显式值覆盖一切**：用户 `config.yaml` 显式 `interim_assistant_messages: true` 是第 ①②层，优先于 tier。诊断"某平台行为异常"时先查用户显式配置，别只盯代码默认。
5. **唯一真实 gap = 漏配**：qqbot 是唯一 `SUPPORTS_MESSAGE_EDITING=False` 但 `_PLATFORM_DEFAULTS` 无条目的平台（→ 落 GLOBAL 默认 True）。配置表遗漏是干净可贡献点。PR #65100。

**证据**：
- `display_config.py:143` `"weixin": _TIER_LOW`；`_TIER_LOW` 含 `interim_assistant_messages: False`（:91）
- 实测 `resolve_display_setting({}, 'qqbot', 'interim_assistant_messages')` 改前 True（漏配→GLOBAL）、改后 False（→_TIER_LOW）
- plan-reviewer 报告 BLOCKER；改方向后 PASS；PR https://github.com/NousResearch/hermes-agent/pull/65100

**附：workflow scope 坑**（fork→upstream PR）：feature 分支若基于 upstream main（含 `.github/workflows/ci.yml` 历史改动），push 到 fork 时 GitHub 要求 token 有 `workflow` scope（`gh repo sync` 同样要求）。解法：`gh auth refresh -h github.com -s workflow` 一次性加 scope，之后 sync+push+pr 一气呵成。

关联 [[2026-06-18]]（hermes 限流贡献，本次是 display 默认值不同主题；共同元教训：实测优先 + 独立审查）。

---

## 2026-07-17 — gateway 改 final 回复内容要注入到 _handle_message_with_agent 末端（footer 后/return 前），_run_agent_inner 的 final_response 取出点是中间会被再加工

<!-- tags: hermes, gateway, injection-point, no-op, response, contribution, plan-reviewer -->

**场景**：要给 gateway 最终回复 prepend 一行图片处理状态（📎 已识别/⚠ 失败）。第一反应注入 `run.py:19683` `final_response = result.get("final_response")`（`_run_agent_inner` 内）。plan-reviewer 第1轮 + 编排器亲自读 run.py:12060-12613 发现是**中间点非出口**——其后 response 还要经 `_handle_message_with_agent` 的 normalize(12136)→sanitize(12139)→**reasoning prepend(12186，`response = f"💭 Reasoning...\n\n{response}"` 会在前面插)**→footer append(12241) 四道再加工。在 19683 prepend 会被 reasoning 插到前面，破坏"状态行首行"语义。

**教训**：
1. **gateway final response 发送链是多层**：`_run_agent_inner`(19683 取出) → `_handle_message_with_agent`(12070 再取出 + normalize/sanitize/reasoning-prepend/footer-append + 12613 return response) → base.py 发送。**改 final 回复文本的注入点要在 `_handle_message_with_agent` 所有后处理之后（footer append 12241 后）、`return response`(12613) 前**，不是 `_run_agent_inner` 的取出点。
2. **与 [2026-07-16] no-op 陷阱同构**：都是把多层链的"中间点"误当"出口/生效点"。display 是 4 层查找链末端 default= 被 tier 命中；本次是 response 处理链末端被 reasoning-prepend/footer 再加工。**改 hermes 输出内容前，先追完整条处理链到真正发送出口（grep `return response` + 顺流读后处理）**。
3. **MEDIA append(19847) 是 append 先例但不可类比 prepend**：MEDIA 标签语义稳定（下游 `extract_media` 识别），位置不敏感；纯文本状态行位置敏感（必须首行），对再加工零容忍。**append 先例 ≠ prepend 安全**。
4. **流式平台 already_sent(12589) return None**：流式回复不返回 response（已流式发送），prepend 不显示。声明为已知限制（流式平台主模型多为 native 不降级），**不蹭 footer 的 trailing-send**（那样破坏"零额外 gateway 消息"红线，加重 iLink 限流）。

**证据**：
- run.py:12186 reasoning prepend（在 footer 前）；run.py:12241 footer append；run.py:12266-12282 图片反馈 prepend（正确注入点）；run.py:12613 return response
- plan-reviewer 第1轮 BLOCKER B1 → 编排器修正 → 第2轮 PASS（亲自读 12060-12613 验证 12241→12613 区间仅 12386 append 不破坏首行）
- PR https://github.com/NousResearch/hermes-agent/pull/65794

**附：红队 xfail 信号 + 编排器修复**：红队对 `build_image_feedback_line` 的 cfg 形式参数化标 xfail，暴露 `_read_main_model_name` 漏 `cfg["model"]["model"]` 形式（run.py:2481-2487 single-source resolver 支持三形式：str / `["default"]` / `["model"]`）。编排器对齐 resolver 修复 + 清理红队过时 xfail 标记 → 31 passed。**红队 xfail 是有价值的"待修复信号"，别当 pass 忽略；修后要清理 xfail 标记让测试干净**。

关联 [[2026-07-16]]（no-op 注入点陷阱同构，本次是 response 链）。

---

## 2026-07-19 — hermes PR 迭代：先 rebase main（main 会漂移）+ sweeper 引用的 commit 常是 maintainer 已做的

<!-- tags: hermes, contribution, rebase, sweeper, main-drift, PR-iteration -->

**场景**：PR #65794（图片反馈层）提后 sweeper 给 keep_open/medium 3 问题，其中 Problem 1（模型名读 `_RUNTIME_MAIN_MODEL`/`load_config` 过时）引用 commit `73057ed16`。查证：feat(2724ccbab) 落后 origin/main(7235592ad)，merge-base 659d1123c；`73057ed16` 是 maintainer（Teknium = sweeper 作者 teknium1）提的 `fix(auxiliary): scope runtime state to each turn`，改了 image_routing.py/run.py/auxiliary_client.py/run_agent.py（与 feat 同批文件）。

**教训**：
1. **PR 迭代先 rebase main**：feat PR 基于 main，main 持续演进。更新 PR 前必 `git fetch origin main && git rebase origin/main`，解冲突后 `push --force-with-lease`。feat 落后 main 时 sweeper 会基于最新 main 认知挑"用旧机制"。
2. **sweeper 引用的 commit 常是 maintainer 自己的改动**：sweeper 作者 teknium1 = maintainer Teknium，它引用的 commit 往往是 maintainer 已做的同类修复——**rebase 后 main 可能已给一半答案**。本案 `73057ed16` 已在图片路由时调 `_resolve_session_agent_runtime` 拿 turn_model + `scoped_runtime_main` 包裹；feat rebase 后只需"路由时存 turn_model 到 status，render 用 captured"（sweeper 建议方向）即解 Problem 1。
3. **rebase 冲突解决：保留双方机制**：main 机制改动（`scoped_runtime_main` 包裹）+ feat 业务改动（`session_key` 旁路记录）可共存——plan-reviewer 验证 `_record_outcome` 在 scoped 块内可用、不覆盖 captured `main_model`。
4. **main 的测试 mock 要适配新参数**：feat 给 `_enrich_message_with_vision` 加 `session_key` → main 测试 `fake_enrich` mock 签名加 `session_key=None`（rebase 副产物，断言语义不变）。
5. **sweeper 红线复现**：source-shape 测试（`inspect.getsource` 读源码）违反 AGENTS.md:1380——写"真实验证"时别用 inspect.getsource 证明注入点，改 behavior 测试（[[hermes-contribution-followups]] sweeper 红线同源）。

**证据**：PR #65794 commit e1316af09；rebase 2724ccbab→e1316af09；73057ed16 stat（image_routing +4 / run.py +28 / auxiliary_client +78）；修复后 159 passed。

关联 [[2026-07-17]]（同 PR 注入点教训，本次是迭代流程）+ [[hermes-contribution-followups]]（sweeper 红线）。
```

## [2026-08-14] FTS5 跨引擎索引不一致：engine-version 门控检测 + 测试 fabrication 两个坑
<!-- tags: hermes, sqlite, fts5, contribution, testing, fabrication, state-db -->

**场景**：hermes #86027——SQLite 升级（3.46.1→3.5x）后 legacy inline FTS5 trigram 表被判 `malformed inverted index`，但 MATCH/触发器写全正常 → 启动零报错、malformed 静默携带。根因：content 含嵌入 NUL 时 trigram tokenizer 跨引擎行为变更，**任一引擎只认自己写的索引**（对称验证：老引擎也拒新引擎写的同内容索引）。

**解法模式**：`state_meta` 存上次验证通过的 `sqlite3.sqlite_version`（`fts_integrity_engine`），引擎变更时才对每个 fts 表跑 FTS5 `'integrity-check'` 特殊命令，失败→`'rebuild'`（普通 inline 表也可用，从 `%_content` 影子重分词）+复核。门控永不炸打开（整体吞 `sqlite3.Error` 转日志）；无验证能力的宿主（探针 None / 无 FTS5）不盖 marker——不替同引擎 capable 宿主背书。

**fabrication 两坑（CI 无老引擎时怎么造这个状态）**：
1. ❌ 删 `%_content` 影子行——能让 `'integrity-check'` 炸，但 `'rebuild'` 从 `%_content` 重分词 → 该行永久丢失（MATCH 2→1），"修复后命中数保持"断言必挂。红蓝两队独立收敛到同一结论。
2. ✅ DEADBEEF 覆写 `%_data` 块——索引坏但内容在，`'rebuild'` 完整复原。另：破坏操作须与触发器写入分事务提交，否则 commit 本身在 fts5 一致性检查里炸。

**教训**：修 FTS5 索引类问题先做"repair 命令从哪重分词"的语义实验（orphan 行实验：drop 触发器插孤儿行再 `'rebuild'`，孤儿仍缺失=从影子表而非业务表重建），直接决定测试 fabrication 与修复方案选型。

---

## [2026-08-15] hermes 开源贡献：认领 issue 方向前先搜 referencing PRs + 共享线程池 idle 复用破坏 patch 窗口 + 上游无 format 门别全文件重排
<!-- tags: hermes, contribution, pytest, test-isolation, thread-pool, mock, ruff, CI -->

**场景**：#83993（cron 投递可观测性）公开认领方向 1+2 后开工，才发现 PR #84006（早认领 3 天）已实质覆盖同领域 → 转向互补缺口（修完成通知谎报）交付 PR #86622。过程中踩两个工程坑：

**坑 1 — 认领前不搜 referencing PRs**：与 [08-03 GottZ 教训]（cron 只查 issue state 不查 comments 漏掉跨 PR 收敛评论）同构的第三变体：**查 issue 活动必须三件套——issue comments + `gh pr list --search "<N> in:body"`（谁在 body 里 closes/salvages 它）+ 关联 PR 的 review**。本案 #84006 在 issue 里零评论、只靠 body 里 `Closes #83993` 关联，漏看即重复认领。

**坑 2 — 共享 DaemonThreadPoolExecutor 的 idle 线程复用改变 mock 可见窗口**：新测试文件先跑 → 向进程级共享 executor（`tools/async_delegation._executor`，跨测试不重置）提交过 worker → idle token 残留 → 后续文件的 dispatch 复用 idle 线程（submit 瞬返、主线程不放开 GIL）→ 邻居测试 patch 退出后线程才 lazy import 绑到**真实函数** → mock 被绕过、断言超时。而邻居单独跑能过是因为首次 submit 时 `Thread.start()` 阻塞调用方直至新线程 bootstrap，worker 得以在 patch 窗口内绑定 mock——**上游测试隐式依赖这个世界**。修复：autouse `_clean_state` fixture 调官方 `tools.async_delegation._reset_for_tests()`（拆 executor + 清 records），镜像 `tests/tools/test_async_delegation.py` 既有模式。**诊断抓手：顺序敏感 = 100% 确定性复现，用最小单进程实验（两轮同参数 dispatch）隔离出唯一必要条件（idle token 存在）**。

**坑 3 — 上游 CI 没有 format 门**：lint.yml 的 blocking 门仅 `ruff check .`（PLW1514），ruff+ty diff 是 advisory（--exit-zero）。全文件 `ruff format` 重排（261 行 diff 里 236 行格式噪音）纯属自找 sweeper「scope 不聚焦」。**贡献前先读目标 repo 的 CI workflow 分清 blocking/advisory；改大文件时 diff 精确收敛到语义改动（本案 +24/-5）**。

**证据**：PR #86622（commit d33bec590d）；#84006 协调评论 issuecomment-5300182324；坑 2 根因实验输出（round1 fresh spawn True / round2 idle reuse False + 同源 RuntimeError）。

关联 [[hermes-contribution-followups]]（贡献进度）+ [2026-07-19]（PR 迭代 rebase 教训，本案是其开工前变体）。

---

## [2026-08-16] macOS headless 浏览器 QA 产证链路（无 playwright 时的 probe 注入法）
<!-- tags: testing, headless, edge, chrome, qa, html, screenshot, autopilot -->

**场景**：travel-planner 模板重写 QA 需真浏览器渲染证据（computed 字号/触控高度/DOM 计数/截图），本机无 playwright/puppeteer/jsdom。纯 Chrome CLI 踩三坑后的可用链路：

**坑 1 — Chrome 151 headless 在已有运行实例下挂起**（即使独立 --user-data-dir）；换 **Edge headless**（同 Chromium CLI）+ 稳定 flags：`--no-first-run --no-default-browser-check --disable-background-networking --disable-component-update --disable-sync --mute-audio`（疑似首跑联网组件更新卡死）。

**坑 2 — Edge dump-dom 输出完整 DOM 后进程不退出**（macOS 已知 Chromium 类 bug）：`timeout -s KILL 20` 包裹，**以 stdout 以 `</html>` 结尾为成功哨兵**，rc 非零也接受。

**坑 3 — headless 最小窗宽 ~492px**，`--window-size=375` 被 clamp → 375px 移动视口验证全成假象（截图是 492 布局的左裁剪，文字"溢出"是伪缺陷）。解法 **iframe wrapper**：`iframe{width:375px;height:100vh}` 内视口真实 375（媒体查询按 iframe 宽生效），需 `--allow-file-access-from-files` 才能让 wrapper JS 读 contentDocument。精确裁剪：wrapper `display:flex;justify-content:center` + 窗口 501 宽 + `sips -c H 375` 中心裁剪（sips `--cropOffset` 会被忽略退化为居中，故用居中布局对齐）。

**probe 注入法**（无框架获取 computed/ACT 证据）：产物 HTML 的 `<head>` 后注入 error collector（`window.__qaErrors` + localStorage 预置/清除），`</body>` 前注入探针（DOMContentLoaded + setTimeout 60ms 后把 computed font-size/getBoundingClientRect/节点计数/click ACT 序列写进 `display:none <pre id="qa-probe">`），dump-dom 后正则提取 JSON。localStorage 跨 run 污染用每次独立 user-data-dir 隔离。

关联：QA artifact 实例见 `.autopilot/runtime/requirements/20260816-看下-travell-skill-里的-ht/qa/harness.py`。

---

## [2026-08-16] skill 产物副本的现场微调会分叉——模板能力必须回流 assets/ 源头
<!-- tags: skill, travel-planner, template, workflow, autopilot -->

**场景**：8/13 三亚行程把 `assets/template.html` 复制到 `output/sanya-template.html` 现场改出多日分组 day-divider 功能，但未回流权威模板；inject.py 只读 assets/ → 下一次多日行程会静默丢失该能力。8/16 模板重写时 diff 两副本才发现并合并回流。

**教训/How to apply**：
- skill 模板类微调**只改 `assets/` 源头**；`output/` 是一次性产物，改它等于改影子。
- 给这类 skill（travel-planner / restaurant-recommender 同架构）加功能前，先 `diff assets/template.html output/*-template.html` 查未回流分叉；schema 文档同步补字段（day/day_weather/subtitle 本次已补）。

**travel-planner 模板 backlog**（2026-08-16 QA 遗留，下次大改顺手处理）：① render 字符串拼接无 HTML 转义（数据自产风险低，加 10 行 escapeHtml）；② inject.py `json.dumps` 结果直接 replace 进 `<script>`，数据含 `</script>` 会闭合突破（治本：`json.dumps(...).replace('</','<\\/')`）；③ 预算按钮组缺 aria-pressed。

---

## [2026-08-17] 模板裸元素选择器 × JS 渲染语义标签 = 样式碰撞（header 白-on-白案例）
<!-- tags: css, html, template, travel-planner, autopilot, debugging -->

**场景**：travel-planner 杂志章节风重写，封面用裸元素选择器 `header { color:#fff; padding… }` + `header::after` 噪点纹理；蓝队给日章节头用了语义化 `<header class="day-head">` → 继承封面白字，章节日期白-on-白不可见，直到 375px 截图目视才暴露（DOM/probe 数值全绿发现不了）。

**解法**：渲染组件改 `<div class="day-head">`（脱离裸选择器命中面）。

**教训/How to apply**：
- 单文件模板里**组件样式全 class 化**，裸元素选择器只用于真正的全局唯一元素；或约定 JS 渲染的重复组件一律 div+class，不用语义化标签（语义让位于碰撞风险，除非裸选择器同步 class 化）。
- 排查同类问题先 `grep -nE "^(header|footer|nav|section|article)[ ,{.:]"` 列出所有裸元素选择器，再对照 JS 渲染的标签清单求交。
- **computed 数值探测发现不了"白字白底"类视觉 bug**（color/background 各自合法）——截图目视（或对比度计算）是必要补充，这就是 P6 视觉谓词的价值。

---

## [2026-08-17] Sage 色板正文文字用 dark 变体：浅色仅徽章底/大色块（WCAG 大字阈值边界）
<!-- tags: color, sage, accessibility, css, travel-planner, autopilot -->

**场景**：杂志章节风类型色系统，food 时间标签用 `--amber` #D4920A（米白底实测 2.45:1）、break 用 `--muted` #8F8F8D（2.99:1）被 qa-reviewer 判 Major——18px bold 未达到 WCAG「大字」阈值（18.66px bold / 24px regular），按正文需 4.5:1。

**规则**（Sage 色板文字用法）：
- 正文/标签文字（<18.66px bold）：用 dark 变体——`--amber-dark` #8A5F03（5.22:1）、`--muted-dark` #6E6E6C（4.72:1）、`--accent` #3A7D68（4.50:1 边界可用）
- 浅色 `--amber`/`--muted` 仅用于：徽章/胶囊底色（配 dark 文字）、大号装饰（≥24px）、图标底色块（12% 透明度染色不算文字）
- `--sky` #3B87CC（3.51:1）仅大字/图标可用，正文避免
- **改色必算对比度**（WebAIM contrast checker 或算式），别信"看起来清楚"——老人阅读场景 4.5:1 是底线不是加分项

关联 [[2026-08-16] skill 产物副本的现场微调会分叉]（同模板迭代史）。
