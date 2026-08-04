# Agent Harness 工程原则与最佳实践

> 提炼自 `learn-everything/topics/agent-harness-engineering`（14-artifact 教程，以 Claude Code 为参照系从 0 到 1 构建 harness）。**hermes-agent 和 Claude Code 同构**，这些原则直接指导 hermes 开发。改 hermes 任何子系统前先对照本文。

---

## 核心元原则（贯穿所有子系统）

### 1. 准确性 > 流畅度（0 假设）
回答涉及具体函数/行号/调用链/字段名前，**先读源码再回答**，不凭命名推断。hermes 源码在 `~/workspace/hermes-agent/`，直接 Read/grep 进去看。讲错要显式纠正（"我说错了 X / 真相是 Y"），不悄悄滑过。
- **术语跨层必须前缀限定**：`messages context` / `AsyncLocalStorage context` / `process context` —— 不裸用 `context`（会把多层不同的隔离糊成一句）。

### 2. why/how 优先于 what（心智模型 > 字典）
解释工业实现/设计选择时，why+how 铺在 what 前：① 问题长什么样 ② 备择方案为何不行 ③ 为什么这套赢 ④ 副作用/边缘场景 ⑤ 才到代码字面/file:line。比例 ~50/30/20，what 不能压过半。直接抛 `常量=100` + 实现 + file:line 是字典不是教学。

---

## 10 条跨子系统通用原则

### A. 正交架构（最硬的横切原则）
每个子系统只解决一个维度，新维度叠加不改旧维度。**加新子系统前先问"能否不改任何旧子系统代码就接入"——不能 = 架构有问题。**
- hook 在 compact 内部 emit，不改 compact 逻辑
- streaming 只换 runRounds 入口，dispatch/compact/hooks/obs 全复用
- MCP 工具合并进主 registry 自动走已有管道
- auto-memory 复用 claude-md 的 LRU + Session-Set 去重

### B. 模型不可靠，约束活在代码层
安全/隐私/cardinality/格式校验**永远不能靠 prompt 自律**，必须机制层强制。prompt 只负责"协作"和"教化"。
- 模型在用户催促下跳过 ask_user（thinking 明说"用户要求不问"，照做）
- 带 tools 的模型即使 prompt 要求 text-only，仍 2.79% 偷调工具 → 空 tools 数组是唯一可靠保险

### C. 双轨注入：stable system prompt + dynamic attachment
- 稳定部分（CLAUDE.md 根、MEMORY.md 索引、core instruction）→ system prompt → 可 cache
- 动态部分（nested CLAUDE.md、选中 memory、skill listing、todo reminder）→ `<system-reminder>` attachment → 每 turn 变
- **任何"随会话状态变的指令"必须走 attachment，不能塞 system prompt**（会持续 bust cache）。

### D. 双层去重：LRU + Session-Set
- LRU（小容量，挡 model 主动读触发）
- Session-Set（session 内无限，挡系统注入触发）
- **任何"已加载/已注入"状态追踪都用双层，单层必漏。**

### E. 软契约（soft contract）哲学
约束写在 prompt/类型签名/字段名里，**不在 runtime throw**。保留 model agency，让模型学"为什么"。
- **判别**：违反约束只是"行为不优雅" → 软契约；违反是"数据损坏/安全漏洞" → 硬约束（runtime throw）。
- 例：hook handler 必填 `reason`、cacheBreak 的 `_reason`、TodoWrite 不变量零 runtime 校验、memory type 可选。

### F. 协议优先，实现次之
先定义"协议契约"（数据形状、id 配对、事件名），再写实现。**协议变更代价远高于实现变更。**
- messages 是唯一状态（loop 间不存变量，model 知道的一切都在 messages 里）
- round 是原子单元（tool_use_id 配对决定，不能 round 内部切）
- tool_use_id 配对（位置无关，streaming 重排不断）
- MCP initialize 握手 / JSON-RPC over stdio

### G. 失败语义分级
每个子系统**显式声明"失败时怎么办"**，不能含糊：
- Hook 失败 = `non_blocking_error`（记录、忽略，不影响核心）
- Sub-system 失败 = 熔断/重试/拒绝（如 `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES=3`）
- 模型拒绝 = `is_error: true`（协议反馈通道，模型自适应）

