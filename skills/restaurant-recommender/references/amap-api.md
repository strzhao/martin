# 高德 API 参考

## 端点

| 端点 | 用途 | 频率 |
|------|------|------|
| `weather/weatherInfo` | 天气预报（4天） | 1次/任务 |
| `place/text` | POI 关键词搜索 | 5-10次/任务 |
| `place/around` | 周边搜索 | 按需 |
| `direction/driving` | 驾车路线规划 | 1-3次/任务 |

## 关键参数

- API Key: `673a1050e930744c4affc925dc90dc13`
- 杭州 adcode: `330100`
- 杭州坐标: `120.155,30.274`
- 绍兴 adcode: `330602`

## 搜索关键词模板

### 餐厅搜索（按菜系）
- 正餐: `绍兴菜` / `本帮菜` / `土菜馆` / `农家菜`
- 面食: `次坞打面` / `面馆`
- 河鲜: `河鲜` / `渔庄`
- 小吃: `臭豆腐` / `烧饼` / `蒸饺`

### 景点搜索
- 古镇: `古镇` / `古村`
- 自然: `竹海` / `漂流` / `避暑` / `山`
- 文化: `名人故居` / `博物馆`

## QPS 控制

**所有调用必须串行，间隔 ≥ 0.3 秒**。并发 4 个请求会触发 `CUQPS_HAS_EXCEEDED_THE_LIMIT`。

```bash
curl -s "..." && sleep 0.3 && curl -s "..."
```

## 静态地图 URL

```
https://restapi.amap.com/v3/staticmap?key=<KEY>&location=<lng>,<lat>&zoom=13&size=600*300&markers=mid,,A:<lng>,<lat>
```

## 导航 URL Scheme

```
https://uri.amap.com/navigation?to=<lng>,<lat>,<名称>&mode=car&callnative=1
```

此链接在手机上点击可唤起高德地图 APP 导航。

## 高德状元榜

通过 WebSearch 搜索 `高德状元榜 <城市> 美食` 获取 TOP 10 排名，或直接访问：
`https://www.amap.com/ranking/<city>/food`
