# martin — Hermes Agent 操作目录

通过 Claude Code 管理和操作 Hermes Agent 的工作目录。

## Hermes Agent 环境

- **版本**: v0.12.0
- **安装路径**: `/Users/stringzhao/workspace/hermes-agent/`
- **CLI 路径**: `/Users/stringzhao/.local/bin/hermes`
- **用户数据目录**: `~/.hermes/`（config.yaml、sessions、skills、memories、cron、logs 等）
- **当前模型**: `deepseek-v4-pro`（DeepSeek provider，`https://api.deepseek.com/anthropic`）
- **终端后端**: local（命令直接在宿主机执行）
- **当前工具集**: hermes-cli

## 常用命令速查

### 交互式聊天

```bash
hermes                    # 进入交互式 CLI 聊天
hermes chat               # 同上
hermes --tui              # TUI 模式（Node/React 前端）
hermes -z "描述你的需求"    # 单次非交互式任务
hermes -m "模型名"         # 指定模型
hermes -t "工具集名"       # 指定工具集
hermes --resume SESSION   # 恢复指定会话
hermes --continue         # 继续最近会话
hermes --accept-hooks     # 自动批准高危操作（慎用）
hermes --yolo             # 跳过所有确认（慎用）
```

### 配置管理

```bash
hermes config             # 查看完整配置
hermes config get <key>   # 读取指定配置项
hermes config set <key> <value>  # 修改配置项
hermes model              # 切换默认模型/提供商
hermes tools              # 配置启用的工具
hermes setup              # 重新运行设置向导
```

### 会话管理

```bash
hermes sessions list      # 列出历史会话
hermes sessions browse    # 交互式会话浏览器（支持 FTS5 搜索）
hermes sessions export <id>  # 导出会话
hermes sessions delete <id>   # 删除会话
hermes logs               # 浏览日志
```

### 网关（多平台消息）

```bash
hermes gateway            # 前台运行消息网关
hermes gateway start      # 后台启动网关服务
hermes gateway stop       # 停止网关
hermes gateway status     # 网关状态
hermes gateway install    # 安装为系统服务（launchd）
```

### Cron 定时任务

```bash
hermes cron               # 进入 cron 管理交互界面
hermes cron list          # 列出所有 cron 任务
hermes cron status        # 查看定时任务状态
```

### 高级功能

```bash
hermes acp                # 以 ACP 服务器模式运行（供 VS Code/Zed/JetBrains 集成）
hermes mcp serve          # 以 MCP 服务器模式运行（供 Claude Desktop 等客户端调用）
hermes dashboard          # 启动 Web 仪表盘
hermes doctor             # 诊断配置和依赖
hermes skills             # 搜索、安装、管理技能
hermes plugins            # 管理插件
hermes profile            # 多实例配置管理
hermes update             # 更新到最新版本
hermes version            # 显示版本
```

### 终端后端切换

```bash
hermes config set terminal.backend local      # 本地执行（默认）
hermes config set terminal.backend docker     # Docker 容器隔离执行
hermes config set terminal.backend ssh        # SSH 远程执行
hermes config set terminal.backend modal      # Modal 云执行
# 需要相应的环境变量和配置
```

## 架构概览

```
用户输入 → hermes CLI (cli.py / hermes_cli/main.py)
         → AIAgent (run_agent.py) → 会话循环
              ├── prompt_builder.py → 组装 system prompt
              ├── model_tools.py → 工具发现/调用
              │    ├── tools/registry.py → 工具注册中心
              │    └── tools/*.py → 40+ 内置工具
              ├── tools/environments/ → 终端后端 (local/docker/ssh/modal)
              ├── agent/memory_manager.py → 记忆管理
              ├── agent/context_compressor.py → 上下文压缩
              └── agent/skill_commands.py → 技能系统
         → hermes_state.py → SQLite + FTS5 持久化会话
```

## 关键文件位置

| 文件 | 说明 |
|------|------|
| `~/.hermes/config.yaml` | 主配置文件 |
| `~/.hermes/.env` | API 密钥等敏感信息 |
| `~/.hermes/sessions/` | SQLite 会话存储（含 FTS5 全文索引） |
| `~/.hermes/skills/` | 技能目录 |
| `~/.hermes/memories/` | 记忆存储 |
| `~/.hermes/cron/` | Cron 任务定义 |
| `~/.hermes/logs/` | 日志文件 |
| `~/.hermes/SOUL.md` | Agent 人格/自定义指令 |
| `~/.hermes/skins/` | 皮肤/主题（YAML） |

## Claude Code 操作模式

当前目录下，Claude Code 可以：

1. **执行 hermes 命令**：直接通过 Bash 工具运行 `hermes` 相关命令
2. **管理配置**：读写 `~/.hermes/config.yaml` 和 `~/.hermes/.env`
3. **查看状态**：`hermes status`、`hermes doctor`、`hermes logs`
4. **操作会话**：`hermes sessions list/browse/export`
5. **管理 cron 任务**：`hermes cron list/status`
6. **管理网关**：`hermes gateway start/stop/status`
7. **更新 agent**：`hermes update`

