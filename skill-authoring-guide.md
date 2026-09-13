# Skill 开发最佳实践

> 来源：Anthropic 官方《Skill authoring best practices》（platform.claude.com/docs，2026-09-13 整理入库）。
> **何时读**：新建、修改、评审**任何 SKILL.md** 之前——CC 的 `.claude/skills/`、仓内 `skills/`、hermes 的 `~/.hermes/skills/` 与各 profile skills 一律适用。
> 配套：改 hermes skill 子系统**源码**看 [`harness-engineering-principles.md`](harness-engineering-principles.md)；在 CC 里动手创建/迭代 skill 优先走 `skill-creator` skill，本文做验收口径。

## 0. 心智模型：三段式加载机制（决定一切写法）

skill 不是一次全量注入的 prompt，而是按需加载的文件系统：

1. **发现层**：启动时只有所有 skill 的 `name` + `description`（frontmatter）预载进 system prompt。
2. **加载层**：Claude 判断相关后才读 SKILL.md 正文。
3. **执行层**：正文里指向的引用文件按需再读；脚本**只执行不加载**——只有输出进 context。

两条推论：

- **description 决定「会不会被选中」**——它是 skill 唯一的销售员，写砸了正文再好也白搭。
- **大文件放引用文件零 context 成本**——这是渐进披露的物理基础（§1 原则四）。

## 1. 五条核心原则

### 原则一：Context 是公共财——简洁至上

SKILL.md 正文一旦被加载，其中每个 token 都在与会话历史、其他上下文竞争。默认假设：**Claude 已经很聪明**。只写它不知道的：领域私有事实、仓内约定、脆弱步骤。每段过三问：

- Claude 真的需要这个解释吗？
- 能假设它已经知道吗？
- 这段配得上它的 token 成本吗？

```markdown
✗ 冗余（~150 tokens）：「PDF（Portable Document Format）是一种常见文件格式，
  包含文本、图像等内容。要提取文本需要使用库，有很多库可选，推荐 pdfplumber
  因为易用且覆盖大部分场景。首先你需要用 pip 安装它，然后……」

✓ 简洁（~50 tokens）：
  使用 pdfplumber 提取文本：
  ```python
  import pdfplumber
  with pdfplumber.open("file.pdf") as pdf:
      text = pdf.pages[0].extract_text()
  ```
```

### 原则二：自由度分级——约束密度匹配任务脆弱度

| 自由度 | 形态 | 何时用 |
|---|---|---|
| 高 | 文本指引（启发式、多路线） | 多种做法都成立、决策依赖上下文（如 code review） |
| 中 | 伪代码 / 带参数的模板 | 有偏好路径但允许变化、配置影响行为（如报表生成） |
| 低 | 精确脚本、禁改参数 | 操作脆弱易错、一致性关键、顺序不可换（如 DB migration） |

**类比**：悬崖上的独木桥（只有一条活路）→ 低自由度，给精确指令；无障碍开阔地（条条大路）→ 高自由度，给方向就好。

判据只有一条：**这一步错了会不会报废重来？** 会 → 收紧自由度；不会 → 放手。

### 原则三：description 是唯一的选择器

Claude 靠它在 100+ 候选 skill 中做选择。铁律：

- **第三人称**（description 会进 system prompt，人称混乱干扰发现）：✓「提取 PDF 文本并生成报告」；✗「我可以帮你处理 Excel」「你可以用这个来……」
- **必须同时写「做什么」+「何时用」**（触发场景/用户会提到的关键词）：

```yaml
# ✓ 好：动作全 + 触发词全
description: Extract text and tables from PDF files, fill forms, merge documents.
  Use when working with PDF files or when the user mentions PDFs, forms,
  or document extraction.

# ✗ 坏：零信息量
description: Helps with documents
description: Processes data
```

- **name 规范**：小写字母/数字/连字符，≤64 字符；推荐动名词形态（`processing-pdfs`、`analyzing-spreadsheets`）或名词短语（`pdf-processing`）；禁保留词 `anthropic`/`claude`；禁空词（`helper`/`utils`/`tools`/`documents`/`data`）。

