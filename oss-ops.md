# 开源项目运营（oss-ops）

> 沉淀于 2026-08-28。基于 strzhao 名下 28 个非 fork repo 盘点（核心 9 仓）+ 渠道/工具/trending/竞品调研（livecycle 1.5k⭐ playbook 全文 + 2026 现况修正）+ martin 六层上下文工程模式复用。**做任何开源运营动作前先读此文档。** 台账数据是快照会过时，分层红线与渠道规则才是重点。

---

## 1. 定位与分工

开源运营是与 hermes 同级的**持续性命题**。分工三方：

| 角色 | 职责 |
|---|---|
| **用户** | **CEO 角色：只做审批、项目发起、优化发起，不碰具体执行**。给 Hermes 造运营工具（P0 stargazer 分析器 / P1 dev.to 发布工具 / P2 审批硬化）；L2 审批（一切对外动作） |
| **Hermes Agent** | 日常执行：每日巡检 cron、组合铺开、内容起草、release notes 草稿 |
| **martin 侧 Claude Code** | 上下文工程、打样质量件（英文 README 等模板基准）、pre-flight 审视（`/oss-preflight`）、验收 |

指挥层级：**策略在本文档（单点维护），进度在 memory `[[oss-ops-progress]]`，执行状态在 `.autopilot/project/`（dag.yaml）**。Hermes 侧运行手册在 `~/.hermes/skills/github/oss-ops/SKILL.md`（只带运行时必需品，知识不复制）。

### 1.1 自动化优先原则（2026-08-29 用户拍板）

**纯工作量、与效果判断无关的事，一律自动化给 AI；效果判断（选哪张图/何时发/批不批）留给人。** 运营动作按自动化层级选路：

| 层 | 通道 | 适用 |
|---|---|---|
| 1 API | `gh` / dev.to REST / tunnel img | 一切有公开 API 的动作，永远首选 |
| 2 Web UI 自动化 | **opencli**（`@jackwener/opencli`，Chrome Browser Bridge + 169 site adapters + browser 原生命令） | 无 API 但有网页界面的动作：site settings 类操作、平台后台、无 API 的发布渠道 |
| 3 人手工 | 直接请用户 | 无 API 无 UI，或凭据输入（登录/2FA），或自动化被反自动化对抗击败的动作 |

opencli 使用要点（08-29 首战验证）：
- 前置：Chrome 需运行（`open -a "Google Chrome" -g` 可自动拉起），daemon 常驻（端口 19825），扩展连接后 `opencli profile list` 出 session 名，全部命令走 `opencli browser <session> <cmd>`
- `github whoami` 的 logged_in 只验 cookie 存在性≠会话有效，实跑一跳 settings 页才算数；GitHub 对无效会话的 settings 返回 404 而非登录跳转
- `browser find --css/--role/--text` 拿 ref → `click <ref>`；`eval` 可在页面上下文跑任意 JS（含 base64 内存构造 File 注入，绕开 file chooser）
- **social preview 上传 runbook（08-29 实战打通，opencli 层 2 全自动）**：GitHub 无公开 API（GraphQL 只读），走 opencli：①`browser open <repo>/settings` ②eval 里 base64 → `File` → `DataTransfer` → 合成 **drop 事件**打到上传区（**必须 `bubbles: true`**——GitHub 用 document 级委托监听，打偏目标也能冒泡生效）③拖放流上传即生效，**没有 Save 步骤** ④验证别找 Save 按钮：看页面上出现 "Remove image"，或 GraphQL `repository.openGraphImageUrl` 变为 `repository-images.githubusercontent.com/...`（默认是 opengraph.githubassets.com 动态卡）。坑：`input.files+change/input` 合成事件免疫、直 POST `/settings/open-graph-image` 404、原生 chooser 不经真实 UI 点击不弹——这三路不通，别浪费时间。**教训：验证信号要选对（Remove image/API 字段），找错信号会把成功误报成失败靠人眼纠错。**



## 2. 审批分层红线（命题宪法，所有 agent/skill/cron 引用）

**背景**：HN 官方 flag AI 生成/编辑内容（"violates the social contract that it takes more effort to write than read"，2026-08 核实）；Reddit 全面打击 AI slop；**账号声誉是一次性资产**，被封不可恢复。另：hermes 侧外发能力本身无审批门，L2 纪律靠 skill 约定，机制化强制是用户工具 P2（已知缺口）。

