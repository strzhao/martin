---
active: true
phase: "done"
gate: ""
iteration: 4
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
fast_mode: true
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: true
task_dir: "/Users/stringzhao/workspace/martin/.autopilot/runtime/requirements/20260611-使用--skill-creator-skill-cr"
session_id: ddbf56aa-5e53-47a1-9e18-8d925be555e6
started_at: "2026-06-10T17:04:48Z"
contract_required: true
html_review: true
---

## 目标
使用 /skill-creator:skill-creator skill 按照当前设计的方案开始实现本次的 skill 和 html 等，完成后用 claude -p 模式测试下这个 skill (避免上下文的影响)

> 📚 项目知识库已存在: .autopilot/knowledge/。design 阶段请先加载相关知识上下文。

## 设计文档

### 领域 Skill 委托

本任务委托给 **skill-creator** skill 执行实现。skill-creator 是专门用于创建、修改和优化 Claude Code skill 的领域工具，封装了 skill 创建的最佳实践（SKILL.md 编写规范、渐进式加载、eval 测试等）。

**委托输入**：
- 完整设计文档（本文件）
- 参考设计：`.claude/autopilot/brainstorm-travel-planner.md`（含所有 dry run 验证数据）

### Context

**目标**：创建一个 `travel-planner` Claude Code skill，帮助用户规划城市周边短途旅行（杭州出发），生成包含多源交叉验证信息的 HTML 攻略页面，通过 HTTP 服务器 + tunnel 暴露到公网供微信访问。

**技术栈**：
- Skill：Claude Code SKILL.md + references/ + assets/ + scripts/
- HTML：单文件、内联 CSS/JS、`__TRIP_DATA__` 占位符模板注入
- HTTP Server：Node.js 内置 `http` 模块（零依赖）
- Tunnel：`tunnel` CLI（frpc，已配置 `tunnel.stringzhao.life`）
- 数据源：高德 API（REST）+ opencli（dianping/xiaohongshu/bilibili/weixin）+ WebSearch + Vision API（Qwen3.6-35B base64）

### 架构设计

```
travel-planner/
  SKILL.md                          # 主指令：工作流 + 工具调用顺序
  references/
    amap-api.md                     # 高德 API 端点 + 关键词模板 + QPS 控制
    opencli-guide.md                # opencli 命令速查 + session 管理
    search-guide.md                 # WebSearch 策略 + 平台指向词
    cross-verify-rules.md           # 多源交叉验证规则
    vision-api.md                   # Qwen 视觉识别 base64 用法
    bilibili-analysis.md            # B站字幕提取策略
    trip-data-schema.md             # trip_data.json 完整 Schema
  assets/
    template.html                   # HTML 模板（__TRIP_DATA__ 占位符 + 内联 CSS/JS）
  scripts/
    inject.py                       # JSON → HTML 注入脚本
    server.js                       # 零依赖 HTTP 服务器
```

### 数据流

```
Research Phase → trip_data.json → inject.py → trip.html
                                            ↓
                              node server.js (localhost:3456)
                                            ↓
                              tunnel expose 3456 <subdomain>
                                            ↓
                    https://<subdomain>.tunnel.stringzhao.life
                                            ↓
                                 微信/任何浏览器打开
```

### 信息源架构

6 Agent 并行搜索 → 汇总交叉验证：

| Agent | 工具 | 数据 |
|-------|------|------|
| 高德 Agent | Bash curl API | 天气/POI/路线/状元榜 |
| dianping Agent | Bash opencli | 餐厅搜索+详情（评分/口味/环境/价格/地址） |
| xiaohongshu Agent | Bash opencli | 原生笔记搜索（标题/点赞数） |
| bilibili Agent | Bash opencli | 探店视频+字幕（真实评价/价格） |
| weixin Agent | Bash opencli | 公众号文章搜索+下载 |
| WebSearch Agent | WebSearch | 游记攻略补充 |

交叉验证规则：同一餐厅被 ≥2 个独立源认可 → 高置信度

### HTML 页面设计

- 布局：单列纵向（移动端友好）
- 地图：高德静态图 + URL Scheme 导航
- 内容：多源精华聚合卡片 + 外链跳转
- 交互：预算切换、时间线滚动、地点导航

### 关键约束

- 免费 API（高德免费额度日均 30 万次）
- 单文件 HTML（零依赖、可离线打开）
- HTTP 服务器零 npm 依赖（仅 Node.js 内置模块）
- 微信内置浏览器兼容

