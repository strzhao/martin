---
name: dianping-review
description: "Use when the user asks to generate Dianping (大众点评) restaurant reviews. Scans /Volumes/stringzhao_主空间/大众点评/ for pending review folders, generates Chinese-language reviews from food photos and voice notes, and saves them to the folder."
version: 4.8.0
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
    related_skills: [whisper, dianping-cluster]
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

**每道菜必须有观察和感受，不能只是语音转述。但知识解释（料理原理）全篇最多 1 处。**

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

### 4. 真人食客风格（v4.8 — 去 AI 味）

你是**在手机上打字的普通食客**，不是写评测报告的编辑。你发点评的目的是跟其他食客说「这家我吃过了，情况是这样的」，不是在教人做菜或展示专业知识。

**核心定位**：一个有观察力的普通食客。懂一点吃但不掉书袋，能说出好坏但不用术语。像你朋友在微信里安利一家店。

**风格铁律**：

1. **手机打字感**：短句为主，偶尔长句。允许不完整句子。不用刻意追求段落工整。结尾偶尔不加句号。允许语气词（"还别说""怎么说呢""反正""讲真"）。

2. **评分不用数字**：不用"4.5分""3分""2.5分"这种精确分数。用口语表达——"挺好吃的""还可以""一般般""不太行""不值"。开篇可以用"整体不错""整体还行""整体一般"替代打分。推荐度用"推荐""可以试试""不推荐"就够了，不加星星。

3. **禁用符号**：
   - ❌ `——`（破折号）— 手机打字没人用，改句号分段
   - ❌ `✓` `✗` `→` `↑` 等装饰符号
   - ❌ `*` `**` 加粗标记
   - ❌ 列表式的 `- 第一点 / - 第二点` 结构

4. **禁用学术词汇**：以下词汇出现即不合格——
   - 美拉德反应、焦化层、芥子油苷、脂肪酸、氨基酸、肌原纤维蛋白
   - 复合层次感、IMP-谷氨酸协同效应、乳酸发酵产生酯类
   - 说人话版本：「外壳焦香」「带点苦」「油香重」「肉香味浓」
   
   延伸：所有化学/生物学术语一律禁止。要表达同样的意思，用日常语言描述你吃到嘴里的感受。

5. **知识融入规则（v4.8 大幅收紧）**：
   - 全篇最多 **1 处**料理知识（不是每道菜）
   - 必须用「说起来」「之前看人说过」「其实」最多 1 次
   - 一句话带过，不展开解释原理
   - 正确：「说起来梅子排骨这种，话梅少了确实吃不出酸味」✓
   - 错误：「其实梅子排骨的精髓在于话梅用量和投放时机，放少了没味道、下早了酸味煮挥发」✗（展开=教程）
   - 如果不知道该插哪道菜，就干脆不插知识。知识缺失 > 被 AI 检测。

6. **结构差异化（v4.8 新增）**：
   - 禁止每道菜用相同公式。有的菜写 1 句，有的写 4 句
   - 不强制每道菜都配「性价比判断」
   - 视觉观察自然穿插，不是「——证据模式」
   - 例：一道菜可以只写「鸡翅好吃。外酥里嫩，汁水锁住了。腌得也到位。」
   - 另一道菜可以展开：「牛排有点柴。切下去就知道了，纤维粗，嚼着费劲。一百多一份的话不太值。」

**开篇格式**（简化为两种随机选）：
- A：「X人，花了X块，人均X。整体不错。招牌菜确实有两下子，但有两道跟价格不太匹配。」
- B：「人均X。X个人点了个套餐加两道菜。整体还行。」

**环境服务**：能两句话说完就别写三段。不用写「环境优雅」「服务周到」这种套话。

**总结**：不写「推荐指数X星」。直接说「值得来」「可以试试」「一般般」「不太推荐」。加一句什么场景合适。

**标签**：只用 `#位置 #菜系 #推荐菜`，不出现「探店」二字。

