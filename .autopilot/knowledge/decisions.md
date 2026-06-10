# 设计决策记录

<!-- tags: python, macos, environment -->

## 2026-05-03 — whisper 语音识别环境在 Apple Silicon 上的最优方案

**决策**：选择 mlx-whisper 作为主引擎（Apple MLX 框架，Metal GPU/ANE 加速），faster-whisper 作为备选（CTranslate2 CPU 优化），openai-whisper 仅作兼容层。

**原因**：
- M4 Max 128GB + Metal 4 环境下，mlx-whisper 利用 ANE + GPU 联合加速，tiny 模型推理 < 1.5s
- MLX 是 Apple 官方框架，无需额外配置即可使用 Metal GPU
- whisper.cpp 虽然更快但需要编译步骤，CI/CD 不便
- openai-whisper 依赖 PyTorch（~2GB），仅保留作为 API 兼容

**前提**：brew 安装的 Python 3.12 受 PEP 668 保护，必须先 `python3 -m venv .venv` 创建虚拟环境。

**模型选择**：tiny（~75MB）快速测试 / base（~150MB）日常转写 / large-v3（~3GB）高精度

## 2026-06-11 — 本地 LLM API 封装为 CLI 工具的技术选型

<!-- tags: cli, typescript, llm, qwen -->

**背景**：本地 llama.cpp llama-server 提供 OpenAI 兼容 API（`/v1/chat/completions`），但直接 curl 调用有多个痛点（JSON 转义、base64 OS 差异、参数记忆）。需要封装为 CLI 工具方便 Claude Code 等 Agent 调用。

**选择**：TypeScript + commander + tsup，独立 `qwen` 命令（非 opencli external）。

**拒绝的替代方案**：
- Shell 脚本：JSON 处理脆弱，base64 命令跨平台差异大
- opencli internal adapter：框架设计为浏览器自动化，API 包装过度依赖
- opencli external register：增加一层间接调用，不如独立命令直接

**权衡**：TypeScript 工程需要编译步骤（tsup），但换来类型安全、跨平台一致的 base64 编码、commander 自动生成 `--help`。
