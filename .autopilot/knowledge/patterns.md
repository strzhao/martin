# 工程模式与教训

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