### 常用操作示例

```bash
# 快速任务：让 hermes 完成一次性工作
hermes -z "帮我检查当前目录的 git 状态并汇报"

# 指定模型执行
hermes -m "anthropic/claude-opus-4-6" -z "复杂的代码审查任务"

# 恢复之前的会话继续工作
hermes --resume <session_id>

# 查看最近的会话
hermes sessions list | head -20

# 诊断问题
hermes doctor
```

## whisper 语音转写

本机已部署高性能 whisper 语音识别环境，利用 M4 Max 的 Metal GPU / ANE 加速。

### 基本用法

```bash
# 激活虚拟环境
source /Users/stringzhao/workspace/martin/.venv/bin/activate

# 基本转写（默认 mlx 引擎 + tiny 模型 + 中文 + txt 输出）
python scripts/transcribe.py audio.m4a

# 高精度转写（large-v3 模型，推荐用于重要内容）
python scripts/transcribe.py audio.m4a --model large-v3

# 速度优先（large-v3-turbo，精度接近 large-v3 但更快）
python scripts/transcribe.py audio.m4a --model large-v3-turbo
```

### 参数速查

| 参数 | 可选值 | 默认值 | 说明 |
|------|--------|--------|------|
| `audio` | 文件路径 | - | 输入音频（支持 wav/m4a/mp3 等） |
| `--engine` | mlx / faster / whisper | mlx | 推理引擎 |
| `--model` | tiny / base / small / medium / large-v3 / large-v3-turbo | tiny | 模型尺寸 |
| `--language` | zh / en / auto | zh | 语言 |
| `--output-format` | txt / srt / vtt / json | txt | 输出格式 |
| `--output-dir` | 目录路径 | . | 输出目录 |

### 模型选择

| 场景 | 模型 | 大小 | 速度 |
|------|------|------|------|
| 快速测试 | tiny | ~75MB | 极快 |
| 日常转写 | base | ~150MB | 快 |
| 高精度 | large-v3 | ~3GB | 中速 |
| 高精度快速 | large-v3-turbo | ~1.5GB | 较快 |

### 输出格式示例

```bash
# SRT 字幕
python scripts/transcribe.py audio.m4a --output-format srt

# JSON（含时间戳，适合程序处理）
python scripts/transcribe.py audio.m4a --output-format json

# 英语转写
python scripts/transcribe.py audio.m4a --language en
```

### 环境说明

- Python 3.12 虚拟环境位于 `.venv/`（brew 强制要求 PEP 668）
- 模型缓存：`~/.cache/huggingface/`
- 引擎优先级：mlx-whisper（Metal GPU 加速）> faster-whisper（备选）> openai-whisper（兼容层）

## 色彩体系（stringzhao-life）

本项目 UI / 状态栏统一采用「苔绿 Sage」色彩体系（来源 [stringzhao.life/colors](https://stringzhao.life/colors)）。完整设计资产沉淀在 [`statusline-sage/COLORS.md`](statusline-sage/COLORS.md)：品牌色、核心色板、辅助色板、色彩关系、CSS Tokens、交互原则。

核心语义色：
- 苔 **Sage** `#3A7D68` — 品牌主色、clean git `⎇`、低用量指标（<60%）
- 苔浅 **Sage Light** `#52A688` — 路径 / 分支名 / 项目名（活跃态）
- 琥 **Amber** `#D4920A` — warning / 中用量（60–85%）/ worktree 标记
- 朱 **Vermillion** `#D94F3D` — destructive / 高用量（≥85%）/ dirty 计数 / **高峰期倍率警示**
- 天 **Sky** `#3B87CC` — info / 模型名
- 烟 **Smoke** `#8F8F8D` — 分隔符 `│`、辅助标签

设计原则：纸/墨铺底、苔绿点睛；三级灰阶（雾/烟/炭）承接信息层级；琥/朱/天对应 warning / destructive / info 语义状态。**朱红仅用于"高代价/警示"语义**——高峰期 token 3 倍消耗即归此列。新增 UI 一律按此取色；换配色改 `statusline-sage.sh` 顶部色彩函数的 RGB 三元组（truecolor 24-bit 实现）。

## 注意事项

- Hermes Agent v0.12.0 使用 OpenAI-compatible API，当前配置为 DeepSeek provider
- 配置文件 `~/.hermes/config.yaml` 格式为 YAML，修改后 `hermes` 会自动加载
- API 密钥等敏感信息存放在 `~/.hermes/.env`，不要提交到版本控制
- 会话数据（SQLite）在 `~/.hermes/sessions/`，支持 FTS5 全文搜索
- 网关支持 Telegram、Discord、Slack、微信、飞书等 15+ 平台
- `--accept-hooks` 和 `--yolo` 会跳过安全确认，仅在信任的环境下使用