> hermes 侧：`agent/skill_utils.py` 解析同构 frontmatter，并额外支持 `platforms` / `environments` 门控字段（限定加载平台/运行环境）。上述 name/description 纪律两边通用。

### 原则四：渐进披露——SKILL.md 是目录，不是全书

- 正文 **<500 行**；接近上限就拆引用文件。
- **引用只许一层深**：所有引用文件必须从 SKILL.md 直接链出。嵌套引用（A→B→C）会被部分预览（`head -100` 式），信息不完整。
- **>100 行的参考文件顶部加 Contents 目录**——部分读取时仍能看到全貌。

三种组织模式：

```markdown
# 模式 1：高层指引 + 引用文件
## Advanced features
**Form filling**: See [FORMS.md](FORMS.md)      ← 需要时才读
**API reference**: See [REFERENCE.md](REFERENCE.md)

# 模式 2：按域分文件（问销售只载销售，token 最省）
**Finance**: → reference/finance.md
**Sales**:   → reference/sales.md
（正文附 grep 快查入口）

# 模式 3：条件深化（基础在正文，高级按条件读）
## Editing documents
For simple edits, modify the XML directly.
**For tracked changes**: See [REDLINING.md](REDLINING.md)
```

文件名自描述（`form_validation_rules.md` 而非 `doc2.md`），目录按域组织（`reference/finance.md` 而非 `docs/file1.md`）。

### 原则五：先评测后写作，用真实运行迭代

**eval-first（评测驱动）**——防「为想象中的需求写文档」：

1. **裸跑找 gap**：不带 skill 跑代表性任务，记录具体失败/缺失的上下文。
2. **造 3 个评测场景**：对准这些 gap。结构：`{skills, query, files, expected_behavior[]}`。
3. **测基线**：无 skill 时 Claude 的表现。
4. **写最小指令**：刚好覆盖 gap、能过评测即可。
5. **迭代**：跑评测对比基线，逐步打磨。

**Claude A/B 迭代法**：Claude A（设计者）帮你写/改 skill，Claude B（fresh 实例、带 skill）干真活。观察 B 的四个信号，回炉 A：

| 信号 | 诊断 |
|---|---|
| 没触发 skill / 触发了不该触发的 | description 弱（原则三） |
| 按你没想到的顺序读文件 | 结构不合直觉 |
| 漏掉引用文件 / 该读没读 | 链接不显眼，或该内容该上提正文 |
| 反复读同一文件 | 内容该从引用文件上提到正文 |
| 从不打开某个文件 | 删掉，或改正文信号 |

**多模型现实（本仓强化项）**：hermes profile 队列跑 kimi k3 / glm-flash / deepseek-flash，CC 侧另有模型组合——**以队列里最弱的模型为验收基准**。为 Opus 写的「一点就透」在弱模型上会跑偏；弱模型比强模型更需要显式步骤和低自由度形态。

## 2. 结构化模式速查（复制即用）

### 2.1 Workflow + Checklist（复杂多步任务）

复杂操作拆成明确顺序步骤；特别复杂的加 checklist 让 Claude 复制进回复逐项勾选：

```markdown
## PDF form filling workflow

Copy this checklist and check off items as you complete:
- [ ] Step 1: Analyze the form (run analyze_form.py)
- [ ] Step 2: Create field mapping (edit fields.json)
- [ ] Step 3: Validate mapping (run validate_fields.py)
- [ ] Step 4: Fill the form (run fill_form.py)
- [ ] Step 5: Verify output (run verify_output.py)

**Step 3: Validate mapping** — Run: `python scripts/validate_fields.py fields.json`
Fix any validation errors before continuing. …
```

明确步骤防止 Claude 跳过关键校验；无代码任务同样适用（研究综述五步例：读源→提主题→交叉验证→结构化摘要→核引用）。

### 2.2 Feedback Loop（质量关键任务）

**跑校验 → 修 → 重跑 → 通过才继续**：

```markdown
1. Make your edits to `word/document.xml`
2. **Validate immediately**: `python ooxml/scripts/validate.py unpacked_dir/`
3. If validation fails: fix issues → run again
4. **Only proceed when validation passes**
```

