## 探索的目的与约束

**目标**：设计一个「城市周边短途游」攻略生成与行程安排的 Claude Code skill，核心解决「从哪里获取高质量攻略和信息」的问题。

**项目上下文**：
- 当前 workspace（martin）是 Hermes Agent 操作目录，已有 whisper 语音转写环境
- 已有 skill 结构参考：`~/.claude/skills/` 下均为 SKILL.md（YAML frontmatter + markdown 指令），支持 `references/`、`scripts/`、`assets/` 子目录
- Skill 创建规范：description 描述触发条件（非功能描述）、SKILL.md < 500 行、渐进式加载（metadata → body → bundled resources）
- 可用工具：WebSearch、WebFetch（通用搜索/抓取）、Bash（调用 API/脚本）、Agent/Workflow（多 Agent 编排）

**明确约束**：
1. 尽量免费方案（可接受免费 API，如高德开放平台免费额度）
2. 质量优先于速度（宁可多几分钟交叉验证）
3. 个性化学习/记忆（自动学习 + 迭代优化）
4. 不急于实现，先理清信息获取策略

## 候选方案与权衡

### 方案 A：纯搜索聚合（WebSearch + WebFetch）

工作流：用户需求 → WebSearch 多平台搜索 → WebFetch 抓取具体内容 → LLM 交叉验证 → 输出行程

- **优势**：零外部依赖，开箱即用；不需要任何 API key
- **劣势**：小红书/大众点评反爬严格，WebFetch 命中率不稳定；缺乏结构化数据（路线距离、实时路况只能靠 LLM 估算）；每次都需重新搜索，无缓存

### 方案 B：搜索 + 高德 API 混合

工作流：用户需求 → 高德 API（POI搜索+路线规划+实时路况）→ WebSearch 补充小红书/点评/马蜂窝口碑 → LLM 交叉验证（客观数据 vs 主观评价）→ 迭代输出

- **优势**：高德 API 免费额度充足（日均 30 万次），提供准确结构化路线数据；WebSearch 专注口碑补充而非基础信息；三维交叉验证（高德评分 + 点评评分 + 小红书笔记）天然过滤「照骗」
- **劣势**：需注册高德开放平台获取 API key；依赖高德 POI 覆盖率（江浙沪覆盖率极高，不成问题）

### 方案 C：全平台多 Agent 并行深度搜索（⭐ 选定）

工作流：用户需求 → 4 个 Agent 并行从小红书/大众点评/马蜂窝/高德独立深挖 → 汇总 Agent 去重+交叉验证+冲突标记 → 结构化行程初稿 → 用户审阅迭代

Agent 分工（Dry Run + opencli/Vision 验证后调整）：

- **opencli 小红书 Agent**（Bash 调用 opencli）：`opencli xiaohongshu search` 搜索原生笔记 → 提取标题/点赞数/作者 → 高频笔记标记为高信号。**注意**：search 可用，note detail 反爬不可用
- **opencli dianping Agent**（Bash 调用 opencli）：`opencli dianping search` 搜餐厅列表 → `opencli dianping shop <id>` 获取评分/口味/环境/服务/人均/地址/特色。**核心源**——结构化餐饮数据
- **opencli bilibili Agent**（Bash 调用 opencli）：`opencli bilibili search` 搜探店视频 → `opencli bilibili video <bvid>` 获取元数据 → `opencli bilibili subtitle <bvid>` 提取逐句字幕。**核心源**——真实探店评价+菜品+价格
- **WebSearch 大众点评/本地口碑 Agent**：搜索餐厅口碑，微信公众号文章。dianping opencli 已覆盖后降级为补充源
- **WebSearch 游记攻略 Agent**：搜索结构化游记 + 路线模板（穷游/Trip.com/马蜂窝合并）
- **opencli weixin Agent**（可选，Bash）：`opencli weixin search` 搜公众号文章 → `opencli weixin download --url` 下载全文 Markdown
- **opencli ctrip Agent**（可选，过夜场景）：`opencli ctrip search` 搜目的地/酒店
- **Vision Agent**（可选，Bash 调用 llama-server）：对关键图片进行内容识别——菜品、环境、「照骗」验证。base64 模式，单张 ~2 min
- **汇总 Agent**：多源交叉验证——高德评分 + 状元榜排名 + 点评评分(多维) + 小红书点赞数 + B站播放/字幕评价，三维以上独立源确认才标记「高置信度」

