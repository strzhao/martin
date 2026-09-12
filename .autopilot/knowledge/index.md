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

- [2026-08-23] pytest 点号文件名 × tests/__init__.py 包导入 = 收集必炸 | tags: pytest, naming, test-collection, hermes, acceptance-tests | → patterns.md
- [2026-08-23] CPython sqlite3 跨线程 close vs write_txn = SIGSEGV(非异常) | tags: sqlite3, threading, sigsegv, close-race, hermes, upstream-pr | → patterns.md

- [2026-08-24] 单进程全仓 pytest sweep 跨文件 env 污染(WEIXIN_ACCOUNT_ID import 期写入) | tags: pytest, cross-file-pollution, env-leak, hermes | → patterns.md
- [2026-08-24] 取证日志镜像原则:观测结论与控制流判定同源 | tags: logging, classification, forensic | → patterns.md

- [2026-09-06] 红蓝对抗 fake harness 必须守约 DI resolve 语义（51 红接缝错位教训） | tags: testing, dependency-injection, red-blue, fake, contract, gcli | → patterns.md
- [2026-09-06] plan 期"已实证"的外部数据断言也会错：实机 dry-run 是最便宜的证伪器 | tags: verification, false-evidence, smoke-test, dry-run, gcli | → patterns.md
- [2026-08-24] scheduler in-flight 超时分类:#38922 cancel() 返回值语义与 fixture 驱动法 | tags: hermes, cron, future, test-fixture | → patterns.md

- [2026-09-06] 零依赖 CLI 下的 YAML 编辑：手写针对性行级编辑器（宁报错不猜+幂等钉死） | tags: typescript, yaml, zero-dependency, gcli, config-editing | → decisions.md

## Domain Knowledge
- [Hermes Agent 安装与配置](domains/hermes-agent.md) — 在 macOS ARM64 上安装 Hermes Agent 的关键决策和踩坑记录
- [2026-08-23] hermes 事件落库(T1)架构四决策(懒启动 atexit/不设 WAL/config 链分叉/check_same_thread) | tags: hermes, observability, sqlite, config-chain, events-sink | → decisions.md
- [2026-08-24] weixin context token v2(issued_at 落盘+双 dict 分离+回滚自愈) | tags: hermes, weixin, token, forensics | → decisions.md
- [2026-09-05] jq `//` 把 false 当 falsy：布尔配置静默失效事故根因 | tags: bash, jq, boolean, config-parsing, incident, contrib-watch | → patterns.md
- [2026-09-05] bash `$var` 紧跟全角标点并入变量名：三方同踩 12+ 处 | tags: bash, unicode, fullwidth, variable-name, testing | → patterns.md
- [2026-09-05] 第三方工具链遮蔽系统 diff：stdout 空的静默假绿 | tags: macos, toolchain-shadow, diff, PATH, testing | → patterns.md
- [2026-09-05] 变异测试 vs 纵深防御：注入必须剥离全部同类防御层 | tags: testing, mutation-testing, defense-in-depth, false-green | → patterns.md
- [2026-09-06] bash 3.2 case 大小写不敏感撞 stub 分支 | tags: bash, macos, stub, false-null | → patterns.md
- [2026-09-06] macOS mktemp X 串末尾约束 + 空路径重定向吞错 | tags: bash, macos, mktemp, fail-path | → patterns.md
- [2026-09-06] launchd 进程组收割杀 nohup 子进程 | tags: launchd, macos, background, silent-death | → patterns.md
- [2026-09-06] L2-A 审批交互化：短码能力 URL + 判定层下沉 tunnel-cli | tags: approval, security-model, tunnel-cli, dark-launch | → decisions.md
- [2026-09-07] QA 验收谓词 artifact 必须每谓词独立观测（切片多路径=复制冒充，MD5 去重拦截） | tags: qa, autopilot, artifact, predicate, evidence-integrity | → patterns.md
- [2026-09-08] 契约字面量要锚定工具源码：速记进契约 → 红队锁死速记 → 实现被逼教错语法 | tags: contract, autopilot, tool-syntax, red-team, hermes | → patterns.md
- [2026-09-07] bash 产线统一入库验收门选型：三关聚合薄壳 + regex 单源 + pre-commit 路径守卫 | tags: testing, gate, bash, pipeline, contrib-watch | → decisions.md
- [2026-09-08] hermes 复杂编码委派 coder profile 选型：真 profile 内转调 + 单条 claude -p 长进程 | tags: hermes, kanban, profile, claude-code, autopilot, delegation, headless | → decisions.md
- [2026-09-11] zcode 插件手动四件套脚本化 sync-autopilot-to-zcode.sh（registry upsert 保留字段/installedAt 仅版本变化刷/旧版本实体并存） | tags: zcode, plugin, sync-script, registry-upsert, idempotency | → decisions.md

