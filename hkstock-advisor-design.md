# hkstock 2.0：AI-native 私人投资顾问方案

> 状态：待评审 · 2026-09-11
> 背景：09-08 上线的 hkstock 理财专家跑了三天，推送一塌糊涂。排障发现病根不在投递层 bug，而在**定位**——系统以"信息流"为锚，不是以"你"为锚。本文先研究"AI-native 投资顾问应该是什么"的行业全貌，再给出完整设计方案。

---

## 0. 现状诊断：三天暴露的四层断裂

| 层 | 断裂点 | 实证 |
|---|---|---|
| 用户认知 | 持仓是**占位假数**（茅台100股@1500 等），偏好**完全空白** | `holdings.yaml` 头注"请口述更新"从未被更新；SOUL.md 零用户画像 |
| 生成 | 简报=通用市场综述，不回答"与我何干" | 三天简报无一句涉及成本/浮亏/仓位占比 |
| 交付 | 稳定送达的是 kanban 机器黑话通知（本地路径+C4/mktd 术语，200字截断）；人话摘要 3 天 2 天投递失败无补发 | 遥测 send_result 记录 |
| 纪律 | SOUL.md 隐私条款"不逐条复述标的与数量"**主动阉割个性化** | 条款本意防外泄，误伤了本人一对一推送 |

一句话：**现在的 hkstock 是一个会写市场评论的机器人，不是一个认识你的顾问。**

---

## 1. 行业研究：AI-native 投顾的全貌

### 1.1 海外参照

