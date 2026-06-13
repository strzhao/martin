---
name: restaurant-recommender
description: 帮助用户发现和排名值得去吃的餐厅，从多源采集信息到生成交互式 HTML 排名页面。当用户提到"推荐餐厅"、"好吃的"、"吃什么"、"排名"、"美食推荐"、"找餐厅"、"附近有什么好吃的"、"评分高的餐厅"、"火锅"、"本帮菜"、"粤菜"时使用。即使用户只是随口说"今天吃什么"或"周末想吃顿好的"，也应该触发此 skill 来推荐餐厅。
---

# Restaurant Recommender — 多源餐厅排名推荐器

## 工作流概览

```
读取用户偏好记忆 → 高德POI搜索+状元榜排名 → 多源并行搜索(6路)
    → 交叉验证聚合 → 输出 restaurant_data.json
    → inject.py 生成 HTML → server.js 启动服务
    → tunnel 暴露公网 URL → 返回给用户
```

## 步骤 0：读取用户偏好记忆

在开始搜索前，先检查用户偏好记忆：

```bash
cat ~/.claude/projects/*/memory/food-preferences.md 2>/dev/null
cat ~/.claude/projects/*/memory/restaurant-history.md 2>/dev/null
```

从记忆中提取：口味偏好（辣/清淡/重口等）、忌口、预算偏好、已去过的餐厅列表、已推荐过的餐厅列表。

**已去过/已推荐过的餐厅自动排除**，不要重复推荐。如果记忆文件不存在，询问用户偏好并创建。

---

## 步骤 1：高德 API — POI 餐厅搜索 + 状元榜排名（串行调用，间隔 0.3s）

API Key: `673a1050e930744c4affc925dc90dc13`

### 1.1 城市 adcode 确认

默认城市为**杭州**（adcode: `330100`）。如用户指定其他城市，先搜索对应 adcode：

```bash
# 搜索城市 adcode
curl -s "https://restapi.amap.com/v3/config/district?key=<KEY>&keywords=<城市名>&subdistrict=0"
```

### 1.2 POI 餐厅搜索

```bash
# 按菜系/类型搜索餐厅
curl -s "https://restapi.amap.com/v3/place/text?key=<KEY>&keywords=<菜系/餐厅类型>&city=<ADCODE>&citylimit=true&offset=20&extensions=all"
```

**关键词模板**（请使用这些精准词）：
- 本帮菜/杭帮菜：`本帮菜|杭帮菜|浙江菜`
- 火锅：`火锅|四川火锅|潮汕牛肉火锅`
- 粤菜：`粤菜|茶餐厅|烧腊`
- 日料：`日料|寿司|居酒屋`
- 面馆：`面馆|次坞打面|片儿川`
- 小吃：`小吃|生煎|小笼包|葱包烩`
- 高端餐饮：`私房菜|人均300|黑珍珠`

### 1.3 餐厅详情（高评分优先）

对搜索结果中的高评分餐厅，获取深度信息：

```bash
# 获取单个餐厅详情
curl -s "https://restapi.amap.com/v3/place/detail?key=<KEY>&id=<POI_ID>&extensions=all"
```

提取：评分、人均消费、营业时间、地址、电话、特色标签。

### 1.4 高德状元榜（餐厅排名）

搜索高德状元榜获取 TOP 排名数据：

```bash
# WebSearch 搜索状元榜
```

搜索词：`高德状元榜 <城市> 美食` / `高德美食榜单 <城市>` / `高德必吃榜 <城市>`

**QPS 控制**：所有高德 API 调用必须串行，间隔 ≥ 0.3 秒，否则触发 `CUQPS_HAS_EXCEEDED_THE_LIMIT`。

---

## 步骤 2：多源并行搜索（opencli + WebSearch）

### 2.1 opencli 大众点评 — 餐厅搜索 + 详情

```bash
# 搜索餐厅
opencli dianping search "<菜系> <城市>" --city "<城市>" --window background

# 获取详情（高价值数据）
opencli dianping shop "<shop_id>" --window background
```

shop 详情返回：`score`（总分）、`taste`（口味）、`environment`（环境）、`service`（服务）、`reviews`（评论数）、`price`（人均）、`address`、`features`。

### 2.2 opencli 小红书 — 搜索 + 详情获取

```bash
# Step A: 搜索笔记
opencli xiaohongshu search "<城市> <菜系> 推荐" -f json --window background
```

返回 20 条原生笔记含标题、作者、点赞数、URL。**点赞数作为推荐热度指标**。

返回的 URL 格式为 `search_result/<note_id>?xsec_token=...`，其中 `note_id` 就是真实的笔记 ID。