校验器可以是脚本，也可以是「读 STYLE_GUIDE.md 对照检查清单」。这个模式对产出质量的提升是所有模式里最大的。

### 2.3 Template（输出格式）

严格场景（API 响应/数据格式）写死结构并标 ALWAYS；弹性场景给合理默认并明示可判断调整。

### 2.4 Examples（风格靠样例传递）

输出质量依赖「看到样例」的 skill，给 input/output 对——比形容词描述有效得多：

```markdown
**Example 1:**
Input: Added user authentication with JWT tokens
Output:
feat(auth): implement JWT-based authentication

Add login endpoint and token validation middleware
```

三个好样例 > 三段「要简洁、要专业、要有条理」。

### 2.5 Conditional Workflow（决策路由）

在决策点显式分流；大 workflow 拆文件按路由读：

```markdown
1. **Creating new content?** → Follow "Creation workflow"（docx-js 从零建）
   **Editing existing content?** → Follow "Editing workflow"（解包→改 XML→逐步校验→重打包）
```

## 3. 带脚本的 Skill

- **Solve, don't defer**：错误就地处置，不抛回给 Claude 猜：

```python
# ✓ 好：处置后继续
try:
    with open(path) as f: return f.read()
except FileNotFoundError:
    print(f"File {path} not found, creating default")
    with open(path, "w") as f: f.write("")
    return ""

# ✗ 坏：fail and let Claude figure it out
return open(path).read()
```

- **无 voodoo constants**：每个魔法数注释理由，否则 Claude（和你）都不知道对不对：

```python
# HTTP requests typically complete within 30 seconds;
# longer timeout accounts for slow connections
REQUEST_TIMEOUT = 30
```

- **明示「执行」还是「参考」**——绝大多数应执行（更稳/省 token/保一致）：「Run `analyze_form.py` to extract fields」vs「See `analyze_form.py` for the algorithm」。
- **Plan-validate-execute**：批量/破坏性/高风险操作，先让 Claude 落结构化计划文件（如 `changes.json`）→ 脚本校验 → 才执行。校验报错要 verbose 带上下文（「Field 'signature_date' not found. Available fields: …」），Claude 才能自修。适合：batch 操作、不可逆变更、复杂校验规则。
- **依赖显式声明**：写 `pip install pypdf` 安装行，不假设已装（「Use the pdf library」是反模式）。
- **MCP 工具全限定名**：`ServerName:tool_name`（如 `BigQuery:bigquery_schema`），裸名会 tool not found。
- **路径一律正斜杠**：`scripts/helper.py`，永不 `scripts\helper.py`。

## 4. 内容纪律

- **禁时效信息**：「2026-08 前用旧 API」会过期变错。用「Current method + Old patterns」结构收纳历史：

```markdown
## Current method
Use the v2 API endpoint: `api.example.com/v2/messages`

## Old patterns
<details><summary>Legacy v1 API (deprecated 2025-08)</summary>…</details>
```

- **术语全篇一致**：选一个词用到底（endpoint/field/extract 各选其一），同义词混用（URL/route/path、box/element/control）干扰指令遵循。
- **不堆选项**：给默认 + 逃生口，不写「可以用 A 或 B 或 C 或 D」：

```markdown
✓ Use pdfplumber for text extraction. …
  For scanned PDFs requiring OCR, use pdf2image with pytesseract instead.
✗ You can use pypdf, or pdfplumber, or PyMuPDF, or pdf2image, or…
```

## 5. 反模式速查表

| 反模式 | 后果 | 改正 |
|---|---|---|
| description 空泛/第一二人称 | 不被选中 / 触发错乱 | 第三人称 + 做什么 + 何时用 + 关键词 |
| 名字叫 helper/utils/tools | 无法一眼判断用途 | 动名词或名词短语，自描述 |
| 正文塞全书 / >500 行 | 加载即挤占 context | 渐进披露拆引用文件 |
| 引用嵌套 >1 层 | 部分预览、信息残缺 | 全部从 SKILL.md 一层直链 |
| 长参考文件无目录 | 部分读取看不到全貌 | 顶部 Contents |
| 堆砌「Claude 已知」的解释 | 白烧 token | 只写 Claude 不知道的 |
| 给 N 个平级选项 | 决策瘫痪 | 默认 + 逃生口 |
| 时效性表述 | 文档悄悄变错 | Current + Old patterns |
| 脚本报错甩给 Claude | 不可靠、费轮次 | solve, don't defer |
| 无理由魔法数 | 无法判断对错 | 注释每个常量的依据 |
| 假设包装了/MCP 裸名/反斜杠路径 | 运行时才炸 | 显式依赖/全限定名/正斜杠 |
| 一次写成永不迭代 | 与真实行为脱节 | eval-first + A/B 观察（原则五） |