- **优势**：每路信息挖得最深，覆盖面最广；独立搜索避免单一平台偏差；汇总阶段跨平台交叉验证有效过滤营销内容
- **劣势**：每次规划 token 消耗较大（估算 30K-80K tokens）；并行需等待最慢的 Agent（马蜂窝/高德 Agent 通常较快，小红书/点评 Agent 可能更耗时）；需合理设计 Agent prompt 避免重复内容

## 选择与理由

**选定方案**：方案 C — 全平台多 Agent 并行深度搜索

**选择理由**：
1. 用户明确选择「质量优先于速度」，愿意为深度验证承担 token 成本
2. 搜索广度并行是过滤「照骗」和刷分的有效手段——同一 POI 在小红书好评如潮但在点评差评多，交叉对照即可发现
3. 周边游是低频决策（每月可能 1-2 次），单次 token 成本可接受
4. 后续可通过「按复杂度分级」策略优化：熟悉的目的地用 2 Agent 快速出，陌生的目的地启用完整 4 Agent

**被排除方案及原因**：
- 方案 A：缺乏结构化数据（路线/距离/时间），WebFetch 不稳定，无法满足「实时信息准确」要求
- 方案 B：高性价比但覆盖面不如 C，且「搜索广度并行」是用户明确选择的方向（方案 B 可作为降级模式保留）

## Dry Run 验证记录

**验证日期**：2026-06-11  
**验证场景**：杭州出发，周六（6/13）周边一日游，真实需求  
**高德 API Key**：`673a1050e930744c4affc925dc90dc13`

### 各信息源实测结论

| 信息源 | 可行度 | 实测表现 | 关键教训 |
|--------|--------|----------|----------|
| **高德 API** | ⭐⭐⭐⭐⭐ | 天气/POI/路线全部精准返回，结构化数据可直接使用 | 搜索关键词极其重要——「绍兴菜」命中率远高于「餐厅」「美食」；QPS 限制需串行调用 + sleep 0.3s |
| **WebSearch→小红书** | ⭐⭐⭐ | 能搜到热门目的地趋势（富阳石梯、桐庐石舍村），但只能读搜索引擎摘要和第三方转载 | 搜索结果可用于「发现趋势」和「信号确认」；不同平台的同一目的地被提及次数可作为置信度信号 |
| **WebSearch→大众点评** | ⭐⭐⭐⭐ | 搜索结果丰富，攻略质量高；第三方聚合（搜狐、杭州网、什么值得买、微信公众号）弥补了直接访问受限 | 搭配「本地人推荐」「苍蝇馆子」「宝藏」「小破店」等关键词效果好；微信公众号文章是意外的高质量来源 |
| **WebSearch→马蜂窝** | ⭐⭐ | 搜索引擎索引偏少，多通过 Trip.com 转载出现 | 马蜂窝内容在 WebSearch 中信号弱，不适合作为独立 Agent；可合并到「游记攻略 Agent」中 |
| **高德状元榜** | ⭐⭐⭐⭐⭐ | `amap.com/ranking/shaoxing/food` 返回 TOP 10 结构化排名，含多维度综合评分 | **意外发现**——可作为餐厅推荐的权威参考源，比单纯 POI 搜索评分更可靠 |
| **opencli 小红书 search** | ⭐⭐⭐⭐⭐ | 原生笔记搜索，返回 20 条笔记含标题/作者/点赞数/URL；内容质量远超 WebSearch 摘要 | 点赞数可作为信号强度；标题中常直接含店名；搜索频率控制避免风控 |
| **opencli 小红书 note** | ⭐ | 详情页被安全拦截（`SECURITY_BLOCK`），ephemeral/persistent session 均无效 | 笔记详情是高价值数据但反爬严格；降级方案：直接用搜索结果中的标题+标签信息 |
| **opencli 小红书 download** | ⭐ | 同上——需要 full signed URL，受安全拦截影响 | 图片下载需绕过反爬 |
| **Qwen3.6-35B 视觉识别** | ⭐⭐⭐⭐ | base64 传图成功，能准确描述食物/场景；需 1500-3000 max_tokens（thinking 模型消耗 ~1500 tokens 推理链）；URL 模式不可用（`cannot make GET request`） | 可以用于识别美食图片内容、验证「照骗」；每次识别 ~2 min，适合关键图片而非批量；需要先通过其他方式下载图片再 base64 传

### 四源交叉验证的实际效果

以「绍兴一日游」为例，四源交叉验证展示了实际价值：