**Morgan Stanley（机构标杆，98% 顾问团队采用）**——四个启示：
- 知识层用 RAG 锁定**自有语料**（10 万文档），不靠模型裸奔；
- Debrief 把每次客户互动变成**结构化记忆**回流 CRM；
- **Next Best Action 引擎**：基于客户组合+交易史+偏好推个性化建议；
- 所有产出**人类顾问过手**才到客户——AI 是效率层不是替代者。
（[OpenAI 案例](https://openai.com/index/morgan-stanley/)、[Celent 分析](https://www.celent.com/en/insights/531525129)）

**消费级三杰的分工**（[对比评测](https://skywork.ai/skypage/en/PortfolioPilot-Review-An-In-depth-Analysis-of-the-AI-Financial-Advisor/1975075435329941504)、[Magnifi](https://agent-finder.co/reviews/magnifi)、[Monarch](https://help.monarch.com/hc/en-us/articles/16116906962452-About-Monarch-s-AI-Features)）：
- **PortfolioPilot**：全净资产视图（股/债/房/币）+ 全年税务优化扫描 + 蒙特卡洛情景——**组合级智能**；
- **Magnifi**：自然语言研究副驾 + 组合健康分（集中度/隐藏费率/持仓重叠）——**研究级智能**；
- **Monarch**：AI 周报 + "sparkle" 洞察（解释净值为什么变了）——**认知级智能**。
- 三者共同边界：**只 inform 不 execute**，判断永远留给用户。

**2026 行业趋势**（[MSCI Wealth Trends 2026](https://www.msci.com/research-and-insights/research-reports/2026-wealth-trends)、[Oliver Wyman](https://www.oliverwyman.com/our-expertise/insights/2025/dec/wealth-management-trends-2026.html)、[InvestSuite](https://www.investsuite.com/insights/blogs/top-wealth-management-trends-in-2026-the-shift-to-agentic-ai-and-private-markets)）：
- generative → **agentic**（从答题到自主执行多步工作流）；
- **hyper-personalization 已是 baseline expectation**，不再是加分项；
- "family office 下沉"：组合体检、税务、目标规划变成大众可得的常态服务。

### 1.2 国内参照：蚂小财（7000 万月活验证的形态）

四个与用户相关的设计（[功能解析](http://m.eeo.com.cn/2025/0623/733821.shtml)、[竞品分析](https://www.woshipm.com/evaluating/6125681.html)、[三个皮匠报告](https://m.sgpjbg.com/labels/aizhinengtougupuhuihua.html)）：
1. **盯盘**：只提炼**与持仓相关**的国内外大事并解读净值波动风险——相关性滤镜；
2. **个性化早晚报**：按持仓+行为整理"**与我相关**"的头条——用户可定制关注板块/基金经理；
3. **理性投资提醒**：行情剧烈时累计发出 832 万次提醒——**行为教练**角色，对抗追涨杀跌；
4. **三笔钱**：按人生目标（日常开销/子女教育/养老）做配置规划——**目标导向**而非产品导向。

### 1.3 学术参照：FinMem 系列

[FinMem（AAAI 2024）](https://arxiv.org/abs/2311.13743) → [FinAgent](https://www.arxiv.org/pdf/2507.22936) → [InvestorBench（ACL 2025）](https://www.alphaxiv.org/abs/2412.18174) 的架构共识：
- **Profiling 模块**：风险偏好不是静态表单，随交互经验**自适应演化**；
- **分层记忆**：工作记忆 + 浅/中/深层长期记忆，**不同衰减率**（日报新闻→浅层快衰减；财报/你的买入逻辑→深层慢衰减）；
- 检索打分 = 时效 × 相关性 × 重要性，金融场景额外加时间敏感权重。

### 1.4 合规红线（决定能力边界）

中国监管是**功能监管、穿透认定**（[财联社](https://m.cls.cn/detail/2451503)、[江苏检察](https://www.jsjc.gov.cn/shzs/fzzc/202604/t20260408_1320912.shtml)）：凡输出具体品种判断/买卖时点提示，无论包装成什么，即落入投资咨询监管，须持牌。

**本系统的安全位**：纯自用（只服务你本人）、不收费、不对外发布、不做买卖指令——保持在"**信息 + 解读 + 结构化信号**"层，永不进"指令"层。这是设计红线，不是局限。

### 1.5 提炼：AI-native 私人投顾的五个不变量

```
1. 以"你的资产负债表 + 画像"为锚，不是以信息流为锚
2. 每条推送必须回答"与我何干、我多该在意"（相关性滤镜）
3. 画像与记忆随交互成长（不是一次性表单）
4. 主动但克制：默认不打扰，打扰要有预算和理由
5. 信息/解读/信号可以自动，指令永不出系统
```

---

## 2. 目标形态：你的私人分析师的一天

| 时刻 | 你收到的 | 形态 |
|---|---|---|
| 08:23 盘前 | **账户晨报**：你的组合昨收变化（盈亏 vs 成本、仓位）→ 与你相关的 ≤3 件事 → 今日唯一要你看一眼的变量 | 微信，2 分钟读完 |
| 盘中 | **默认静默**。只有触发预设条件才推（持仓单日 ±5%、你关心的财报/公告落地、信号库新信号） | 异动卡，说明"为什么值得打扰你" |
| 15:45 收盘后 | **账户日报**（可关）：今日盈亏归因、有无信号命中/失效 | 微信，1 分钟 |
| 周六 09:43 | **周复盘**：你的组合 vs 基准、信号命中率回顾、下周日历、一个画像确认问题 | 微信 + 对话 |
| 随时 | **持仓问答**："茅台这笔我还亏多少？""平安银行最近为什么强？" | 微信对话 |
| 每月 | **组合体检**：集中度/重叠度/与目标的偏离度（三笔钱视角），只给解读不给指令 | 微信长卡 |

---

## 3. 架构方案（六层）

```
┌─ L6 治理层：合规红线 + 质量 KPI + 反馈闭环
├─ L5 互动层：微信问答 / 主动补全画像 / 复盘对话
├─ L4 交付层：简报2.0契约 + wake-only 推送 + 失败补发 + 隐私分级
├─ L3 分析层：三分析师 + 画像滤镜 + 信号库 + 命中率回测
├─ L2 感知层：mktd/akshare 现有 + 持仓事件监控（公告/财报/分红）
└─ L1 用户认知层：真实持仓 + investor-profile + 交互记忆 ← 当前全空
```

### L1 用户认知层（P0，本周，需要你参与）

**① holdings.yaml 真实化**：账户结构 / 标的 / 数量 / 成本 / 买入逻辑（为什么买——这是深层记忆，决定日后解读角度）。你口述，我落档。

**② 新建 `investor-profile.md`**（投资画像单一真源）：
- 风格与期限（价投/波段/红利；每笔打算持多久）
- 风险偏好（可接受的最大回撤、对亏损的真实反应）
- 关注板块与标的池（watchlist）
- 目标与约束（这笔钱的目标、有无新增资金计划、忌讳不碰什么）
- 推送偏好（频率、长度、能看多细）

**③ 交互记忆**：问答/反馈沉淀进 honcho + profile 增量更新——画像不是建完就冻，每次你纠正它（"我不关心这个板块"）都落档。

### L2 感知层（P1）

现有 mktd/akshare/快讯保留，**增量是"持仓事件监控"**：财报披露日、公告、分红除权、行业政策（如白酒批价、银行注资）——这些是"与你有关"的第一筛选器。宏观日历只保留与你持仓/画像相关的条目。

### L3 分析层（P1-P2）

- 三分析师框架（基本面/资金面/事件）保留，**收敛时加画像滤镜**：这条信息对"你的成本、你的仓位、你的期限"意味着什么；
- signals.jsonl 继续 append-only 积累，**加命中率月度回测**（复盘卡已具雏形）；
- FinMem 式分层：日报快讯=浅层（当周衰减）、财报与买入逻辑=深层（长期保留）。

### L4 交付层（P0-P1，含上轮已诊断的修复）

- **简报 2.0 契约**（见 §4 样例）：账户为锚，长度有硬上限，每段必须过"与我何干"检查；
- **推送链路修复**：kanban 订阅 notify→wake-only（消灭机器黑话直推）；摘要 send 失败→延迟补发 + 补发也败则降级告警；
- **隐私分级重写**：本人微信 DM 的持仓细节口径由你拍板（见决策点 D1），SOUL.md 条款按拍板改写。

### L5 互动层（P2）

- 持仓问答走微信对话（hkstock profile 已有入口）；
- **主动补全**：每周复盘卡末尾带一个画像确认问题（"你这笔茅台打算拿多久？"），像真人顾问 onboarding 一样渐进建档；
- 你的每次纠正都是画像的增量输入。

### L6 治理层（P0 起持续）

- **合规红线入 SOUL**：永不输出买卖指令/买卖时点；信号只给方向+置信+证据链；每份简报送免责尾行（已有）；
- **质量 KPI**：①推送零机器黑话（本地路径/卡 ID/C4 等术语不得出现）；②人话摘要送达率 100%（失败有补发记录）；③每条内容过"与我何干"自检；④信号命中率季度回顾；
- **反馈闭环**：你对推送的回复/忽略模式进入画像（总忽略期货段→降权；总追问白酒→加权）。

---

## 4. 简报 2.0：改版前后对比

**现在（09-11 实际推送，投递失败的版本已经算好的了）**：
> 隔夜美股三连跌 + 通胀交易回归……茅台 1285.13（-0.45%）：缩量阴跌……110022 消费基金 -1.63%：连跌四日……

——换成任何一个读者都成立，没有一句只有你能读到的话。

**2.0 目标形态（示意，数字将来自你的真实持仓）**：
> 📊 **你的账户 · 09-10 收盘**
> 组合当日 -0.8%，相对成本累计浮亏 X.X%。主要拖累是茅台（占组合 N%）。
>
> **与你相关的 3 件事**
> ① 茅台盘中 1282 破了 9/9 低点——你成本 M 元，现浮亏 P%；按你的期限（你说过这是长持仓），这次破位不改变买入逻辑（半年报利空已落地），但中秋批价是下一个验证点
> ② 平安银行逆势放量 +1.28%——银行中期分红 2660 亿话题升温，与你的红利偏好同向
> ③ 今晚 20:30 美国 CPI——若超预期，你的消费基金（已连跌四日）短期还会承压，但与你无关操作，只需知道
>
> **今日唯一要你看一眼的**：茅台能否收回 1290。收不回我周六复盘会展开。

差异：每句话都过了"成本/仓位/期限/偏好"滤镜；市场新闻从主角降为配角；结尾只有一个钩子不是四个。

---

## 5. 路线图与验收

| 期 | 内容 | 验收 |
|---|---|---|
| **P0 建档周**（本周） | 你口述持仓+画像 → holdings.yaml 真实化 + investor-profile.md v1；隐私口径拍板；推送链路修复（wake-only + 补发） | 简报引用真实成本/仓位；零黑话推送；摘要送达率 100% |
| **P1 简报 2.0**（下周） | morning-brief skill 改版（账户为锚契约）；异动触发器（±5%/财报/公告）；可选收盘日报 | 连续 5 个交易日每份简报过"与我何干"抽检 |
| **P2 记忆成长**（第 3-4 周） | 问答偏好沉淀、周复盘带画像确认问题、信号命中率回顾进周报 | investor-profile 有 ≥3 次交互驱动的增量更新 |
| **P3 组合体检**（月度） | 集中度/重叠/三笔钱偏离度月卡 | 首月产出一份你认可"值得读"的体检卡 |

---

## 6. 待你拍板的决策点

下面几个选择决定 P0 怎么落地，可直接在页面里点选提交：

```interactive
id: privacy-level
type: radio
question: D1 隐私边界——本人微信一对一推送，持仓细节给到什么口径？
options:
  - 全量：标的+数量+成本+盈亏金额都可以出现
  - 半脱敏：标的+盈亏百分比可以，不出现具体金额和数量
  - 保守：只说方向和结论，盈亏百分比也不出现
```

```interactive
id: push-budget
type: radio
question: D2 打扰预算——盘中异动要不要推？
options:
  - 早晚两报 + 盘中异动（持仓±5%/财报/公告才推，说明理由）
  - 只要早晚两报，盘中一律不打扰
  - 只要晨报，收盘日报也不要
```

```interactive
id: evening-report
type: radio
question: D3 收盘账户日报（15:45，1 分钟读完：今日盈亏归因+信号命中）要吗？
options:
  - 要，每天收
  - 不要，晨报+周复盘够了
  - 先开一周试试再定
```

```interactive
id: onboarding-style
type: radio
question: D4 画像建档方式偏好？
options:
  - 一次口述全给（我现在就在这个页面/微信里说完）
  - 渐进式：先给持仓，偏好靠每周复盘一个问题慢慢补
  - 混合：持仓+三条最重要的偏好先给，其余渐进
```

```interactive
id: holdings-now
type: text
question: D5 如果选"一次口述"，直接写这里：真实持仓（账户/标的/数量/成本）+ 三条偏好（期限/风格/忌讳）。也可留空改在微信里口述
placeholder: 例：A股账户 茅台200股@1620（长持）、……；偏好：红利+价投，单笔至少拿半年，不碰题材炒作
```

```interactive
id: overall-score
type: rating
question: D6 方案整体打分（1-5）
```

```interactive
id: overall-comment
type: text
question: D7 其他意见、漏掉的诉求、或对方案的修正
placeholder: 选填，800 字内
```

---

## 增补：2.1「组合观点」升级（2026-09-11 深夜，用户二次反馈拍板）

2.0 演练简报仍被评"和 app 看没区别"——只报涨跌幅不够。用户原话定稿核心产出：**"告知我当前适合买什么、适合卖什么、或者什么都不动，以及原因是什么"**，并明确"价值投资，不做短线和量化"。

落地变更：
- **核心产出 = 组合观点**：每持仓落入 加仓/持有/减仓/清仓/观望 五态 + 理由链；开头一行组合总观点；
- **理由只准来自基本面与估值**（PE-TTM 当前值+近十年分位 `ak.stock_hk_valuation_baidu`、财报 `ak.stock_financial_hk_report_em`、回购/分红、行业格局）；技术分析词汇只作背景不作论据；
- **观点稀缺性纪律**：默认「不动」，观点变化须有基本面/估值新触发；
- **投研档案** `hkstock-data/theses/<symbol>.md`（活体：当前观点+观点历史 append-only；买入逻辑栏待用户口述，AI 不代编）；
- **合规边界重定义**：「不做买卖指令」细化为——不**执行**交易、不**对外**荐股不变；给本人的组合观点（加仓/持有/减仓+理由链）是本系统核心服务。免责尾行保留。

## 附：研究来源

- [MSCI Wealth Trends 2026](https://www.msci.com/research-and-insights/research-reports/2026-wealth-trends) · [Oliver Wyman 10 Wealth Trends 2026](https://www.oliverwyman.com/our-expertise/insights/2025/dec/wealth-management-trends-2026.html) · [InvestSuite: Agentic AI 趋势](https://www.investsuite.com/insights/blogs/top-wealth-management-trends-in-2026-the-shift-to-agentic-ai-and-private-markets)
- [OpenAI × Morgan Stanley](https://openai.com/index/morgan-stanley/) · [Celent: AI @ Morgan Stanley Assistant](https://www.celent.com/en/insights/531525129)
- [PortfolioPilot 评测](https://skywork.ai/skypage/en/PortfolioPilot-Review-An-In-depth-Analysis-of-the-AI-Financial-Advisor/1975075435329941504) · [Magnifi 评测](https://agent-finder.co/reviews/magnifi) · [Monarch AI 功能](https://help.monarch.com/hc/en-us/articles/16116906962452-About-Monarch-s-AI-Features)
- [蚂小财 2025 新版解析](http://m.eeo.com.cn/2025/0623/733821.shtml) · [蚂小财 vs i问财 vs 妙想竞品分析](https://www.woshipm.com/evaluating/6125681.html) · [AI 智能投顾普惠实践](https://m.sgpjbg.com/labels/aizhinengtougupuhuihua.html)
- [FinMem (arXiv 2311.13743)](https://arxiv.org/abs/2311.13743) · [FinAgent (arXiv 2507.22936)](https://www.arxiv.org/pdf/2507.22936) · [InvestorBench (ACL 2025)](https://www.alphaxiv.org/abs/2412.18174) · [Agentic Trading 综述 2026](https://arxiv.org/html/2605.19337v1)
- 合规：[财联社·投顾新规](https://m.cls.cn/detail/2451503) · [江苏检察·无资质荐股案例](https://www.jsjc.gov.cn/shzs/fzzc/202604/t20260408_1320912.shtml) · [中基协·智能投顾国际监管经验](https://www.amac.org.cn/hyyj/hjtj/201912/P020231126399651565749.pdf)

## 增补：2.2「列表化 + 教学式原因」（2026-09-11 深夜，用户三次反馈拍板）

- 推送形态=**组合观点列表**：每仓一行（动不动+一句原因）+ 新买入候选行；免责套话/合规口径段全废（用户原话"把之前定的红线去掉，没意义，我个人用的，我要参考 AI 的建议结合我自己的判断"）
- **原因行=教学式写法**（用户核心诉求："通过原因说明教会我，让我后续也能学习和掌握相关的判断能力"）：讲透判断方法、给可复用规则；用到的规则落「方法笔记」行
- 简报五段：组合观点/隔夜与盘前/持仓关联/期货日报摘要/今日关注与建议；验收测试同步翻转（6.P4 断「组合观点」在场+「不构成投资建议」缺席；契约漂移豁免=holdings 或 SKILL 晚于产物时谓词待下一份判定）
- 演练卡 t_bf9687c4 PASS：列表形态+教学式理由链（分位语义/低估值≠错杀/利润增速双向看/结构纵向坐标）+3 条方法笔记
