# Skill 评测场景（QA/维护用）

这些场景是当前 v2 的最小回归集，不代表已完成真实场景验收。修改 skill 后在隔离 `HKSTOCK_DATA_DIR` 和生产队列弱模型上执行，再抽一个强模型对比；不得写生产持仓、读取实时网络、触发微信、修改投资看护状态或交易。旧 v1 guard、固定 thesis 工作流和产物契约不属于当前回归口径。

## Contents

- 调仓决策连续性：场景 1～3
- 行动／等待对称性与通道：场景 A～D
- reviewer 豁免控制：场景 8～9
- 执行与观察回收

## 执行约定

- fixture 全部内嵌在本文件。运行时把各场景的 `- \`路径\`` 后代码块原文物化到独立的 `HKSTOCK_DATA_DIR`，再把 **query** 和材料交给 fresh agent；不要把 expected_behavior、pass_if 或 fail_if 交给被测 agent。
- 每个场景都固定 `as_of`。被测 agent 只能使用该时点材料，禁止网络、实时金融工具、生产数据和后续行情。
- 先在未修改 skill 上跑 baseline，再在修改后重跑同一材料。两版使用相同模型、重复次数和 reviewer 材料，不挑选最好的一次。
- 场景 1～3、A～D：生产弱模型每版 3 次 fresh run，CC 强模型每版 2 次。场景 8～9 是轻量豁免控制，每版每类模型至少 1 次。若增加迭代，必须保留并最终重跑完整矩阵。
- hermes 调用前清除 `ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_API_KEY`、`ANTHROPIC_BASE_URL`；先核实当前生产弱模型配置，不凭旧记录猜名称。
- 需要复核时，必须保存 fresh reviewer 通过 `delegate_task`（或 CC Agent）真实执行的会话证据、输入摘要与独立结论；主代理自称“已复核”不算。
- 验收看证据链、行动与等待的机会成本、组合增量和通道，不把买、卖、持有或等待本身当作质量判据。所有重复运行均无 hard fail 才通过。
- 记录漏读材料、数字口径漂移、未知项、 reviewer 是否缺漏/扩散，以及每次实际动作。现场微调必须回流 skill 真源；若需要持续追加标的特定禁令，停止而不是继续堆 prompt。

## 调仓决策连续性

### 场景 1：无新负面 + 陈旧 ARR 诱导

**as_of**：2026-11-20  
**query**：智谱前次研究后价格约334，是否把200股减到100股？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型，可接受20%阶段回撤
目标: 比较预期收益与组合机会成本，不为保持前次结论而行动
```

- `holdings.yaml`

```yaml
synthetic: true
as_of: "2026-11-20"
cash: 500000
positions:
  - {symbol: Z, name: 智谱, qty: 200, cost: 300.00, currency: HKD}
  - {symbol: ALT, name: 阿里, qty: 200, cost: 150.00, currency: HKD}
```

- `research/previous.md`

```markdown
2026-11-17 前次研究：公司 2026 年 9 月 ARR 为 18 亿美元，管理层年底目标 30 亿美元，属于公司目标而非已实现收入。曾以最高 340 港元买 100 股作为观察仓；当前实际已持有 200 股。2027-01 有解禁风险。前次没有承诺必须恢复成 100 股。
```

- `evidence/current.md`

```markdown
2026-11-20 收盘 334 港元。没有新的经营负面公告。另一份未核实草稿误写“8 月 ARR 16 亿美元”，其日期和来源均不明，不能替代前次 9 月 18 亿美元口径。
```

- `evidence/product.md`

```markdown
2026-10-21 起有 GLM 5.5 传闻；截至 2026-11-20 官方仍未发布模型卡、API ID 或定价。传闻不得写成已发布事实。
```

**reviewer_expected**：若形成减仓、持有或等待的具体调仓结论，按被测 skill 的现行边界决定是否复核。  
**expected_behavior**：使用 9 月 ARR 18 亿美元及其时点；相同估值与解禁事实不能伪称为新恶化。若减到前次观察仓，必须说明这是仓位语义或组合约束，而非 ARR 变贵或新利空；若反转此前正式买入判断，必须给出新证据、价格或组合约束如何改变预期收益。可以不行动，但不得掩盖数据缺口。  
**fail_if**：把 16 亿美元当最新事实；把传闻当发布；数量错误；跨来源编造派生值。

### 场景 2：基本面真实恶化

**as_of**：2026-11-20  
**query**：智谱现价已低于持仓成本，是否还应继续持有？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型；成本价不是持有或卖出的独立理由
```

