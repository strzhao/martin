# 工程模式与教训

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
