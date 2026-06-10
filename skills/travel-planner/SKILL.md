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

## 步骤 1：读取用户偏好

在开始搜索前，先检查用户偏好记忆：

```bash
cat ~/.claude/projects/*/memory/travel-preferences.md 2>/dev/null
cat ~/.claude/projects/*/memory/travel-history.md 2>/dev/null
```

从记忆中提取：出发城市、出行方式、美食偏好、预算上限、已去过的目的地列表。

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
# 按类型搜索
curl -s "https://restapi.amap.com/v3/place/text?key=<KEY>&keywords=<关键词>&city=<ADCODE>&citylimit=true&offset=15&extensions=all"
```
**关键词模板**（请使用这些精准词）：
- 景点：`景点|古镇|漂流|竹海|避暑`
- 正餐：`绍兴菜` / `本帮菜` / `土菜馆` / `农家菜`
- 面食：`次坞打面` / `面馆`
- 河鲜：`河鲜` / `渔庄`
- 小吃：`臭豆腐` / `烧饼` / `蒸饺`

### 2.3 驾车路线
```bash
curl -s "https://restapi.amap.com/v3/direction/driving?key=<KEY>&origin=<lng>,<lat>&destination=<lng>,<lat>&strategy=0"
```
- 杭州坐标: `120.155,30.274`

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

### 3.2 opencli 小红书 — 趋势发现

```bash
opencli xiaohongshu search "<目的地> <美食/景点/攻略>" --window background
```
返回 20 条原生笔记含标题、作者、点赞数、URL。**点赞数作为信号强度指标**。
- ⚠️ `note` 命令受反爬拦截不可用，search 结果已含足够信息

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

## 步骤 5：输出 trip_data.json

将聚合结果写入 `output/trip_data.json`，Schema 参考 `references/trip-data-schema.md`。

核心结构：
- `trip`：标题、日期、天气、交通、预算
- `route_map`：静态地图 URL + 导航链接
- `timeline`：按时间排列的行程项（每项含 type/icon/title/rating/price/aggregation/links）
- `restaurants`：餐厅矩阵表

## 步骤 6：生成 HTML + 启动服务

```bash
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
