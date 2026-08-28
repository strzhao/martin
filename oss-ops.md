# 开源项目运营（oss-ops）

> 沉淀于 2026-08-28。基于 strzhao 名下 28 个非 fork repo 盘点（核心 9 仓）+ 渠道/工具/trending/竞品调研（livecycle 1.5k⭐ playbook 全文 + 2026 现况修正）+ martin 六层上下文工程模式复用。**做任何开源运营动作前先读此文档。** 台账数据是快照会过时，分层红线与渠道规则才是重点。

---

## 1. 定位与分工

开源运营是与 hermes 同级的**持续性命题**。分工三方：

| 角色 | 职责 |
|---|---|
| **用户** | 只做产品 + 给 Hermes 造运营工具（P0 stargazer 分析器 / P1 dev.to 发布工具 / P2 审批硬化）；L3 动作（Show HN 首帖、KOL 私聊、付费投放）；L2 审批 |
| **Hermes Agent** | 日常执行：每日巡检 cron、组合铺开、内容起草、release notes 草稿 |
| **martin 侧 Claude Code** | 上下文工程、打样质量件（英文 README 等模板基准）、pre-flight 审视（`/oss-preflight`）、验收 |

指挥层级：**策略在本文档（单点维护），进度在 memory `[[oss-ops-progress]]`，执行状态在 `.autopilot/project/`（dag.yaml）**。Hermes 侧运行手册在 `~/.hermes/skills/github/oss-ops/SKILL.md`（只带运行时必需品，知识不复制）。

## 2. 审批分层红线（命题宪法，所有 agent/skill/cron 引用）

**背景**：HN 官方 flag AI 生成/编辑内容（"violates the social contract that it takes more effort to write than read"，2026-08 核实）；Reddit 全面打击 AI slop；**账号声誉是一次性资产**，被封不可恢复。另：hermes 侧外发能力本身无审批门，L2 纪律靠 skill 约定，机制化强制是用户工具 P2（已知缺口）。

| 层 | 定义 | 动作清单 | 执行方 |
|---|---|---|---|
| **L1 全自动** | 只读 + 本地草稿 | stars/traffic/issue/stargazer 采集、日差分、日报、英文 README 及文章**草稿**、release notes 草稿、repo 内务分析 | Hermes cron 独立跑 |
| **L2 起草+审批** | 一切**对外可见**变更 | README/LICENSE/topics 推送、issue/PR 评论、dev.to 文章、release 发布、awesome PR、social preview 变更 | Hermes/martin 起草 → pending 文件 → gateway 推微信 → 用户回「批/改/否」→ 执行 + approved.log 回执；48h 无回复自动搁置记入日报 |
| **L3 仅人零自动化** | 合规/关系敏感 | Show HN 首帖（用户本人发）、KOL/人脉私聊要 star、付费投放、giveaway | 用户 |

**正例**：Hermes 写好 issue 回复草稿存 pending → 微信审批 → 批 → `gh issue comment` → approved.log。
**反例（禁止）**：cron 里「顺手回复新 issue」「自动发布文章」；用小号互 star；批量 DM 求 star（playbook 里的 retargeting 战术属 L3，agent 不做）。

## 3. 项目组合台账（2026-08-28 快照）

