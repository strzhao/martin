---
name: dianping-review
description: "Use when the user asks to generate Dianping (大众点评) restaurant reviews. Scans /Volumes/stringzhao_主空间/大众点评/ for pending review folders, generates Chinese-language reviews from food photos and voice notes, and saves them to the folder."
version: 4.6.0
author: martin
license: MIT
platforms: [macos]
prerequisites:
  commands: [pnpm, ai-todo]
  repos:
    - path: /Users/stringzhao/workspace/relight
      note: "提供 dianping-vision CLI（图片专业分析），需已 pnpm install"
metadata:
  hermes:
    tags: [Dianping, review, restaurant, food, Chinese, content-generation, quality-scoring, batch-processing]
    related_skills: [whisper]
---

# Dianping Review Generator

## Overview

Generate high-quality Dianping (大众点评) restaurant reviews by scanning review folders under `/Volumes/stringzhao_主空间/大众点评/`. Each subfolder contains materials for one restaurant visit: food photos, optional voice notes, and receipt images. The skill tracks which folders have been reviewed via a `.reviewed` marker file — no duplicates.

## Core Principles

These principles override all other instructions. They are non-negotiable.

### 1. 绝不杜撰 (Zero Fabrication)

AI must never invent information. Every detail in the review must be traceable to one of these sources:

| Source | Confidence | How to use |
|--------|-----------|------------|
| 🎙️ 语音记录 | **确认** — 评价者本人的用餐记忆 | 直接作为作者自己的经验写入 |
| 🖼️ 图片分析 | **观察** — 视觉模型从图片中直接看到的 | 可描述外观/摆盘/环境，作为补充 |
| 🔍 网络搜索 | **参考** — 公开的料理知识 | 作为作者自己的知识积累自然表达 |
| 🤔 合理推断 | **推测** — 基于经验的猜测 | 标注"看起来""目测"或省略 |
| ❓ 未知 | **无信息来源** | 省略或写"价格未知" |

**杜撰红线**（出现以下任一情况 = 不合格）：
- 图片中看不到价格，却写了一个具体金额
- 评价者没提到的菜名，AI 自己编了一个
- 评价者说"还行"，AI 写成"味道惊艳"
- 图片模糊看不清，AI 却描述了摆盘细节

**内部溯源标记**（仅用于交叉验证，不写入最终评价）：
- 语音中的观点 → 定调层，直接作为作者自己的判断表达
- 图片专业分析 → 观察层，作为技术证据（火候/调味/刀工/食材状态）
- 料理知识 → 解释层，作为"为什么"的解释框架
- 收据中的价格/菜名 → 作为硬数据直接使用

### 2. 语音定调，专业赋能 (Voice Sets Direction, Expertise Adds Depth)

**核心哲学**：语音是评价的"骨架"（观点定调），图片+知识是"血肉和筋骨"（专业解释）。三者合一才能生成远超语音原文的有深度评价。

**三层信息模型**：

| 层级 | 来源 | 作用 | 示例 |
|------|------|------|------|
| 定调层 | 语音 | 核心判断——好吃/不好吃/哪里有问题 | "鱼很嫩""偏硬""酱油太重" |
| 观察层 | 图片专业分析 | 技术证据——火候/调味/刀工的可见线索 | "表面焦褐色均匀""酱汁光泽度低""切面纤维粗" |
| 解释层 | 料理知识 | 为什么——判断标准、常见问题、技术原理 | "煎焗火候到位表现为焦褐色均匀""春笋五月纤维化是自然规律" |

**语音处理规则**：
- 语音中的观点 → 直接作为作者自己的判断表达（和 v3 一致）
- 语音中的批评（"酱油太重"）→ 是核心判断，**配合图片+知识解释为什么**
- 语音未提的菜品（仅在图片中看到）→ 可作为补充，仅描述外观不评味道
- 图片分析和语音描述矛盾 → 以语音为准（你吃了）

**关键转变**：v3 的做法是"语音说了什么就写什么"——这是转录，不是评价。v4 的做法是：

```
语音说「鱼很嫩」         → 评价写「鱼肉嫩滑，新鲜度没问题」
                              ↑ 这就是 v3 的质量上限

语音说「鱼很嫩」         → 评价写「鱼肉嫩滑，新鲜度没问题。
+ 图片看到鱼皮完整无破损，   筷子夹起时鱼肉呈蒜瓣状分离——
+ 蒸制火候和时间控制精准      这是清蒸鱼火候到位的标志」
                              ↑ 这才是 v4 要求的水准
```

**每道菜必须产出 30-50% 的"专业增量"**——图片观察 + 料理知识解释，不能只是语音转述。

**零杜撰的边界澄清**（重要！）：

| 类别 | 示例 | 判定 |
|------|------|------|
| ✅ 基于图片可见证据的专业观察 | "表面焦褐色均匀，说明煎焗火候到位" | 非杜撰——可见证据 |
| ✅ 基于公知料理知识的判断 | "春笋五月纤维偏粗，口感下降是正常的" | 非杜撰——公知 |
| ✅ 语音+图片交叉验证的推断 | 语音说"偏硬"+图片看到纤维粗="火候没把握好" | 非杜撰——双重证据 |
| ❌ 图片中不可见的细节 | "用的是十年陈皮""老板师从XX大师" | 杜撰——无法验证 |
| ❌ 用户未评价但AI自行判断口味 | 用户没提某菜，AI写"味道惊艳" | 杜撰——无定调来源 |
| ❌ 无法从图片辨识的具体信息 | "辣椒是重庆空运的二荆条" | 杜撰——图片看不出来 |

### 3. 语音为主线，视觉为佐证（Voice Leads, Visual Supports — v4.5）

**核心问题**：v4.0-4.4 的三层合成模板将"观察层"作为独立段落，导致图片分析反客为主——视觉描述成了叙事主线，语音感受沦为边角料。读者感受是"AI 在分析照片"，而非"作者在讲自己吃了什么"。

**v4.5 修正**：语音定调是**叙事主线**，图片观察是**穿插其中的证据**，料理知识是**收尾的解释**。三者不是并列的三个段落，是一条线上的三个节拍：