1. **天气约束 → 过滤目的地**：高德天气 API 实测周六中雨转小雨，直接排除了户外徒步/溯溪/玩水类目的地（富阳石梯、安吉竹海、临安大鱼线），聚焦「雨天友好」的绍兴古镇逛吃

2. **路线数据 → 筛选可行性**：高德驾车路线 API 返回 63.6km/66min，确认当日自驾往返可行

3. **多源交叉 → 信号强度**：仓桥直街被小红书+点评+马蜂窝三源同时高频提及 → 高置信度推荐；沈园口碑两极 → 标注为「可选」

4. **评分对照 → 过滤营销**：高德 API POI 评分 + 高德状元榜排名 + WebSearch 本地人推荐，三维对照过滤了纯网红店（如一些评分虚高但本地人不去的店）

### 搜索技巧发现

| 技巧 | 说明 |
|------|------|
| **高德 API 关键词模板** | 「绍兴菜」搜正餐、「土菜馆」搜苍蝇馆子、「次坞打面」搜面馆、「河鲜」搜水产——按菜系/品类搜远优于泛搜「美食」「餐厅」 |
| **高德商圈搜索限半径** | 500m 半径噪声大（混入便利店、服装店等），建议缩小到 300m 或直接用区域关键词搜索 |
| **WebSearch 平台指向词** | 搜点评用「本地人推荐」「苍蝇馆子」「排队」；搜小红书用「探店」「出片」「宝藏」；搜马蜂窝用「攻略」「路线」 |
| **高德 QPS 控制** | 实测并发 4 个请求即触发 `CUQPS_HAS_EXCEEDED_THE_LIMIT`，需串行调用 + sleep 0.3s 间隔 |

### opencli + 小红书 vs WebSearch 质量对比

**实测对比**（同场景：绍兴美食推荐）：

| 维度 | WebSearch | opencli 小红书 search |
|------|-----------|----------------------|
| 结果数 | ~10 条（含第三方转载） | 20 条原生笔记 |
| 内容来源 | 搜狐、Trip.com、什么值得买 转载 | 小红书用户原文 |
| 信号强度 | 无（转载无互动数据） | ✅ 点赞数（485/348/152...）可直接判断可信度 |
| 信息密度 | 低——转载经过二次加工损耗 | 高——标题直接含店名、分类、地址 |
| 图片 | 少量（转载中偶尔包含） | 需单独下载（受安全拦截限制） |
| 费用 | 免费 | 免费（需 opencli + Chrome） |

**实例对比**：

```
WebSearch 典型结果:
  "绍兴本地人最爱吃的9家小馆子" — 163.com 转载，无互动数据

opencli 小红书典型结果:
  ❤️ 485 | "和朋友一致认为绍兴好吃的店（夯到拉）"
         P1-P8分类：饭馆/面/小吃/糕点/特产/下午茶/甜品
  ❤️ 348 | "绍兴真正牛逼好吃的🔟家小店！！！"
  ❤️ 152 | "绍兴，个人觉得无法超越的9家绍兴菜（附地址）"
```

### Vision API 验证详情

**环境**：llama.cpp llama-server + Qwen3.6-35B-A3B + mmproj-F16.gguf  
**API**：`http://127.0.0.1:8001/v1/chat/completions`（OpenAI 兼容）

**实测结果**：

| 模式 | 结果 | 说明 |
|------|------|------|
| URL 传图 | ❌ `cannot make GET request` | llama-server 不支持下载远程图片 |
| base64 传图 | ✅ 成功 | 需先用其他方式下载图片再编码 |
| max_tokens=100 | ❌ `finish: length`, content 空 | thinking 模型消耗 ~1500 tokens 推理链 |
| max_tokens=500 | ❌ `finish: length`, content 空 | 500 tokens 仍不够推理链 |
| max_tokens=3000 | ✅ `finish: stop`, content 正常 | 推理链 ~1485 字符 + 回答 |

**示例输出**：
- 输入：食物摆拍图片（base64）
- 回答：「木桌上摆放三盘泰式料理，含炸物、肉片与沙拉，点缀香菜辣椒。」

**适用场景**：
- ✅ 验证「照骗」：识别图片实际内容 vs 文案描述
- ✅ 环境识别：判断餐厅环境（苍蝇馆子 vs 网红装修）
- ✅ 菜品识别：识别图片中的具体菜品，辅助推荐
- ⚠️ 速度：~2 min/张（35B MoE on M4 Max），适合选 3-5 张关键图片
- ❌ 批量识别：成本过高，不适合