**禁止**：
- "听你说""据了解""用户提到"等距离标记
- "非常好吃""环境优雅""服务周到""底子扎实""在线""到位"等 AI 高频套话
- "完全不值""最大的雷""翻车""网红店气质"等情绪化审判
- ai-todo笔记中的元信息（质量评分、文件路径、"零杜撰"等）
- 任何形式的**教学口吻**（"X的精髓在于Y""X讲究的是Y""X关键在Y"）

## Directory Structure

**v4.7 新增**：`dianping-cluster` skill 产出标准化目录格式，本 skill 直接消费。

```
/Volumes/stringzhao_主空间/大众点评/
├── 2026-07-19_午餐_得闲饮茶(杭州粤菜)_¥279/  # ← dianping-cluster 产出
│   ├── cluster.json                          # 聚类元数据（餐厅/菜名/价格/交叉验证）
│   ├── feedback.txt                          # 用户评价（语音转写或文字）
│   ├── IMG_2407.PNG                          # 美团截图（权威数据源）
│   ├── IMG_2408.HEIC                         # 环境照
│   ├── IMG_2409.HEIC                         # 菜品照 1
│   └── ...
│   ├── review.md                            # ← 本 skill 产出
│   └── .reviewed                            # ← 生成后创建
├── 后市街/                                   # 旧格式（兼容）
│   ├── 后市街.m4a
│   └── ...
└── ...
```

**识别规则**（优先 cluster.json 格式）：
- 目录包含 `cluster.json` → 直接从 cluster.json 读取餐厅/菜名/价格，跳过 Step 0.2 和餐厅识别
- 目录不包含 `cluster.json` → 走旧流程（兼容），尝试从文件名/截图提取餐厅信息

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

### Step 0.2: Read cluster.json（v4.7 — 优先消费 dianping-cluster 产出）

如果目录包含 `cluster.json`，直接从聚类元数据中提取结构化信息，**跳过餐厅识别和价格提取**：

```bash
cat "$FOLDER/cluster.json" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print('RESTAURANT:', c['restaurant']['name'])
print('CITY:', c['restaurant'].get('city', ''))
print('CUISINE:', c['restaurant'].get('cuisine', ''))
print('PACKAGE:', c['package']['name'], '¥', c['package']['group_buy_price'])
print('DISHES:')
for d in c.get('dishes', []):
    status = '✓' if d['verified'] else '⚠(修正:' + d.get('correction', '') + ')'
    photo = d.get('photo', '无照片')
    name = d['name_meituan']  # 权威菜名（已交叉验证）
    print(f'  {status} {name} -> {photo}')
print('FEEDBACK:', '有' if c.get('feedback') else '无')
"
```

**cluster.json 提供的信息可直接替代以下步骤**：
| 信息 | 传统来源 | cluster.json 字段 | 
|------|---------|-------------------|
| 餐厅名 | 截图 OCR / 猜测 | `restaurant.name`（已通过 Qwen OCR 提取） |
| 城市/菜系 | 推断 | `restaurant.city` / `restaurant.cuisine` |
| 价格 | 截图 OCR | `package.group_buy_price` |
| 菜名 | 截图 OCR + 看图猜 | `dishes[].name_meituan`（权威，已交叉验证 Qwen 误判） |
| 菜品-照片映射 | 手动匹配 | `dishes[].photo` |

如果目录没有 `cluster.json`（旧格式或手动放置），回退到以下降级流程。

### Step 0.5: Gather Materials

```bash
IMAGES=$(find "$FOLDER" -maxdepth 1 \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.HEIC" \) -print | sort)
AUDIO=$(find "$FOLDER" -maxdepth 1 \( -iname "*.m4a" -o -iname "*.mp3" -o -iname "*.wav" \) -print | sort)
FEEDBACK_TXT="$FOLDER/feedback.txt"
CLUSTER_JSON="$FOLDER/cluster.json"
```

**Restaurant identification priority**（v4.7 简化）：
1. **`cluster.json` → `restaurant.name`**（最高优先级，已通过 Qwen OCR + 交叉验证确认）
2. 美团截图 OCR（旧流程兼容）
3. 文件夹名 / 语音文件名 / 环境图

