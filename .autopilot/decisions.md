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