| 仓 | slug | ⭐ | 定位一句话 | 短板 | 批次 |
|---|---|---|---|---|---|
| ai-todo | strzhao/ai-todo | 4 | NL-first 任务管理：单输入框+预览执行+无限层级+项目空间（Next.js 16 + DeepSeek，线上 ai-todo.stringzhao.life） | **打样仓**：无 LICENSE/topics/issue 模板，README 纯中文无 GIF，package.json 无 description | C |
| ai-todo-cli | strzhao/ai-todo-cli | 0 | 给 AI agent 用的 todo CLI（全 JSON 输出、动态命令发现、`npx skills add`）v0.4.3 | README 已英文；无 LICENSE/模板 | C |
| autopilot | strzhao/autopilot | **27** | Claude Code plugins（组合最大资产） | **仓不在本机需 clone**；未盘点 | D |
| ai-news | strzhao/ai-news | 3 | AI 新闻消费层（首页+flomo 推送+点击统计） | README 纯 API 文档式 | D |
| claude-code-buddy | strzhao/claude-code-buddy | 2 | macOS Dock 像素猫咪伴侣（Electron+Homebrew） | 纯文字 README | D |
| learn-everything | strzhao/learn-everything | 2 | Claude Code skill 形态学习工具（/learn 单入口） | 无 CI 无 .github | D |
| relight | strzhao/relight | 0 | 照片 AI 分析管理平台（Turborepo+Homebrew tap） | — | D |
| lmedia-cli | strzhao/lmedia-cli | 0 | Apple Silicon 本地媒体生成 CLI（零 API 成本） | — | D |
| tunnel-cli | strzhao/tunnel-cli | 0 | 一键内网穿透 CLI v1.3.0 | **无 README** | D |
| stringzhao-life | strzhao/stringzhao-life | 0 | 个人主页站（域名在用） | create-next-app 默认 README；**待用户决策：声明 demo 或转 private** | D |

横切事实（2026-08-28 盘点）：**0/9 有 LICENSE、CONTRIBUTING、ISSUE_TEMPLATE；无一有截图/GIF**。ai-todo 仓库内 `ai-todo-cli/` 目录是空残留（真 CLI 是独立仓），待清理。

## 4. 渠道与发布事实核查（每条标核实日期）

1. **GitHub Topics 自设**（2026-08-28 核，GitHub Docs）：repo admin 在 About 齿轮或 API 直接加，上限 20 个。⚠️ livecycle playbook（2023）说「topics 须由非官方关联者提交」**已过时**——topics 是零成本立即动作。
2. **Trending = star velocity**（2026-08-28 核）：相对自身历史基线的加速度，非绝对数；无官方 trending API；**spoken language 由 owner 设置** → 英文 README + English spoken language 进大盘（中文只进中文圈 trending）。推论：发布脉冲（文章+HN+awesome 同周日）集中在短窗口制造 velocity。
3. **dev.to REST API 免费可全自动**（2026-08-28 核）：`POST https://dev.to/api/articles`，header `api-key`，body markdown；`published: false` 可先存草稿。**Hashnode GraphQL 2026-05-13 起收费**（Pro plan）——弃用。
4. **GitHub 侧 gh CLI 零开发**：已登录 strzhao，scope 含 repo+workflow。`gh repo edit --description/--homepage/--add-topic`、`gh api repos/:o/:r/traffic/views|clones`、`/stargazers` 分页全够用。
5. **收录/发布渠道现状**（2026-08-28 核）：GitHub20K **已死**（演变为 Postiz——但 Postiz 本身是个值得研究其打法的开源项目）；awesome-claude-code（hesreallyhim）收录标准 = 资源 ≥14 天（首 commit 起）+ 每 PR 只提一个资源；ai-todo-cli 2026-03-05 创建**已满足门槛**。Product Hunt 对 dev tool 仍有效但 ROI 降，DevHunt/Show HN 转化更好；dev.to **#showdev** 是首选首发标签。
6. **竞品**（2026-08-28 核）：Taskosaur（对话式 AI PM）、TaskFlow AI（NL→日程）、AppFlowy AI。**ai-todo 差异化主轴 = 「给 AI agent 用的 todo」**（CLI 全 JSON 输出 + Claude Code skill + NL 单输入框）——内容定位主打 agent 赛道，不打泛 AI todo 红海。

## 5. ai-todo 打样 playbook（阶段 C，全部动作先攒 7 天 baseline）