**无需再手动识别餐厅名**：`dianping-cluster` skill 已在聚类阶段完成了 OCR + 交叉验证，`cluster.json` 中的 `restaurant.name` 即为权威餐厅名。

### Step 0.6: User Input Check（v4.7 升级 — 优先 feedback.txt）

**硬性规则：没有用户的评价作为「定调层」，不生成任何评价文本。图片只能提供视觉证据，不能替代用户的味觉判断。**

在 Step 0.5 收集素材后，按以下优先级获取用户评价：

**1. 检查 `feedback.txt`**（dianping-cluster 产出）：
```bash
if [ -f "$FOLDER/feedback.txt" ] && [ -s "$FOLDER/feedback.txt" ]; then
  echo "FEEDBACK_AVAILABLE"
fi
```

如果有 `feedback.txt` → 直接作为「定调层」使用，跳过询问。

**2. 检查语音文件**：
```bash
if [ -z "$AUDIO" ] && [ ! -s "$FOLDER/feedback.txt" ]; then
  echo "NO_INPUT"
fi
```

**如果 `NO_INPUT`**（既无语音也无 feedback.txt）：
1. **立即暂停所有后续步骤**，不要进入 Step 1 图片分析
2. 使用 `clarify()` 工具询问用户
3. 用户的文字回复 → 作为「定调层」，保存为 `$FOLDER/feedback.txt`，逐菜映射到后续三层分析中
4. **只有在获得用户文字评价后**，才继续 Step 1 及之后步骤

**询问模板**（用 `clarify()` 发送，open-ended 模式）：

```
这个文件夹「<folder_name>」没有语音笔记。跟我说说这顿饭吧——
- 整体感觉怎么样？
- 每道菜吃了什么感受？（哪些好、哪些一般、哪些不行）
- 有什么特别想提的？
```

**为什么必须这样做**：
- 核心原则#1「绝不杜撰」：口味评价必须来自用户本人
- 图片只能提供外观证据（火候/食材/调味的可见线索），不能替代「好不好吃」
- 没有定调层的评价 = 基于外观猜测口味 = 杜撰

**如果用户回复了文字评价**：
- 将用户原话作为「定调层」文本
- 在 Step 2b 三层结构组装时，用用户文字替代语音转写
- 后续流程与有语音时一致（图片分析 + 知识解释 = 专业增量）

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

**v4.7 优化 — 复用聚类阶段的 vision.json**：如果该文件夹由 `dianping-cluster` skill 产出（含 `cluster.json`），聚类时已跑过 dianping-vision CLI，可直接复用其 vision.json 跳过重跑（节省 ~90s）。前提是照片内容一致（同一顿饭）。若后续加了新照片，重新跑 CLI。

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

### Step 2: Input Processing — Audio, User Text, or feedback.txt

**2a. Audio Transcription**（如果有语音文件）— Use bundled script:
```bash
python3 <skill_dir>/scripts/whisper_transcribe.py "<audio_path>" zh
```
Extract: dishes mentioned + opinions, prices, service, atmosphere, standout points.
If the script fails, fall back to `execute_code` with inline faster-whisper Python.

**2a-alt. feedback.txt**（v4.7 新增 — dianping-cluster 产出）：
如果 `$FOLDER/feedback.txt` 存在且非空：
- 直接读取作为「定调层」文本
- 逐句提取：每道菜的评价、整体感受、人数、消费
- 同传统语音转写一样，逐菜映射到后续三层分析中

**2a-alt2. User Text Input**（如果 Step 0.6 触发了无语音询问）：
- 用户的文字回复已经通过 `clarify()` 获得
- 将用户原文作为「定调层」使用，不需要转写
- 逐句提取：每道菜的评价、整体感受、人数、消费

**2b. Assemble Three-Layer Structured Analysis（三层结构组装）**

