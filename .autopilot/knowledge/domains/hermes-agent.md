<!-- tags: hermes-agent, installation, macos, arm64, identity, configuration -->

## Hermes Agent 安装与配置

**决策日期**: 2026-05-02

**场景**: 在 macOS ARM64 (Apple Silicon) 上安装 Hermes Agent (NousResearch)

**关键发现**:

1. **Agent 命名机制**: Hermes Agent 的身份通过 `~/.hermes/SOUL.md` 控制（不是 config.yaml 的 agent_name 字段）。SOUL.md 占据 system prompt 第 1 槽位。

2. **安装路径**: 推荐用 `setup-hermes.sh` 而非 `curl | bash`，因为后者可能卡在 SSH clone。如果已手动 git clone 仓库，直接 cd 到仓库目录运行 `bash setup-hermes.sh`。

3. **文件位置**: 
   - `.env`: 项目根目录（加载时优先从项目目录读取）
   - `config.yaml`: `~/.hermes/config.yaml`（从 HERMES_HOME 读取）
   - `SOUL.md`: `~/.hermes/SOUL.md`
   - CLI 符号链接: `~/.local/bin/hermes` → 项目目录/hermes

4. **终端后端**: 无 Docker 时使用 `local` 后端，需配合 `approvals.mode: manual` 保障安全。

5. **API Provider**: 推荐 OpenRouter（支持 200+ 模型，配置最简单），需 `OPENROUTER_API_KEY`。
