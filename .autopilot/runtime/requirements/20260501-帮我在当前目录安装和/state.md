---
active: true
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "true"
task_dir: "/Users/stringzhao/workspace/martin/.autopilot/requirements/20260501-帮我在当前目录安装和"
session_id: 7ad88d69-00c6-419c-8e94-c6627e3231f3
started_at: "2026-05-01T15:10:58Z"
---

## 目标
帮我在当前目录安装和配置好 hermes agent, 他的名字后续就叫 martin， skill 后续再做

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### Context
用户希望在当前设备（macOS Apple Silicon）上安装和配置 Hermes Agent（NousResearch 开源 AI Agent），命名为 "martin"。当前工作目录几乎是空的，这是一个全新的安装任务。

### 关键约束
- **无 Docker**：只能使用 `local` 终端后端
- **macOS ARM64**：完全支持
- **Agent 命名机制**：Hermes Agent 的身份通过 `~/.hermes/SOUL.md` 控制（不是 config.yaml）

### 设计方案
安装流程：curl 安装脚本 → 自动安装 uv + Python 3.11 → 克隆仓库到 ~/.hermes/hermes-agent → 创建 venv → 符号链接 hermes CLI 到 ~/.local/bin/hermes → 生成默认配置

安装后配置：
1. PATH 修复：确保 `~/.local/bin` 在 `~/.zshrc` 的 PATH 中
2. API Key 配置：写入 `OPENROUTER_API_KEY` 到 `~/.hermes/.env`
3. Agent 命名：编写 `~/.hermes/SOUL.md`，在其中体现名字 "martin"
4. 终端后端保持 local，审批模式保持 manual

## 实现计划

| # | 步骤 | 状态 |
|---|------|------|
| 1 | 安装前预检（磁盘空间、PATH、无冲突） | [x] 783GB可用，无冲突 |
| 2 | 执行安装脚本（使用本地已有 clone + setup-hermes.sh） | [x] 187个依赖已安装 |
| 3 | 确保 PATH 正确 | [x] ~/.local/bin 已在 PATH |
| 4 | 重载 shell 环境 | [x] |
| 5 | 配置 API Key | [⚠] 需用户手动配置 |
| 6 | 编写 martin 个性文件 (SOUL.md) | [x] |
| 7 | 运行诊断 (hermes doctor) | [x] 1个issue：API key未配 |
| 8 | 确认安装成功 | [x] hermes --version → v0.12.0

## 红队验收测试

### 验收场景结果
1. **CLI 安装验证**: `which hermes` → `~/.local/bin/hermes` ✓ | `hermes --version` → `v0.12.0 (2026.4.30)` ✓
2. **配置文件命名验证**: `cat ~/.hermes/SOUL.md` → 包含 "martin" 身份定义 ✓
3. **服务健康检查**: `hermes doctor` → 核心诊断全部通过，仅 API key 未配 ⚠️
4. **目录结构**: `~/.hermes/` 含 config.yaml + SOUL.md + cron/sessions/logs/skills/memories/ ✓
5. **CLI 入口点**: venv/bin/hermes + ~/.local/bin/hermes 符号链接正确 ✓

## QA 报告

### Wave 1 — 命令执行

| Tier | 检查项 | 结果 | 证据 |
|------|--------|------|------|
| 0 | CLI 可用性 | ✅ | `which hermes` → `~/.local/bin/hermes` |
| 0 | 版本输出 | ✅ | `hermes --version` → v0.12.0 (2026.4.30) |
| 0 | SOUL.md 内容 | ✅ | 包含 "martin" 中文个性定义 |
| 0 | 目录结构 | ✅ | config.yaml + SOUL.md + cron/sessions/logs/skills/memories/ |
| 1 | hermes doctor | ✅ | 核心诊断全部通过，仅 1 个 ⚠️（API key 未配） |

### Wave 1.5 — 真实场景验证

**场景 1**: `[独立]` `hermes --version`
- 执行: `export PATH="$HOME/.local/bin:$PATH" && hermes --version`
- 输出: `Hermes Agent v0.12.0 (2026.4.30)` / `Python: 3.11.15` / `OpenAI SDK: 2.32.0`
- 结果: ✅

**场景 2**: `[独立]` `hermes doctor`
- 执行: `hermes doctor`
- 输出: 核心诊断全部 ✓，1 issue（API key 未配置，非阻塞）
- 结果: ✅

**场景 3**: `[独立]` SOUL.md 验证
- 执行: `cat ~/.hermes/SOUL.md`
- 输出: 包含 "# martin" 标题和完整中文个性描述
- 结果: ✅

### Wave 2 — AI 审查

**设计符合性**: 安装结果完全符合设计方案——hermes CLI 可用、SOUL.md 命名为 martin、目录结构完整、hermes doctor 诊断通过。

**代码质量**: 无需审查（无代码变更）。

### 结果判定

- ✅ 安装成功：Hermes Agent v0.12.0
- ✅ 命名正确：SOUL.md 定义为 "martin"
- ✅ 配置完整：config.yaml + .env + 目录结构
- ⚠️ API Key 待配：需用户运行 `hermes setup` 或手动编辑 `~/.hermes/.env`

> 💡 仅剩 1 个 ⚠️（API key），属于用户侧待配置项，不阻塞流程。

## 变更日志
- [2026-05-01T15:10:58Z] autopilot 初始化，目标: 帮我在当前目录安装和配置好 hermes agent, 他的名字后续就叫 martin， skill 后续再做
- [2026-05-01T15:20:00Z] design 阶段完成：设计方案已通过审批（含 Plan Reviewer BLOCKER 修复：agent 命名改用 SOUL.md）
- [2026-05-02T00:00:00Z] implement 阶段完成：Hermes Agent v0.12.0 安装成功，SOUL.md 已配置为 "martin"，hermes doctor 核心诊断通过，API key 待用户配置
- [2026-05-02T00:05:00Z] qa 阶段完成：全部验证通过，仅 API key 待用户配置（非阻塞）
- [2026-05-02T00:05:00Z] merge 阶段：知识提取与收尾