读取 Step 1 产出的 `/tmp/dianping-review/<folder>/vision.json`（`results[].analysis` 是每张图的 7 项专业分析），结合语音转写或用户文字输入，组装为结构化文档，供 Step 3 使用。按三层模型组织：

```markdown
## 结构化分析 (v4.0 三层模型)

### 整体信息
- 餐厅：<名称推测>
- 人数：<语音/文字中提到>
- 总消费/人均：<语音/收据>

### 菜品 1: <菜名>
#### 定调层（语音/用户文字）
- 评价者判断：<引用语音原文 或 引用用户文字回复>
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

**Style**: 真人食客风格（见核心原则#4）。像一个普通食客在微信里分享。知识用日常语言，禁止学术腔。

**核心原则：评价 ≠ 转录。每道菜必须有观察和感受，但全篇料理知识最多 1 处。**

#### Step 3a: 逐菜合成（v4.8 重写 — 去公式化）

**核心转变**：v4.5 的"体验→视觉→知识→性价比"四段式太整齐了，每道菜一个模子，AI 检测器一抓一个准。v4.8 废除统一模板，每道菜写法随机变化。

**随机写法池**（每道菜从以下挑一种，全文不重复超过 2 次）：

| 写法 | 适合场景 | 示例结构 |
|------|---------|---------|
| A. 快评式 | 正常好吃的菜 | 菜名（价格），推荐。一句话好吃在哪。一句话不足（如果有）。|
| B. 吐槽式 | 明显有问题的菜 | 菜名（价格），不太行。问题在哪。什么原因（最多一句，不展开讲原理）。|
| C. 展开式 | 招牌/惊喜菜 | 菜名（价格），推荐。2-3 句说感受。1 句视觉观察（自然融入，不单起段落）。|
| D. 随口带过 | 中规中矩 | 菜名（价格），正常水准。不展开了。|

**视觉观察融入规则**（v4.8 简化）：
- 禁止单起一段做"观察层"
- 视觉证据放在体验描述中，作为自然补充
- 正确：「牛肉切下去就知道卤透了，筷子一拨就散」✓（观察和体验融合）
- 错误：「牛肉表面焦褐色均匀，筋膜完全化开」✗（纯观察段落）

**知识融入规则**（v4.8 大幅收紧）：
- 全篇最多 1 处料理知识，不是每道菜
- 一句话带过，不展开
- 自然融入，不用"因为""所以""这说明"开头
- 如果不需要就不加。知识缺失 > 被 AI 检测

**性价比**：只在价格明显偏高/偏低时提一句。正常价位不需要每道菜都评价性价比。

**参考示例**（v4.8 风格）：

```
✅ A 写法（快评式）：
鸡翅（套餐内），推荐。外酥里嫩，汁水锁得好。腌得也到位，骨头边都有味。

✅ B 写法（吐槽式）：
四季豆（¥42），不太行。吃起来就是普通炒豆角，三巴酱和樱花虾的味道基本没有。42 块点盘豆角不太值。

✅ C 写法（展开式）：
榴莲薄脆披萨（¥58），推荐。第一口就被榴莲味闷住了，甜度很足。饼底薄得像脆壳，边缘带着焦斑，不是软塌塌那种。榴莲也给得大方，58 不便宜但味道对得起。

✅ D 写法（随口带过）：
蔬菜拼盘（套餐内），正常水准。新鲜度没问题。
```

#### Step 3b: 完整评价结构（v4.8 简化）

```
[开篇 — 直接开始，不加标题]
随机选 A 或 B：
A: X人，花了X块，人均X。整体不错。<一两句整体印象>。
B: 人均X。X个人点了个套餐加几道菜。整体还行。

[菜品详情 — 逐道，每道菜从写法池（Step 3a）中随机挑一种]
写法不要重复，有的 A，有的 B，有的 C，有的 D。
菜少的店（≤5道），挑 2 道用 C 展开，其余用 A/D。
菜多的店（≥6道），最多 1 道用 C，其余用 A/D/B。

[环境与服务 — 1-2句，不展开]

