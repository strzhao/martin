---
active: true
phase: "done"
gate: ""
iteration: 4
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
fast_mode: true
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: true
task_dir: "/Users/stringzhao/workspace/martin/.autopilot/runtime/requirements/20260611-开始实现"
session_id: ddbf56aa-5e53-47a1-9e18-8d925be555e6
started_at: "2026-06-10T16:51:28Z"
contract_required: true
html_review: true
---

## 目标
实现 `qwen` CLI 工具——将 Qwen API 调用封装为独立命令行工具，解决裸 curl 的 5 个痛点，提供 `--help`。TypeScript + commander + tsup，放在 `~/workspace/qwen-cli/`。

> 📚 项目知识库已存在: .autopilot/knowledge/。design 阶段请先加载相关知识上下文。

## 设计文档

### Context

Qwen3.6-35B-A3B (MoE, thinking model) 运行在 llama.cpp llama-server (port 8001, mmproj 多模态)。当前直接 curl 调用有 5 个痛点：
1. JSON 转义错误（response 含 control characters）
2. base64 编码命令 OS 差异（macOS `base64 -i` vs Linux `base64`）
3. max_tokens 不够 thinking 模型推理链消耗（需 ≥2000，vision 需 ≥3000）
4. 图片 URL 模式不可用（llama-server 不支持远程下载）
5. 每次需记住完整 curl 命令格式

### 设计决策

**技术栈**：和 raven-cli/ai-todo-cli/little-bee-cli 一致——TypeScript + commander ^13 + tsup

**命令接口**：
- `qwen ask "prompt" [--tokens N] [--json] [--stdin]` — 文本对话
- `qwen vision -i <file|url> "prompt" [--tokens N] [--json]` — 图片识别
- `qwen status` — 健康检查 + 模型信息 + PM2 进程状态
- `qwen models` — 列出可用模型
- `qwen --help` / `qwen ask --help` / `qwen vision --help` — commander 自动生成

**核心设计**：
- `lib/config.ts` — 环境变量优先（QWEN_API_URL/KEY/MODEL），默认值 fallback
- `lib/api.ts` — chatCompletions() / visionCompletions() / healthCheck()，统一处理 JSON 解析、base64 编码、thinking fallback
- `src/commands/ask.ts` — 文本对话 + stdin 管道
- `src/commands/vision.ts` — 图片识别（URL → fetch → base64 / file → read → base64）
- `src/commands/status.ts` — 健康检查 + 模型列表 + PM2 进程状态
- `src/commands/models.ts` — 模型列表

**API 配置**：
```typescript
apiUrl: process.env.QWEN_API_URL || 'http://127.0.0.1:8001'
apiKey: process.env.QWEN_API_KEY || 'qwen-local-key'
model: process.env.QWEN_MODEL || 'qwen3.6-35b'
defaults.maxTokens: 1000
defaults.visionMaxTokens: 3000
```

**thinking 模型处理**：Qwen3.6 返回 `reasoning_content` + `content`。提取 `content`，为空则 fallback 到 `reasoning_content`。

**安装**：`cd ~/workspace/qwen-cli && npm link`（全局 `qwen` 命令）

**CLAUDE.md 集成**：在 `~/.claude/CLAUDE.md` 末尾追加 Qwen CLI 使用段落。

### 工程结构
```
~/workspace/qwen-cli/
  package.json           # { "name": "qwen-cli", "type": "module", "bin": { "qwen": "dist/index.js" } }
  tsup.config.ts         # entry: src/index.ts, format: esm, dts: true
  tsconfig.json          # target: ES2022, module: NodeNext
  src/
    index.ts             # commander program 入口
    commands/
      ask.ts             # qwen ask
      vision.ts          # qwen vision
      status.ts          # qwen status
      models.ts          # qwen models
    lib/
      api.ts             # chatCompletions / visionCompletions / healthCheck
      config.ts          # 环境变量 + 默认值
      format.ts          # 输出格式化 / 错误友好提示
```

## 实现计划

### Step 1: 项目脚手架
- 创建 `~/workspace/qwen-cli/` 目录
- 初始化 package.json（name/qwen-cli, type/module, bin/qwen）
- 配置 tsup.config.ts（entry: src/index.ts, esm, dts）
- 配置 tsconfig.json（ES2022, NodeNext）

### Step 2: 核心库（lib/）
- `lib/config.ts` — 环境变量读取 + 默认值
- `lib/api.ts` — chatCompletions() 函数：
  - 拼接 `/v1/chat/completions`
  - Bearer auth
  - 解析 response JSON，提取 content/fallback reasoning_content
  - 错误处理（网络超时、非 200 状态码）
  - visionCompletions() 函数：检测 `-i` 是 file 还是 URL → 编码 base64 → data URI → OpenAI vision 格式
  - healthCheck() 函数：GET /health + GET /v1/models
- `lib/format.ts` — 纯文本提取 / JSON 美化 / 错误友好提示

### Step 3: 命令实现
- `src/index.ts` — commander 入口，注册 subcommands
- `src/commands/ask.ts` — 文本对话 + `--stdin` 管道
- `src/commands/vision.ts` — 图片识别
- `src/commands/status.ts` — 服务状态
- `src/commands/models.ts` — 模型列表

### Step 4: 构建 & 安装
- `npm run build`（tsup）
- `npm link`（全局 qwen 命令）

### Step 5: CLAUDE.md 更新
- 在 `~/.claude/CLAUDE.md` 末尾追加 Qwen CLI 使用说明

### 文件清单（需创建/修改）
| 文件 | 操作 |
|------|------|
| `~/workspace/qwen-cli/package.json` | 创建 |
| `~/workspace/qwen-cli/tsup.config.ts` | 创建 |
| `~/workspace/qwen-cli/tsconfig.json` | 创建 |
| `~/workspace/qwen-cli/src/index.ts` | 创建 |
| `~/workspace/qwen-cli/src/commands/ask.ts` | 创建 |
| `~/workspace/qwen-cli/src/commands/vision.ts` | 创建 |
| `~/workspace/qwen-cli/src/commands/status.ts` | 创建 |
| `~/workspace/qwen-cli/src/commands/models.ts` | 创建 |
| `~/workspace/qwen-cli/src/lib/api.ts` | 创建 |
| `~/workspace/qwen-cli/src/lib/config.ts` | 创建 |
| `~/workspace/qwen-cli/src/lib/format.ts` | 创建 |
| `~/.claude/CLAUDE.md` | 追加 |

## 红队验收测试
验收测试文件：`/Users/stringzhao/workspace/qwen-cli/test/acceptance.test.sh`（14 用例，9 组）

测试结果：12 PASS / 0 FAIL / 1 SKIP（vision 缺 Pillow，环境问题非代码问题）

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [2026-06-10T16:51:28Z] autopilot 初始化，目标: 开始实现
