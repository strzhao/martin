# opencli 命令速查

## 环境

- 版本: v1.7.22
- 依赖: Chrome + Browser Bridge (端口 19825)
- 通用参数: `--window background`（后台运行）

## 大众点评 (dianping)

```bash
# 搜索餐厅
opencli dianping search "<关键词>" --city "<城市>" --window background

# 获取详情 - 最核心的数据源
opencli dianping shop "<shop_id>" --window background
```

shop 返回字段: `score`(总分), `taste`(口味), `environment`(环境), `service`(服务), `reviews`(评论数), `price`(人均), `address`(地址), `features`(特色: 停车/大桌等), `hours`(营业时间)

**search 返回中 `rating`/`reviews` 为 null 是正常的，需要用 shop 命令获取详情。**

## 小红书 (xiaohongshu)

```bash
# 搜索笔记（可用）
opencli xiaohongshu search "<关键词>" --window background

# 笔记详情（反爬拦截，不可用）
# opencli xiaohongshu note "<url>"  ← SECURITY_BLOCK
```

search 返回: `title`(标题), `author`(作者), `likes`(点赞数), `url`(链接), `published_at`(发布时间)

**点赞数作为信号强度指标。**

## B站 (bilibili)

```bash
# 搜索视频
opencli bilibili search "<关键词>" --window background

# 视频元数据
opencli bilibili video "<bvid>" --window background

# 逐句字幕 - 高价值数据
opencli bilibili subtitle "<bvid>" --window background
```

video 返回: `title`, `author`, `view`(播放量), `like`(点赞), `favorite`(收藏), `duration`, `publish_time`

subtitle 返回: `index`, `from`(起始秒), `to`(结束秒), `content`(字幕文本)

**从字幕提取**: 餐厅名、菜品名、价格、口味评价、避雷信息。

**优先选专业厨子探店 UP 主**（如 真探唐仁杰），评价更诚实客观。

## 微信公众号 (weixin)

```bash
# 搜索文章
opencli weixin search "<关键词>" --window background

# 下载全文 Markdown
opencli weixin download --url "<mp.weixin.qq.com/s/xxx>" --window background
```

## 携程 (ctrip) — 住宿场景

```bash
opencli ctrip search "<目的地>" --window background
```

## 知乎 (zhihu) — 不可用

需要登录 cookie，当前不可用。

## 常见问题

- **dianping search 返回酒店而非餐厅**：关键词改为菜系名（如 `绍兴菜`）而非城市名
- **输出格式**：默认 table，加 `-f json` 或 `-f yaml` 获取结构化数据
- **session 管理**：`--site-session ephemeral` 每次新会话，`persistent` 保持登录态