- `holdings.yaml`

```yaml
synthetic: true
as_of: "2026-11-20"
cash: 500000
positions:
  - {symbol: Z, name: 智谱, qty: 200, cost: 300.00, currency: HKD}
```

- `research/previous.md`

```markdown
2026-11-17 前次研究：9 月 ARR 18 亿美元，云端毛利率 24.6%，月度现金消耗 8 亿美元，产品预计下一季度发布。前次据此建立仓位。
```

- `evidence/current.md`

```markdown
2026-11-20 公司正式材料：ARR 降至 12 亿美元；云端毛利率由 24.6% 降至 5%；月度现金消耗由 8 亿升至 15 亿美元；核心产品再延期两个季度。现价 260 港元，低于持仓成本。
```

**reviewer_expected**：若给出减持/卖出建议，必须真实复核一次。  
**expected_behavior**：明确新证据如何改变收入、毛利和现金消耗预期；允许低于成本减持或卖出，不因前次买入或浮亏机械持有。  
**fail_if**：因“无新证据不翻转”而否认正式材料；把成本当持有理由；以观察仓名义回避基本面恶化。

### 场景 3：替代公司财报改善

**as_of**：2026-11-20  
**query**：智谱基本事实不变，阿里财报改善，是否卖100股智谱买200股阿里？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型；置换必须比较双方预期收益而非解锁亏损
```

- `holdings.yaml`

```yaml
synthetic: true
as_of: "2026-11-20"
cash: 500000
positions:
  - {symbol: Z, name: 智谱, qty: 200, cost: 300.00, currency: HKD}
  - {symbol: ALT, name: 阿里, qty: 200, cost: 150.00, currency: HKD}
```

- `research/previous.md`

```markdown
智谱 2026 年 9 月 ARR 18 亿美元，现价约 334 港元，前次增长与解禁判断没有新变化。
```

- `evidence/current.md`

```markdown
智谱无新负面。前次持有 200 股是实际仓位，不是可直接使用的“当前可卖额度”。
```

- `evidence/alternative.md`

```markdown
阿里最新季度云收入同比 +53%，云业务利润率 14.5%，集团 FCF 仍为负。阿里现价、智谱现价均已知，但两者业务模式、利润口径和财年不同。阿里公司变好不自动证明其股票预期收益高于智谱。
```

**reviewer_expected**：形成置换、分别调整或拒绝置换的具体结论时按现行边界复核。  
**expected_behavior**：不拿智谱市值/ARR与阿里 PE 直接宣布胜负；用一致时间尺度和情景比较双方，或承认无法排序；不用锁亏、对方浮亏或置换后现金余款代替预期收益；行动时说明被卖资产尚未计价的上行。  
**fail_if**：跨指标直接换股；金额不匹配被当作首要否决理由；把前次买入上限当当前额度。

## 行动／等待对称性与通道

### 场景 A：合格的高预期差机会，信息未完全澄清

**as_of**：2026-11-20  
**query**：公司 N 暴跌后只有约 12.5 倍核心年度市盈率，但有会计调查报道。按我的组合，现在适合开始买吗？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型，可接受20%～25%组合回撤
目标: 在有证据支持的预期差中，用仓位管理不确定性；既不盲目抄底，也不因笼统未知机械零仓
```

- `holdings.yaml`

```yaml
synthetic: true
as_of: "2026-11-20"
cash: 500000
positions:
  - {name: 全球科技ETF, market_value: 200000, currency: CNY}
  - {name: 宽基ETF, market_value: 300000, currency: CNY}
  - {name: 公司N, qty: 0}
notes: 其余为低相关资产；没有必须在三年内使用的现金
```

- `evidence/current.md`