| 层 | 定义 | 动作清单 | 执行方 |
|---|---|---|---|
| **L1 全自动** | 只读 + 本地草稿 | stars/traffic/issue/stargazer 采集、日差分、日报、英文 README 及文章**草稿**、release notes 草稿、repo 内务分析 | Hermes cron 独立跑 |
| **L2 起草+审批（无 L3，已合并）** | 一切**对外可见**动作，含发布 | README/LICENSE/topics 推送、issue/PR 评论、dev.to 文章、release 发布、awesome PR、social preview 变更、**Show HN 发帖、KOL/人脉私聊要 star、付费投放、giveaway**（原 L3 全部并入） | 见下方**两路执行** |

**L2 两路执行（2026-08-29 修订二，用户拍板「合作运营」）**——审批确认方式分路，红线不分路：

- **L2-A 异步路（Hermes，用户不在场）**：cron/巡检发起 → 草稿存 `~/.hermes/oss-ops/pending/` → gateway 推**微信**审批 → 用户回「批/改/否 #id」→ Hermes 执行 → 追加 approved.log。48h 无回复自动搁置记入日报。发布工具未就绪时 Hermes 主动找用户要授权/方式。
- **L2-B 实时路（Claude Code/martin 会话，用户在场）**：用户在会话中发起或对草稿明确说「批/发/上」→ **会话内即时确认即执行**，不走微信、不等固定时间窗（含 baseline 等待期——用户可随时拍板提前上线，提前会破坏 P1 的 7 天对照，执行前一句话告知即可）。执行后**同样追加 approved.log**（标注 `realtime` 渠道），Hermes 次日日报对账可见。
- 两路共用的不变项：一切对外动作必须有用户确认（异步=微信批复，实时=会话内明示）；preflight 质检不豁免；反 slop 红线不豁免；`/oss-preflight` 对高风险发布物仍前置。

**正例**：Hermes 写好 issue 回复草稿存 pending → 微信审批 → 批 → `gh issue comment` → approved.log；用户在 Claude Code 会话说「把 O1 上了」→ martin 执行 `gh repo edit` → approved.log 标 realtime。
**反例（禁止）**：cron 里「顺手回复新 issue」「自动发布文章」（未经审批）；Claude Code 会话中**未经用户明示**就推送/发布（实时路≠免审批，只是确认方式从微信变成当面）；用小号互 star；批量 DM 求 star（retargeting 战术同样走 L2 审批，审批前 agent 不做）。

## 3. 项目组合台账（2026-08-28 快照）

| 仓 | slug | ⭐ | 定位一句话 | 短板 | 批次 |
|---|---|---|---|---|---|
| ai-todo | strzhao/ai-todo | 4 | NL-first 任务管理：单输入框+预览执行+无限层级+项目空间（Next.js 16 + DeepSeek，线上 ai-todo.stringzhao.life） | **打样仓**：无 LICENSE/topics/issue 模板，README 纯中文无 GIF，package.json 无 description；**陈年开放 PR#1**（2026-03，子任务 API 端点）待处置（首日巡检发现 08-28） | C |
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
7. **国内渠道**（2026-08-29 核，用户拍板国内运营为一等轨）：
   - **V2EX**：分享创造 / 独立开发者节点，主阵地（有节点发帖规则，鼓励分享与复盘类内容）
   - **掘金**：中文技术内容平台，文章同步出口
   - **少数派 Matrix**：投稿路径 = 注册 → 发 3 篇合规内容转正式作者 → Matrix 发布 → 编辑部精选上首页；应用推荐支持单篇推荐（编辑部整合合集）；ai-todo 工具类应用高匹配
   - **Gitee 镜像**：官方 Push 方向自动镜像低成本；star 数据不互通、流量远低于 GitHub —— GitHub 主仓 + Gitee 国内加速入口、简介引导回主仓；阶段 D 后再评估
   - 国内渠道发布一律 L2 审批流覆盖
