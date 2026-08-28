---
name: oss-preflight
description: 开源运营对外发布物落地前的快速审视入口——把即将发布的文章/README 推送/release notes/issue 评论/awesome PR/社交内容交给 oss-publish-preflight agent 做 slop 红线、事实断言、渠道规则、L2/L3 边界审视。任何从 strzhao 名下账号对外发布前的第一关。
argument-hint: [要审视的发布草稿/变更描述/文件路径；缺省=从当前会话上下文提取]
disable-model-invocation: true
allowed-tools: Agent
---

# 开源运营发布 pre-flight（oss-preflight）

用户要对外发布任何东西（dev.to 文章、README/LICENSE/topics 推送、release、issue/PR 评论、awesome 收录 PR、社交内容）之前，先过审视关。本命令只做一件事：**调用 `oss-publish-preflight` agent 出红队审视报告**，然后原样呈现。发布与否由用户拍板，本命令不落地任何东西。

## 执行步骤

1. **确定审视对象**：`$ARGUMENTS` 有值时用它（草稿全文、文件路径、或变更描述）；为空时回溯当前会话提取正在酝酿的发布物（内容 + 目标渠道 + 发布动机）。

2. **组装完整上下文**。Agent 是 fresh-context，看不到本会话——prompt 必须自包含：
   - 草稿**逐字粘贴**或给绝对路径（不要转述）
   - 目标渠道（dev.to / GitHub push / awesome PR / 评论 / release）
   - 会话里的相关背景：为什么发、目标读者、想达成的效果、相关既有内容链接
   - 需要它回答的核心问题：slop 特征、事实断言、渠道合规、层级边界

3. **同步调用 agent**（`subagent_type: oss-publish-preflight`，`run_in_background: false`——审视结果是发布决策的前置，必须等它回来）。Agent 是只读的，会自己读 oss-ops.md 红线、跑 gh 实查核数字。

4. **原样呈现审视报告**（层级判定/slop 检查/事实抽验/渠道合规/红旗/发布建议），末尾附一行执行建议：哪些项需用户先拍板、哪些修改可直接做。

## 纪律

- 报告里出现 ❌ 红旗时，**不得绕过直接发布**——先向用户呈现红旗与替代方案
- 本命令不发布任何东西、不 push、不评论；对外动作一律走 L2 审批流（见 `oss-ops.md` §2）
- L3 类动作（Show HN 首帖等）本命令只审「支撑包」内容，发帖永远用户本人
