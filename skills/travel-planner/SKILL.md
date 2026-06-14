---
name: travel-planner
description: 帮助用户规划城市周边短途旅行（1-2天），从多源采集信息到生成交互式 HTML 攻略页面。当用户提到"周边游"、"周末去哪"、"一日游"、"短途旅行"、"出去玩"、"攻略"、"行程安排"、"想去周边"时使用。即使用户只是随口说"周末好无聊"或"附近有什么好吃的"，也应该触发此 skill 来推荐周边目的地。
---

# Travel Planner — 多源周边游攻略生成器

## 工作流概览

```
读取用户偏好记忆 → 高德天气+路线 → 多源并行搜索(6路)
    → 交叉验证聚合 → 输出 trip_data.json
    → inject.py 生成 HTML → server.js 启动服务
    → tunnel 暴露公网 URL → 返回给用户
```

## 步骤 0：确定起点 + 出行方式（最高优先级）

**默认起点**：用户家 — 龙湖春江天玺（景宸天玺名城），坐标 `120.241, 30.210`，最近地铁 7 号线兴议站。

**规则**：
- 用户**未指定起点** → 默认从小区出发
- 用户**说了「我在XX」** → 以用户当前位置为起点
- **第一个 timeline item 必须是「从起点出发」的交通项**

**默认出行方式**：从用户偏好文件读取。当前偏好明确为**自驾（开车）**。
- 所有交通项默认走驾车路线，icon 用 🚗
- 停车信息必须标注（高德 POI 搜索时查询目的地停车场）
- **禁止**在用户未明确要求的情况下安排地铁/公交
- 例外：目的地是步行街/无车区，可在最近停车场下车后步行到达

每次生成行程前必须先确认起点坐标和出行方式。

---

## 步骤 1：读取用户偏好

在开始搜索前，先检查用户偏好记忆：

```bash
cat ~/.claude/projects/*/memory/travel-preferences.md 2>/dev/null
cat ~/.claude/projects/*/memory/travel-history.md 2>/dev/null
```

从记忆中提取：出发城市、同行人员、出行方式、美食偏好、预算上限、已去过的目的地列表。

**已去过的地方自动排除**，不要重复推荐。如果记忆文件不存在，询问用户偏好并创建。

## 步骤 2：高德 API — 天气 + 路线（串行调用，间隔 0.3s）

API Key: `673a1050e930744c4affc925dc90dc13`

### 2.1 天气查询
```bash
curl -s "https://restapi.amap.com/v3/weather/weatherInfo?key=<KEY>&city=<ADCODE>&extensions=all"
```
- 杭州 adcode: `330100`
- 获取未来 4 天预报，判断天气是否适合出行

### 2.2 目的地 POI 搜索
```bash
# 按类型搜索（景点+餐厅）
curl -s "https://restapi.amap.com/v3/place/text?key=<KEY>&keywords=<关键词>&city=<ADCODE>&citylimit=true&offset=15&extensions=all"
```
**关键词模板**（请使用这些精准词）：
- 景点：`景点|古镇|漂流|竹海|避暑`
- 正餐：`绍兴菜` / `本帮菜` / `土菜馆` / `农家菜`
- 面食：`次坞打面` / `面馆`
- 河鲜：`河鲜` / `渔庄`
- 小吃：`臭豆腐` / `烧饼` / `蒸饺`

### 2.2b 停车场查询（必做 — 用户自驾）
```bash
# 对每个目的地，使用 around API 搜索周边停车场
curl -s "https://restapi.amap.com/v3/place/around?key=<KEY>&location=<lng>,<lat>&radius=500&keywords=停车场&offset=5&extensions=all"
```
每个目的地必须标注最近停车场及距离。

### 2.3 驾车路线
```bash
curl -s "https://restapi.amap.com/v3/direction/driving?key=<KEY>&origin=<lng>,<lat>&destination=<lng>,<lat>&strategy=0"
```
- 默认起点：`120.241,30.210`（龙湖春江天玺）
- 每个相邻目的地之间查询驾车距离和时间
- 用户偏好自驾，默认 strategy=0（速度优先）

### 2.4 高德状元榜（餐厅排名）
搜索 `高德状元榜 <城市> 美食` 获取 TOP 10 排名数据。

**QPS 控制**：所有高德 API 调用必须串行，间隔 ≥ 0.3 秒，否则触发 `CUQPS_HAS_EXCEEDED_THE_LIMIT`。

## 步骤 3：多源并行搜索（opencli + WebSearch）

### 3.1 opencli 大众点评 — 餐厅搜索 + 详情

```bash
# 搜索餐厅
opencli dianping search "<菜系> <城市>" --city "<城市>" --window background

# 获取详情（高价值数据）
opencli dianping shop "<shop_id>" --window background
```
shop 详情返回：`score`（总分）、`taste`（口味）、`environment`（环境）、`service`（服务）、`reviews`（评论数）、`price`（人均）、`address`、`features`。

