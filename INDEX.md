# martin 知识文档索引（唯一入口）

> 本文件是 martin 目录全部知识文档的**唯一索引**。新增知识文档必须在此登记，否则视为不存在。
> 日常操作手册见 `CLAUDE.md`；技能列表见 `README.md`；本索引只收「先读再动手」的沉淀文档。

## 工具最佳实践

| 文档 | 一句话 | 何时读 |
|---|---|---|
| [opencli-best-practices.md](opencli-best-practices.md) | 浏览器自动化：opencli 优先于 Playwright（E2E 例外），state→act→verify 循环、adapter 优先、登录态安全边界 | **任何浏览器/网页操作前** |

## Skill 工程

| 文档 | 一句话 | 何时读 |
|---|---|---|
| [skill-authoring-guide.md](skill-authoring-guide.md) | Anthropic 官方 skill 开发最佳实践提炼：description 选择器/自由度分级/渐进披露/eval-first + 五种结构模式 + 验收 checklist + 本仓 skill 资产映射 | **新建、修改、评审任何 SKILL.md 前** |

## Hermes 工程

| 文档 | 一句话 | 何时读 |
|---|---|---|
| [harness-engineering-principles.md](harness-engineering-principles.md) | 10 条通用原则 + 27 反模式 + 14 子系统速查；正交架构/模型不可靠/软契约/context 经济 | **改 hermes 任何子系统前** |
| [hermes-contribution.md](hermes-contribution.md) | 上游共建打法：合入画像、review-first 策略主轴 2.0、salvage 流程、sweeper 红线 | **参与 hermes-agent 共建前** |
| [hermes-contribution-direct-api-call-heartbeat.md](hermes-contribution-direct-api-call-heartbeat.md) | direct_api_call 心跳贡献草稿（issue-first 模板案例） | 处理该 PR / 找 issue-first 范例时 |
| [hermes-observability-guide.md](hermes-observability-guide.md) | 本地观测栈消费指南：`hermes forensics summary` 30 秒入口、症状→命令决策树、日志路由表 | **排查 hermes 异常前** |
| [hermes-observability-audit.md](hermes-observability-audit.md) | 可观测性缺口审计（2026-08-23）：取证能力地图 + 上游 issue 版图 | 找可观测性贡献弹药时 |

## 开源运营

| 文档 | 一句话 | 何时读 |
|---|---|---|
| [oss-ops.md](oss-ops.md) | 审批分层红线（L1/L2 无 L3）、渠道规则、9 仓台账、ai-todo 打样 playbook | **任何开源运营动作前** |

## Operator 赋权设计（值班 agent 的自主边界与修复判断）

| 文档 | 一句话 | 何时读 |
|---|---|---|
| [operator-autonomy-design.md](docs/operator-autonomy-design.md) | v1：分级授权 L0–L4 + 许可表（路径白名单）——**已被 v2/v3 取代，留档对照** | 追溯「为什么白名单被否」 |
| [operator-autonomy-design-v2.md](docs/operator-autonomy-design-v2.md) | v2：AI First 修复闭环 + 三件套（只读 token / 回退点通道 / 哈希链账本）——**三件套已被 v3 删**，骨架与三态判词沿用 | 追溯「机制化为何反噬」 |
| [operator-autonomy-design-v3.md](docs/operator-autonomy-design-v3.md) | v3：四原则判断脚手架（机械层归零、git 即基建、不修论证、周议程门）——**议程门与流血三判据已被 v3.1 删** | 三方对比 / 回看议程门的由来 |
| [operator-autonomy-design-v3.1.md](docs/operator-autonomy-design-v3.1.md) | **v3.1（现行）：四问模板 + 红队协议 + 当班修复流 + 可逆性红线 + 已知缺陷清单**；用户 09-13 晚全量拍板 11 项 | **判断一个缺口该不该修、或改任何域内机制之前** |
| [operator-autonomy-design-v3-dogfood.md](docs/operator-autonomy-design-v3-dogfood.md) | v3.1 的验证报告：5 缺口回放 + v1/run-watch 历史回放 + 两路 fresh-context 红队原文 + 定稿结论 | 想知道 v3.1 凭什么定稿 / 复验红队判词时 |

## 维护规则

1. 新增沉淀文档 → 在本索引对应分区加一行（文档名链接 + 一句话 + 何时读）
2. 文档废弃 → 从索引删除并归档或删除文件，不留死链
3. 「何时读」是 AI 的触发条件，写触发场景不写文档摘要
