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

- 带娃（3 岁半+）：+15% 缓冲，连续游玩 ≤3h；午睡弹性可选（不再按婴儿作息硬排），午后仍建议留 1 个低强度时段
- 全天 ≤4 个主要景点 + 2 餐
- 景点间距 >500m 必须插入 🚗 transport 项
- 禁止「12:00 午餐结束 → 12:00 下一站开始」

## 步骤 4.6：候选方案选择页（人审环，09-06 拍板；两轮制）

调研交叉验证完成后、写 trip_data.json **之前**，先把候选方案交给用户选——用户判断注入在生成之前，是行程质量的关键杠杆。

**两轮选择，严格按顺序（09-06 用户拍板：吃依附于骨架，不同页不同时）**：

- **第一轮 = 骨架**：过夜点/住宿 + 每天白天玩什么。这轮**绝对不放餐厅选项**——路线没定，"顺路"无从谈起，让用户选吃是伪选择。
- **第二轮 = 吃**：第一轮结果出来、骨架（路线）定稿后，**按实际路线筛选顺路餐厅**再出第二页选择。每个午餐/晚餐槽位给 2-3 家「当时位置 30 分钟车程内」的候选。

### 第一轮：骨架选择页

按槽位组织：过夜点/住宿 2-4 个候选、每个游玩时段 2-4 个候选。每个候选给决策就绪信息：**3-4 条 highlights（≤18 字）+ 价格 + 从上一站车程 + 核实等级（high/medium/low）+ 一句主要风险**。

### 生成选择页（md 交互组件，`tunnel drops example` 看 DSL）

- **每个槽位一组 radio**（id 如 `camp` / `day1` / `day2`），选项=候选名 + 关键数据（如「安顶山｜富阳790m｜免费｜三江交汇日出｜1.5h」）
- 每组最后一个选项固定为「都不满意」
- 页尾 **1 个 text 组件**（id `comment`）：「都不满意的槽位想换成什么方向？」——text 组件全页 ≤3，不要每个槽位各放一个；`show_when` 联动可用但非必需
- 可选加项（咖啡点/顺路景点）用 checkbox
- 约束：id 页内唯一；组件 ≤32；选项文本 ≤6 字会自动横排胶囊（方案名长，保持竖排即可）

### 候选说明块标准（09-06 拍板：用户对候选地陌生，裸列表=盲选）

**每个候选必须在 radio 组件上方配 markdown 说明块**，radio label 保持短（与说明块标题对应）：

```markdown
#### 安顶山｜富阳 · 免费
三江交汇（浦阳江+富春江+钱塘江）日出观景台，车直达，790m 海拔夏季避暑热门。
- ✅ B 站 2025 实测：免费停车+免费过夜+公厕干净+有售卖机
- 📕 小红书：「日出值得早起，云海看运气」— [原文](https://www.xiaohongshu.com/...)
- ▶️ B 站：「安顶山车中泊 vlog」— [原文](https://www.bilibili.com/...)
- ⚠️ 周末车位紧张，建议 18:00 前到
```

内容要求：
- **定位一句话**（是什么/为什么值得/适合谁）+ 3-4 条关键事实
- **实评摘录 ≥2 条，每条必须带原文链接**（小红书/B站/知乎/公众号，markdown 链接可点击跳转）——链接是决策的抽查锚点，没链接的实评不上选择页
- **一句主要风险**（管制/拥挤/温度/设施缺口）
- 调研阶段必须同步采集原文 URL：`voices` 条目升级为 `{quote, source, url, tone}`——派 subagent 时在 prompt 里明确要求「每个实评带原文链接」，回来检查缺 URL 的补采

### 媒体条（gallery 组件，09-06 拍板：陌生地点「看脸」是最高效的决策方式）

每个候选说明块**标题下方紧跟一个横滑媒体条**（2-4 条），用 interactive DSL 的 `gallery` 类型（tunnel-cli ≥1.9.3，服务端 tunnel-gateway 需同步部署否则报「type 非法」）：

```interactive
id: camp-1-media
type: gallery
items:
  - https://img.jpg | 安顶山日出
  - https://cover.jpg | ▶ B站实拍 | https://www.bilibili.com/video/BVxxx
```

