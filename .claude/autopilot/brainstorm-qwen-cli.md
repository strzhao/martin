## 探索的目的与约束

**目标**：将 Qwen API（llama.cpp llama-server）的调用封装为独立 `qwen` CLI 工具，解决当前裸 curl 调用的 5 个痛点，提供 `--help` 命令，并在全局 CLAUDE.md 中添加使用说明。

**项目上下文**：
- Qwen 推理服务：llama.cpp llama-server，端口 8001，API key `qwen-local-key`
- 模型：Qwen3.6-35B-A3B（MoE，thinking 模型）+ mmproj-F16.gguf（多模态）
- 当前调用痛点：JSON 转义错误、base64 命令 OS 差异、max_tokens 不够 thinking 模型吃、图片 URL 模式不可用、每次需记完整 curl 命令
- 已有 CLI 工程模式：TypeScript + commander + tsup（raven-cli、ai-todo-cli、little-bee-cli）
- 已有 opencli v1.7.22，但用户选择独立命令而非 opencli external register

**明确约束**：
1. 独立 `qwen` 命令（非 opencli 子命令）
2. 放在 `~/workspace/` 下维护（`~/workspace/qwen-cli/`）
3. TypeScript + commander + tsup，和已有 CLI 保持一致
4. commander 自动生成 `--help`（零成本）

## 候选方案与权衡

本任务需求明确，无需多方案对比。直接选定方案：**TypeScript 独立 CLI**。

## 选择与理由

**选定方案**：TypeScript 独立 CLI（`~/workspace/qwen-cli/`）

**选择理由**：
1. 用户明确选择独立 `qwen` 命令，不走 opencli external register
2. 和 raven-cli/ai-todo-cli/little-bee-cli 技术栈一致，降低维护成本
3. commander 的 `--help` 零成本自动生成
4. TypeScript 类型安全，JSON 处理健壮，base64 编码跨平台兼容

## 设计概要

### CLI 命令结构

```
qwen ask "prompt"              文本对话 → 返回纯文本
      [--tokens N]             最大 token 数（默认 1000，vision 默认 3000）
      [--json]                 输出原始 JSON
      [--stdin]                从 stdin 读取 prompt

qwen vision -i <file|url> "prompt"   图片识别
      [--tokens N]             默认 3000（thinking 模型需要推理链空间）
      [--json]

qwen status                   服务健康检查 + 模型信息 + 进程状态

qwen models                   列出可用模型

qwen --help                   帮助信息
qwen ask --help               ask 子命令帮助
qwen vision --help            vision 子命令帮助
```

### 核心痛点解决

| 痛点 | 解决方案 |
|------|----------|
| JSON 转义错误 | `api.ts` 统一处理：`JSON.parse()` + 错误恢复，输出前验证 |
| base64 命令 OS 差异 | Node.js `fs.readFileSync` + `Buffer.toString('base64')`，跨平台一致 |
| max_tokens 不够 | `ask` 默认 1000，`vision` 默认 3000（thinking 模型需推理链空间） |
| 图片 URL 模式不可用 | 自动检测：URL → `fetch` 下载 → base64 编码 → data URI 传参 |
| 记不住 curl 命令 | `qwen ask "..."` 一行搞定，自动拼接 API URL / Key / Model |

### 工程结构

```
~/workspace/qwen-cli/
  package.json              # { "name": "qwen-cli", "bin": { "qwen": "dist/index.js" } }
  tsup.config.ts            # 编译配置
  tsconfig.json
  src/
    index.ts                # 入口：commander program 定义 + 全局选项
    commands/
      ask.ts                # qwen ask — 文本对话
      vision.ts             # qwen vision — 图片识别
      status.ts             # qwen status — 服务健康检查
      models.ts             # qwen models — 模型列表
    lib/
      api.ts                # 核心：chatCompletions() / visionCompletions() / healthCheck()
      config.ts             # 配置：API_URL / API_KEY / DEFAULT_MODEL / 默认参数
      format.ts             # 输出格式化：纯文本提取 / JSON 美化 / 错误友好提示
```

### API 配置（config.ts）

```typescript
export const config = {
  apiUrl: process.env.QWEN_API_URL || 'http://127.0.0.1:8001',
  apiKey: process.env.QWEN_API_KEY || 'qwen-local-key',
  model: process.env.QWEN_MODEL || 'qwen3.6-35b',
  defaults: {
    maxTokens: 1000,
    visionMaxTokens: 3000,
    temperature: 0.7,
    timeout: 120000,  // vision 可能需要 2 分钟
  },
};
```

### 关键实现细节

**chatCompletions()**：
- 拼接 `/v1/chat/completions` 端点
- `Authorization: Bearer <apiKey>`
- 自动处理 thinking 模型响应：提取 `content` 字段，若为空则 fallback 到 `reasoning_content`
- `--json` 模式输出完整响应

**visionCompletions()**：
- 检测 `-i` 参数是文件路径还是 URL
- URL → `fetch` 下载至临时 buffer → base64 编码
- 文件 → `fs.readFileSync` → base64 编码
- 构造 `data:image/<mime>;base64,<data>` data URI
- 组装 OpenAI vision 格式的 messages
- 自动设置 max_tokens=3000

**status()**：
- `GET /health` → 健康检查
- `GET /v1/models` → 模型列表
- 额外检查：PM2 进程状态（`pm2 status` 解析）

### CLAUDE.md 集成

在 `~/.claude/CLAUDE.md`（全局）中新增：

```markdown
## Qwen 本地推理

本地 llama.cpp llama-server（端口 8001），Qwen3.6-35B-A3B + 多模态，通过 `qwen` CLI 调用。

```bash
qwen ask "你的问题"              # 文本对话
qwen vision -i img.jpg "描述"    # 图片识别（URL 或本地文件均可）
qwen status                      # 服务状态
qwen models                      # 模型列表
```

所有命令均支持 `--help` 查看详细参数。
```

## 待主 SKILL 接力的设计决策

### 用户已确认的决策

| 决策项 | 选择 |
|--------|------|
| CLI 名称 | `qwen`（独立命令） |
| 调用方式 | `qwen ask` / `qwen vision` / `qwen status` / `qwen models` |
| 实现方式 | TypeScript + commander + tsup |
| 工程位置 | `~/workspace/qwen-cli/` |
| Help 命令 | commander 自动生成 `--help`（零成本） |
| CLAUDE.md | 全局 `~/.claude/CLAUDE.md` 新增 Qwen 使用说明段落 |
| 安装方式 | `npm link` 或 `npm install -g .`（从本地目录） |

### 需要在实现中深化的点

1. **thinking 模型响应处理**：Qwen3.6-35B-A3B 返回 `reasoning_content` + `content`，当 `content` 为空时如何 fallback
2. **错误处理**：服务不可用时的友好提示；超时重试策略；API 返回非 200 时的错误信息提取
3. **stdin 管道支持**：`echo "..." | qwen ask --stdin` 的实现（检测 stdin 是否有数据）
4. **安装方式**：`npm link` 后 `qwen` 命令全局可用，还是直接用 `tsx` 开发模式
5. **配置文件**：环境变量 vs 本地 config 文件（`~/.qwen-cli.json`），环境变量优先
6. **CLAUDE.md 更新**：在 `~/.claude/CLAUDE.md` 中找到合适的插入位置，不覆盖已有内容
