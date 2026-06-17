# 工程模式与教训

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