发布顺序（每步都是 L2 除标注）：O1 零成本 API 基建（description/homepage/topics ≤20：`todo, todo-app, task-management, ai, ai-agents, productivity, nextjs, deepseek, natural-language, claude-code, llm, self-hosted, developer-tools, agent-tools`）→ O2 MIT LICENSE（`Copyright (c) 2026 strzhao`）+ issue 模板（bug_report.yml/feature_request.yml 双语）+ CONTRIBUTING 精简版 → O3 英文 README（martin 侧 Claude Code 打样，中文迁 `README.zh-CN.md` 互链；结构：hero 一句话+badges+**≤10s GIF** → Why 三卖点 → Quickstart → **For AI agents 段前置**（CLI+skill）→ Features 截图 → 对比表（主轴 agent-first）→ Roadmap/License；`package.json` 补 description）→ O4 social preview（1280×640 PNG，**用 Sage 苍绿 #3A7D68 品牌色**，参照 `statusline-sage/COLORS.md`；API 不可达需用户手工上传）+ 删空残留目录 `ai-todo-cli/` → O5 oss-repo-lint 打分 ≥9/10 + 排 7 天效果验证 scheduled task。

GIF 规范：≤10s、≤10MB、只录核心动线（输入 NL → 预览 diff → 确认执行），playwright 录屏或用户 Screen Studio 手录。

## 6. 组合铺开策略（阶段 D，Hermes 执行、martin 验收）

先 clone autopilot（27⭐ 最大资产）盘点：README/LICENSE/issues/stargazer 构成——**stargazer 分析器（P0）首战**。
每仓最小集 = LICENSE + description + topics ≥5 + issue 模板 + README 基线（tunnel-cli 补基础版）。
双语策略：核心 4 仓（ai-todo/ai-todo-cli/claude-code-buddy/autopilot）做全英文 README；其余中文为主、顶部加英文摘要段。
批次 1：autopilot / tunnel-cli / ai-news / claude-code-buddy；批次 2：relight / learn-everything / lmedia-cli / stringzhao-life（后者待用户决策处置）。
lint 工具 `oss-repo-lint`（martin/clis/，bash+gh）：LICENSE/README 长度+图+安装节/description/topics ≥5/issue 模板/CI badge/social preview，输出 9 仓打分表，周一随日报附。

## 7. 内容引擎（阶段 E，依赖用户工具 P1）

首发平台 dev.to（免费 API + 算法推荐 + #showdev），社交渠道**引流到平台帖而非自建博客**（借平台算法放大，livecycle 验证过的打法）。首篇选题：「给 AI agent 用的 todo：为什么我把 todo CLI 重写成全 JSON 输出」——带真实数据（baseline 期间 star/issue 数字）。
内容四象限轮换：直接介绍 / how-to 植入 / listicle（提名别人换互推——开源不是零和）/ building in public。
**反 slop 写作红线**（发布前 `/oss-preflight` 审）：个人声音、具体数字、真实使用故事；禁五特征——模板腔、空洞形容词、无具体数据、套话 intro、总结腔。AI 参与写作可以，但**内容的事实底座必须真实**（真实数据/真实截图/真实使用记录），首帖建议用户最终过目。

## 8. 发布脉冲（阶段 F）

- **release**（L2）：ai-todo v0.13 整合打样成果；notes 模板 = 新增/改进/修复三段 + GIF + 升级指引；发布前后 3 日 traffic 对比回写 memory。
- **Show HN**（**L3，用户本人发**）：Hermes 只备支撑包——3 版 title+text 候选、FAQ 预案、发帖日值守监控（日报加密到小时级）。直接贴 GitHub repo 链接（HN 对 repo 链接友好），作者首评讲「为什么造它」。不分享直链求票（HN 反感）。
- **awesome PR**（L2）：awesome-claude-code 提 ai-todo-cli（门槛已满足），严格按其 CONTRIBUTING 格式，每 PR 一个资源。
- **Product Hunt / DevHunt**：待 Show HN 数据复盘后另议（追加记录于本节）。

## 9. 事故与反模式（持续追加，不重写）

（空——首条待打样/发布过程中沉淀）

## 相关记忆

- [[oss-ops-progress]] —— 命题动态进度账本（阶段指针、baseline 状态、待验证预测、效果数据）