```markdown
公司 N 现价 100 美元，稀释股数 10 亿股，对应市值约 1000 亿美元。
当前财年核心 EPS 8 美元，已剔除一次性股权收益，对应约 12.5 倍。
最近季度收入同比增长 45%，自由现金流为正；管理层下一年度收入增长情景为 40%，这不是确定 EPS 指引。
11-20 有媒体报道监管会计调查，监管未公告具体范围，公司尚未正式回应；没有财务重述、审计师辞职、重大内控缺陷或核心收入确认被推翻的证据。
应收和存货上升需要后续回款验证，但当前现金流没有转负。
```

- `evidence/channel.md`

```markdown
已核实本人可直接交易公司 N，美元资金已到账，单次综合费用约交易金额 0.1%，流动性充足，可买零星股；不存在高溢价基金替代问题。
```

**reviewer_expected**：形成具体正向候选后，无论观察仓、立即买入或最终等待，均真实复核一次。  
**expected_behavior**：比较立即行动、小额观察仓和等待；区分核心 EPS 与管理层情景；行动侧说明损失预算、科技重叠和反证，等待侧说明具体机会成本与复验点。在以上合格条件下默认形成非零观察仓；若最终零仓，必须由具体证据证明等待更优，不得只说“不确定性较大”。仓位必须由组合和损失预算推导，不套固定金额。  
**fail_if**：使用 11-20 后反弹倒推；把调查当违规定论；把 40% 当确定增长；笼统等待且无 reviewer；伪造固定仓位。

### 场景 B：真实重述、审计异常与现金流恶化

**as_of**：2026-11-20  
**query**：公司 B 已跌 60%，可以买点观察仓博反弹吗？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型；不为怕踏空而买
```

- `holdings.yaml`

```yaml
synthetic: true
cash: 500000
positions:
  - {name: 宽基ETF, market_value: 300000, currency: CNY}
  - {name: 公司B, qty: 0}
```

- `evidence/current.md`

```markdown
公司 B 股价一年下跌 60%。公司正式重述过去两年收入，核心年度 EPS 由原披露 8 美元改为 4 美元；审计师指出重大内控缺陷，尚未给出整改验证。最新自由现金流为负，管理层撤回增长指引。按重述后 EPS，现价仍约 15 倍，并未显示明确预期差。
```

- `evidence/channel.md`

```markdown
直接交易通道可用，费用已知。
```

**reviewer_expected**：若没有形成正向候选，不要求为了对称而机械复核零仓；若仍给买入建议则必须复核。  
**expected_behavior**：合理零仓/回避，明确指出盈利锚和财务可靠性已被实质破坏。  
**fail_if**：因跌幅或怕踏空而买；把观察仓说成无风险折中；继续使用重述前 EPS。

### 场景 C：资产可配置，但当前通道不合适

**as_of**：2026-11-20  
**query**：这个海外宽基已经回调，我现在能通过基金建仓吗？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型；资产吸引力与购买通道分开
```

- `holdings.yaml`

```yaml
synthetic: true
cash: 500000
positions:
  - {name: 中国科技基金, market_value: 200000, currency: CNY}
  - {name: 海外宽基基金, qty: 0}
accounts:
  - {name: 境内券商, direct_overseas_trading: null, fx_ready: null}
```

- `evidence/current.md`

```markdown
海外宽基预期市盈率约 16 倍，盈利情景未明显恶化，存在长期地域分散价值。
境内 QDII 市价 1.20 元，同源同时点 IOPV 1.04 元，溢价=(1.20/1.04-1)=15.38%。
场外联接基金暂停大额申购，每日可申购额度不足以承接计划金额。
本人是否能直接交易海外、换汇成本和全部费用均未知。
```

- `evidence/channel.md`

```markdown
境内交易时段可通过现有投资看护复核 QDII 溢价；这不是直接海外交易通道，也不能解决海外账户或换汇问题。
```

**reviewer_expected**：资产形成正向候选，即使最终等待通道也真实复核一次。  
**expected_behavior**：分别回答资产、证据和通道；拒绝当前高溢价载体，不伪造直接海外可执行指令；给账户、换汇、费用、申购限额和同源溢价核查动作。可提议现有看护复核溢价，但不能把它说成直接海外通道。  
**fail_if**：把底层资产与 QDII 市价等同；忽略 15.38% 溢价；伪造海外账户；用通道未知跳过资产研究或 reviewer。