## 6. 交付前验收 Checklist

**核心质量**

- [ ] description 具体含关键词，同时写了做什么 + 何时用，三人称
- [ ] SKILL.md 正文 <500 行；超限内容已拆引用文件
- [ ] 引用全部一层深；>100 行参考文件有目录
- [ ] 无时效信息（或已收进 Old patterns）
- [ ] 术语全篇一致；样例具体不抽象
- [ ] workflow 步骤清晰；渐进披露使用得当

**代码与脚本**

- [ ] 脚本就地处置错误（solve, don't defer）
- [ ] 无无理由魔法数
- [ ] 依赖显式声明且已验证可用
- [ ] 「执行 vs 参考阅读」意图明确
- [ ] 正斜杠路径；MCP 工具全限定名
- [ ] 关键操作有校验步骤；质量关键任务有 feedback loop

**测试与迭代**

- [ ] ≥3 个评测场景已建（eval-first，防想象需求）
- [ ] 在队列内**最弱模型** + 一个强模型上实测过
- [ ] 真实任务场景测过（非只跑样例）
- [ ] A/B 观察信号已有回收渠道（下次迭代的输入）

## 7. 本工程落地映射

### 7.1 skill 资产分布（写在哪、部署到哪）

| 位置 | 消费方 | 现有 | 部署注意 |
|---|---|---|---|
| `.claude/skills/` | Claude Code 直接消费 | contrib-watch（七模式）、write-article、contrib-preflight、oss-preflight、verify-changes | 仓内即生效 |
| `skills/` | 用户自装域 skill（hermes 主仓引用） | travel-planner、dianping-review、movie-fetcher、restaurant-recommender | **不随 hermes update 同步到 profile，需手动拷贝**（已知痛点） |
| `~/.hermes/skills/` | hermes / profile worker | hermes-contrib-l2 等 | hermes 侧直装 |

hermes frontmatter 额外支持 `platforms` / `environments` 门控字段（`agent/skill_utils.py`），可限定加载范围；name/description 纪律与 CC 完全同构。

### 7.2 仓内范式参照（好的长什么样）

- **contrib-watch SKILL.md**：模式一~七按域分区 + 统一调用契约（输入文件/产物路径/终态事件）≈ 渐进披露模式 2 的单文件版——新增多模式 skill 照此形态。
- **write-article**：四层质检（L1 脚本扫描→L2 风格→L3 事实溯源→L4 互评）= §2.2 feedback loop 范式；素材五层底座 = §2.3 template pattern。
- **travel-planner / dianping-review**：多源采集 + 模板输出 + 脚本执行链 ≈ §2.1 workflow + §3 脚本纪律（dpctl 发布序列是典型的低自由度形态）。

### 7.3 与既有能力的关系

- **skill-creator**（CC plugin）：创建/改进 skill、跑 eval、优化 description 触发——动手工具；本文 = 验收口径与纪律。
- **harness-engineering-principles.md**：context 经济同源（其原则④）；它管 hermes 框架**源码**怎么改，本文管 SKILL.md **内容**怎么写。

## 8. 迭代维护规则

1. skill 不是写完就完：每次真实使用都是一次评测——按 §1 原则五的四信号观察，回改。
2. 改 description 必须真测触发（弱模型上），改结构必须真跑一轮任务回归。
3. skill 产物的现场微调必须回流 skill 源头（仓内既有教训：产物副本微调会分叉）。
4. 本文废弃或官方规范更新 → 更新本文并在 `INDEX.md` 对应行改「一句话」。
