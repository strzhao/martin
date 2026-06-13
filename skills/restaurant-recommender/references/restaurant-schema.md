# restaurant_data.json Schema

## 完整 JSON Schema

```json
{
  "recommendation": {
    "title": "杭州 · 本帮菜美食推荐榜",
    "city": "杭州",
    "date": "2026-06-13",
    "cuisine": "本帮菜",
    "budget": {
      "economy": 50,
      "standard": 100,
      "premium": 200
    }
  },
  "restaurants": [
    {
      "name": "外婆家（湖滨店）",
      "rank": 1,
      "cuisine": "本帮菜",
      "district": "上城区",
      "address": "湖滨路88号银泰in77 B区3楼",
      "price_per_person": 85,
      "must_try": ["茶香鸡", "外婆红烧肉", "蒜蓉粉丝虾"],
      "confidence": "high",
      "scoring": {
        "amap": 4.7,
        "dianping": 4.4,
        "bangdan_rank": 1,
        "bangdan_score": 4.80,
        "bilibili": {
          "bvid": "BV1PG411c7K5",
          "views": 3200727,
          "quotes": ["样样都好吃，全程无槽点"]
        },
        "xhs_likes": 485,
        "weixin": "本地美食博主强烈推荐"
      },
      "features": ["有大桌", "免费停车", "可预订"],
      "tiers": {
        "economy": { "name": "工作日午市套餐", "price": 58 },
        "standard": { "name": "招牌双人套餐", "price": 118 },
        "premium": { "name": "私宴定制", "price": 268 }
      },
      "links": {
        "dianping": "https://www.dianping.com/shop/G2m6g92SqMXoSbxi",
        "bilibili": "https://www.bilibili.com/video/BV1PG411c7K5",
        "xhs": "https://www.xiaohongshu.com/explore/abc123"
      }
    }
  ],
  "sources": [
    "高德API", "大众点评(opencli)", "小红书(opencli)",
    "B站(opencli)", "微信公众号(opencli)", "WebSearch"
  ]
}
```

## 字段说明

### recommendation（推荐摘要）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `title` | string | ✅ | 推荐标题，如「杭州 · 本帮菜美食推荐榜」 |
| `city` | string | ✅ | 目标城市 |
| `date` | string | ✅ | 推荐日期，格式 YYYY-MM-DD |
| `cuisine` | string | ✅ | 菜系类型（本帮菜/火锅/粤菜/日料等） |
| `budget` | object | ✅ | 三档预算（economy/standard/premium），单位元/人 |

### budget（预算）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `economy` | number | ✅ | 经济档人均预算 |
| `standard` | number | ✅ | 标准档人均预算 |
| `premium` | number | ✅ | 品质档人均预算 |

### restaurants[]（餐厅排名数组）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `name` | string | ✅ | 餐厅名称 |
| `rank` | number | ✅ | 排名（1 为最高） |
| `cuisine` | string | ✅ | 菜系 |
| `district` | string | ✅ | 所在行政区 |
| `address` | string | ✅ | 详细地址 |
| `price_per_person` | number | ✅ | 人均价格（标准档） |
| `must_try` | array | ✅ | 必点菜品列表（至少 1 项） |
| `confidence` | string | ✅ | 置信度：high / medium / low |
| `scoring` | object | ✅ | 评分多源数据 |
| `features` | array | ❌ | 特色标签（如「可预订」「有包厢」） |
| `tiers` | object | ❌ | 三档预算对应的套餐/菜品推荐 |
| `links` | object | ✅ | 外部链接集合 |

### scoring（评分子对象）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `amap` | number | ❌ | 高德评分（1-5） |
| `dianping` | number | ❌ | 大众点评评分（1-5） |
| `bangdan_rank` | number | ❌ | 高德状元榜排名 |
| `bangdan_score` | number | ❌ | 高德状元榜评分 |
| `bilibili` | object | ❌ | B站探店视频数据 |
| `bilibili.bvid` | string | ❌ | B站视频 BV 号 |
| `bilibili.views` | number | ❌ | 播放量 |
| `bilibili.quotes` | array | ❌ | 视频中提及的评价摘录 |
| `xhs_likes` | number | ❌ | 小红书相关笔记点赞数汇总 |
| `weixin` | string | ❌ | 微信公众号评价摘要 |

**约束**：`scoring` 至少包含 2 个独立数据源（`amap` / `dianping` / `bangdan_rank` / `bilibili` / `xhs_likes` / `weixin` 中的至少 2 个字段非空）。

### tiers（三档预算详情）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `tiers.economy` | object | ❌ | 经济档推荐 |
| `tiers.standard` | object | ❌ | 标准档推荐 |
| `tiers.premium` | object | ❌ | 品质档推荐 |
| `tiers.economy.name` | string | ✅ | 套餐/菜品名称 |
| `tiers.economy.price` | number | ✅ | 价格（元/人） |

### links（链接集合）

| 字段 | 类型 | 说明 |
|------|------|------|
| `dianping` | string | 大众点评店铺链接 |
| `bilibili` | string | B站探店视频链接 |
| `xhs` | string | 小红书笔记链接 |
| `weixin` | string | 微信公众号文章链接 |

### 置信度（confidence）

| 值 | 含义 | 判定标准 |
|----|------|----------|
| `high` | 高置信度 | ≥ 2 个独立源确认推荐 |
| `medium` | 中置信度 | 仅 1 个源，但有评分数据支撑 |
| `low` | 低置信度 | 仅 1 个源提及，无评分数据 |

**铁律**：高置信度餐厅至少 3 家。

### sources（数据来源）

字符串数组，列出所有使用的数据来源，如：
```json
["高德API", "大众点评(opencli)", "小红书(opencli)", "B站(opencli)", "微信公众号(opencli)", "WebSearch"]
```
