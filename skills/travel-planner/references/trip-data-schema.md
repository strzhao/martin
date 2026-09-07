# trip_data.json Schema

## 完整 JSON Schema

```json
{
  "trip": {
    "title": "绍兴 · 烟雨江南逛吃一日游",
    "date": "2026-06-13",
    "weather": {
      "condition": "小雨",
      "temp_high": 24,
      "temp_low": 20,
      "wind": "东北风1-3级"
    },
    "transport": {
      "mode": "自驾",
      "distance_km": 63.6,
      "duration_min": 66,
      "origin": "杭州",
      "destination": "绍兴"
    },
    "budget": {
      "food_per_person_tight": 150,
      "food_per_person_comfort": 188,
      "food_per_person_premium": 243
    }
    // 推荐使用 food_per_person_tight/comfort/premium 三档
    // 模板同时兼容旧版 economy/standard/premium 字段名（fallback 读取）
    // 也可以只提供 food_per_person 单一人均（无三档切换）
  },
  "route_map": {
    "static_url": "https://restapi.amap.com/v3/staticmap?...",
    "navi_url": "https://uri.amap.com/navigation?to=120.585,30.002,绍兴鲁迅故里&mode=car"
  },
  "timeline": [
    {
      "time": "10:30",
      "type": "transport|food|sight|break",
      "icon": "🅿️|🍜|📍|☕",
      "title": "鲁迅故里停车场",
      "description": "停车，开始行程",
      "location": { "lng": 120.585, "lat": 30.002, "name": "鲁迅故里停车场" },
      "navi_url": "https://uri.amap.com/navigation?to=120.585,30.002,鲁迅故里停车场&mode=car",
      "rating": { "amap": 4.7, "bangdan_rank": 1, "bangdan_score": 4.80 },
      "price_per_person": 77,
      "confidence": "high|medium|low",
      "aggregation": {
        "dianping": {
          "shop_id": "G2m6g92SqMXoSbxi",
          "score": 4.4,
          "taste": 4.4,
          "environment": 4.6,
          "service": 4.5,
          "reviews": 39465
        },
        "bilibili_quotes": ["样样都好吃，全程无槽点"],
        "bilibili_bvid": "BV1PG411c7K5",
        "bilibili_views": 3200727,
        "xhs_likes": 485,
        "xhs_url": "https://www.xiaohongshu.com/..."
      },
      "address": "鲁迅中路5号咸亨新天地",
      "features": ["有大桌", "付费停车", "有宝宝椅"],
      "links": {
        "dianping": "https://www.dianping.com/shop/G2m6g92SqMXoSbxi",
        "bilibili": "https://www.bilibili.com/video/BV1PG411c7K5",
        "xhs": "https://www.xiaohongshu.com/...",
        "amap_navi": "https://uri.amap.com/navigation?to=120.585,30.002,寻宝记&mode=car"
      }
    }
  ],
  "restaurants": [
    {
      "name": "寻宝记绍兴菜",
      "type": "绍兴菜",
      "price_per_person": 77,
      "rating_amap": 4.7,
      "bangdan_rank": 1,
      "dianping_score": 4.4,
      "dianping_reviews": 39465,
      "confidence": "high",
      "district": "鲁迅故里",
      "address": "鲁迅中路5号咸亨新天地",
      "links": { "dianping": "...", "bilibili": "...", "xhs": "..." }
    }
  ],
  "sources": [
    "高德API", "大众点评(opencli)", "小红书(opencli)",
    "B站(opencli)", "微信公众号(opencli)", "WebSearch"
  ]
}
```

## 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `trip.title` | string | ✅ | 攻略标题 |
| `trip.weather` | object | ✅ | 天气信息 |
| `trip.transport` | object | ✅ | 交通信息 |
| `trip.budget` | object | ✅ | 三档预算 |
| `route_map` | object | ✅ | 地图 URL |
| `timeline[]` | array | ✅ | 行程时间线 |
| `timeline[].aggregation` | object | ❌ | 聚合证据数据（sight/food 通用——sight 同样要有点评分/小红书赞/B站实评，模板渲染「为什么推荐」折叠块不区分类型） |
| `restaurants[]` | array | ⚠️ | 餐厅矩阵——有 food 项时必填；纯游玩行程（无 food 项）可给空数组，「餐厅总览」章节自动隐藏 |
| `restaurants[].confidence` | string | ✅ | 置信度 high/medium/low |
| `timeline[].navi_url` | string | ❌ | 高德导航链接（缺省时 inject 自动从 `location` 坐标生成 `uri.amap.com/marker` 兜底） |
| `timeline[].duration_min` | number | ❌ | 该项预计停留分钟数——页面渲染「约X小时」时长徽章（带娃节奏感关键信息，sight/food 缺失时 lint 警告） |
| `generated_at` | string | ❌ | 数据采集时间（页脚「数据采集于」）——**inject 自动烙入数据文件 mtime**，一般无需手写 |
| `alternatives` | array | ❌ | Plan B 备选方案 `[{name, when, detail}]`——`when`=启用条件（如「雨停且娃想看恐龙」），渲染为独立「🌂 Plan B」章节（雨天/带娃场景刚需） |
| `trip.subtitle` | string | ❌ | 副标题，渲染于 header 主标题下方（适合写出行人员、日期范围等补充说明） |
| `timeline[].day` | string | ❌ | 多日行程的日分组标签（如 `8/19（周三）· 市区休闲日`）；相邻 item 的 day 值变化时渲染日分隔条，单日行程不提供此字段 |
| `timeline[].day_weather` | string | ❌ | 当日天气摘要胶囊（如 `🌧 小雨 30°/26°`），随日分隔条一同渲染，取每组首个 item 的值 |
| `timeline[].highlights` | string[] | ❌ | 决策要点（≤4 条、每条 ≤18 字），渲染为紧凑 bullet 列表；**优先于 description**（有 highlights 时 description 折叠为「完整说明」） |
| `timeline[].tips` | string[] | ❌ | 注意事项（风险/营业时间/天气影响），渲染为琥珀色注意卡 |
| `timeline[].photos` | string[] | ❌ | 现场照片 URL（横向滑动条，加载失败自动隐藏——图源防盗链是常态，宁缺毋滥） |
| `timeline[].info` | object | ❌ | 实用硬信息块 `{hours, ticket, reservation, parking, crowd}`——营业时间/票价明细（成人儿童老人免票线）/预约渠道/停车场+费用+步行分钟/高峰时段。sight 与 food 必填 parking（自驾刚需）；查不到的键省略，**禁止编造** |
| `timeline[].play_guide` | string[] | ❌ | 怎么玩/怎么吃（3-5 条）：游览动线、必看点、推荐菜、最佳拍照位。与 highlights 互补——highlights 回答「选不选它」，play_guide 回答「去了怎么玩」 |
| `timeline[].kid` | string | ❌ | 带娃适配一行（3 岁半+：适龄项目/身高限制/儿童票/体力续航，如「1.2m 以下免票，1.1m+ 项目可玩 8 成」；母婴室/推车类婴儿需求不再采集） |
| `timeline[].voices` | object[] | ❌ | 真实声音 `[{quote, source, url, tone}]`——一好（tone:"good"）一差（tone:"bad"）两条代表性实评，各 ≤30 字；source 注明出处（如「小红书·320 赞笔记」），**url 为原文链接**（选择页与攻略页都靠它做抽查锚点，调研必须采集，查不到链接的实评标注「链接未采集」）；**必须来自真实采集，禁止编造** |