[总结 — 1-2句]
直接说「值得来」「可以试试」「一般般」，加一句什么场景合适。

[标签 — 1行]
标签：#位置 #菜系 #推荐菜
```

#### Step 3d: 集成规则（v4.8 简化）

- 语音观点 → 直接作为作者判断，不用"听你说"前缀
- 图片分析 → 选最相关的 1 个维度自然融入体验描述，不是每张图都用
- **料理知识 → 全篇最多 1 处**，一句话带过。不需要就不加
- 环境 → 只在图片中明确可见或语音提及时描述，1-2 句即可
- 禁止"底子扎实""在线""到位""稳定"等 AI 高频套话

#### Step 3e: v4.8 质量门禁（新增去 AI 味检查）

**结构差异**：
- [ ] 每道菜写法是否不同？（不允许全文统一模板）
- [ ] 菜名后第一句是否给出了推荐/不推荐？（不是评分数字）

**人味检查**（v4.8 核心）：
- [ ] 全文 **0** 个破折号 `——`？
- [ ] 全文 **0** 个小数评分（3.5/4.5/2.5 分）？
- [ ] 全文 **0** 个学术词汇（美拉德/芥子油苷/脂肪酸/氨基酸/肌原纤维蛋白/酯类/复合层次感）？
- [ ] 全文 **≤ 1** 处料理知识展开？超过 1 处 = 不合格
- [ ] 全文 **0** 次教学口吻（"X的精髓在于Y""X讲究的是Y""X关键在Y"）？
- [ ] 全文 **0** 个装饰符号（✓ ✗ → ↑ `*` `**` `- 列表`）？
- [ ] 有没有短句？有没有口语词（"还别说""讲真""反正"）？
- [ ] 环境服务是否 ≤ 2 句话？（没写"环境优雅""服务周到"）
- [ ] 结尾是否直接说"值得来/可以试试"？（没写"推荐指数X星"）

**内容底线**：
- [ ] 没有"听你说""据了解"等距离标记？
- [ ] 无任何杜撰内容？
- [ ] 标签在末尾，不含「探店」二字？
- [ ] 无 AI 套话（"非常好吃""底子扎实""在线""到位"）？

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

### Step 6: Save Output + Present to User

Write `review.md` to the folder, then `touch .reviewed`.

**完成后，立即将 review.md 的完整内容直接返回给用户**，方便用户直接在聊天中消费和复制。无需等待用户确认或询问——生成即推送。

如果同时处理多个文件夹，**每家店的点评必须独立发送（单独一条消息）**，不能合并到一条消息中用分隔符拼接。方便用户逐条复制到大众点评。

### Step 7: Sync to ai-todo Notes

**The note body must be directly copyable to 大众点评 with zero edits.**

No meta-commentary: no file paths, no quality scores, no "零杜撰", no emoji symbols.

**CRITICAL**: `ai-todo notes:create` only has `--title` and `--tags`. There is NO `--description` flag. The ENTIRE review — headline, dish details, environment, summary, and tags — must all go in the single `--title` argument. The `--title` field accepts multi-line text with embedded newlines.

Title argument: The complete review text, from opening to closing tags:
```
X人，花了X块，人均X。整体不错。

鸡翅（套餐内），推荐。外酥里嫩，汁水锁得好。
...
环境：<评价>
总结：值得来。<场景>
标签：#<位置> #<菜系> #<推荐菜>
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
8. **v4.0 核心**：每道菜必须有基于图片的具体观察。全篇料理知识最多 1 处。纯语音转述 = 不合格。