### opencli 全平台能力验证

**环境**：opencli v1.7.22，828 条内置命令覆盖 148 个站点 + 12 个外部 CLI

#### 已验证可用的旅行相关站点

| 站点 | 命令 | 可用 | 返回数据质量 | 对 skill 的价值 |
|------|------|------|-------------|----------------|
| **dianping** | `search` | ✅ | 餐厅名/菜系/区域/人均/shop_id | 替代 WebSearch 大众点评 |
| **dianping** | `shop` | ✅⭐ | 评分/口味/环境/服务/评论数/地址/特色 | **核心源**——结构化餐饮数据 |
| **xiaohongshu** | `search` | ✅ | 20条笔记/标题/作者/点赞/URL | 趋势发现 + 信号强度 |
| **xiaohongshu** | `note` | ❌ | `SECURITY_BLOCK` | 反爬拦截，不可用 |
| **bilibili** | `search` | ✅ | 视频标题/UP主/播放量/BV号 | 探店视频发现 |
| **bilibili** | `video` | ✅ | 标题/UP主/播放/点赞/收藏/时长/封面 | 视频元数据 + 信号强度 |
| **bilibili** | `subtitle` | ✅⭐ | **逐句字幕（时间戳+文本）** | **核心源**——真实探店评价+价格+口味 |
| **weixin** | `search` | ✅ | 公众号文章标题/摘要/时间/URL | 本地深度攻略文章 |
| **weixin** | `download` | ✅ | 全文 Markdown 下载 | 获取完整公众号文章 |
| **ctrip** | `search` | ✅ | 酒店/景点/地标结构化数据 | 住宿推荐 + 目的地信息 |
| **zhihu** | `search` | ❌ | 返回空数组 | 需要登录 cookie |

#### bilibili 字幕数据价值实测

**测试视频 1**：神奇海挪「美食博主特种兵旅行之绍兴一日吃」（2,170,132播放）
- 字幕 214 条，完整记录了：仓桥直街→小绍兴点菜→黄酒布丁(嫩像鸡蛋羹)→梅干菜排骨(软烂脱骨)→梅干菜蒸饺(甜口蘸醋)→黄酒棒冰(奶味浓)→酱油冰激凌(¥18太贵)→老表非洲菜(¥35，吃不惯)→柯桥古镇
- **价值**：真实消费体验 + 具体菜品评价 + 价格 + 避雷信息

**测试视频 2**：真探唐仁杰「绍兴.老胡子 厨子探店¥300」（2,866,411播放）
- 字幕 96 条，完整记录了：老胡子饭店→服务差没菜单→白切鹅(¥40)→猪蹄(¥40)→笋(脆嫩鲜甜)→螃蟹(¥180)→总评「全程无槽点，样样都好吃」
- 还提到了石锅大饭店火爆腰花(¥55)「口感最牛逼」
- **价值**：专业厨子视角评价 + 具体菜品价格 + 诚实负面反馈

**与文字攻略的差异**：
```
文字攻略：「老胡子饭店不错，本地人推荐」
bilibili 字幕：「三个人没地儿，根本没人理你，连个菜单都没有，
            自己写都不知道哪学...全程无槽点，样样东西我都觉得很好吃」
→ 真实体验：服务差但菜品好 — 这种矛盾信息文字攻略不会写
```

#### 升级后的信息源架构

```
                    ┌──────────────────────────────────┐
                    │       汇总 Agent (交叉验证)         │
                    │  高德评分 + 状元榜 + 点评评分       │
                    │  + 小红书点赞 + B站播放/字幕评价     │
                    └──────────────┬───────────────────┘
           ┌───────────────────────┼───────────────────────┐
           │                       │                       │
    高德 API (Bash)         opencli (Bash)           Vision (Bash)
    ┌──────┴──────┐      ┌──────┴────────┐      ┌──────┴──────┐
    │ 天气        │      │ dianping      │      │ Qwen3.6-35B │
    │ POI 搜索    │      │   search+shop │      │ base64 传图  │
    │ 路线规划    │      │ xhs search    │      │ 关键图片识别 │
    │ 状元榜      │      │ bilibili      │      │ 验证「照骗」  │
    └─────────────┘      │   search+video│      └─────────────┘
                         │   +subtitle   │
                         │ weixin search │      ┌──────────────┐
                         │ ctrip search  │      │  WebSearch    │
                         └───────────────┘      │  补充校验     │
                                                └──────────────┘
```

