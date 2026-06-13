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

### 2.3 opencli B站 — 探店视频 + 字幕

```bash
# 搜索探店视频
opencli bilibili search "<城市> <菜系> 探店" --window background

# 获取视频元数据（播放量/点赞/收藏）
opencli bilibili video "<bvid>" --window background

# 获取逐句字幕（高价值数据）
opencli bilibili subtitle "<bvid>" --window background
```

从字幕中提取：餐厅名、具体菜品、价格、口味评价、避雷信息。专业的厨子探店 UP 主（如 真探唐仁杰）评价更可靠。

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

## 步骤 3：交叉验证聚合

汇总所有来源的数据，应用以下规则：

1. **高置信度（high）**：同一餐厅被 ≥ 2 个独立源认可 → 标记为首选，排名靠前
2. **中置信度（medium）**：仅 1 个源提到，但有评分数据 → 标记为备选
3. **低置信度（low）**：仅 1 个源，无评分 → 不纳入最终推荐

验证维度：
- 高德评分 + 状元榜排名 + 点评评分（三维）
- 小红书点赞数 + B站播放量（推荐热度）
- B站字幕中的诚实负面评价（如「服务差但菜品好」→ 标注风险）

### 聚合规则

- 点评 shop_id 是核心关联键，用于关联多源数据到同一餐厅
- 同名餐厅按地址匹配去重（步行街/商场不同分店视为不同餐厅）
- 评分归一化：多渠道评分取加权平均（点评权重 0.4，高德权重 0.3，状元榜权重 0.2，B站/小红书热度权重 0.1）

### 排名规则

- 综合评分（归一化后）降序
- 同分时，高置信度优先
- 同置信度时，点评评论数多的优先
- 用户偏好菜系加权（+0.2 分）

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