### v4.0 新增常见错误
15. **纯转述（v4 最常见失败模式）**：把语音内容用更好的措辞写一遍，但没有图片观察。解决方案：回到 Step 3a，检查每道菜是否有至少 1 句基于实际观察的具体描述。
16. **知识掉书袋**：插入了与图片/语音无关的料理知识。例如语音和图片都没提"锅塌"，却插入一段鲁菜历史。解决方案：每条知识必须直接解释图片证据或语音观点。
17. **图片分析未利用 / 视觉证据覆盖不全（v4.5 → v4.8 简化）**：完成了 Step 1 专业图片分析，但草案中未引用任何视觉观察。**v4.8 要求：重要的菜自然融入 1 句视觉观察，不是每道菜必须有**。不单起"观察层"段落。解决方案：从 vision.json 中提取关键视觉细节，融入体验描述中（如"切下去就知道卤透了"）。
18. **观察层空洞**：写了"火候不错"但没有具体证据。解决方案：必须写具体可见证据（"焦褐色均匀""酱汁挂壁""鱼肉蒜瓣状分离"）。
19. **知识教科书化（v4 高频陷阱）**：使用"乳酸发酵产生酯类""IMP-谷氨酸协同效应""肌原纤维蛋白变性收缩"等学术语言，导致评审判定"不像真人写的"（真实性扣分）。解决方案：用日常语言——"自然发酵，酸味慢慢出来""两种鲜碰到一起是加成的""胶原没有充分化开"——保留知识内核，换日常语言。
20. **通用知识当具体问题（杜撰红线）**：语音只说"一般不推荐"，却在评价中写"没酒香""淀粉老化变硬"作为这道菜的具体问题。这是将通用料理知识伪装成具体观察 = 杜撰。解决方案：用推测语气区分——"其实酒酿圆子挑细节…感觉这份这些细节没太注意到"——知识作为判断标准框架，不作为这道菜的确定事实。

### 工具链陷阱（v4.0-v4.2 历史，v4.3 已通过 CLI 化全部规避）
19. ~~vision_analyze 不可用 → terminal + background curl~~ → v4.3 改为 `npx tsx dianping-vision.ts`（从 `apps/backend` 目录），不再依赖 Hermes 内置 vision 或 terminal 并行
20. **delegate_task 搜索不返回实际结果**：子代理的 web_search 只返回 self-report summary，不返回实际搜索内容。深度料理研究（Step 2.5）需要直接执行 web_search 或使用 execute_code 调用搜索，不要委托给子代理。（与图片分析无关，仍然适用）
21. ~~Qwen 视觉 token 不足 < 2000~~ → CLI 默认 4096，且 `finish_reason=length` 时自动 stderr 告警
22. ~~execute_code 连续调用 Qwen 被中断~~ → CLI 用 OpenAI SDK + 进程内 p-limit 并发，不走 execute_code/terminal

### v4.8 新增 — AI 检测陷阱（最高优先级）

31. **破折号 `——` 一出现就死**：大众点评 AI 检测把破折号作为强特征。手机打字没人用破折号。全文 0 破折号，用句号分段替代。

32. **小数评分是自杀**："4.5分""2.5分"这种精确到 0.5 的评分 = 算法生成的。真人用"不错""一般""不太行"。

33. **每道菜配知识 = 教科书模式**：v4.5 要求每道菜 30-50% 专业增量，但现在会被 AI 检测。v4.8 全篇最多 1 处知识，不需要就不加。

34. **教学口吻触发检测**："X的精髓在于Y""X讲究的是Y""X关键在Y"——任何教你做菜的句式都是 AI 签名。

35. **学术词汇黑名单**：美拉德反应、芥子油苷、脂肪酸、氨基酸、肌原纤维蛋白、酯类、复合层次感。出现一个，整篇重写。

36. **结构整齐 = 算法生成**：如果读完发现每道菜都是"菜名+定调+体验+视觉+知识+性价比"，AI 检测器直接标记。v4.8 的 A/B/C/D 写法池就是为了打破这个模式。

37. **AI 高频套话补充黑名单**："底子扎实""在线""到位""稳定""细节在线""火候拿得稳"。这些词出现在 90% 的 AI 评价里。

38. **标签含「探店」触发风控**：大众点评对"探店"标签敏感，子代理可能自动加。落盘前 grep 检查并删除。

28. **视觉分析喧宾夺主（v4.5 高频陷阱 — v4.8 已通过禁用破折号/纯视觉段落解决）**：步骤见 v4.8 Step 3a——视觉观察必须融入体验描述，不单起段落。自检：闭上眼睛读一遍——能想象自己在吃饭而不是看照片，就对了。

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

