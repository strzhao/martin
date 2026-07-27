# 知识索引

## Decisions
- [2026-05-03] whisper 语音识别方案选型 | tags: python, macos, mlx | → decisions.md
- [2026-06-11] 本地 LLM API 封装为 CLI 工具的技术选型 | tags: cli, typescript, llm, qwen | → decisions.md
- [2026-06-11] travel-planner skill 多源信息采集 + HTML 输出架构 | tags: skill, travel, api, opencli, multi-source, html | → decisions.md
- [2026-06-13] restaurant-recommender skill 复用 travel-planner 架构 | tags: skill, restaurant, food, architecture-reuse, multi-source | → decisions.md

## Patterns
- [2026-06-18] 限流反复发作根因：typing 高频累积（成功不打日志）+ cooldown 只防限流后 + 可观测性缺失 | tags: rate-limit, typing, observability, messaging-adapter, debugging | → patterns.md
- [2026-06-11] TypeScript fetch body 类型冲突 | tags: typescript, fetch, nodejs | → patterns.md
- [2026-06-13] DEBUG 级别的后台定时器静默消耗 API 限流配额 | tags: api, rate-limit, debugging, heartbeat, messaging-adapter | → patterns.md
- [2026-06-17] 限流 cooldown 门控须 sleep 后重新检查时间（mock-sleep 测试盲区）| tags: api, rate-limit, testing, asyncio, messaging-adapter | → patterns.md
- [2026-07-16] 改 hermes display 平台默认值要追到 display_config.py tier 系统（run.py default= 是 4 层链末端 no-op）+ workflow scope 坑 | tags: hermes, display, config, contribution, no-op, plan-reviewer | → patterns.md
- [2026-07-17] gateway 改 final 回复内容要注入到 _handle_message_with_agent 末端（footer 后/return 前），_run_agent_inner 的 final_response 取出点是中间会被 reasoning-prepend/footer 再加工 + 红队 xfail 信号 | tags: hermes, gateway, injection-point, no-op, response, contribution, plan-reviewer | → patterns.md
- [2026-07-19] hermes PR 迭代先 rebase main（main 漂移）+ sweeper 引用的 commit 常是 maintainer 已做的（rebase 后已解一半）+ rebase 保留双方机制 + main 测试 mock 适配新参数 + source-shape 测试红线 | tags: hermes, contribution, rebase, sweeper, main-drift, PR-iteration | → patterns.md

## Domain Knowledge
- [Hermes Agent 安装与配置](domains/hermes-agent.md) — 在 macOS ARM64 上安装 Hermes Agent 的关键决策和踩坑记录
