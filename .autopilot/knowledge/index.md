# 知识索引

## Decisions
- [2026-05-03] whisper 语音识别方案选型 | tags: python, macos, mlx | → decisions.md
- [2026-06-11] 本地 LLM API 封装为 CLI 工具的技术选型 | tags: cli, typescript, llm, qwen | → decisions.md
- [2026-06-11] travel-planner skill 多源信息采集 + HTML 输出架构 | tags: skill, travel, api, opencli, multi-source, html | → decisions.md
- [2026-06-13] restaurant-recommender skill 复用 travel-planner 架构 | tags: skill, restaurant, food, architecture-reuse, multi-source | → decisions.md

## Patterns
- [2026-06-11] TypeScript fetch body 类型冲突 | tags: typescript, fetch, nodejs | → patterns.md
- [2026-06-13] DEBUG 级别的后台定时器静默消耗 API 限流配额 | tags: api, rate-limit, debugging, heartbeat, messaging-adapter | → patterns.md
- [2026-06-17] 限流 cooldown 门控须 sleep 后重新检查时间（mock-sleep 测试盲区）| tags: api, rate-limit, testing, asyncio, messaging-adapter | → patterns.md

## Domain Knowledge
- [Hermes Agent 安装与配置](domains/hermes-agent.md) — 在 macOS ARM64 上安装 Hermes Agent 的关键决策和踩坑记录