**提取笔记 ID**：
```python
import re
note_id = re.search(r'/([a-f0-9]{24})\?', url).group(1)
```

**构造可分享链接**（手机端可打开）：
```
https://www.xiaohongshu.com/explore/<note_id>
```

```bash
# Step B: 获取笔记详情（用于提取具体推荐内容）
opencli xiaohongshu note "<search_result_url>" --window background
```

返回：title、author、content、likes、collects、comments、tags。

### 2.3 opencli B站 — 探店视频 + 本地 ASR 转写（核心环节）

**这是整个数据采集流水线中最重要的环节。** 点评/高德/小红书的评分都可以被刷，但真人探店视频中 UP 主的真实语气、停顿、措辞——经过本地 whisper 逐字转写后——无法伪造。ASR 转写是步骤 3 中高置信度判定的**必要条件**：没有 ASR 转写正面引用的餐厅，最高只能是 medium。

#### Step A: 搜索 + 筛选

```bash
# 搜索探店视频
opencli bilibili search "<城市> <菜系> 探店" --window background

# 获取视频元数据（播放量/点赞/收藏）
opencli bilibili video "<bvid>" --window background
```

筛选规则（选择 3-5 个视频做深度转写，不是全量）：
- **优先**：专业厨子探店（如 真探唐仁杰）— 会从技术和食材角度评价，诚实客观
- **优先**：本地美食博主日常 vlog — 真实消费，非商业合作
- **优先**：播放量 > 50K 的大 UP — 评价更客观
- **排除**：标题含「广告」「合作」的商业视频
- **排除**：纯画面+BGM 无解说的视频（转写了也是背景音乐）

#### Step B: 下载 + 提取音轨

```bash
# 下载视频（选带音频的最低画质以节省带宽和时间）
yt-dlp -f "best[height<=480]+bestaudio/best[height<=480]" \
  -o "/tmp/bilibili_%(id)s.%(ext)s" \
  "https://www.bilibili.com/video/<bvid>"

# 提取音轨为 16kHz 单声道 wav（whisper 标准输入格式）
ffmpeg -i "/tmp/bilibili_<bvid>.mp4" \
  -ac 1 -ar 16000 -sample_fmt s16 \
  "/tmp/bilibili_<bvid>.wav" -y
```

#### Step C: 本地 whisper ASR 转写

```bash
# 激活虚拟环境（brew PEP 668 要求）
source /Users/stringzhao/workspace/martin/.venv/bin/activate

# mlx-whisper 转写（large-v3-turbo：高精度 + 快速，M4 Max Metal 加速）
python3 -c "
import mlx_whisper, json
result = mlx_whisper.transcribe(
    '/tmp/bilibili_<bvid>.wav',
    path_or_hf_repo='mlx-community/whisper-large-v3-turbo',
    language='zh'
)
print(json.dumps({
    'text': result['text'],
    'segments': [{'start': s['start'], 'end': s['end'], 'text': s['text']} for s in result['segments']]
}, ensure_ascii=False, indent=2))
"
```

转写耗时约视频时长的 1/3-1/2（M4 Max + large-v3-turbo）。

#### Step D: AI 分析转写文本

拿到完整转写文本后，你（AI）需要做的是**理解人类说话的真实含义**，而不是匹配关键词：

**信号识别**（这些只有真人语音转写才能捕捉）：
- **真情实感好评**：「吃到嘴里第一口就知道对了」「软烂脱骨」「这个是真的香」→ 语气词、重复强调、语速变化的上下文
- **无功无过**：「还可以」「还行」「就那样吧」「挺好吃的」（注意：「挺好吃的」在不同语境和语气下含义完全不同——ASR 文本中看上下文判断）
- **犹豫/敷衍**：「嗯…还行吧」「怎么说呢…就那样」→ 停顿和填充词是差评的软信号
- **避雷/差评**：「踩雷」「这个就算了啊」「不值这个价」「太咸了」「没入味」→ 强负面信号
- **商业推广痕迹**：「必点」「绝绝子」「姐妹们冲」→ 高频推广话术，可信度打折

**关键信息提取**：
- 提到的具体餐厅名和菜品名
- 价格信息（「这一顿花了 130」「人均 80」）
- 对比评价（「比 XX 店的好吃」「跟总店没法比」）
- 回头意愿（「下次还会来」「不会再来第二次」）

### 2.4 opencli 微信公众号 — 本地美食攻略

```bash
opencli weixin search "<城市> <菜系> 推荐" --window background
```

### 2.5 WebSearch — 补充搜索

用 `WebSearch` 搜索美食排行榜、游记中的餐厅推荐，补充 opencli 可能漏掉的信息。