```
语音体验开篇 → 视觉证据嵌入 → 知识解释收尾 → 回到个人判断
```

**硬性规则**：

1. **每道菜的叙述以第一人称体验开头**：不只是转述"鱼很嫩"，而是用**吃了之后的感受**自然开场。\"咬下去...\"\"吃起来...\"\"第一口...\"。

2. **视觉证据必须嵌入语音叙事中，不能独立成段**：用破折号（——）、\"你看\"、\"这\"等口语词作为连接器，把图片观察嵌进去。

3. **最多连续 2 句纯视觉描述**：超过 2 句没回到第一人称体验，就说明视觉在主导叙事——不合格。

4. **收尾必须回到吃这件事上**：\"所以...\"\"难怪...\"\"这么说来...\"——把知识解释引回到个人体验判断。

**模板对比**：

```
❌ v4.4（视觉驱动）：
「表面美拉德反应很到位——深琥珀色到红棕色的焦化层均匀裹在肉块上。
肉块肥瘦相间，白色的羊尾油颗粒嵌在瘦肉之间，烤制后脂肪融化、油光包裹。」
→ 读起来像化验报告，不像人在讲吃的

✅ v4.5（语音驱动）：
「咬下去外焦里嫩，汁水锁得挺好——你看这串的表面，
焦褐色裹得均匀，没有烤焦的黑斑，说明师傅火候拿得确实稳。」
→ 先说吃了什么感觉，再看外表为什么这样，最后回到判断
```

### 4. 温和专业风格（老高+隋卞式）

评价以**懂行的朋友**为基调——像老高（真探高文麒）那样温和地分享，像隋卞（特厨隋坡）那样有技术眼光地观察。你不是在给餐厅打分定生死，是在跟其他食客说「这家我帮你们试过了，情况是这样的」。

**结构**：
- 开篇：X人 ¥X总消费 人均¥X，整体口味X分——<定性短语>
- 逐道：菜名（价格）<定调短语>。<好在哪/差在哪：食材/火候/调味/做法>。<值不值>
- 环境服务：位置、装修、服务简评
- 总结：推荐指数X星，适合场景，再访意愿
- 标签：#位置 #菜系 #推荐菜 #探店报告

**知识融入**：老高式自然带出——「其实…」「这道有意思的地方是…」。v4 中知识用于解释图片证据和语音判断，每篇 2-3 处，一句话带过不展开。格式见 style-guide 第五章。

**批评原则**：就事论事，不升级为对餐厅的定性。不说「网红店气质」「评分虚高」「最大的雷」「翻车」——改为具体描述问题。

**禁止**：
- "听你说""据了解""用户提到"等距离标记
- "非常好吃""环境优雅""服务周到"等AI套话
- "完全不值""最大的雷""翻车""网红店气质"等情绪化审判
- ai-todo笔记中的元信息（质量评分、文件路径、"零杜撰"等）

## Directory Structure

```
/Volumes/stringzhao_主空间/大众点评/
├── 后市街/                          # 餐厅/位置名 = 一次评价
│   ├── 后市街.m4a                   # 语音笔记
│   ├── IMG_1801.PNG                 # 菜品照
│   ├── IMG_1804.jpg
│   └── ...
│   ├── review.md                    # ← 生成后写入
│   └── .reviewed                    # ← 生成后创建（空文件，标记已完成）
├── 20260503/
│   ├── 后市街.m4a
│   ├── IMG_1801.PNG
│   └── ...
└── ...
```

**Rules**:
- Each subfolder in `/Volumes/stringzhao_主空间/大众点评/` = one review task
- A folder is **pending** if it does NOT contain a `.reviewed` marker file
- A folder is **done** if `.reviewed` exists → skip it
- After review generation, write `review.md` and `touch .reviewed`

## When to Use

- User says "生成点评"、"写评价"、"大众点评"、"review"
- User says "扫一下点评目录"、"看看有没有新的评价"
- The agent should proactively discover pending folders when triggered

## Full Workflow

### Step 0: Discovery

Scan for subfolders without `.reviewed`:
```bash
ls -d "/Volumes/stringzhao_主空间/大众点评"/*/ 2>/dev/null | while read dir; do
  if [ ! -f "$dir.reviewed" ]; then
    echo "PENDING|$dir"
  else
    echo "DONE|$dir"
  fi
done
```
If zero pending folders: tell the user and stop.
Restaurant name inference: folder name first, then audio filename, then context clues.

### Step 0.2: Auto-Discover Restaurant Photos from NAS (v4.6 — Plugin API)

如果用户尚未手动放置照片到点评文件夹，通过 relight 插件 API 自动从 NAS 发现并导出：

**1. 触发聚类任务**：

```bash
RELAY_API="${RELAY_API:-http://localhost:3000}"
RUN_RESULT=$(curl -s -X POST "$RELAY_API/api/plugins/dianping-cluster/run" \
  -H "Content-Type: application/json" \
  -d "{\"timeStart\":\"<date>T18:00:00+08:00\",\"timeEnd\":\"<date>T21:00:00+08:00\"}")
TASK_ID=$(echo "$RUN_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['taskId'])")
echo "任务 ID: $TASK_ID"
```

**2. 轮询等待完成**（最长 120s）：

```bash
for i in $(seq 1 40); do
  TASK_JSON=$(curl -s "$RELAY_API/api/plugins/dianping-cluster/tasks/$TASK_ID")
  STATUS=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['status'])")
  if [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ]; then break; fi
  sleep 3
done
```

**3. 导出照片到点评文件夹**：

```bash
# 从任务结果的 photos[].outputPath 复制已转换的 JPEG 文件
echo "$TASK_JSON" | python3 -c "
import sys, json, shutil, os
task = json.load(sys.stdin)['data']
if task['status'] != 'done':
    print(f'任务未完成: {task[\"status\"]}', file=sys.stderr)
    sys.exit(1)
r = json.loads(task['result']) if isinstance(task['result'], str) else task['result']
photos = r.get('photos', [])
for i, p in enumerate(photos):
    src = p['outputPath']
    ext = os.path.splitext(src)[1] or '.jpg'
    dst = os.path.join('$FOLDER', f'{os.path.basename(p[\"path\"])}{ext}')
    shutil.copy2(src, dst)
    print(f'  [{i+1}/{len(photos)}] {os.path.basename(dst)}')
print(f'共 {len(photos)} 张照片 → $FOLDER')
"
```