31. **子代理标签污染（v4.7.1 新增）**：使用 delegate_task 并行生成点评时，子代理可能在标签行加入 "杭州探店""探店报告" 等包含「探店」的变体标签。**必须在本机落盘前检查并删除**标签行中任何包含「探店」的 tag。最终格式严格为 `标签：#位置 #菜系 #推荐菜`，不出现「探店」二字。

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
14. **Structural elements ≠ fabrication**: The quality reviewer may flag template-required structural elements (整体口味, 标签) as "fabrication" because they aren't verbatim from the voice recording. These are syntheses — the skill explicitly requires them. If the reviewer fails ONLY on structural elements and all dish evaluations match the audio, accept the feedback for refinement but proceed after at most 2 rounds. Do not loop indefinitely trying to pass a reviewer that rejects the template itself.

### ai-todo Notes
9. Note body = review text + tags ONLY. No meta info.
10. The note IS the publishing copy — treat as final product

## Verification Checklist

- [ ] Directory scanned for pending folders
- [ ] `.reviewed` folders skipped
- [ ] **如果无语音文件 → 已通过 `clarify()` 获得用户文字评价（Step 0.6）**
- [ ] Images professionally analyzed via `dianping-vision` CLI（vision.json 已生成且 `stats.failed=0`）
- [ ] Audio transcribed **或** 用户文字评价已作为定调层（if available）
- [ ] Three-layer analysis assembled（定调层 + 观察层 + 解释层）
- [ ] No fabrication: all facts cross-checked (对照 v4 零杜撰边界表)
- [ ] No "听你说"/"据了解" markers in final output
- [ ] **v4.8 去 AI 味**：全文 0 破折号、0 小数评分、0 学术词汇、≤1 处知识
- [ ] **v4.8 结构差异**：每道菜写法随机，不重复统一模板
- [ ] **v4.8 口语化**：有短句、有口语词、无教学口吻、无 AI 套话
- [ ] Dish-by-dish pricing
- [ ] Tags at the end, no「探店」
- [ ] Quality review passed (≥18, all ≥3, **depth ≥ 3**, no fabrication)
- [ ] `review.md` written + `.reviewed` marker created
- [ ] ai-todo note is clean, copy-paste ready
- [ ] No AI clichés or emotional judgment
- [ ] **Folder renamed to `日期_餐厅名_位置` format (v4.1)**

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 4.8.0 | 2026-07-22 | **去 AI 味大改**：废除四段式统一模板 → A/B/C/D 随机写法池；禁用破折号、小数评分、学术词汇；全篇知识 ≤1 处；新增口语化要求（短句/语气词）；开篇格式简化 2 选 1；总结取消「推荐指数X星」；AI 检测陷阱 pitfalls 31-38；新增 AI 高频套话黑名单 |
| 4.7.0 | 2026-07-04 | cluster.json 优先消费（dianping-cluster 产出）；无语音强制询问 feedback.txt |
| 4.6.1 | 2026-07-04 | **无语音强制询问**：新增 Step 0.6；**模板新增逐菜评分**；**「你看」零容忍** |
| 4.6.0 | 2026-06-15 | **Step 0.2 改用插件 API** |
| 4.5.1 | 2026-06-11 | 餐厅名提取失败降级命名；extract_order_prices.py 误中环境图 |
| 4.5.0 | 2026-05-30 | **语音主线重构**：三层从并列段落改为单条叙述线 |
| 4.4.0 | 2026-05-30 | 新增 Step 1.5 订单价格提取 |
| 4.3.0 | 2026-05-26 | 图片分析链路 CLI 化 |
| 4.2.1 | 2026-05-26 | terminal 后台并行 API 调用 |
| 4.1.0 | 2026-05-13 | 文件夹重命名功能 |
| 4.0.0 | 2026-05-10 | 三层信息模型重构；专业增量≥30%强制要求 |