- 每行格式：`图片直链 | 说明(≤20字) | 跳转链接(可选)`；视频条 = 封面图 + label 前缀「▶ 」+ link 视频页
- **图片必须验证可加载**（`curl -sI` 返回 200 且 content-type 为 image/*）——防盗链 403 的弃用；来源优先级：携程/官媒/知乎 > B站封面(i0.hdslb.com) > 其他；小红书图床防盗链严重慎用
- 渲染端自带兜底：`referrerpolicy="no-referrer"` + 加载失败整条自动隐藏（宁缺毋滥）
- gallery 是纯展示组件：不计 text 配额、不参与提交聚合；组件 id 与 radio 分开命名（如 `camp-1-media` vs `camp`）

### 部署与闭环

```bash
tunnel deploy 选择页.md --name travel-select-<目的地拼音>      # 第一轮骨架
tunnel deploy 餐厅页.md --name travel-food-<目的地拼音>        # 第二轮吃
# 发链接：https://d.stringzhao.life/<slug>
tunnel drops results <slug>   # 用户说「选好了」后收结果
```

- 每轮发链接时明确告诉用户：**选完回一句「选好了」**，然后拉 results 进入下一步
- 第一轮结果 → 先定稿骨架（路线+时间表）给用户一句话确认 → 再出第二轮餐厅页
- 用户未选的槽位：默认取 AI 推荐的第一候选，并在该项 tips 标注「默认推荐，可现场换」
- **发完链接后不要重发/重建同 slug 页面**——`tunnel rm` 重建会丢掉用户已提交的选择（重发前先 `tunnel drops results` 确认无提交）
- 等结果期间不要空转其他路线生成——选择是单点依赖

## 步骤 5：输出 trip_data.json

Schema 参考 `references/trip-data-schema.md`。写出后立即 `python3 scripts/lint.py`。

### 内容结构规则（09-06 产品审查拍板：决策成本优先）

- **每个 sight/food 项优先写 `highlights`**：3-4 条决策要点，每条 ≤18 字（如「大堂巨幕缸免费」「水族馆 ¥198/99」）。有 highlights 时 description 在页面上自动折叠为「完整说明」。
- **风险/营业时间/天气影响写进 `tips`**（琥珀色注意卡单独展示），不要埋在 description 句子里。
- **description 保留但降级为背景叙述**；句首 💡（核实结论）/⚠️（注意）标记会被模板自动提级为彩色卡片，散文也建议沿用这两个标记。
- **有真实照片 URL 才填 `photos`**（点评/小红书图床有防盗链，加载失败页面会自动隐藏；宁缺毋滥，禁止编造或放占位图）。

### 内容丰富化字段（09-06 拍板：每项信息量不足的整改）

调研阶段必须同步采集、生成阶段尽量填齐（schema 详见 references/trip-data-schema.md）：

- **`info` 实用信息块**：sight/food **必填 `parking`**（停车场+费用+步行几分钟——自驾刚需）；尽量填 `hours`（营业/停止入场）、`ticket`（成人/儿童/老人/免票线）、`reservation`（预约渠道）、`crowd`（高峰时段/建议到达时间）。查不到的键省略，**禁止编造**。
- **`play_guide`**：3-5 条「怎么玩/怎么吃」——游览动线、必看点、推荐菜、最佳拍照位。与 highlights 分工：highlights 管「选不选」，play_guide 管「去了怎么玩」。
- **`kid`**：带娃适配一行——3 岁半+ 阶段关注**适龄项目/身高限制/儿童票规则/体力续航**（如「1.2m 以下免票，大部分项目 1.1m+ 可玩」）；母婴室/推车/喝奶午休已是过去时，不再作为硬约束采集
- **`voices`**：一好一差两条代表性实评（各 ≤30 字 + 出处），比评分数字立体。**必须来自真实采集的点评/小红书/B站内容，禁止编造**。

### 内容深度均衡（09-06 拍板：纠正「偏吃」的结构性失衡）

本 skill 起源于逛吃场景，吃的基础设施（餐厅矩阵/点评子评分/榜单/餐饮三档预算）明显厚于玩。**sight 与 food 同等调研深度**，具体约定：

- **`aggregation` 聚合证据 sight 同样必填**（模板「为什么推荐」不区分类型）——博物馆/乐园也要有点评分、小红书赞数、B站实评，不是只有餐厅配拥有证据
- **调研查询按槽位配比**：每个游玩时段的搜索深度 ≥ 每个正餐（门票/预约/游玩时长/实评槽点，同餐厅的人数/排队/推荐菜一个规格）
- **`restaurants[]` 非必填**：纯游玩行程给空数组即可，餐厅总览章节自动隐藏——lint 不再对此告警
- **预算口径**：含门票行程在 `budget` 里补 `per_person_total`（门票+停车+餐饮全口径人均），不要只给餐饮三档

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