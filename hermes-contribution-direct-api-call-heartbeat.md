# 贡献草稿：direct_api_call 非流式心跳

> 草稿日期 2026-08-05。来源：本地两个 ai-todo cron 8/4 失败的诊断（pro + flash 双中招，根因非流式路径无心跳）。按 `hermes-contribution.md` 的 issue-first + 附 PR 路径。

## 本地 patch 状态

- branch：`fix/direct-api-call-heartbeat`（基于 `origin/main` @ `3fa318a50`）
- 已 commit（本地，**未 push**）：`agent/chat_completion_helpers.py` +39 行，`tests/run_agent/test_streaming.py` +1 测试
- 测试：`tests/run_agent/test_streaming.py` 全 37 passed
- 当前 working tree 已切回 `fix/process-poll-loop-salvage`（你的另一摊 salvage 没受影响）

## 提 issue 顺序

1. 先在 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) 提下面那份 issue（拿到 issue 号）。
2. 等 sweeper 扫一遍（它会判断 main 上是否已修——本案未修，应留 open）。
3. push branch → fork，开 PR，`Fixes #<issue号>`。

---

## Issue 草稿

**Title:** `[Bug] Cron inactivity watchdog kills non-streaming requests during slow provider first-byte (direct_api_call has no activity heartbeat)`

**Labels:** `type/bug`, `comp/agent`, `comp/cron`, `area/streaming`

**Body:**

### Summary

`direct_api_call()` — the inline non-streaming path used by every cron turn and delegated child (`should_use_direct_api_call()` → True) — refreshes the activity tracker only once, *before* the request. While it blocks on `chat.completions.create()` (no intermediate events), the cron inactivity watchdog (`HERMES_CRON_TIMEOUT`, default 600s) sees zero activity and kills the job. A provider whose first byte is slow but whose connection is alive (not a connection error) is indistinguishable from a hung job.