**时间窗口推断**：
- 用户说"X日晚餐" → X日 18:00-21:00
- 用户说"X日午餐" → X日 11:00-14:00
- 仅提供日期 → 覆盖 11:00-21:00
- 语音文件 mtime 作为日期参考

**降级策略**：
- API 不可达（`curl` 连接失败）→ 回退 CLI 直调：`cd /Users/stringzhao/workspace/relight/apps/backend && npx tsx src/cli/discover-dianping-photos.ts --time-start "..." --time-end "..." --output-dir "$FOLDER" --mode convert`
- 聚类结果为 0 张 → 告知用户并继续 Step 0.5（手动放置照片）
- 任务 failed → 打印 `error` 字段，回退 CLI 直调或手动

### Step 0.5: Gather Materials

```bash
IMAGES=$(find "$FOLDER" -maxdepth 1 \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.HEIC" \) -print | sort)
AUDIO=$(find "$FOLDER" -maxdepth 1 \( -iname "*.m4a" -o -iname "*.mp3" -o -iname "*.wav" \) -print | sort)
```

**Restaurant identification priority**:
1. If any image is a Dianping detail page screenshot (recognizable: star rating, 人均¥, 口味/环境/服务 scores, address) → extract: restaurant name, rating, avg spend, cuisine type, location. These are **hard facts**, not fabrications. Use them for tags (#萧山, #江浙私房菜, etc.) and restaurant context.
2. If screenshot has restaurant name **cut off at top** (common in deal page screenshots): fall back to environment images for signage text, deal page category prefixes (e.g., "梅间冷味集" → "梅间"), and location clues from audio filename.
3. Fallback: audio filename (e.g., "龙湖春江天玺(北门).m4a" → near 龙湖春江天玺)
4. Fallback: folder name

### Step 1: Professional Image Analysis（专业图片分析 — v4.3 CLI 化）

**v4.3 起，图片分析链路全部下沉到 relight 仓库的 `dianping-vision` CLI**。原先在 SKILL.md 内联的 sips/base64/curl/python/并行 wait 逻辑（HEIC 解码、resize、字段 fallback、超时重试、错误聚合）全部封装在编译型 TS 代码里，避免 shell 链路的脆弱性。

**调用方式**（一条命令，处理整个文件夹）：

```bash
mkdir -p "/tmp/dianping-review/<folder>"
cd /Users/stringzhao/workspace/relight/apps/backend
npx tsx src/cli/dianping-vision.ts \
  --folder "$FOLDER" \
  --output "/tmp/dianping-review/<folder>/vision.json" \
  --concurrency 4
```

> ⚠️ **不要用 `pnpm --filter @relight/backend tsx ...`** — `tsx` 不是 package.json 中的 script，pnpm 会报 `ERR_PNPM_RECURSIVE_RUN_NO_SCRIPT`。正确做法是 `cd apps/backend && npx tsx`。

**CLI 入参**：
- `--folder <dir>`：扫描目录下 `.jpg/.jpeg/.png/.heic/.heif`（不递归）。也可以位置参数传具体图片路径。
- `--concurrency`：默认 4（保守限速，避免 Qwen 单机过载）。
- `--output`：写 JSON 到指定路径；同时也输出到 stdout。
- `--max-edge`：默认 1568（沿用原 sips 参数）。
- `--max-tokens`：默认 4096（足以覆盖 Qwen 推理 token + 输出，避免 `finish_reason=length` 截断）。

**CLI 内部已处理**：
- HEIC/HEIF → JPEG（heic-decode + sharp）
- 长边超 1568px 自动 resize + JPEG 85% 重编码
- buffer → base64，不写临时文件
- OpenAI SDK 调用，120s timeout，maxRetries=0（失败即记入 `error` 字段，不阻塞其他图）
- 字段 fallback：`content || reasoning_content`
- `enable_thinking: false`（关 Qwen 推理模式确保输出走 content）
- `finish_reason=length` 时自动告警到 stderr

**专业分析 Prompt** 内嵌在 CLI（`apps/backend/src/cli/dianping-vision.ts` 顶部 `DIANPING_VISION_PROMPT` 常量），照搬 v4.0 的"7 项问题"模板（菜名识别 / 火候 / 食材 / 调味 / 做法 / 分量 / 整体判断）。如需调整 prompt，去 relight 仓库改并 commit，比改 skill 更受版本管控。

**输出契约**（写入 `--output` 指定文件 + stdout）：

```json
{
  "ok": true,
  "totalMs": 31204,
  "stats": { "total": 7, "success": 7, "failed": 0 },
  "results": [
    {
      "image": "/Volumes/.../IMG_2021.jpg",
      "index": 0,
      "analysis": "1. 【菜名识别】...\n2. 【火候判断】...",
      "elapsedMs": 28432
    }
  ]
}
```

`index` 保留原始排序（concurrency 不保证返回顺序）。失败的图片该项有 `error` 字段、无 `analysis`。

**Exit code**：0=全部成功，2=部分失败，1=全部失败/参数错误。

**两阶段策略已废弃**（v4.3 简化）：v4.2 因 max_tokens 紧张才搞 quick(200)+full(2000) 两阶段。CLI 默认 4096 tokens 已能稳定容纳推理 + 完整输出，且 Qwen 单图 ~27-84s 取决于图片复杂度，并发 4 张总耗时与原 7 并行同量级。所有图统一走专业分析，skill 后续根据 `analysis` 内容自行决定哪些菜要展开为评价。

**实测**：单张约 27s（中等复杂度图），7 张 `concurrency=4` 总耗时 ~50-90s。

**产出物**：`/tmp/dianping-review/<folder>/vision.json`，Step 1.5 和 Step 2b 直接读取该文件。

### Step 1.5: Order/Receipt Price Extraction（订单价格提取 — v4.4 新增）

**问题**：dianping-vision CLI 使用烹饪分析 prompt，对订单/收据截图只会做"食材判断"而不会仔细 OCR 价格。必须在单独步骤中提取价格。

**调用方式**：

```bash
python3 <skill_dir>/scripts/extract_order_prices.py \
  /tmp/dianping-review/<folder>/vision.json \
  /tmp/dianping-review/<folder>/prices.json \
  --folder "$FOLDER"
```

**工作原理**：
1. 扫描 vision.json 中所有 `results[].analysis`，匹配关键词（"订单"/"收据"/"小计"/"结账"等）识别订单截图
2. 对每张订单截图，用 Qwen API 发送纯 OCR prompt（要求逐行输出 菜名|规格|数量|价格）
3. 解析为结构化数据，合并去重，保存到 `prices.json`

**输出契约**：

```json
{
  "order_found": true,
  "images_processed": 1,
  "items": [
    {"name": "呼伦贝尔羊肉串（一打）", "qty": "x1", "price": 66.0, "note": "原味"},
    {"name": "去壳大虾", "qty": "x2", "price": 18.0, "note": ""}
  ],
  "total": 233.2
}
```

如果 `order_found: false`，表示没有订单截图，跳过价格信息。

**集成**：Step 3 生成评价时，从 `prices.json` 的 `items` 中查找对应菜品价格填入 `（¥XX）`，从 `total` 填入开篇总消费。

### Step 2: Input Processing & Audio Transcription

**2a. Audio Transcription** — Use bundled script:
```bash
python3 <skill_dir>/scripts/whisper_transcribe.py "<audio_path>" zh
```
Extract: dishes mentioned + opinions, prices, service, atmosphere, standout points.
If the script fails, fall back to `execute_code` with inline faster-whisper Python.

**2b. Assemble Three-Layer Structured Analysis（三层结构组装）**

读取 Step 1 产出的 `/tmp/dianping-review/<folder>/vision.json`（`results[].analysis` 是每张图的 7 项专业分析），结合语音转写，组装为结构化文档，供 Step 3 使用。按三层模型组织：

```markdown
## 结构化分析 (v4.0 三层模型)

### 整体信息
- 餐厅：<名称推测>
- 人数：<语音提到>
- 总消费/人均：<语音或收据>

### 菜品 1: <菜名>
#### 定调层（语音）
- 评价者判断：<引用语音原文观点>
- 态度倾向：好评/中评/差评

#### 观察层（图片分析 · 此菜对应图片）
- 火候：<从图片分析中提取>
- 食材：<从图片分析中提取>
- 调味：<从图片分析中提取>
- 做法：<从图片分析中提取>
- 分量：<从图片分析中提取>

#### 整合提示
- 语音观点 × 图片证据的交叉点：<匹配/矛盾/补充>
- 可展开的专业维度：<哪几个维度有深度可挖>

### 菜品 2: <菜名>
...
```

此文档是 Step 3 草案生成的唯一事实基础。

### Step 2.5: Deep Culinary Research（深度料理研究 — 升级 v4.0）

**质量基准**：研究深度应达到 `references/deep-research-benchmark.md` 的水平——包含定量数据（温度/时间/化学物质）、判断标准、翻车原因、食材季节性。

**不再是"1-2个趣闻"**。对每道菜必须执行以下搜索流程，产出结构化知识笔记：

**搜索策略（每道菜 3 次搜索）**：

1. **做法与标准**：`"[菜名] 传统做法 关键步骤 技术要点"`
   - 目标：了解这道菜做好的标准是什么，关键步骤是什么
2. **判断标准**：`"[菜名] 怎么判断好坏 火候 调味"`
   - 目标：了解专业厨师如何评判这道菜，常见翻车点
3. **食材知识**：`"[关键食材] 最佳季节 挑选技巧"`（如有季节性或特殊食材）
   - 目标：了解食材本身的特性

**知识笔记格式**（保存到结构化分析文档中）：

```
### 菜品X 料理知识

**标准做法**：<关键步骤概括，1-2句>

**做好的标志**：<从火候/调味/食材三角度概括判断标准>

**常见翻车点**：
- <问题1> → <专业解释>
- <问题2> → <专业解释>

**食材知识**（如适用）：
- <食材特性，如"春笋五月纤维化""清远鸡皮薄肉嫩">
```

**集成原则**：知识必须用于**解释语音中的具体观察**或**图片中的具体证据**。不要"掉书袋"式插入不相关的知识。

✅ 正确集成：
> 语音说"春笋有涩味" → 知识"春笋含草酸，焯水可去涩" → 评价写"可能焯水这一步没处理好，涩味没去掉"

❌ 错误集成：
> 语音没提任何与鲁菜相关的内容 → 知识"锅塌是鲁菜传统技法" → 插入评价 → 这就是掉书袋

### Step 3: Professional Draft Generation（专业草案生成 — 重写 v4.0）

Load references:
```
skill_view(name="dianping-review", file_path="references/dianping-style-guide.md")
```

**Style**: 老高+隋卞·温和专业型。像一个懂行的朋友告诉你真相。**知识必须用口语表达，禁止学术腔**——"自然发酵，酸味慢慢出来"✓，"乳酸发酵产生酯类"✗。

**核心原则：评价 ≠ 转录。每道菜必须产出 30-50% 的专业增量。**

#### Step 3a: 逐菜合成（核心流程 — v4.5 重写）

对每道菜，从三层结构分析中提取并合成。**关键转变**：三层不是三个段落，是一条叙述线上的三个节拍。

```
语音体验开篇 → 视觉证据嵌入 → 知识解释收尾 → 回到个人判断
```

**合成模板（v4.5）**：

```
<菜名>（<价格>）<定调短语>。

[语音体验开篇 — 1-2句]
用第一人称吃的感受自然开场。不转述「语音说鱼很嫩」，
而是「咬下去鱼肉嫩滑」「吃起来没有腥味」「第一口就觉得...」

[视觉证据嵌入 — 紧随其后，不超过2句]
用破折号（——）直接连到视觉观察，不加"你看""这"等指向词。
视觉证据必须直接支持上面的体验判断。
禁止独立成段的纯视觉描述。

⚠️ 禁止用"你看这盘里""你看这里""你看这"——这些词打破第一人称叙述的沉浸感，
让读者感觉有人在指着照片解说。破折号本身已经完成了叙事节奏的切换。

[知识解释收尾 — 1-2句]
用「其实...」「这说明...」「所以...」「难怪...」自然带出，
解释为什么好吃/不好吃，必须回到吃这件事上。

[性价比 — 1句] <值不值>
```

**参考示例**：`skill_view(name="dianping-review", file_path="references/v4.5-before-after.md")` — 包含 v4.4 vs v4.5 的真实 before/after 对比和结构拆解。首次使用 v4.5 模板时建议先加载。

**关键连接词**（用于嵌入视觉证据，替代独立段落的表达）：

| ❌ v4.4 独立观察句式 | ✅ v4.5 嵌入叙事句式 |
|---------------------|---------------------|
| "表面呈深琥珀色，焦化层均匀" | "——焦褐色裹得很均匀，没有烤焦的黑斑" |
| "虾壳呈鲜亮的橙红色，虾身弯曲成C字" | "——虾壳亮橙色透着新鲜，虾身蜷成标准的C形" |
| "面条细长均匀、表面光滑不粘连" | "——面条根根分明不粘连，一看就过了冰水" |
| "食材新鲜，纹理清晰可见" | "——颜色和纹理一眼就知道新鲜度在线" |

> ⚠️ 破折号后直接接观察，**不加"你看"**。破折号已切断叙事节奏，再加"你看"是过度打断。

**合成示例（对比）**：

❌ **v4.4（视觉驱动 — 不合格）**：
> 「烤生蚝（¥13）不太行。蚝壳大肉小，基本没什么吃头。吃进嘴里就是蒜蓉酱和调料味，完全吃不到蚝肉本身的鲜甜。」

→ 只有语音转述，没有视觉证据嵌入，没有知识解释。

✅ **v4.5（语音驱动 — 合格）**：
> 「烤生蚝（¥13）不太行。夹起来就觉得不对——壳挺大，蚝肉小得可怜，一口下去全是蒜蓉酱的味，蚝本身的鲜甜完全没吃到。其实生蚝好不好，上桌那一刻看饱满度就知道七七八八了，这颗明显缩得厉害，不是烤过头就是蚝本身瘦。13块一只，还不如加钱吃虾。」

→ 语音体验「夹起来就觉得不对」开篇 → 视觉「壳大肉小」嵌入 → 知识「生蚝看饱满度」解释 → 回到性价比判断。

#### Step 3b: v4.4 vs v4.5 质量对比（强制自检标准）

| 维度 | v4.4 质量（不合格 — 视觉驱动） | v4.5 要求（合格 — 语音驱动） |
|------|----------------------|---------------------|
| 开头 | "表面美拉德反应很到位——深琥珀色到红棕色的焦化层均匀裹在肉块上" | "咬下去外焦里嫩，汁水锁得挺好——你看这表面，焦褐色裹得很均匀" |
| 视觉证据 | 独立成段，2-3 句纯视觉描述 | 嵌入叙述中，用"——""你看"等口语词连接 |
| 结尾 | 纯视觉描述收尾，无个人判断回归 | 用"所以""说明"回到吃这件事+性价比判断 |
| 阅读感受 | AI 在分析照片 | 懂行的朋友在分享吃了什么 |

**自检法**：写完一道菜的评语后，划掉语音直接转述的部分。剩下的（图片观察 + 知识解释）必须 ≥ 转述部分。达不到就重写。

#### Step 3c: 完整评价结构

```
[开篇 — 1-2句]
X人用餐总消费X元，人均X元。整体口味X分——<定性短语>。

[菜品详情 — 逐道，按 Step 3a 模板]
<菜名>（<价格>）<定调短语>。<定调层>。<观察层>。<解释层>。<性价比>。

[环境与服务 — 1-2句]

[总结 — 2-3句]
推荐指数<1-5>星。<适合场景 + 再访意愿>

[标签 — 1行]
标签：#<位置> #<菜系> #<推荐菜> #探店报告
```

#### Step 3d: 集成规则（更新）

- 语音观点 → 直接作为作者判断，不用"听你说"前缀
- 图片分析 → 选最相关的 1-2 个技术维度展开，不是全写
- 料理知识 → **仅用于解释图片证据或语音问题**。语音没提到的问题 + 图片看不到的证据 → 不要插入知识
- 环境 → 只在图片中**明确可见**或语音提及时描述
- 知识融入 → 老高式："其实…""有意思的是…"；最多 2-3 处（v3 是 1-2 处，v4 因为用知识做解释所以适度增加）

#### Step 3e: v4.5 质量门禁（更新）

- [ ] **第一人称主线**：每道菜是否以个人体验开头+收尾？（不允许视觉描述作为开头）
- [ ] **视觉嵌入而非独立**：视觉观察是否用"——""你看""这"等口语词嵌入叙述？（不允许独立成段）
- [ ] **纯视觉≤2句**：是否有超过 2 句纯视觉描述未回到第一人称？（超过 = 不合格）
- [ ] 每道菜是否有图片观察层？（至少 1 句基于图片的技术证据）
- [ ] 每道菜是否有知识解释层？（至少 1 处料理知识解释）
- [ ] 专业增量是否 ≥ 语音转述？（自检比例）
- [ ] 知识是否直接解释了图片证据或语音问题？（无"掉书袋"）
- [ ] 没有"听你说""据了解"等距离标记？
- [ ] 没有任何杜撰内容？（对照零杜撰边界表）
- [ ] 标签在末尾？
- [ ] 结构匹配模板？

### Step 4: Independent Quality Review

Use `delegate_task` with the structured analysis for cross-validation. Reviewer loads `references/scoring-rubric.md` and checks:
1. Five-dimension scoring (specificity, vividness, usefulness, authenticity, **depth** — v4.0 new)
2. Fabrication cross-validation (every claim vs. sources)
3. Depth assessment: professional value-add ≥ 30%?
4. JSON output with `fabrication_found` boolean

**v4.0 Threshold**: total ≥ 18, all dimensions ≥ 3, **depth ≥ 3**, NO fabrication → PASS.
Fabrication = hard fail → re-draft, not just refine.
Depth < 3 → return to Step 3 with specific dish guidance.

### Step 5: Iterative Refinement

For dimensions < 3, apply targeted fixes. Max 3 rounds.

### Step 6: Save Output to Folder

Write `review.md` to the folder, then `touch .reviewed`.

### Step 7: Sync to ai-todo Notes

**The note body must be directly copyable to 大众点评 with zero edits.**

No meta-commentary: no file paths, no quality scores, no "零杜撰", no emoji symbols.

**CRITICAL**: `ai-todo notes:create` only has `--title` and `--tags`. There is NO `--description` flag. The ENTIRE review — headline, dish details, environment, summary, and tags — must all go in the single `--title` argument. The `--title` field accepts multi-line text with embedded newlines.

Title argument: The complete review text, from opening to closing tags:
```
X人用餐总消费X元，人均X元。整体口味X分——<定性短语>。

黑松露煎焗清远鸡（86元）这道不错。<好在哪>。<值不值>。

...

环境与服务：<评价>

总结：推荐指数<X>星。<场景、再访意愿>

标签：#<位置> #<菜系> #<推荐菜> #探店报告
```

Tags argument: `大众点评,<category>,<cuisine>,<location>,<quality>,<price>`

**Verify before considering done**: Check `ai-todo notes:list` — does the note's title field contain the full review, or just a headline? If only a headline, delete and recreate with the full text in `--title`.

**Pitfall**: Do NOT create the note with just the headline in `--title` and expect a separate body. That produces a useless note. The CLI is headline-only; embed the full review in the headline field.

### Step 8: Rename Folder（重命名文件夹 — v4.1 新增）

评价落盘后，将文件夹从纯日期重命名为 `日期_餐厅名_位置` 格式，方便后期查找。

**命名规则**：
```
原文件夹名 → 日期_餐厅名_位置
```

**示例**：
- `20260503` → `20260503_纸鸢私房餐厅_高银街`
- `20250510` → `20250510_龙湖春江天玺_萧山`

**提取逻辑**：
- 日期：从原文件夹名提取（如 `20260503`）
- 餐厅名：从 review.md 的餐厅信息中提取（收据/截图中的餐厅名）
- 位置：从 review.md 的位置/标签信息中提取（如 `高银街`、`萧山`），优先用道路/商圈名

**餐厅名未知时的降级命名**（v4.5.1）：如果截图和语音都无法提取餐厅名，使用 `日期_菜系_位置` 格式：
- `20260530` → `20260530_日式烧肉_滨江天街`
- 菜系从 vision 分析推断（日式烧肉/韩式烤肉/中式炒菜等）
- 位置从语音文件名或环境图片推断

**命令**：
```bash
mv "/Volumes/stringzhao_主空间/大众点评/20260503" "/Volumes/stringzhao_主空间/大众点评/20260503_纸鸢私房餐厅_高银街"
```

**命名约束**：
- 不使用特殊字符，空格用下划线代替
- 餐厅名超过 8 个字时截断保留前 8 字
- 总长度控制在 50 字符以内

### Step 9: Batch Summary

If processing multiple folders, present a clean summary.

## Common Pitfalls

### Image Processing（v4.3 起由 dianping-vision CLI 兜底，不再手工处理）
1. ~~HEIC → JPEG conversion required before base64~~ → CLI 内部 heic-decode 自动处理
2. ~~Always use `curl -d @file` pattern, never inline base64~~ → CLI 用 OpenAI SDK，无 ARG_MAX 风险

### Vision API（v4.3 起由 CLI 封装）
3. ~~Set max_tokens ≥ 2000 / check reasoning_content fallback~~ → CLI 默认 4096，字段 fallback 已内建
4. Verify llama-server health first（仍需手动）：`curl -s -m 3 -H "Authorization: Bearer qwen-local-key" http://127.0.0.1:8001/v1/models | head -c 100`
5. ~~API Key handling~~ → CLI 从 `config.ai.apiKey` 读取（默认 `qwen-local-key`），可通过 `AI_API_KEY` env 覆盖
6. ~~content vs reasoning_content fallback~~ → CLI 已自动处理

### Review Quality
5. No "听你说"/"据了解" distance markers
6. Missing price → write "价格未知"; distinguish 点单 vs 结账单
7. No AI clichés: "非常好吃""环境优雅""服务周到". Also no emotional judgment: "最大的雷""翻车""网红店气质""评分虚高". Use measured criticism instead.
8. **v4.0 核心**：每道菜必须有图片观察 + 知识解释（专业增量 ≥ 30%）。纯语音转述 = 不合格。

### v4.0 新增常见错误
15. **纯转述（v4 最常见失败模式）**：把语音内容用更好的措辞写一遍，但没有图片观察、没有知识解释。解决方案：回到 Step 3a，检查每道菜是否有观察层和解释层。
16. **知识掉书袋**：插入了与图片/语音无关的料理知识。例如语音和图片都没提"锅塌"，却插入一段鲁菜历史。解决方案：每条知识必须直接解释图片证据或语音观点。
17. **图片分析未利用 / 视觉证据覆盖不全（v4.5 强化）**：完成了 Step 1 专业图片分析，但草案中部分菜品未引用任何图片分析结果。**v4.5 硬性要求：每道菜都必须有至少 1 句基于图片的技术证据（观察层），不允许任何一道菜纯语音转述**。质量审查中 depth 维度扣分的主因就是视觉证据覆盖率 < 100%。解决方案：从 vision.json 中为每道菜提取对应的观察层数据，明确写入评价。如果某道菜确实没有对应图片（如主食未拍照），至少补充 1 条料理知识解释，确保无"零专业增量"的菜品。
18. **观察层空洞**：写了"火候不错"但没有具体证据。解决方案：必须写具体可见证据（"焦褐色均匀""酱汁挂壁""鱼肉蒜瓣状分离"）。
19. **知识教科书化（v4 高频陷阱）**：使用"乳酸发酵产生酯类""IMP-谷氨酸协同效应""肌原纤维蛋白变性收缩"等学术语言，导致评审判定"不像真人写的"（真实性扣分）。解决方案：用老高式口语化表达——"自然发酵，酸味慢慢出来""两种鲜碰到一起是加成的""胶原没有充分化开"——保留知识内核，换日常语言。
20. **通用知识当具体问题（杜撰红线）**：语音只说"一般不推荐"，却在评价中写"没酒香""淀粉老化变硬"作为这道菜的具体问题。这是将通用料理知识伪装成具体观察 = 杜撰。解决方案：用推测语气区分——"其实酒酿圆子挑细节…感觉这份这些细节没太注意到"——知识作为判断标准框架，不作为这道菜的确定事实。

### 工具链陷阱（v4.0-v4.2 历史，v4.3 已通过 CLI 化全部规避）
19. ~~vision_analyze 不可用 → terminal + background curl~~ → v4.3 改为 `npx tsx dianping-vision.ts`（从 `apps/backend` 目录），不再依赖 Hermes 内置 vision 或 terminal 并行
20. **delegate_task 搜索不返回实际结果**：子代理的 web_search 只返回 self-report summary，不返回实际搜索内容。深度料理研究（Step 2.5）需要直接执行 web_search 或使用 execute_code 调用搜索，不要委托给子代理。（与图片分析无关，仍然适用）
21. ~~Qwen 视觉 token 不足 < 2000~~ → CLI 默认 4096，且 `finish_reason=length` 时自动 stderr 告警
22. ~~execute_code 连续调用 Qwen 被中断~~ → CLI 用 OpenAI SDK + 进程内 p-limit 并发，不走 execute_code/terminal

### v4.5 新增陷阱

28. **视觉分析喧宾夺主（v4.5 高频陷阱）**：Step 3a 三层合成时，观察层被写成独立段落（2-3 句纯视觉描述），导致评价读起来像照片分析报告而非用餐体验。典型特征：每道菜以视觉描述开头（"表面呈深琥珀色"），语音感受被挤压到角落。解决方案：使用 v4.5 模板——以第一人称体验开头，视觉证据用"——""你看""这"嵌入，最多 2 句纯视觉描述后必须回到个人体验。自检：闭上眼睛读一遍评价——如果能想象自己在吃饭而不是看照片，就对了。

29. **餐厅名提取失败（v4.5.1 新增）**：dianping-vision CLI 使用烹饪分析 prompt，对大众点评截图（团购页面/店铺主页）只会做"食材判断"而不会提取餐厅名称、地址等元数据。即使截图顶部有餐厅名，vision 分析结果中也找不到。**解决方案**：
   - **优先路径**：如果截图是大众点评详情页（有星级/人均/口味环境服务分），用单独的精简 OCR 调用提取餐厅名。用 curl + Qwen API，max_tokens=150，prompt 仅要求"提取餐厅名称和位置"。
   - **实际限制**：Qwen 视觉 API 单次调用 ~60-84s，且 terminal timeout 常有。如果 OCR 多次失败或超时：
     - 从语音文件名推断位置（如"龙湖滨江天街"）
     - 从 vision 分析中提取菜系类型（如"日式烧肉"）
     - 文件夹重命名时使用 `日期_菜系_位置` 格式（如 `20260530_日式烧肉_滨江天街`）
     - 标签中只写商圈/菜系，不编造店名
   - **长期方案**：dianping-vision CLI 未来应支持 `--extract-metadata` 模式，对截图类图片用不同 prompt。

30. **extract_order_prices.py 误中环境图（v4.5.1 新增）**：脚本通过 vision.json 的 analysis 文本匹配关键词（"订单"/"收据"/"小计"）来识别订单截图。但环境照片的 vision 分析中可能包含"点餐/结账用"等描述，导致误判。**症状**：prices.json 的 `order_found: true` 但 `items: []`，因为 OCR 发现图片中没有实际订单信息。**影响**：漏掉真正的价格来源——大众点评团购页面（IMG_2069 类型）的菜品单价未被提取。**当前处理**：如果 `order_found=true` 但 `items=[]` 或 `total=0`，手动从 vision.json 中查找 Dianping 团购页面的分析结果，提取总价和套餐结构。团购页面的价格信息在 vision 分析的"菜单设计"部分，不在 OCR 可提取的位置。

### v4.4 新增陷阱

27. **遗漏核心招牌菜**：当餐厅以某道菜命名（如"很久以前羊肉串"），且该菜占总消费 30%+ 或多张图片中出现时，即使语音未直接评价也必须写入评价。处理方式：从图片分析中提取外观/火候/食材证据，标注价格分量，不编造口味评分。不能因为是"语音未提"就直接跳过——读者会困惑为什么去羊肉串店没写羊肉串。
23. **relight 仓库未 install**：首次跑 CLI 前确保 `cd /Users/stringzhao/workspace/relight && pnpm install` 已执行。CLI 通过 `cd apps/backend && npx tsx src/cli/dianping-vision.ts` 调用，需要 backend 包的 node_modules 完整。
24. **llama-server 未启动**：CLI 调用前先 `curl -s -m 3 -H "Authorization: Bearer qwen-local-key" http://127.0.0.1:8001/v1/models`，200 才继续。CLI 单次 timeout 180s，server 挂了会全部超时。
25. **CLI 部分失败处理**：exit code 2 表示部分图失败、其他成功，应读 `vision.json` 的 `results[].error` 字段识别失败图，决定是否跳过或重跑（重跑只对失败的图传位置参数）。

### Whisper Transcription
8. **Whisper CLI doesn't exist**: The `whisper` command is not installed. Use the bundled script: `python3 <skill_dir>/scripts/whisper_transcribe.py <audio_path> [language]`. This uses faster-whisper Python API directly, handles turbo model download (~1.5GB first run), and has longer timeout tolerance than `terminal`.
9. **First-run model download**: faster-whisper downloads the turbo model (~1.5GB) to `~/.cache/huggingface/hub/models--Systran--faster-whisper-turbo/` on first use. First run may take 60-120s. Subsequent runs ~20s.
10. Audio files > 2 min produce multi-segment transcripts. The script parses ALL segments automatically.

### Vision API (Qwen3.6-35B)
11. **Verbose reasoning preamble**: Qwen returns long reasoning chains (标记为 `reasoning_content`) before the actual analysis in `content`. The useful content is at the END. When extracting, prefer `content` but fall back to `reasoning_content`, and truncate the preamble.
12. **Batch processing**: 10+ images × ~84s each = 14+ min for full professional analysis. Use **two-tier strategy** (see Step 1 speed optimization): quick ID (200 tokens, ~8s) for all images, full analysis (2000 tokens) only for key dishes.
13. **Vision model misidentification**: Qwen often misidentifies dishes (e.g., calls 油豆腐烧肉 "红烧牛腩", sees menu images as food). Cross-validate vision output against audio transcription and menu info. Audio always wins.
14. **Performance note**: Actual Qwen3.6-35B visual analysis measured at **~60-84s per image** (varies by image complexity and system load). Quick ID prompts at ~7-8s. Plan timing accordingly.

### Web Search / Research
15. **macOS grep lacks `-P` flag**: `grep -oP` (Perl regex) does not work on macOS. When scraping DuckDuckGo HTML or other text, use `grep -o` with standard regex or pipe through `sed`/`awk`. Alternative: use `python3 -c "import re; ..."` for complex extraction.
16. **DuckDuckGo HTML search may return empty**: Restaurant-specific dish names often return zero results from general web search. Don't loop retrying — fall back to built-in culinary knowledge and the `references/deep-research-benchmark.md` knowledge base.
17. **`web_search` 工具不可用（v4.3.1）**：Hermes agent 无 `web_search` 工具，`browser_navigate` 到 DuckDuckGo 也可能因反爬机制不返回实际搜索结果。Step 2.5 深度料理研究应**优先依赖内置料理知识 + `references/deep-research-benchmark.md`**，直接跳过搜索步骤。搜索策略中列出的 3 次搜索作为知识覆盖检查清单（确保每道菜想到了做法/火候/食材三个维度），而非必须执行的网络请求。

### Quality Reviewer Guardrails
14. **Structural elements ≠ fabrication**: The quality reviewer may flag template-required structural elements (整体口味X分, 推荐指数X星, 标签) as "fabrication" because they aren't verbatim from the voice recording. These are syntheses — the skill explicitly requires them. If the reviewer fails ONLY on structural elements and all dish evaluations match the audio, accept the feedback for refinement but proceed after at most 2 rounds. Do not loop indefinitely trying to pass a reviewer that rejects the template itself.

### ai-todo Notes
9. Note body = review text + tags ONLY. No meta info.
10. The note IS the publishing copy — treat as final product

## Verification Checklist

- [ ] Directory scanned for pending folders
- [ ] `.reviewed` folders skipped
- [ ] Images professionally analyzed via `dianping-vision` CLI（vision.json 已生成且 `stats.failed=0`）
- [ ] Audio transcribed (if available)
- [ ] Three-layer analysis assembled（定调层 + 观察层 + 解释层）
- [ ] Deep culinary research per dish（每道菜 3 次搜索，结构化笔记）
- [ ] No fabrication: all facts cross-checked (对照 v4 零杜撰边界表)
- [ ] No "听你说"/"据了解" markers in final output
- [ ] **v4.5 第一人称主线：每道菜以体验开头+收尾，视觉证据嵌入叙事（非独立成段）**
- [ ] **每道菜专业增量 ≥ 30%（图片观察 + 知识解释 ≥ 语音转述）**
- [ ] Structure matches v4 template
- [ ] Dish-by-dish pricing
- [ ] Tags at the end
- [ ] Quality review passed (≥18, all ≥3, **depth ≥ 3**, no fabrication)
- [ ] `review.md` written + `.reviewed` marker created
- [ ] ai-todo note is clean, copy-paste ready
- [ ] No AI clichés or emotional judgment
- [ ] **Folder renamed to `日期_餐厅名_位置` format (v4.1)**

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 4.6.0 | 2026-06-15 | **Step 0.2 改用插件 API**：聚类触发 `POST /api/plugins/dianping-cluster/run` + 轮询 + 从 `result.photos[].outputPath` 复制已转换 JPEG。新增降级策略（API 不可达→CLI 直调；任务 failed→回退）。relight 管理后台 `/admin/plugins` 可浏览历史任务和照片集合页 |
| 4.5.1 | 2026-06-11 | 新增 pitfalls #29（餐厅名提取失败：dianping-vision CLI 不提取截图元数据，需单独 OCR 或降级命名）、#30（extract_order_prices.py 误中环境图，团购页面价格未被提取）；强化 pitfall #17（视觉证据必须覆盖所有菜品，100% 非零道）；Step 8 新增餐厅名未知时的 `日期_菜系_位置` 降级命名规则 |
| 4.5.0 | 2026-05-30 | **语音主线重构**：Step 3a 合成模板从"三层并列段落"改为"单条叙述线（体验→证据→解释→判断）"。新增核心原则#3"语音为主线、视觉为佐证"。视觉证据须用口语词（——、你看、这）嵌入叙事，禁止独立成段 |
| 4.4.0 | 2026-05-30 | 新增 Step 1.5 订单价格提取：`extract_order_prices.py` 自动检测订单截图并用纯 OCR prompt 提取价格 |
| 4.3.0 | 2026-05-26 | 图片分析链路 CLI 化：迁移至 `relight/apps/backend/src/cli/dianping-vision.ts`。SKILL.md 不再包含 sips/python/curl 内联代码。两阶段策略废弃（统一 4096 tokens 精析）。HEIC 解码、resize、字段 fallback、超时由 CLI 内部处理 |
| 4.2.1 | 2026-05-26 | Step 1：API 调用策略改为 terminal 后台并行（禁止 execute_code 串行）；新增 pitfalls #22 execute_code 中断问题 |
| 4.1.0 | 2026-05-13 | 文件夹重命名功能 (`日期_餐厅名_位置`) |
| 4.0.0 | 2026-05-10 | 三层信息模型重构；专业增量≥30%强制要求；零杜撰边界表；深度料理研究升级 |
