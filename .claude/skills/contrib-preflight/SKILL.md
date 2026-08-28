---
name: contrib-preflight
description: 上游 hermes 贡献落地前的快速审视入口——把当前要做的 issue/PR/salvage/重要评论交给 hermes-contrib-strategist agent 做形态选择、锚定、查重、scope、合入风险审视。往 NousResearch/hermes-agent 动手前的第一关。
argument-hint: [要审视的贡献想法/草稿/问题描述；缺省=从当前会话上下文提取]
disable-model-invocation: true
allowed-tools: Agent
---

# 贡献 pre-flight 审视（contrib-preflight）

用户要在上游 hermes-agent 落地一个贡献动作（开 issue / 提 PR / salvage / 接手 rebase / 发重要技术评论）之前，先过审视关。本命令只做一件事：**调用 `hermes-contrib-strategist` agent 出审视报告**，然后原样呈现给用户。审视通过与否由用户拍板，本命令不落地任何东西。

## 执行步骤

1. **确定审视对象**：`$ARGUMENTS` 有值时用它（可能是想法描述、issue/PR 草稿、或一个问题现象）；为空时回溯当前会话，提取正在酝酿的贡献意图（问题描述 + 已有的分析/草稿）。

2. **组装完整上下文**。Agent 是 fresh-context，看不到本会话——prompt 必须自包含：
   - 用户的想法/草稿**逐字粘贴**（不要转述）
   - 会话里已有的相关背景：问题怎么发现的、已做的分析、相关 PR/issue 编号、已知的代码位置（file:line）
   - 需要它回答的核心问题：以什么形态落地（issue-first / own-PR / salvage / review-comment / 观望）、锚点在哪、scope 怎么切、有什么红旗

3. **同步调用 agent**（`subagent_type: hermes-contrib-strategist`，`run_in_background: false`——审视结果是后续决策的前置，必须等它回来）。Agent 是只读的，会自己跑 gh 查重、读策略文档和上游 AGENTS.md。

4. **原样呈现审视报告**（按 agent 的输出格式：形态判定/锚点/查重/scope/合入风险/验证清单/红旗/落地顺序），末尾附一行执行建议：哪些项需要用户先拍板、哪些可以直接进落地流程。

## 纪律

- 审视报告里出现 ❌ 红旗时，**不得绕过直接落地**——先向用户呈现红旗与替代方案
- 用户对报告说「按这个做」之后才进入落地（届时走 worktree 范式 + 红队验收）
- 本命令不改代码、不发评论、不 push