### H. 可观测性是 cross-cutting，不是事后补丁
- bypass 模式下 audit 是唯一追溯手段
- logs（详细调试）/ metrics（聚合告警）/ context-map（runtime 查询）三 sink 服务不同消费者，单一 sink 替代不了另一个
- **每个 policy 决策都要带 `decisionReason: {type, ...}` 供审计**

### I. Context 经济是核心 KPI
context 窗口是稀缺资源，**每个功能设计都要问"它怎么影响 context 占用和 cache 命中"**：
- subagent 只回 summary（coordinator context 有界，不随子轮数增长）
- micro-compact 省字节、保 round（无 LLM 成本）
- cache 边界（BOUNDARY sentinel）决定 token 成本
- index 常驻 system prompt + content 按需 attachment（防 system prompt 膨胀）

### J. 模型盲（model-agnostic）策略层
策略（mode/role/permission）活在 harness 代码、**模型不可见**。模型看到的只是工具 schema 和反馈。
- 模型不知道自己 mode（system prompt 不提 mode 字符串、tools schema 在所有 mode 下一致）
- subagent schema 物理约束（swarm-worker 的 tools 物理上没有 ask_user）—— 不是"模型不应该用"，是"用不了因为不存在"

---

## 反模式清单（不要这样做）

### 安全 / 权限
1. **用 prompt 做 permission**（"删除前必须问"写 system prompt）—— 注入场景下用户指令 > system prompt，必被绕过
2. **用 hook 做 permission gate / compact 决策** —— hook 失败 = non_blocking_error ≠ reject，无法保证确定性
3. **跳 MCP initialize 握手** —— 破坏协议、丢失 capability 协商
4. **HTTP hook 只做正则前缀 SSRF 检查** —— 必须 DNS lookup 时校验防 rebinding
5. **Subagent 直接通信**（不经 coordinator 综合）—— 子看不到兄弟 messages

### Context / Cache
6. **动态内容（mcp_instructions、memory content、nested CLAUDE.md）塞 system prompt** —— 永远 cache miss、随增长爆掉
7. **动态 section 放 BEFORE_BOUNDARY** —— 同上
8. **所有 memory 塞 system prompt** —— cache 失效、token 爆炸
9. **round 内部切 compaction 边界** —— 破坏 tool_use_id 配对，API 报 `unexpected tool_use_id`
10. **compact 开头清 cache** —— 浪费上一 turn 还在用的缓存值，永远在结尾清
11. **Coordinator 看子 agent 完整 messages** —— 3 子 × 20 轮 = context 不可用

### Tool / Protocol
12. **基于数组位置配对 tool_result** —— streaming 重排会断协议，必须用 `tool_use_id`
13. **abort 不 drain pending tools** —— 留下不完整 tool_use/result 对，API 拒绝
14. **tool schema 层过滤危险工具当权限** —— 模型收不到 `is_error` 反馈、学不到拒绝信号

### Observability
15. **High-cardinality label（file_path/prompt_id）进 metrics** —— 后端 time-series 爆炸（100 万用户 × 1000 path = 10 亿 series）
16. **分散脱敏逻辑**（每个 emit 点自己脱敏）—— 会忘、会不一致，必须在 sink wrapper 统一
17. **context-map 当持久 sink** —— 进程内 Map，进程退出即失

### Soft Contract / Prompt
18. **TodoWrite runtime 校验"恰好一个 in_progress"** —— 工业只 audit 不 throw，保留 model agency
19. **runtime 强制 memory type** —— 软契约应可选（scan 返回 undefined 不 crash）
20. **CLAUDE.md 写 standard convention / 项目结构 ASCII 树** —— 过不了 every-line-test（Claude `ls` 就知道）。只写"Claude 会犯错的地方"
21. **Reminder 新建 user 消息** —— 违反 API role-alternation，必须搭在上一条 user 消息 content array
22. **`<system-reminder>` 嵌套注入 prepend 在 tool_result 前** —— 必须 append 在 tool_result 之后（API 要求 tool_result 紧跟 tool_use）

### 多 agent
23. **Readline 队列混淆**（多 subagent 同时问，用户不知道答对应哪个）—— 需 per-request ID
24. **一个 subagent 失败 crash 整个 `Promise.all`** —— 用 `Promise.allSettled`