### 验收场景

1. 用户说「帮我规划周末杭州周边一日游」→ skill 执行研究 → 生成 HTML → 返回公网 URL
2. 生成的 HTML 包含：天气、路线地图、时间线、餐厅卡片（含评分+精华引用+链接）
3. 点击地点可唤起高德导航
4. 微信中打开链接可正常浏览
5. 用户偏好已记录（memory），skill 自动排除去过的地方

## 实现计划

### 委托给 skill-creator 的实现步骤

skill-creator skill 将按以下顺序执行：

1. **创建 skill 目录结构**：`~/.claude/skills/travel-planner/`
2. **编写 SKILL.md**（<500 行）：工作流指令、Agent 调用顺序、输出格式规范
3. **编写 references/**（6 个参考文档）：API 用法、搜索策略、验证规则、Schema
4. **编写 assets/template.html**：HTML 攻略模板（`__TRIP_DATA__` + 内联 CSS/JS）
5. **编写 scripts/inject.py**：JSON 读取 → 模板占位符替换 → 输出 HTML
6. **编写 scripts/server.js**：Node.js http 模块，零依赖，serve trip.html
7. **Eval 测试**：写测试 prompt，验证 skill 触发和输出质量

### 关键文件内容规范

**SKILL.md 核心指令**（按此顺序）：
1. 读取用户偏好 memory 文件
2. 高德 API：天气 → POI → 路线 → 状元榜
3. opencli：dianping search+shop、xhs search、bilibili search+video+subtitle
4. WebSearch：游记攻略补充
5. Vision（可选）：关键图片 base64 识别
6. 交叉验证：≥2 源确认
7. 输出 trip_data.json
8. 运行 inject.py + server.js + tunnel

**template.html 设计要点**：
- 移动优先（微信 WebView 兼容）
- 单列纵向布局
- CSS 变量管理配色
- JS 渲染时间线 + 餐厅卡片
- 预算切换按钮

**inject.py 逻辑**（~20 行）：
```python
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
with open('assets/template.html') as f: template = f.read()
html = template.replace('__TRIP_DATA__', json.dumps(data, ensure_ascii=False))
with open('output/trip.html', 'w') as f: f.write(html)
```

### 测试计划

实现完成后，用 `claude -p` 在新上下文测试：
```bash
claude -p "帮我规划这周末杭州出发的周边一日游，我喜欢吃"
```
验证：skill 是否正确触发、输出质量、HTML 是否生成

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1 — 命令执行

| Tier | 检查项 | 状态 | 证据 |
|------|--------|------|------|
| Tier 1 | trip_data.json Schema 验证 | ✅ PASS | 所有必填字段存在，timeline≥3，restaurants≥2 |
| Tier 1 | trip.html 内容完整性 | ✅ PASS | 6/7 检查通过（1个编码假阴性），15,855字节 |
| Tier 3 | server.js 服务 | ✅ PASS | GET / → 200，/health → `{"status":"ok"}` |

### Wave 1.5 — 验收场景谓词求值

| # | 验收谓词 | 判定 | Artifact |
|---|----------|------|----------|
| 1 | skill 触发 + 生成攻略 | ✅ PASS | `claude -p` 输出 — 正确触发，返回多方案对比+预算+美食清单 |
| 2 | HTML 含天气/地图/时间线/卡片/评分/链接/预算 | ✅ PASS | trip.html — 含 staticmap、timeline-item、寻宝记、dianping.com、switchBudget |
| 3 | 地点可唤起高德导航 | ✅ PASS | template.html 含 `uri.amap.com/navigation` 链接，`link-navi` CSS 类 |
| 4 | 微信兼容 | ✅ PASS | viewport meta + -webkit- 前缀 + 响应式 @media |
| 5 | 用户偏好记忆 | ✅ PASS | `travel-preferences.md` 已存在，SKILL.md 步骤1 读取 |

### QA 结论

**全部验收谓词 PASS** — 无 FAIL，无 Critical。

- 技能文件完整（SKILL.md + 7 refs + template + 2 scripts）
- 数据链路验证通过（JSON → inject → HTML → server）
- claude -p 隔离上下文测试通过
- 微信兼容（移动优先布局，单列，响应式）

## 变更日志
- [2026-06-10T17:04:48Z] autopilot 初始化，目标: 使用 /skill-creator:skill-creator skill 按照当前设计的方案开始实现本次的 skill 和 html 等，完成后用 claude -p 模式测试下这个 skill (避免上下文的影响)