**信息维度覆盖**：

| 维度 | 数据源 | 结构化程度 |
|------|--------|-----------|
| 餐厅评分 | dianping shop (总分+口味/环境/服务) | ⭐⭐⭐⭐⭐ |
| 人均价格 | dianping search/shop | ⭐⭐⭐⭐⭐ |
| 真实评价 | bilibili subtitle (逐句字幕) | ⭐⭐⭐⭐ |
| 菜品推荐 | bilibili subtitle + xhs search | ⭐⭐⭐⭐ |
| 路线规划 | 高德 API | ⭐⭐⭐⭐⭐ |
| 天气 | 高德 API | ⭐⭐⭐⭐⭐ |
| 趋势/热度 | xhs search (点赞) + bilibili video (播放) | ⭐⭐⭐⭐ |
| 本地攻略 | weixin search/download (公众号全文) | ⭐⭐⭐ |
| 住宿 | ctrip search (过夜场景) | ⭐⭐⭐⭐⭐ |
| 图片验证 | Vision API (照骗识别) | ⭐⭐⭐ |

### 输出格式验证

交互式迭代模式得到了实际验证——用户三轮反馈：
1. 「记录去过的地方」→ 写入 memory 文件
2. 「自驾 + 美食重点」→ 调整行程主线和搜索重心
3. 「更多饭店选择」→ 第二轮深挖，产出矩阵式餐厅列表

多预算路线（经济版 ¥150 / 标准版 ¥188 / 品质版 ¥243）是自然演进的产物，skill 设计应内建此模式。

### 记忆系统验证

已创建 `travel-preferences.md`（`~/.claude/projects/-Users-stringzhao-workspace-martin/memory/`），记录：
- 出行偏好（自驾、美食优先、人均预算 ¥150）
- 已去过的目的地列表（含日期，避免重复推荐）

skill 设计时应：
- 规划前先读取已有偏好文件
- 行程结束后主动收集反馈并追加到 memory
- 搜索时自动排除已去过目的地

## 待主 SKILL 接力的设计决策

### 用户已确认的决策

| 决策项 | 选择 |
|--------|------|
| 旅行类型 | 城市周边短途（1-2 天） |
| 出发地 | 杭州（已确认，自驾） |
| 质量维度 | 真实口碑 + 结构化行程 + 实时信息准确 + 本地人视角 |
| 信息来源 | 高德 API（英雄源）+ 大众点评/本地口碑 + 小红书/趋势 + 游记攻略（马蜂窝/穷游/Trip.com 合并） |
| 输出模式 | 交互式迭代规划（多轮反馈修正，内建多预算路线） |
| 个性化 | 自动学习 + 迭代优化（出行后收集反馈，已创建 travel-preferences.md + travel-history.md） |
| 架构 | 4 Agent 并行搜索广度（Dry Run 后调整：马蜂窝 Agent 合并到游记攻略 Agent） |
| 预算 | 人均 ≤¥150（可灵活上浮至 ¥200），内建经济版/标准版/品质版三档 |
| 出行方式 | 自驾（已确认） |
| 美食优先级 | 最高——餐厅搜索需多轮深挖，矩阵式呈现，高德评分 + 状元榜 + 本地口碑三维验证 |

### 需要在设计文档中深化的点

1. **高德 API 搜索关键词模板**：预设按场景的关键词矩阵——正餐（「绍兴菜」「本帮菜」「土菜馆」）、面食（「次坞打面」「面馆」）、河鲜（「河鲜」「渔庄」）、小吃（「臭豆腐」「烧饼」「蒸饺」）。Dry Run 验证：关键词精准度决定命中率
2. **交叉验证规则**：汇总阶段冲突判断——高德 POI 评分 + 状元榜排名 + WebSearch 本地人推荐频率，三维对照。同一餐厅被 ≥2 个独立源认可才标记为「高置信度」
3. **高德 API 集成细节**：
   - 端点：`weather/weatherInfo`（天气）、`place/text`（POI 搜索）、`place/around`（周边搜索）、`direction/driving`（驾车路线）
   - QPS 控制：串行调用，间隔 ≥ 0.3s，避免 `CUQPS_HAS_EXCEEDED_THE_LIMIT`
   - 额外：`amap.com/ranking/<city>/food` 拉取高德状元榜 TOP 10