搜索词聚焦：`<城市> <菜系> 推荐餐厅` / `<城市> 美食排行榜` / `<城市> 必吃榜`

### 2.6 Vision API（可选）— 菜品图片识别

仅当需要验证菜品卖相或识别关键图片内容时使用：

```bash
# 先下载图片
curl -sL -o /tmp/food_img.jpg "<image_url>"
# base64 编码并调用
IMG_B64=$(base64 -i /tmp/food_img.jpg | tr -d '\n')
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer qwen-local-key" \
  -d "{\"model\":\"qwen3.6-35b\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"描述图片中的菜品，中文，30字\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$IMG_B64\"}}]}],\"max_tokens\":2000}"
```

⚠️ max_tokens 必须 ≥ 2000（Qwen thinking 模型推理链占 ~1500 tokens），单张耗时 ~2 min。

---

## 步骤 3：AI 交叉验证聚合（核心判断环节）

**这里不是机械打分，而是你（AI）做定性判断。** Python 脚本只能检查字段是否存在，但「这家店到底是真好还是刷出来的」只有你能判断。

### 3.1 数据收集清单

在判断之前，确保每个候选餐厅至少覆盖这些来源：

| 来源 | 必须 | 提供什么 |
|------|------|----------|
| 点评 shop 详情 | ✅ | 总分 + 三维（口味/环境/服务）+ 评论数 + 人均 + 特色 |
| ASR 转写 | ✅ 高置信度必须 | 逐句真实评价，无法刷分的诚实信号 |
| 高德 POI 评分 | 推荐 | 双源交叉验证 |
| 小红书搜索 | 推荐 | 热度信号 + 探店笔记内容 |
| WebSearch | 补充 | 游记/攻略中的提及 |

**铁律：标记为 high 置信度的餐厅，必须有 ASR 转写正面引用。** 无 ASR 转写的餐厅，最高只能 medium——因为评分和点赞可以刷，但逐句字幕里的「吃到嘴里第一口就知道对了」或「无功无过吧」无法伪造。

### 3.2 三维结构判断（AI 定性）

点评返回口味/环境/服务三个分数。**不要机械计算差值**，而是通过 AI 阅读理解三维结构：

- **口味 > 环境 + 服务**：实力店信号。厨房比装修强，回头客驱动。
- **环境 > 口味**：警惕信号。结合上下文判断——是高端餐厅本就该环境好，还是商场连锁靠装修引流？
- **三维均衡 4.0+ 且评论数极大（>3000）**：大概率是连锁标准化出品。不难吃，但也不惊艳。除非 ASR 转写有真情实感的好评，否则不应进入 top 3。

对于每个进入 top 5 的餐厅，在 aggregation 中写一句话的三维解读，例如：

```
"口味 4.6 > 环境 4.4 > 服务 4.3 — 典型的厨房驱动型实力店，评分结构健康"
```

或：

```
"环境 4.6 > 口味 4.5 — 环境溢价，需结合字幕判断口味是否配位"
```

### 3.3 连锁品牌识别（AI 定性）

通过餐厅名称、点评返回的特征（「有包厢」「有宝宝椅」vs 商场标准化描述）、WebSearch 结果综合判断是否为连锁品牌。连锁店本身不是问题——「荣小馆」是连锁但品质好——但连锁 + 无 ASR 转写 = 必须降级。

### 3.4 ASR 转写锚定（最高权重）

**这是整个验证体系最关键的一环。** 点评/高德/小红书的评分都可以被刷，但 B站逐句字幕中的真实评价——尤其是专业厨子探店 UP 主的——是最诚实的信号。

字幕分析要点：
- **真情实感好评**：「吃到嘴里第一口就知道对了」「软烂脱骨」「脆嫩鲜甜」→ 强正面信号
- **无功无过**：「还可以」「还行」「挺好吃的」（此处「挺好吃的」≠ 真情实感）→ 弱信号
- **避雷/差评**：「不推荐」「踩雷」「18块钱就算了啊」→ 强负面信号，一票否决
- **广告/商业合作**：标题含「广告」「合作」或语气明显推广 → 直接排除该视频

### 3.5 置信度判定（AI 综合）

1. **🟢 高置信度（high）**：≥ 2 个独立源认可 **且** ASR 转写有真情实感正面评价 **且** 三维结构健康（口味 ≥ 环境） **且** 无明显差评
2. **🟡 中置信度（medium）**：有评分数据但缺少 ASR 转写验证，或三维结构有环境溢价但无其他负面信号
3. **🔴 低置信度（low）**：仅 1 个源且无评分，或 ASR 转写明确踩雷 → 不纳入推荐