### 3.2 opencli 小红书 — 搜索 + 详情获取

```bash
# Step A: 搜索笔记
opencli xiaohongshu search "<目的地> <美食/景点/攻略>" -f json --window background
```
返回 20 条原生笔记含标题、作者、点赞数、URL。**点赞数作为信号强度指标**。

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
小红书内部路由也是用 `/explore/<note_id>` 格式（见 opencli trace 中的 JS 源码 `openNoteDetail`）。

```bash
# Step B: 获取笔记详情（用于 aggregation 内容提取）
opencli xiaohongshu note "<search_result_url>" --window background
```
返回：title、author、content、likes、collects、comments、tags。

⚠️ `note` 命令需要完整的 `search_result` URL（含 xsec_token），但生成的分享链接使用 `explore/<note_id>` 格式，手机端有小红书 App 即可打开。

### 3.3 opencli B站 — 探店视频 + 字幕

```bash
# 搜索探店视频
opencli bilibili search "<目的地> <美食/探店>" --window background

# 获取视频元数据（播放量/点赞/收藏）
opencli bilibili video "<bvid>" --window background

# 获取逐句字幕（高价值数据）
opencli bilibili subtitle "<bvid>" --window background
```
从字幕中提取：餐厅名、具体菜品、价格、口味评价、避雷信息。专业的厨子探店 UP 主（如 真探唐仁杰）评价更可靠。

### 3.4 opencli 微信公众号 — 本地攻略

```bash
opencli weixin search "<目的地> <美食/攻略>" --window background
```

### 3.5 WebSearch — 游记补充

用 `WebSearch` 搜索游记攻略，补充 opencli 可能漏掉的信息。搜索词聚焦「目的地 一日游攻略 路线」。

### 3.6 Vision API（可选）— 图片识别

仅当需要验证「照骗」或识别关键图片内容时使用：
```bash
# 先下载图片
curl -sL -o /tmp/img.jpg "<image_url>"
# base64 编码并调用
IMG_B64=$(base64 -i /tmp/img.jpg | tr -d '\n')
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer qwen-local-key" \
  -d "{\"model\":\"qwen3.6-35b\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"描述图片内容，中文，30字\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$IMG_B64\"}}]}],\"max_tokens\":2000}"
```
⚠️ max_tokens 必须 ≥ 2000（Qwen thinking 模型推理链占 ~1500 tokens），单张耗时 ~2 min。

## 步骤 4：交叉验证聚合

汇总所有来源的数据，应用以下规则：

1. **高置信度**：同一餐厅/景点被 ≥ 2 个独立源认可 → 标记为首选
2. **中置信度**：仅 1 个源提到，但有评分数据 → 标记为备选
3. **低置信度**：仅 1 个源，无评分 → 不纳入最终推荐

验证维度：
- 高德评分 + 状元榜排名 + 点评评分（三维）
- 小红书点赞数 + B站播放量（信号强度）
- B站字幕中的诚实负面评价（如「服务差但菜品好」）

---

## 步骤 4.5：行程松弛度规则（铁律）

这是整个 skill 最重要的章节。**行程品质 > 打卡数量**。

### 4.5.1 流转时间（必须单独列出）

相邻两个游玩地点之间，**如果间距超过 500m 步行或需要换乘**，必须插入独立的 **transport** 类型 timeline item，标注：

- 交通方式（步行/地铁/打车/公交）
- 预计耗时（高德 API 查询或合理估算）
- 导航链接

**禁止**：把一个地点结束的时间直接写成下一地点开始的时间（如「12:00 午餐结束 → 12:00 下一站开始」）。

### 4.5.2 各类型地点的最低时长

| 类型 | 最低时长 | 说明 |
|------|----------|------|
| 🏛️ 博物馆/科技馆 | 90-120 min | 大型馆（>5000㎡）至少 120 min |
| 🧒 儿童探索馆/游乐场 | 90-150 min | 娃进去了出不来 |
| 🎨 文创街区/历史街区 | 60-90 min | 含拍照、逛店、休息 |
| 🛍️ 商场（含晚餐） | 90-120 min | 含逛+吃饭 |
| 🍜 正餐（午餐/晚餐） | 60-90 min | 含等位 10min + 点餐 5min + 上菜 15min + 吃饭 30-60min |
| ☕ 咖啡/下午茶 | 30-45 min | 休息缓冲 |
| 🌳 公园 | 30-60 min | 散步消食 |

### 4.5.3 带娃缓冲

用户带 3 岁小朋友出行，所有时间估算加上 20% 弹性。小朋友需要：
- 上厕所、喝水、哭闹安抚的额外时间
- 体力有限，连续游玩不超过 2.5 小时需安排休息
- 午餐/晚餐时段可能需要更长时间（喂饭、换尿布等）

### 4.5.4 行程密度上限