4. **交互式迭代流程**：初稿输出 → 用户反馈维度（节奏/预算/偏好/替换具体项目）→ 增量修正。Dry Run 验证了三轮迭代模式自然有效
5. **输出格式**：内建多预算路线（经济版/标准版/品质版），餐厅以矩阵表格呈现（含多源评分、人均、位置），景点+美食穿插的流水账格式
6. **记忆系统设计**：`travel-preferences.md` 记录偏好（出行方式/美食倾向/预算上限）+ `travel-history.md` 记录已去目的地（含日期，搜索时自动排除）。行程结束后主动收集反馈
7. **降级策略**：WebFetch 被反爬 → 仅用搜索引擎摘要 + 第三方转载；Token 不足 → 退化为方案 B（高德 API + 2 路 WebSearch）；高德 QPS 限流 → 关键端点优先（天气 > 路线 > POI 评分）
8. **Skill 文件结构**：
   ```
   travel-planner/
     SKILL.md                    # 主指令：工作流 + 工具调用顺序
     references/
       amap-api.md               # 高德 API 端点 + 关键词模板 + QPS 控制
       opencli-guide.md          # opencli 站点命令速查 + session 管理 + 反爬策略
       search-guide.md           # WebSearch 策略 + 平台指向词
       cross-verify-rules.md     # 交叉验证规则 + 信号强度计算
       vision-api.md             # Qwen 视觉识别 API 用法 + token 预算 + base64 流程
       bilibili-analysis.md      # B站字幕分析策略 + 关键信息提取模板
       trip-data-schema.md       # trip_data.json 完整 Schema 定义
     assets/
       template.html             # HTML 攻略模板（含 __TRIP_DATA__ 占位符 + 内联 CSS/JS）
     scripts/
       inject.py                 # JSON → HTML 注入脚本
       server.js                 # 零依赖 HTTP 服务器（Node.js 内置 http 模块）
     output/
       trip_data.json            # 研究阶段输出的结构化数据
       trip.html                 # 最终生成的 HTML 页面
   ```
9. **已记录的用户偏好**：自驾、杭州出发、美食优先、人均 ≤¥150、去过绍兴（鲁迅故里/仓桥直街/八字桥/书圣故里）——搜索时自动排除
10. **opencli 小红书集成要点**：
    - search 命令可靠可用，note detail 不可用（安全拦截）
    - 搜索结果中的点赞数作为信号强度指标
    - 需控制搜索频率避免触发风控
    - 用户可能需手动登录小红书（opencli browser session）
11. **Vision API 集成要点**：
    - 仅支持 base64 传图（URL 模式不可用）
    - max_tokens 需 ≥ 2000（thinking 模型推理链占 ~1500 tokens）
    - 适用场景：验证「照骗」、识别菜品、判断餐厅环境
    - 不适合批量处理（~2 min/张）
12. **bilibili 字幕分析策略**：
    - 优先选专业的厨子探店 UP 主（如 真探唐仁杰 — 客观评价+具体价格）
    - 从字幕中提取：餐厅名/具体菜品/价格/口味评价/避雷信息
    - 字幕信息密度高但噪音也大（BGM歌词、闲聊），需要 LLM 提取关键信息
    - bilibili `video` 命令的播放/点赞/收藏数作为信号强度
13. **dianping shop 详情是信息密度最高的单源**：
    - 总分 + 口味/环境/服务三维评分 + 评论数 + 人均价格 + 地址 + 特色
    - 每个餐厅仅需 1 次 API 调用（search 获取 shop_id → shop 获取详情）
    - 与高德状元榜对照可有效过滤刷分店铺

---

## HTML 消费层设计（2026-06-11 新增）

### 目的与约束

将研究阶段采集的多源数据渲染为一个**可交互的单文件 HTML 页面**，用户可以直观浏览攻略、时间安排、天气、地图、原始内容链接，并支持点击交互（导航跳转、原始内容外链）。

**已确认的设计决策**：

| 决策项 | 选择 | 理由 |
|--------|------|------|
| 页面布局 | **单列纵向布局** | 自然流动，移动端友好，阅读路径清晰 |
| 地图交互 | **静态图 + 点击导航** | 轻量快速；静态图用高德 API 生成；点击跳转 `uri.amap.com/navigation` URL Scheme |
| 内容消费 | **多源精华聚合内嵌 + 外链跳转** | 每张卡片内聚合评分/字幕精华/小红书热度，点击可跳转原链接 |
| 生成方式 | **方案 A：模板注入**（Template + JSON Injection） | 设计数据分离；模板可独立迭代；JSON 注入确保渲染一致 |
| 技术栈 | 纯静态 HTML + 内联 CSS/JS + JSON 数据嵌入 | 单文件、零依赖、可离线打开 |