8. **Reddit（2026-08-29 核，养号型渠道）**：ai-todo 目标 sub = r/ClaudeAI（精准）> r/SideProject（推广宽松）> r/selfhosted（需真实自托管叙事）。账号实况：`u/Grand-Hope4605` 账龄 1 年 ✅ 但 karma 1 零活跃——**低 karma 账号的推广帖会被 automod 过滤**。opencli reddit adapter 支持 comment/reply/upvote/search/subreddit-info（发布主题帖不在内，走 browser）。**红线：绝对禁止 AI 自动评论/自动发帖——Reddit 是全平台反 AI slop 最严的社区，账号是一次性资产**；AI 只做「找帖 + 起草」，每条评论人审（微信/会话）后才发（opencli 执行）。发 ai-todo 主题帖前置：comment karma ≥ 50 + 在目标 sub 有 2 周以上真实参与史。

## 5. ai-todo 打样 playbook（阶段 C，全部动作先攒 7 天 baseline）

发布顺序（每步都是 L2 除标注）：O1 零成本 API 基建（description/homepage/topics ≤20：`todo, todo-app, task-management, ai, ai-agents, productivity, nextjs, deepseek, natural-language, claude-code, llm, self-hosted, developer-tools, agent-tools`）→ O2 MIT LICENSE（`Copyright (c) 2026 strzhao`）+ issue 模板（bug_report.yml/feature_request.yml 双语）+ CONTRIBUTING 精简版 → O3 **双语 README**（martin 侧 Claude Code 打样，**双头等**：`README.md` 英文完整版 + `README.zh-CN.md` 中文完整版对等非缩水，互链；**GIF 双语各配**——en 配英文操作、zh 配中文操作；结构：hero 一句话+badges+GIF → Why 三卖点 → Quickstart → **For AI agents 段前置**（CLI+skill）→ Features 截图 → 对比表（主轴 agent-first）→ Roadmap/License；`package.json` 补 description）→ O4 social preview（1280×640 PNG，**Sage 苍绿 #3A7D68 品牌色**，英文版/双语版两候选用户挑；API 不可达需用户手工上传）+ og-image 补 metadata + 删空残留目录 `ai-todo-cli/` → O5 oss-repo-lint 打分 ≥9/10 + 排 7 天效果验证 scheduled task。

GIF 规范：≤10s、≤10MB、只录核心动线（输入 NL → 预览 diff → 确认执行）。素材生产链路（2026-08-29 验证全通）：dev bypass（`AUTH_DEV_BYPASS=true`）免登录 + playwright 录屏 + ffmpeg palette 转 GIF（fps12/960 宽/128 色，成品 ~500KB）+ HTML→playwright 截图做 social preview；脚本沉淀在 `apps/web/scripts/`（demo-capture.mjs / capture-social.mjs / seed-demo.mjs）。**⚠ create 类操作预览 bug**（08-29 发现，详见 §9）：GIF 动线用 update 类（稳定路径）。

## 6. 组合铺开策略（阶段 D，Hermes 执行、martin 验收）

先 clone autopilot（27⭐ 最大资产）盘点：README/LICENSE/issues/stargazer 构成——**stargazer 分析器（P0）首战**。
每仓最小集 = LICENSE + description + topics ≥5 + issue 模板 + README 基线（tunnel-cli 补基础版）。
双语策略：核心 4 仓（ai-todo/ai-todo-cli/claude-code-buddy/autopilot）做全英文 README；其余中文为主、顶部加英文摘要段。
批次 1：autopilot / tunnel-cli / ai-news / claude-code-buddy；批次 2：relight / learn-everything / lmedia-cli / stringzhao-life（后者待用户决策处置）。
lint 工具 `oss-repo-lint`（martin/clis/，bash+gh）：LICENSE/README 长度+图+安装节/description/topics ≥5/issue 模板/CI badge/social preview，输出 9 仓打分表，周一随日报附。

## 7. 内容引擎（阶段 E，依赖用户工具 P1）

**双轨制**（2026-08-29 用户拍板：国内运营一等轨）：
- **国际轨**：dev.to 首发（免费 API + 算法推荐 + #showdev），社交渠道引流到平台帖而非自建博客（借平台算法放大）。首篇选题：「给 AI agent 用的 todo：为什么我把 todo CLI 重写成全 JSON 输出」——带真实数据（baseline 期间 star/issue 数字）。
- **中文轨**：V2EX 分享创造首发（中文独立 dev 主阵地）→ 掘金同步 → 少数派 Matrix 养号（3 篇转正后投应用推荐）。首篇题材与英文版同源不同稿（V2EX 语气更社区化，讲真实开发过程）。