This is the symmetric gap left by commit `2773b18b5` (#7794), which added per-event `_touch_activity()` to the four **streaming** paths but missed the inline **non-streaming** path.

### Root cause

`agent/chat_completion_helpers.py`, `direct_api_call()`:

```python
def direct_api_call(agent, api_kwargs: dict):
    _check_stale_giveup(agent)
    agent._touch_activity("waiting for non-streaming API response")  # ← only touch
    ...
    try:
        response = _dispatch_nonstreaming_api_request(...)  # ← blocks, no further touch
```

`_dispatch_nonstreaming_api_request()` ultimately calls `request_client.chat.completions.create(**api_kwargs)` synchronously. There is no `Timer`, thread, or loop touching `_touch_activity` during the wait. The docstring acknowledges it relies solely on httpx's `request_timeout_seconds` / `HERMES_API_TIMEOUT` — but `HERMES_API_TIMEOUT` (default well above 600s) > `HERMES_CRON_TIMEOUT` (default 600s), so the cron watchdog fires first.

### Reproduction (real-world)

Hermes v0.12.0, DeepSeek provider (`https://api.deepseek.com`), two `ai-todo` cron jobs (10:00 / 22:00). On 2026-08-04 both windows hit DeepSeek first-byte latency >600s (connection alive, not a connection error).

`agent.log` (note: model-independent — pro in the morning, flash in the evening):

```
2026-08-04 10:00:58 [cron_128cc9dd9d40_20260804_100057] model=deepseek-v4-pro platform=cron
2026-08-04 10:14:45 Turn ended: reason=interrupted_during_api_call model=deepseek-v4-pro api_calls=1/90

2026-08-04 22:00:45 [cron_d27dc9e61a02_20260804_220042] model=deepseek-v4-flash
2026-08-04 22:15:45 Turn ended: reason=interrupted_during_api_call model=deepseek-v4-flash api_calls=1/90
```

`errors.log`:

```
2026-08-04 10:11:00 ERROR cron.scheduler: Job '...' idle for 601s (inactivity limit 600s)
  | last_activity=waiting for non-streaming API response | iteration=1/90 | tool=none
```

Same job re-run at 12:15 (DeepSeek TTFB back to normal) returned `latency=3.0s` — confirming the provider was slow-but-alive, not hung. The 8/3 run hit a clean `APIConnectionError` (fast-fail → retry → success); only the slow-but-alive failure mode triggers the false positive.

### Why this isn't a duplicate

- **#7794 / `2773b18b5`** — fixed the *streaming* paths. Non-streaming `direct_api_call` untouched.
- **#71268** — argues `should_use_direct_api_call()` shouldn't force non-streaming for cron. This issue takes no position on that design choice; it only asks that *while* non-streaming is used, the activity tracker stay fresh. Complementary, not duplicate.
- **#75222** — same function, same symptom but on the **delegated child** path, framed around stale-detection retries. Doesn't identify "zero heartbeat during wait" as root cause, doesn't cover cron.
- **#18004 / #65208** — discuss what happens *after* the timeout fires (thread isolation, SessionDB write loss). They presuppose the firing is correct; this issue argues it's a **false positive**.

### Suggested fix

Daemon heartbeat thread inside `direct_api_call()`, re-touching `_touch_activity` every ~30s while in flight, stopped in `finally`. Mirrors `2773b18b5`'s per-event pattern adapted for the no-event case. ~15 lines + 1 regression test. PR to follow.

### Environment

- Hermes Agent v0.12.0
- Provider: DeepSeek
- Platform: cron (gateway, launchd-supervised)
- Models: deepseek-v4-pro, deepseek-v4-flash (both reproduce)

---

## PR 草稿

**Title:** `fix(chat_completions): refresh activity during non-streaming cron requests`

**Base:** `main` ← head: `fix/direct-api-call-heartbeat`

**Body:**

Fixes #<issue>.

### Problem

`direct_api_call()` — the inline non-streaming path taken by every cron turn and delegated child — calls `_touch_activity()` only once, before the request. The subsequent `chat.completions.create()` blocks with no intermediate events, so the cron inactivity watchdog (`HERMES_CRON_TIMEOUT`, default 600s) sees zero activity and kills the job. When the provider's first byte is slow but the connection is alive, this is a false positive. Real-world repro in the issue (DeepSeek, pro + flash both killed at exactly 600s; same job 3.0s once TTFB normalized).

Symmetric gap left by `2773b18b5` (#7794), which added per-event `_touch_activity()` to the four streaming paths but missed the inline non-streaming path.

### Fix

Add a daemon heartbeat thread inside `direct_api_call()`:

- Before the `try`: start a daemon thread calling `_touch_activity(f"waiting for non-streaming API response ({elapsed}s)")` every `_DIRECT_API_CALL_HEARTBEAT_INTERVAL_S` (30s).
- In `finally`: set the stop `Event`; `Event.wait(interval)` returns True the instant the request finishes, so the thread exits promptly and never outlives the request (success / error / interrupt all share the same finally).

Interval is a fraction of typical inactivity limits (default 600s): frequent enough to feed the watchdog, rare enough to be noise-free on fast responses.

### What this does *not* change

- `should_use_direct_api_call()` untouched — takes no position on #71268.
- Interrupt / abort / close lifecycle untouched. The heartbeat thread only calls `_touch_activity`; it never touches the request client.
- httpx's own timeout remains the bound for genuinely hung providers.

### Tests

New `TestDirectApiCallHeartbeat::test_heartbeat_refreshes_activity_during_slow_response` — stubs `_dispatch_nonstreaming_api_request` to block 100ms with a 20ms heartbeat interval; asserts ≥2 elapsed-suffixed touches during the wait and that touching stops after return.

All 37 tests in `tests/run_agent/test_streaming.py` pass (including the `2773b18b5` streaming-activity tests this mirrors).

---

## Commit message（已用，可 amend）

```
fix(chat_completions): refresh activity during non-streaming cron requests

direct_api_call() blocks on a single chat.completions.create() with no
intermediate events, so the only _touch_activity() fires before the request.
A provider whose first byte is slow but connection alive is indistinguishable
from a hung job, and the cron inactivity watchdog (HERMES_CRON_TIMEOUT,
default 600s) kills tasks that would have succeeded once httpx's own timeout
elapsed.

Add a daemon heartbeat thread (_DIRECT_API_CALL_HEARTBEAT_INTERVAL_S = 30s,
stopped in finally). Closes the symmetric gap left by 2773b18b5, which added
per-event _touch_activity() to the four streaming paths but missed the inline
non-streaming path used by every cron turn and delegated child.

Regression test: test_heartbeat_refreshes_activity_during_slow_response.
All 37 tests in test_streaming.py pass.
```

> 注：commit 含 `Co-Authored-By: Claude`（按本仓库协作规范），提上游前你可自行决定保留或删除。

---

## 后续步骤（你自己执行）

```bash
cd ~/workspace/hermes-agent

# 1. 提 issue（用上面草稿），拿到 issue 号 N
# 2. push branch 到 fork
git push fork fix/direct-api-call-heartbeat
# 3. 开 PR，base: NousResearch/hermes-agent:main，标题/正文用上面 PR 草稿，Fixes #N
```