### 页面结构设计

```
┌──────────────────────────────────────────┐
│  🏷️ 绍兴 · 烟雨江南逛吃一日游                │  标题区
│  📅 6月13日 周六  ⛅ 小雨 24°/20°          │  天气卡片
│  🚗 杭州出发 63.6km/66min  💰 ¥150-243   │  关键信息
├──────────────────────────────────────────┤
│  🗺️ 路线概览                               │  静态地图
│  ┌──────────────────────────────────┐    │  高德静态图 API
│  │  杭州 ──── 63.6km ────→ 绍兴      │    │  (带起终点标记)
│  │      点击 → 打开高德导航            │    │
│  └──────────────────────────────────┘    │
├──────────────────────────────────────────┤
│  ⏱️ 行程时间线                             │
│                                          │
│  10:30 🅿️ 鲁迅故里停车场                    │  每项含：
│        📍 [🗺️ 导航]                       │  · 时间 + 类型图标
│                                          │  · 名称 + 评分/价格
│  10:40 🥟 同心楼 · ⭐4.71 · ¥23           │  · 多源精华聚合卡片
│        ┌ 精华聚合 ──────────────┐        │  · [导航] 按钮
│        │ 🍜 生煎包 ¥1.3 排队王  │        │  · [点评] [B站] [小红书] 链接
│        │ 📝 B站: 一元一个日卖.. │        │
│        │ 🔗 点评 🔗 B站 🔗 小红书│        │
│        └──────────────────────┘        │
│                                          │
│  12:00 🍜 寻宝记 · ⭐4.7 · ¥77           │
│        ┌ 精华聚合 ──────────────┐        │
│        │ 点评: 口味4.4 环境4.6   │        │
│        │ 📝 39,465条评论        │        │
│        │ B站: 「样样都好吃」     │        │
│        │ 小红书: ❤️485 篇推荐   │        │
│        │ 📍 鲁迅中路5号 [🗺️]    │        │
│        │ 🔗 点评 🔗 B站 🔗 小红书│        │
│        └──────────────────────┘        │
│  ...                                     │
├──────────────────────────────────────────┤
│  📊 预算                                  │
│  🟢 经济版 ¥150 | 🔵 标准版 ¥188 | 🟣 品质版 ¥243 │
│                                          │
│  📡 数据来源                               │
│  高德API | 点评 | 小红书 | B站 | 微信公众号  │
└──────────────────────────────────────────┘
```

### 数据流（v2：HTTP 服务器 + Tunnel 暴露）

```
Research Phase → trip_data.json
                    ↓
              inject.py → trip.html
                    ↓
         server.js (Node.js http 模块, 0 依赖)
         serve trip.html on localhost:XXXX
                    ↓
         tunnel expose XXXX <subdomain>
                    ↓
    https://<subdomain>.tunnel.stringzhao.life
                    ↓
         微信/任何浏览器打开
```

### 新增组件

#### 1. `scripts/server.js` — 零依赖 HTTP 服务器

参考 `string-claude-code-plugin` 的零依赖模式，使用 Node.js 内置 `http` 模块（仅 ~20 行）：

```javascript
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3456;
const TRIP_HTML = path.join(__dirname, '..', 'output', 'trip.html');

const server = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    fs.createReadStream(TRIP_HTML).pipe(res);
  } else if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});

server.listen(PORT, () => {
  console.log(`🌐 攻略页面: http://localhost:${PORT}/`);
});
```

- **依赖**：零（仅 Node.js 内置 `http`、`fs`、`path`）
- **端口**：默认 `3456`，可通过 `PORT` 环境变量覆盖
- **路由**：`/` → trip.html，`/health` → 健康检查

#### 2. Tunnel 暴露

使用已安装的 `tunnel` CLI（`~/.tunnel-cli/config.json` 已配置）：

```bash
# 启动 HTTP 服务器
node scripts/server.js &

# 暴露到公网
tunnel expose 3456 shaoxing-trip

# → https://shaoxing-trip.tunnel.stringzhao.life
```

**tunnel-cli 配置**（已就绪）：
- frp 服务器：`43.143.124.222:7000`
- 域名：`tunnel.stringzhao.life`
- 认证 token：已配置

#### 3. 完整启动流程（skill 指令中的一步）

```bash
# 1. 生成 HTML
python3 scripts/inject.py output/trip_data.json