内容四象限轮换：直接介绍 / how-to 植入 / listicle（提名别人换互推——开源不是零和）/ building in public。

**养号社区双线（2026-08-29 立，账号资产先行）**：
- **Reddit**（见 §4.8）：r/ClaudeAI 等日常参与攒 karma，AI 找帖起草 + 人审后发；karma ≥ 50 才发 ai-todo 主题帖。
- **少数派 Matrix**：3 篇转正选题全部来自用户真实在用的工具（事实底座厚）：①「我把任务管理丢给 AI agent」（ai-todo 使用向，本稿扩写）② M4 Max 本地 whisper 语音转写环境（效率受众高匹配）③ lmedia-cli Apple Silicon 本地生图/视频零 API 成本（数码受众）。转正后再投应用推荐。

**六站渠道就绪状态（2026-08-29，动态表见 memory）**：dev.to（API 即发，等 api-key/登录）/ 掘金（browser 发，等登录）/ HN（支撑包已备 `write-article-workspace/show-hn-support-pack.md`，等登录+脉冲窗口）/ V2EX（稿就绪，等邀请码激活）/ Reddit（已登录，养号期）/ 少数派（等登录+转正三篇）。
**反 slop 写作红线**（发布前 `/oss-preflight` 审）：个人声音、具体数字、真实使用故事；禁五特征——模板腔、空洞形容词、无具体数据、套话 intro、总结腔。AI 参与写作可以，但**内容的事实底座必须真实**（真实数据/真实截图/真实使用记录），首帖建议用户最终过目。

**视角转换定律**（2026-08-30 实证，全文见 write-article skill `references/viewpoint-laws.md`）：同场景发布者视角 vs 读者视角差 100 倍（小红书实测：产品介绍体 87-104 赞 vs 痛点/教程体 1428-9841 赞）。内容消费社区（小红书/B站/知乎/掘金）一律读者视角——标题=读者痛点/目标、开头降姿态（转述/亲测/踩坑）、产品藏手段位、诚实折扣必配、为收藏设计、干货帖:产品帖 ≥2:1 交替攒账号信任；发布类社区（V2EX 分享创造/dev.to showdev/Show HN）接受宣告体。ai-todo 读者视角选题矩阵五条已备（见该文件）。

## 8. 发布脉冲（阶段 F）

- **release**（L2）：ai-todo v0.13 整合打样成果；notes 模板 = 新增/改进/修复三段 + GIF + 升级指引；发布前后 3 日 traffic 对比回写 memory。
- **Show HN**（**L2，原 L3 并入**：Hermes 起草+审批后**由 Hermes 执行发布**；发布工具未就绪时主动找用户要授权/方式）：Hermes 备支撑包——3 版 title+text 候选、FAQ 预案、发帖日值守监控（日报加密到小时级）。直接贴 GitHub repo 链接（HN 对 repo 链接友好），作者首评讲「为什么造它」。不分享直链求票（HN 反感）。
- **awesome PR**（L2）：awesome-claude-code 提 ai-todo-cli（门槛已满足），严格按其 CONTRIBUTING 格式，每 PR 一个资源。
- **Product Hunt / DevHunt**：待 Show HN 数据复盘后另议（追加记录于本节）。

## 9. 事故与反模式（持续追加，不重写）

- **2026-08-29 · ai-todo create 类操作预览不渲染（已结案：仅 dev 环境，线上无此 bug）**：dev 环境（Turbopack、bypass 用户）下 create 类 action 预览卡不渲染（update 类全正常）；排除法排查至 React 提交环节未定位根因。**用户 08-29 确认线上版无此 bug（create 正常）**——README 的 create 宣称成立，发布不受影响；GIF 保持 update 动线（招牌场景），create 版 GIF 可选补录（改 demo-capture.mjs 的 SCENE 句子即可）。完整报告存 `oss-ops-data/create-preview-bug-20260829.md`（dev-only 线索留产品线参考）。

## 相关记忆

- [[oss-ops-progress]] —— 命题动态进度账本（阶段指针、baseline 状态、待验证预测、效果数据）