- [2026-09-08] kanban CLI 建卡零订阅→终态不推微信（notify-subscribe 补订三解） | tags: hermes, kanban, subscribe, weixin, hkstock | → patterns.md
- [2026-09-08] 遥测弱断言 vacuous PASS：推送正证据=订阅存在∧终态窗口 send ok 双闸 | tags: qa, vacuous-assertion, telemetry, hkstock | → patterns.md
- [2026-09-08] cron bot-chat 投递≠唤醒：定时链路=cron 直建卡+notify-subscribe 补订 | tags: hermes, cron, bot-chat, subscribe, hkstock | → patterns.md
- [2026-09-08] CC shell ANTHROPIC_* 劫持 hermes LLM（401）：env -u 铁律 | tags: hermes, anthropic, env, 401 | → patterns.md
- [2026-09-08] dry-run 只盖发送不盖账本：notify.sh event 干跑真实入账下轮真推 | tags: bash, dry-run, gate-scope, notify, contrib-watch | → patterns.md
- [2026-09-08] 红线扫描 \border\b 误报代码标识符：交易关键词用中文+显式短语 | tags: qa, false-positive, red-line, hkstock | → patterns.md
- [2026-09-08] coder 卡交付须回 merge 主仓（worktree 残留≠持久交付） | tags: hermes, kanban, coder, worktree, mktd | → patterns.md
- [2026-09-09] 双 shell 二象性：bash 脚本被 zsh 调用时 shebang 是谎言（compgen zsh 静默恒假） | tags: bash, zsh, shebang, dual-shell, silent-failure, vacuous-pass, contrib-watch, testing | → patterns.md
- [2026-09-09] 账本写入方多形态 × 单格式 grep 幂等检查 = 同 key 重复入账 | tags: notify, ledger, idempotency, grep, json-dumps, format-drift, contrib-watch | → patterns.md
- [2026-09-09] 时间依赖黑盒测试：影子 date stub 劫持裸调用（不依赖实现 seam 命名） | tags: testing, black-box, date, stub, sandbox, contrib-watch | → patterns.md
- [2026-09-10] 审计型「零 X」谓词正反两向实测（自败×空转）+ 不可满足断言的等价观测裁决 + 分桶断言变体 | tags: testing, predicate, vacuous-pass, audit-regex, contrib-watch | → patterns.md (evidence updated 2026-09-12)
- [2026-09-12] GitHub PR updatedAt 是全体协作者动作的并集：当事方停摆判定必须锚定其自身最后动作 | tags: github, gh-cli, updatedAt, staleness, ttl, anchor, contrib-watch | → patterns.md
- [2026-09-12] 同一判定逻辑多落点（孪生门）一致性靠机械手段：注释互指 + 双侧同契约测试 + 字节级守卫 | tags: approval, twin-gate, duplication, consistency, drift, contrib-watch | → patterns.md
- [2026-09-10] fixture 数据形态漂移诱发假红：错误根因三处固化（注释+补丁+台账）需全量勘误 | tags: testing, fixture, data-shape, mirror-production, erratum, contrib-watch | → patterns.md
- [2026-09-10] 种子 config 隐式依赖三处齐红 + detect 维度不计总分但影响 exit code | tags: testing, shared-fixture, implicit-dependency, exit-code, contrib-watch | → patterns.md
- [2026-09-10] autopilot 分级字段补判后必须重设 gate（AC-FIELD block 清空 gate 陷阱） | tags: autopilot, stop-hook, gate, state-machine | → patterns.md
- [2026-09-11] kanban.db 只读唯一形态 python3 mode=ro URI（sqlite3 -readonly error 14）+ completed_at 是 epoch 整数 | tags: sqlite, kanban, readonly, python3, epoch, contrib | → patterns.md
- [2026-09-11] 本地修复→上游回馈机械边：回扫闸门幂等三件套（事件 key 预查+建卡幂等键+游标双成功才推进） | tags: contrib, upstream, idempotency, cursor, gate, fail-closed | → patterns.md
- [2026-09-11] patch-id 判重机械边四坑：fork refs 千级流式早退缓存/空 diff 空 patch-id/删 tree 非删 commit/ref 头即判重集 | tags: git, patch-id, dedup, contrib, upstream, performance, testing | → patterns.md
- [2026-09-11] HERMES_KANBAN_DB 优先级压过 --board：kanban 写调用一律 env -u 剥离（env 劫持同族第二例） | tags: hermes, kanban, env, board-pin, cross-context, contrib-watch | → patterns.md
- [2026-09-11] 上游回馈闸门已投递判重选型：纯本地 git refs 头 patch-id（snapshot 扩展评估不走） | tags: contrib, upstream, patch-id, dedup, decision, gate | → decisions.md
- [2026-09-12] 沙盒 e2e 三重击穿链：PATH-stub 被 PATH 重排击穿→env -u 送真 CLI 上真板→HERMES_* 读面重定向掩盖污染 | tags: testing, sandbox, path-stub, hermes-bin, env-redirect, contrib-board, pollution | → patterns.md
- [2026-09-12] shell IFS=$'\t' read 连续 tab 折叠吞空字段：jq @tsv 多列解析必须手动参数展开切分 | tags: bash, zsh, ifs, tsv, empty-field, red-team | → patterns.md