**特别警示**：评分高 + 评论极多(>3000) + 环境分 > 口味分 + 无 ASR 转写 = 典型的高分低质连锁店模式。此类餐厅即使数据漂亮，最多 medium，不应进入 top 3。

### 3.6 排名规则

排名由 AI 综合判断，不机械加权：

- 高置信度 > 中置信度
- 同置信度内，ASR 转写评价质量优先于评分数字
- 用户偏好菜系（从记忆读取）适当加权
- 距离用户起点的便利性作为辅助因素（不远不近 3-5km 最佳）
- 用户预算上限必须尊重，超预算餐厅可放末尾标注「品质之选」

---

## 步骤 4：输出 restaurant_data.json + 质量校验

将聚合结果写入 `output/restaurant_data.json`，Schema 参考 `references/restaurant-schema.md`。

核心结构：
- `recommendation`：推荐标题、城市、日期、菜系、预算
- `restaurants[]`：餐厅排名数组（按 rank 升序，rank 1 为最高）
- 每个 restaurant：name/rank/cuisine/district/address/price_per_person/must_try/confidence/scoring/features/tiers/links

### 输出质量铁律（必须遵守）

写出 restaurant_data.json 后，**必须逐项自检**，否则页面会出现 undefined 和缺失按钮：

| # | 检查项 | 说明 |
|---|--------|------|
| 1 | **budget 字段** | 必须含 `economy`、`standard`、`premium` 三档 |
| 2 | **每个 restaurant** | 必须有 `name`、`confidence`、`scoring` |
| 3 | **scoring 数据源** | 至少含 2 个独立数据源（amap/dianping/bangdan_rank/bilibili/xhs_likes/weixin 中的至少 2 个） |
| 4 | **confidence** | 值必须为 `high` / `medium` / `low` 之一 |
| 5 | **高置信度数量** | 至少 3 家餐厅为 high |
| 6 | **restaurants 总数** | ≥ 5 家 |
| 7 | **dianping 链接** | scoring 有 dianping 评分的，links 必须含 `dianping` |
| 8 | **bilibili 链接** | scoring 有 bilibili.bvid 的，links 必须含 `bilibili` |
| 9 | **must_try** | 每个餐厅至少 1 道必点菜 |
| 10 | **tiers** | 如有按预算的分档推荐，tiers 必须含三档 |

### 自动校验

写出 JSON 后立即运行 lint，有错误必须修复：

```bash
python3 scripts/lint.py output/restaurant_data.json
```

**lint 报错 → 必须修复才能继续**，lint 警告 → 检查后修复或说明原因。

---

## 步骤 5：生成 HTML + 启动服务

```bash
# 0. 先校验
python3 scripts/lint.py output/restaurant_data.json

# 1. JSON → HTML
python3 scripts/inject.py output/restaurant_data.json

# 2. 启动 HTTP 服务器（后台）
node scripts/server.js &
echo $! > /tmp/restaurant-server.pid

# 3. 暴露公网
tunnel expose 3457 <subdomain>
```

生成公网 URL：`https://<subdomain>.tunnel.stringzhao.life`

---

## 步骤 6：更新用户记忆

推荐结束后**主动询问用户反馈**，将：
- 好评的餐厅追加到偏好
- 去过/推荐过的餐厅写入 `restaurant-history.md`（含日期）
- 更新口味偏好（如新发现的菜系偏好）

---

## 关键规则

### 默认值

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 城市 | 杭州 | 用户未指定时默认杭州 |
| 预算 | standard（标准档） | 用户未指定时默认标准档 |
| 推荐数量 | 8-10 家 | 至少推荐 8 家，最多 15 家 |
| 菜系 | 全菜系 | 用户未指定时覆盖主要菜系 |

### 排除规则

- 已去过/已推荐过的餐厅直接排除
- 低置信度（仅 1 源 + 无评分）不纳入最终推荐
- 存在「避雷」标签的餐厅标注风险但可保留（需注明）

### API 调用规则

- 高德 API 必须串行，间隔 ≥ 0.3 秒
- opencli 命令可并行（各自独立）
- WebSearch 可与其他源并行

---

## 降级策略

| 问题 | 降级方案 |
|------|----------|
| 高德 QPS 限流 | 关键端点优先：POI 搜索 > 状元榜 > 详情 |
| opencli 命令失败 | 退回到 WebSearch 搜索 |
| tunnel 不可用 | 直接 `open output/restaurant.html` 本地查看 |
| Vision API 超时 | 跳过图片识别 |
| 无用户记忆 | 询问偏好后创建 |
| 搜索结果不足 8 家 | 扩大搜索范围（菜系变宽、预算放宽） |
