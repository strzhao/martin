---
name: travel-planner
description: 帮助用户规划城市周边短途旅行（1-2天），从多源采集信息到生成交互式 HTML 攻略页面。当用户提到"周边游"、"周末去哪"、"一日游"、"短途旅行"、"出去玩"、"攻略"、"行程安排"、"想去周边"时使用。即使用户只是随口说"周末好无聊"或"附近有什么好吃的"，也应该触发此 skill 来推荐周边目的地。
category: domain
---

# Travel Planner — 多源周边游攻略生成器

## 步骤 0：确定起点 + 出行方式（最高优先级）

**默认起点**：用户家 — 龙湖春江天玺（景宸天玺名城），坐标 `120.241, 30.210`，最近地铁 7 号线兴议站。用户未指定则默认小区出发；用户指定则按用户位置。第一个 timeline item 必为「从起点出发」的交通项。

**默认出行方式**：**自驾（开车）**。所有交通项默认 🚗 走驾车路线，停车信息必标注。禁止在用户未要求时安排地铁/公交。

## 步骤 1：读取用户偏好

用 `memory` 工具查询："travel"、"出行"、"周边游"、"已去过"、"美食偏好"。同时检查 `~/.claude/projects/*/memory/travel-preferences.md`。已去过的地方自动排除。

## 步骤 2：天气 + 目的地搜索

### 天气（降级顺序）
```bash
# 首选：高德 API（需 AMAP_KEY）
curl -s "https://restapi.amap.com/v3/weather/weatherInfo?key=<KEY>&city=330100&extensions=all"

# 降级：wttr.in（无需 key）
curl -s "https://wttr.in/Hangzhou?format=j1"
```

### 目的地搜索
AMAP_KEY 未设置时使用 `delegate_task` 并行搜索（3路）：
1. 杭州周边雨天室内遛娃目的地（3条路线，含景点+餐厅）
2. 杭州本地室内遛娃场所（名称/地址/票价/适龄）
3. 周边室内乐园最新评价和价格

同时用 OSM Nominatim API 获取坐标（间隔 1.5s）：
```python
url = f"https://nominatim.openstreetmap.org/search?q={q}&format=json&limit=1&accept-language=zh"
```

OSM 中国坐标稀疏 → 合理估算并标注近似。

## 步骤 4：交叉验证聚合

≥ 2 源 = high，1 源有评分 = medium，1 源无评分 = low（不推荐）。

## 步骤 4.5：行程松弛度规则（铁律）

| 类型 | 最低时长 | 
|------|----------|
| 🏛️ 博物馆/科技馆 | 90-120 min |
| 🧒 儿童乐园 | 90-150 min |
| 🍜 正餐 | 60-90 min |
| ☕ 咖啡/休息 | 30-45 min |

- 带娃：+20% 缓冲，连续游玩 ≤2.5h
- 全天 ≤4 个主要景点 + 2 餐
- 景点间距 >500m 必须插入 🚗 transport 项
- 禁止「12:00 午餐结束 → 12:00 下一站开始」

## 步骤 5：输出 trip_data.json

Schema 参考 `references/trip-data-schema.md`。写出后立即 `python3 scripts/lint.py`。

### 多路线支持

生成多条对比路线时，每条用独立输出文件（见步骤 6 的 inject 第二参数），再各自部署成独立 drop：
- trip_data.json  → inject → output/<目的地1>.html
- trip_data2.json → inject → output/<目的地2>.html
- trip_data3.json → inject → output/<目的地3>.html

## 步骤 6：生成 HTML + 远端部署

```bash
# 1. 校验 + 注入（每条路线一份独立输出文件）
python3 scripts/lint.py output/trip_data.json
python3 scripts/inject.py output/trip_data.json output/shaoxing.html
# 多路线：对 trip_data2/3.json 各跑一次 inject，输出到不同文件

# 2. 部署到远端 drops（fire-and-forget — 部署完即可关机断网，URL 持久）
tunnel deploy output/shaoxing.html --name travel-shaoxing
# → https://d.stringzhao.life/travel-shaoxing
```

部署要点：

- **slug 约定**：`travel-<目的地拼音>`（如 `travel-shaoxing` / `travel-qiandao`）。drops 全局唯一、持久常驻。
- **slug 冲突**（HTTP 409）：换名（加日期 `travel-shaoxing-260808`）或先 `tunnel rm <slug>` 再传。
- **首次失败排查**：401 = deploy token 不匹配 → 跑 `tunnel drops init` 并按提示把 token 同步到 VPS `.env.production` 的 `DEPLOY_TOKEN`；413 = 超 10 MiB（攻略 HTML 通常 ~25KB，基本不触发）。
- **管理**：`tunnel list` 看全部 drops、`tunnel rm <slug>` 下线。
- 微信里直接发 `https://d.stringzhao.life/<slug>`，手机浏览器 / 微信内置浏览器均可打开（模板自包含、移动优先 620px）。

**本地预览**（不想部署时）：`open output/trip.html`（单文件自包含，可直接打开）。

### 部署失败降级

1. `MEDIA:<filepath>` 微信发送 HTML 文件（手机上可直接打开）
2. `open output/trip.html` 本地查看
3. 纯文本路线总结

## 步骤 7：更新用户记忆

行程结束后询问反馈，写入 travel-history.md。

## 降级策略总表

| 问题 | 方案 |
|------|------|
| AMAP_KEY 未设置 | wttr.in + delegate_task 3路搜索 + OSM坐标 |
| OSM 坐标稀疏 | 合理估算 + 标注近似 |
| tunnel deploy 不可用 | `MEDIA:<filepath>` 微信发 HTML（手机直接打开）→ `open` 本地查看 → 纯文本路线总结 |