### Skill
25. **SKILL.md body 写 `Base directory for this skill:`** —— 代码再加一次 = 双前缀
26. **Shell 模板用 string replacer** —— git 输出里的 `$&`/`` $` ``/`$$` 特殊变量被误解释，必须用 function replacer
27. **`finally` 不恢复临时 permission** —— shell 临时 allow 的 Bash 会泄漏到下个 skill 调用

---

## 子系统速查（14 个，改对应子系统时查）

| # | 子系统 | 核心原则 |
|---|--------|---------|
| 01 | minimal-agent-loop | messages 是唯一状态；stop_reason 即控制流（tool_use→继续 / end_turn→退出）；tool_use_id 是因果链；工具 schema 形状塑造行为 |
| 02 | permission-gate | 安全策略必须活在 harness 代码（模型不可靠）；dispatch 层拦截（模型决定调后、executor 执行前）；拒绝走 `is_error: true` 协议反馈，不改 schema |
| 03 | mode-matrix | mode 是数据、policy 是行为（有序 if 链 + decisionReason）；模型不知道自己 mode；bypass 下 audit 是灵魂；hard-block 防的是 user 自己（不是 model/注入） |
| 04 | subagent-fork | agent-role 是物理约束（schema 不给工具）；context 隔离靠独立 messages 数组；ask routing 靠闭包捕获；coordinator 只看 summary；并行是模型驱动（Promise.all） |
| 05 | context-compactor | round 是原子单元；专用压缩 LLM 调用（空 tools 防 2.79% 偷调）；优先级链便宜→贵（micro→session→auto→api）；`KEEP_RECENT_ROUNDS=2` 防 drift |
| 06 | hook-engine | hook ≠ sub-system（失败只影响旁路）；`Promise.allSettled` 失败隔离；27 标准事件；三种 handler（Function/Prompt/Http）；emit 调用点 `.catch(()=>[])` 双重保险 |
| 07 | observability | 单入口 fan-out；cardinality 字段分级（metrics low / events high）；隐私机制层强制（redactIfDisabled）；context-map ≠ sink |
| 08 | streaming | 流水线并发（model+tools 重叠，sum→max）；tool_use_id 配对（位置无关）；abort 要 drain（合成 error tool_result）；不改旧子系统 |
| 09 | mcp-client | 协议层抽象（第三方贡献工具不改 harness）；JSON-RPC over stdio；initialize 握手强制；服务端是安全边界（协议不清洗输入） |
| 10 | system-prompt-assembly | webpack 式 chunk 分片（按变更频率）；模块作用域缓存闭包；DANGEROUS opt-out 强制 `_reason`；compact 结尾清 cache |
| 11 | skill-system | 文件系统即插件 registry；system-reminder 注入通道（不 bust cache）；shell 模板加载期执行；inline vs fork 正交 |
| 12 | todowrite | 薄工具 + 厚 prompt（runtime 零校验）；三层 reinforcement（continuous/fixed-interval/event-triggered）；transcript 持久化（从 messages 倒扫） |
| 13 | claude-md-system | cascade 加载 + later-override；双层去重（LRU + Session-Set）；compact 触发全清；every-line-test 立法门槛 |
| 14 | auto-memory | 双轨并发提取（主路径 + background fallback）；双轨注入（index 常驻 + content 按需）；软契约类型；相关性选择 + age decay |

---

## 一句话总结
harness 是**正交的子系统集合**（loop / permission / mode-matrix / subagent / compact / hook / obs / streaming / mcp / prompt-assembly / skill / todowrite / claude-md / memory）。每个子系统只解决一个维度、显式声明失败语义、走统一的 dispatch + hook + attachment 通道。**模型不可靠**，所以安全/隐私/cardinality 全部机制层强制；约束优先软契约（prompt/类型）而非 runtime throw。**Context 窗口和 cache 命中率是核心 KPI**，任何设计都要回答"它怎么影响 context 经济"。

---

*来源：`learn-everything/topics/agent-harness-engineering`（14 artifact，每个含 lesson.md/spec.md/notes.md/agent.ts/run-log.txt）。需要某子系统的深度细节时，直接读对应 artifact 的 lesson.md + notes.md。*
