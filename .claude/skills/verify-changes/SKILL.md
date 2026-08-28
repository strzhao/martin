---
name: verify-changes
description: 发布前红队验收——并行 subagent 核查本次改动的代码正确性、公开技术断言的事实准确性、引用完整性。用于 push / 发评论 / 提 PR / 关 issue 前的最后关卡。
argument-hint: [验证目标描述；缺省=自动检测本次会话的全部改动与产出]
disable-model-invocation: true
allowed-tools: Agent
---

# 红队验收（verify-changes）

对本次改动做多路**独立**验证。两条元原则（来自 Claude Code 官方 review 实践 + 本工程教训）：

1. **写代码/写评论的实例不给自己打分**——验证必须由 fresh-context subagent 执行，它看不到本会话的推理，只看得到证据。
2. **行为声称需要 file:line 引用或命令输出，不接受推断**（官方 verification bar，压制 false positive 与 false confidence 双向都管用）。

输入：`$ARGUMENTS` 有值时验证其指定的目标；否则回溯本次会话，验证全部产出。

## 第一步：枚举工件清单

从会话上下文 / git 状态 / gh 状态列出本次的全部产出，分三类：

- **A 代码改动**：worktree/分支/commit、diff、新增/修改的测试、PR body、commit message、已发的 review 回复
- **B 公开技术断言**：已发或待发的 GitHub 评论、issue 回复——把每条「承重断言」拆成独立条目
- **C 引用与事实**：引用的 PR/issue 编号、作者、时间线、file:line、对他人 diff 的性质断言（"X 没有 Y"、"X 是唯一…"）

## 第二步：提取承重断言

承重断言 = 若为假则整个产出被毁。逐工件拆出来列清单，**重点标注三类最脆的**（历史上全部咬过人）：

1. **file:line 引用**——上游 main 前进后行号漂移；核实基准必须是 `origin/main`（fetch 后），不是本地陈旧 tracking ref
2. **「他人 diff 缺 X」类断言**——断言前必须先 `gh pr diff <N>` 全文读一遍其**测试文件**。2026-08-28 教训：thread 里三个资深参与者连犯同一误读，先后「提议补」一个 PR 第一天就带的测试
3. **泛化量词**（所有 / 每个 / never / only / 唯一）——专找反例；反例找到后改措辞收窄辖域，而不是删断言

对代码改动（A 类），承重断言还包括：声称修复的 bug 能在当前 main 复现、修复改变了显现该 bug 的确切行、测试测的是行为而非形状。

## 第三步：并行 spawn 红队 subagent

**每类工件一路**，general-purpose subagent，在**同一条消息里并行发出**（多个 Agent tool use）。每个 prompt 必须包含（subagent 没有本会话上下文，缺一项它就只能猜）：

- 完整背景：worktree 路径 / PR 号 / 分支 / head commit / 断言原文逐条粘贴
- 逐条 verdict 格式：`CONFIRMED / REFUTED / PARTIAL / UNCERTAIN` + 证据摘录（代码段、命令输出、API 返回）
- 具体验证方法建议（跑什么命令、读什么文件、怎么构造复现场景）
- 输出末尾：问题按严重度排序（blocker / major / minor / nit）+ 整体结论
- **只读约束：不得修改任何文件、不得 push**

**代码路（A 类）的专属要求**——红队不是读代码点头：

- **攻击场景复演**：把声称防住/修住的场景写成确定性脚本真跑一遍（含正反两个分支：攻击应被拦截、正常路径不应误伤），不是人工走查
- **异常路径逐行**：模块级/启动路径代码的每个 IO 调用查 try/except——进程启动路径上任何可抛点都是 blocker
- **测试真实性**：每个测试回答"它真的在测声称的东西吗"——mock 是否 mock 了被测逻辑本身（而不是只 mock 世界状态）；有没有从没执行过被测路径的空转测试
- **复跑验证**：hermes 仓库用 `scripts/run_tests.sh`（CI-parity：unset 凭据 / TZ=UTC / per-file 子进程隔离），不裸 `pytest`——"works locally, fails in CI" 的根源就是裸跑
- **premise 四问**（hermes AGENTS.md）：① 这个"缺口"是不是 intentional design？② 前提对得上现有机制的真实行为吗（能不能指到 bug 显现的确切行 + 证明修复改变该行行为）？③ 被补上的"缺失"原本是不是在保护什么？④ 有没有复活维护者已否决的方向 / 超出 agreed scope？

**断言路（B 类）的专属要求**——对每条断言：

- 引用他人 diff 的：`gh pr diff` 拉全 diff 亲自读，包括测试文件
- 引用 main 代码的：`git fetch origin main --quiet` 后 `git show origin/main:<file>` 核对，报实际行号
- 引用他人评论的：`gh api repos/<owner>/<repo>/issues/comments` 拉原文，核对话是谁说的、哪天说的
- **快照 ≠ 当前状态**：邮件/review 是发出时刻的快照，核实状态用 API 双源（评论 API + PR head/mergeable），勿信措辞

**引用路（C 类）**：编号是不是 issue 而非 PR（`gh pr view` 报错就查 `gh issue view`）、作者、日期、时间先后关系逐个过。

## 第四步：汇总与处置

- 三路 verdict 汇成一张表：工件 × 断言 × verdict × 证据
- **REFUTED / PARTIAL → 立即修正，不等用户问**：
  - 评论修正用 `gh api repos/<owner>/<repo>/issues/comments/<id> -X PATCH --input <json-file>`（JSON 文件经 `--input`；`-F body="$(cat …)"` 会把内容当文件名解析，勿用）
  - 代码修正 amend 后 force-push 会重触发 CI——小修值得，但要告知成本；修完必须复跑测试 + lint
  - 修正后**复验受影响的断言**（可单发一个 subagent 只核修正点）
- 修正措辞原则：公开更正优于静默错误；把误读本身写出来（"on re-reading, X was already there"）是加分项
- UNCERTAIN 且无法低成本消除的，列入「残留风险」如实报告

## 输出格式

```
## 验收报告（/verify-changes）
### A 路（代码）：verdict + 关键证据
### B 路（断言）：verdict 表 + 被抓到的问题
### C 路（引用）：verdict
### 处置：已修 X 处（动作明细）/ 待用户拍板 Y 处
### 残留风险：Z（明确说清为什么可接受）
### 新教训（如有，沉淀进记忆）
```

## 附：测试判据速查（审查自己/他人的测试时用）

- **change-detector 禁令**：测试读起来像当前数据的快照（`assert "model-x" in catalog` / `== 21` / `len(...) == 8`）→ 删；像两块数据必须满足的契约/不变式（"每个 catalog 条目都有 context-length"）→ 留
- **不读源码**：`inspect.getsource` / 正则断言源码形状 = 禁令——它测的是代码形状不是行为，两个方向都会错报
- **不 fake host OS**：需要解释器相信自己在另一个 OS 才能过的测试属于那个 OS（marker 不是 skipif——skipif + lane grep 会让测试在所有 host 上都不跑还报绿）
- **垂直回归**：声称修住的场景必须有"真实路径"测试（调公开入口而非 mock 内部函数），断言三层——行为返回值、用户可见诊断、副作用未发生