- **半天（4-5h）**：最多 2 个主要景点 + 1 餐
- **全天（8-10h）**：最多 3-4 个主要景点 + 2 餐 + 1-2 个咖啡/休息
- 景点之间的交通必须计算实际距离和时间，不得用「很快」「不远」等模糊描述

### 4.5.5 示例：正确 vs 错误的 timeline

**❌ 错误（太赶 + 默认地铁）**：
```
10:00-12:00 博物馆A
12:00-13:00 午餐B
13:00-15:00 博物馆C
```

**✅ 正确（松弛 + 自驾）**：
```
09:50-10:10 开车出发（龙湖春江天玺 → 博物馆A，8km，15min）
10:10-10:15 停车（博物馆A停车场，步行3min到入口）
10:15-11:45 博物馆A（90min，从容逛）
11:45-12:00 开车前往午餐（3km，8min）
12:00-13:15 午餐B（75min，含等位+吃饭+休息）
13:15-13:30 开车前往下一站（5km，10min）
13:30-15:00 博物馆C（90min）
```

**transport 项的 icon 规范**：
- 🚗 开车（默认，用户偏好自驾）
- 🚇 地铁（仅用户明确要求时使用）
- 🚕 打车（用户说打车/不开车时使用）
- 🚶 步行（仅 ≤500m 的短距离）

## 步骤 5：输出 trip_data.json + 质量校验

将聚合结果写入 `output/trip_data.json`，Schema 参考 `references/trip-data-schema.md`。

核心结构：
- `trip`：标题、日期、天气、交通、预算
- `route_map`：静态地图 URL + 导航链接
- `timeline`：按时间排列的行程项（每项含 type/icon/title/rating/price/aggregation/links）
- `restaurants`：餐厅矩阵表

### 输出质量铁律（必须遵守）

写出 trip_data.json 后，**必须逐项自检**，否则页面会出现 undefined 和缺失按钮：

| # | 检查项 | 说明 |
|---|--------|------|
| 1 | **budget 字段** | 必须含 `food_per_person` 或 `food_per_person_tight/comfort/premium` 之一 |
| 2 | **每个 timeline item** | 有坐标的必须带 `navi_url` 或 `links.amap_navi` |
| 3 | **聚合链接** | aggregation 有 `bilibili_bvid` 的，links 必须含 `bilibili` |
| 4 | **聚合链接** | aggregation 有 `dianping` 的，links 必须含 `dianping` 或 `dianping_*` |
| 5 | **weather** | 必须含 `temp_high`、`temp_low` |
| 6 | **transport** | 必须含 `distance_km`、`duration_min` |
| 7 | **起点正确** | 第一个非纯描述 timeline item 必须从用户家/指定起点出发（坐标 = 120.241,30.210 除非用户指定） |
| 8 | **流转时间** | 相邻两个游玩地点间距 >500m 或需换乘的，必须插入 transport 类型 timeline item |
| 9 | **行程不赶** | 每个景点停留时间 ≥ 类型最低时长（见步骤 4.5.2）；全天不超过 4 个主要景点 |
| 10 | **午餐/晚餐** | food 类型 item 时长 ≥ 60 min，不得紧跟前一个 item 结束时间开始 |
| 11 | **出行方式** | transport 项优先使用 🚗（开车），含驾车时长+距离+停车信息。禁止在用户未要求时默认安排 🚇/🚌 |

### 自动校验

写出 JSON 后立即运行 lint，有错误必须修复：

```bash
python3 scripts/lint.py output/trip_data.json
```

**lint 报错 → 必须修复才能继续**，lint 警告 → 检查后修复或说明原因。

## 步骤 6：生成 HTML + 启动服务

```bash
# 0. 先校验
python3 scripts/lint.py output/trip_data.json

# 1. JSON → HTML
python3 scripts/inject.py output/trip_data.json

# 2. 启动 HTTP 服务器（后台）
node scripts/server.js &
echo $! > /tmp/travel-server.pid

# 3. 暴露公网
tunnel expose 3456 <subdomain>
```

生成公网 URL：`https://<subdomain>.tunnel.stringzhao.life`

## 步骤 7：更新用户记忆

行程结束后**主动询问用户反馈**，将：
- 好评的餐厅/景点追加到偏好
- 去过的地方写入 `travel-history.md`（含日期）
- 更新口味偏好

## 输出格式

完成所有步骤后，向用户展示：
1. 公网 URL（可直接微信打开）
2. 行程摘要（地点、预算、亮点）
3. 关键餐厅的评分+价格一览

## 降级策略

| 问题 | 降级方案 |
|------|----------|
| 高德 QPS 限流 | 关键端点优先：天气 > 路线 > POI 评分 |
| opencli 命令失败 | 退回到 WebSearch 搜索 |
| tunnel 不可用 | 直接 `open output/trip.html` 本地查看 |
| Vision API 超时 | 跳过图片识别 |
| 无用户记忆 | 询问偏好后创建 |
