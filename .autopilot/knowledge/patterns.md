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