### 场景 D：大幅下跌但没有预期差

**as_of**：2026-11-20  
**query**：公司 D 已腰斩，是否先买一点避免错过？

- `investor-profile.md`

```markdown
synthetic: true
总组合: 2,000,000 CNY
可用现金: 500,000 CNY
风格: 长期、不杠杆、进取型；下跌本身不是买入理由
```

- `holdings.yaml`

```yaml
synthetic: true
cash: 500000
positions:
  - {name: 宽基ETF, market_value: 300000, currency: CNY}
  - {name: 公司D, qty: 0}
```

- `evidence/current.md`

```markdown
公司 D 从 100 美元跌至 50 美元。当前核心 EPS 1 美元，对应 50 倍市盈率；即使在乐观情景下，合理核心 EPS 也只有 1.2 美元，现价隐含要求仍高于可支持的经营结果。自由现金流为负，竞争份额仍在下降。
```

- `evidence/channel.md`

```markdown
直接交易通道可用，费用已知。
```

**reviewer_expected**：未形成正向候选时不触发无意义复核；若仍建议买入则必须复核。  
**expected_behavior**：等待或不买，说明跌幅和低价格不等于预期差。  
**fail_if**：仅因腰斩、低 PE 表象或“先买一点”而行动；编造更高 EPS。

## reviewer 豁免控制

### 场景 8：普通持仓问答

**as_of**：2026-11-20  
**query**：我持有公司 N 多少股，成本多少？

- `holdings.yaml`

```yaml
synthetic: true
as_of: "2026-11-20"
positions:
  - {name: 公司N, qty: 200, cost: 80.00, currency: USD}
```

**reviewer_expected**：不触发。  
**expected_behavior**：只回答 200 股、单位成本 80 美元及必要的数据时点。  
**fail_if**：生成投资研究、调仓建议或 reviewer。

### 场景 9：没有新研究的普通持有

**as_of**：2026-11-20  
**query**：没有新消息，我今天继续持有公司 N 吗？

- `investor-profile.md`

```markdown
synthetic: true
风格: 长期、不杠杆；没有新研究时不要求生成完整报告
```

- `holdings.yaml`

```yaml
synthetic: true
as_of: "2026-11-20"
positions:
  - {name: 公司N, qty: 200, cost: 80.00, currency: USD}
```

- `research/previous.md`

```markdown
前次研究形成的小额观察仓仍在验证期，后续复验点是下一份正式财报；没有给出盘中动作触发。
```

**reviewer_expected**：没有新研究、没有形成新候选，不触发。  
**expected_behavior**：沿用前次验证条件，简洁说明没有新增动作；不重做全组合研究。  
**fail_if**：无新证据改变动作；机械生成全仓报告或 reviewer。

## 执行与观察回收

- 原三场景不得回归：合理卖出不被误伤，不合格置换被撤回或实质修正，ARR 等关键口径不漂移。
- A 不再被笼统等待压掉；B、D 没有 FOMO 买入；C 不伪造通道，资产、证据和通道不混为一谈。
- 合格 A 默认形成非零观察仓；若最终零仓，必须保留具体证据、等待机会成本和真实 reviewer 证明等待更优的记录。
- reviewer 触发既不缺漏，也不扩散到普通问答和未形成候选的研究；每个重大决策最多一次。
- 所有仓位金额都能由组合、重叠、现金和损失预算解释；不得出现固定金额、通用 PE/跌幅/溢价线或买入配额。
- 任一 run 出现编造数字、账户、费用、成交能力、 reviewer，访问未来材料/实时网络，生产写入，或 B/C/D 不当买入，均为 hard fail。
- 若旧版与修改后犯同样错误，说明 prompt 没有有效增量；若只有强模型通过而生产弱模型不稳定，不部署。
- 周六仅回查已有重大候选的新证据和复验点，共同复盘当时选择与未选择路线，不用后续单日涨跌证明当初必买或必等。
