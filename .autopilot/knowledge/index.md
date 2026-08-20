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
- [2026-08-14] FTS5 跨引擎索引不一致：engine-version 门控检测 + fabrication 两坑（删 %_content 影子行会被 rebuild 永久丢行；DEADBEEF 毁 %_data 才是等价形）| tags: hermes, sqlite, fts5, contribution, testing, fabrication | → patterns.md
- [2026-08-15] 认领 issue 前搜 referencing PRs（in:body）+ 共享线程池 idle 复用破坏 mock patch 窗口（_reset_for_tests 治）+ 上游无 format 门别全文件重排 | tags: hermes, contribution, pytest, test-isolation, thread-pool, ruff, CI | → patterns.md
- [2026-08-16] macOS headless 浏览器 QA 产证链路：Edge 稳定 flags + timeout-KILL `</html>` 哨兵 + iframe wrapper 破 492 最小窗宽 + probe 注入取 computed/ACT 证据 | tags: testing, headless, edge, qa, html, screenshot | → patterns.md
- [2026-08-16] skill 产物副本现场微调会分叉：模板能力必须回流 assets/ 源头（三亚 day-divider 案例）+ travel-planner 模板 backlog | tags: skill, travel-planner, template, workflow | → patterns.md
- [2026-08-17] 模板裸元素选择器 × JS 渲染语义标签 = 样式碰撞（header 白-on-白案例）：组件样式全 class 化 | tags: css, html, template, debugging | → patterns.md
- [2026-08-17] Sage 色板正文文字用 dark 变体（amber-dark/muted-dark），浅色仅徽章底/大色块；WCAG 大字阈值边界 | tags: color, sage, accessibility, css | → patterns.md
- [2026-08-20] batch-sync 撞上游 open PR：case-collision 幻影 modified 被 auto-commit（#86183 dirty 事故）：open-PR 防御检查 + 幻影 M 先查根因 + 跨机元数据定位 + server-side 退 ref 最小修复 | tags: git, batch-sync, case-collision, multi-machine, hermes, incident | → patterns.md

## Domain Knowledge
- [Hermes Agent 安装与配置](domains/hermes-agent.md) — 在 macOS ARM64 上安装 Hermes Agent 的关键决策和踩坑记录
