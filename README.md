# martin — Claude Code 技能工作台

基于 Claude Code 的智能技能（Skills）工作台，通过多源数据采集、交叉验证和自动化流水线，将复杂任务转化为一键式体验。

## 技能列表

### 1. travel-planner — 多源周边游攻略生成器

从一句话需求到可分享的交互式 HTML 攻略页，全自动完成。

**触发方式**：提及"周边游"、"周末去哪"、"一日游"、"短途旅行"、"攻略"、"出去玩"等关键词自动激活。

**核心能力**：

| 能力 | 说明 |
|------|------|
| 🧠 用户偏好记忆 | 自动读取出行偏好、去过目的地，避免重复推荐 |
| 🌤 实时天气+路况 | 高德 API 获取天气预报、驾车路线、POI 评分 |
| 🔍 六路并行搜索 | 大众点评 + 小红书 + B站 + 微信公众号 + WebSearch + Vision API |
| ✅ 交叉验证聚合 | 多源数据交叉对比，高/中/低三档置信度标注 |
| 🎨 交互式 HTML | 自适应移动端设计，支持一键高德导航 |
| 🌐 公网发布 | tunnel 暴露公网 URL，可直接微信分享 |
| 🛡 质量校验 | `lint.py` 自动检查 JSON 完整性，防止 undefined 和缺失按钮 |

**工作流**：

```
用户偏好记忆 → 高德天气+路线 → 多源并行搜索(6路)
    → 交叉验证聚合 → trip_data.json
    → inject.py 生成 HTML → server.js 启动
    → tunnel 暴露公网 → 返回给用户
```

**文件结构**：

```
skills/travel-planner/
├── SKILL.md                  # 技能定义（完整工作流 + 降级策略）
├── scripts/
│   ├── inject.py             # JSON → HTML 注入脚本
│   ├── lint.py               # trip_data.json 质量校验（7 项铁律检查）
│   └── server.js             # 本地 HTTP 静态服务器
├── assets/
│   └── template.html         # 响应式 HTML 模板
├── references/
│   ├── amap-api.md           # 高德 API 调用指南
│   ├── search-guide.md       # 搜索策略指南
│   ├── bilibili-analysis.md  # B站数据分析方法
│   ├── cross-verify-rules.md # 交叉验证规则
│   ├── opencli-guide.md      # opencli 工具使用指南
│   ├── trip-data-schema.md   # 输出 JSON Schema
│   └── vision-api.md         # 本地 Qwen 视觉识别指南
├── evals/
│   └── evals.json            # 评估用例
└── output/
    ├── trip_data.json        # 结构化行程数据
    └── trip.html             # 生成的交互式攻略页
```

**已产出攻略**：

- `嘉兴西塘美食探店报告.md` — 嘉兴西塘一日自驾游攻略（含多档预算）

**降级策略**：

| 故障 | 降级方案 |
|------|----------|
| 高德 QPS 限流 | 关键端点优先：天气 > 路线 > POI 评分 |
| opencli 命令失败 | 退回到 WebSearch 搜索 |
| tunnel 不可用 | 直接 `open output/trip.html` 本地查看 |
| Vision API 超时 | 跳过图片识别 |

### 2. whisper 语音转写

高性能本地语音识别，利用 M4 Max Metal GPU / ANE 加速。

| 参数 | 可选值 | 默认值 | 说明 |
|------|--------|--------|------|
| `--engine` | mlx / faster / whisper | mlx | 推理引擎（Metal GPU 加速优先） |
| `--model` | tiny / base / small / medium / large-v3 / large-v3-turbo | tiny | 模型尺寸 |
| `--language` | zh / en / auto | zh | 识别语言 |
| `--output-format` | txt / srt / vtt / json | txt | 输出格式 |

```bash
source .venv/bin/activate
python scripts/transcribe.py audio.m4a --model large-v3-turbo --output-format srt
```

---

## 项目结构

```
martin/
├── README.md                 # 本文件
├── CLAUDE.md                 # Claude Code 项目指令
├── skills/                   # 技能定义
│   └── travel-planner/       # 周边游攻略生成器
├── scripts/                  # 独立工具脚本
│   └── transcribe.py         # whisper 语音转写
└── .venv/                    # Python 3.12 虚拟环境
```

## 环境依赖

- **AI Agent**: Hermes Agent v0.12.0（`~/.hermes/`）
- **本地推理**: llama.cpp + Qwen3.6-35B-A3B（端口 8001）
- **中文搜索**: opencli（大众点评、小红书、B站、微信公众号）
- **地图服务**: 高德 API
- **Python**: 3.12（`.venv` 虚拟环境）
- **语音识别**: mlx-whisper（Metal GPU 加速）

## 协作

所有技能遵循 Claude Code Skill 规范（`SKILL.md` frontmatter + Markdown body），可被 Claude Code 自动发现和触发。技能的核心约束：

- **输出质量铁律**：每个 skill 有明确的校验规则（如 `lint.py`），写入后必须自检
- **降级策略**：每个 skill 定义故障降级方案，保证可用性
- **多源验证**：数据须经交叉验证，标注置信度，不做信息搬运工
