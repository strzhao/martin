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
      "economy": 150,
      "standard": 188,
      "premium": 243
    }
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
| `timeline[].aggregation` | object | ❌ | 聚合数据（仅 food 类型） |
| `restaurants[]` | array | ✅ | 餐厅矩阵 |
| `restaurants[].confidence` | string | ✅ | 置信度 high/medium/low |
| `timeline[].navi_url` | string | ❌ | 高德导航链接 |