# 2. 启动服务器（后台）
node scripts/server.js &
SERVER_PID=$!

# 3. 暴露 tunnel
tunnel expose 3456 ${subdomain} &
TUNNEL_PID=$!

echo "✅ 攻略已上线: https://${subdomain}.tunnel.stringzhao.life"
echo "📱 复制链接到微信打开"

# 4. 等待用户确认后清理
# kill $TUNNEL_PID $SERVER_PID
```

### 更新后的数据流

### JSON 数据结构（草案）

```json
{
  "trip": {
    "title": "绍兴 · 烟雨江南逛吃一日游",
    "date": "2026-06-13",
    "weather": { "condition": "小雨", "temp_high": 24, "temp_low": 20 },
    "transport": { "mode": "自驾", "distance_km": 63.6, "duration_min": 66, "origin": "杭州", "destination": "绍兴" },
    "budget": { "economy": 150, "standard": 188, "premium": 243 }
  },
  "route_map": {
    "static_url": "https://restapi.amap.com/v3/staticmap?...",
    "navi_url": "https://uri.amap.com/navigation?to=120.585,30.002,绍兴鲁迅故里&mode=car"
  },
  "timeline": [
    {
      "time": "10:30",
      "type": "transport",
      "icon": "🅿️",
      "title": "鲁迅故里停车场",
      "location": { "lng": 120.585, "lat": 30.002, "name": "鲁迅故里停车场" },
      "navi_url": "https://uri.amap.com/navigation?to=120.585,30.002,鲁迅故里停车场&mode=car"
    },
    {
      "time": "12:00",
      "type": "food",
      "icon": "🍜",
      "title": "寻宝记绍兴菜",
      "rating": { "amap": 4.7, "bangdan_rank": 1, "bangdan_score": 4.80 },
      "price_per_person": 77,
      "aggregation": {
        "dianping": { "score": 4.4, "taste": 4.4, "environment": 4.6, "service": 4.5, "reviews": 39465 },
        "bilibili_quotes": ["样样都好吃，全程无槽点"],
        "xhs_likes": 485
      },
      "address": "鲁迅中路5号咸亨新天地",
      "features": ["有大桌", "付费停车", "有宝宝椅"],
      "links": {
        "dianping": "https://www.dianping.com/shop/G2m6g92SqMXoSbxi",
        "bilibili": "https://www.bilibili.com/video/BV1PG411c7K5",
        "xhs": "https://www.xiaohongshu.com/search_result/..."
      }
    }
  ]
}
```

### 交互功能清单

| 交互 | 实现方式 | 说明 |
|------|----------|------|
| 地点导航 | `<a href="uri.amap.com/navigation?to=...">` | 点击唤起高德地图 APP |
| 路线地图 | 高德静态图 API `<img>` | 页面加载时显示路线缩略图 |
| 原始内容跳转 | `<a target="_blank" href="...">` | 点评/B站/小红书 新标签页打开 |
| 预算切换 | JS 按钮高亮 `¥150 / ¥188 / ¥243` | 点击切换高亮不同预算路线项 |
| 时间线滚动 | CSS `scroll-behavior: smooth` | 自然滚动，当前时间高亮 |
| 响应式 | CSS media queries | 桌面全宽 → 移动端适配 |

### 后续设计文档需深化

1. **HTML 模板具体样式**：配色、字体、卡片阴影、动画过渡——需适配微信内置浏览器（WebView 限制）
2. **inject.py 脚本**：JSON 读取 → 占位符替换 → 输出文件，约 20 行
3. **server.js 脚本**：零依赖 HTTP 服务器，支持 `/` 和 `/health` 路由，约 20 行
4. **trip_data.json Schema**：完整的 JSON Schema 定义，确保研究阶段输出一致性
5. **高德静态图参数**：起终点坐标、缩放级别、标记样式、图片尺寸
6. **移动端 + 微信适配**：
   - 微信内置浏览器 CSS 兼容性（`-webkit-` 前缀、flexbox 降级）
   - 响应式断点：桌面全宽 → 微信竖屏窄列
   - 高德导航链接在微信中的行为（微信拦截 `uri.amap.com` 需要处理）
7. **hermes 集成**：skill 通过 hermes 运行时，如何管理 server/tunnel 进程生命周期
8. **tunnel 子域名策略**：每次生成新的随机子域名 vs 固定子域名覆盖更新
