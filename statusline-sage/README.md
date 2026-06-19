# statusline-sage

> Sage 色彩体系的 Claude Code 状态栏 —— 路径压缩 · git/worktree · GLM Coding Plan 双窗口 token 限额 · 上下文用量。

一个用 [stringzhao.life/colors](https://stringzhao.life/colors) 色彩体系重写的 Claude Code `statusLine` 脚本。纯 bash（兼容 macOS 自带 bash 3.2），零运行时依赖（仅需系统自带的 `jq` / `git` / `curl`），自带 GLM token 限额的本地缓存与后台刷新，**绝不阻塞输入**。

---

## 效果预览

单行布局，从左到右：`git 区 │ 路径区 │ GLM 限额 │ 模型 │ 上下文 │ 输出风格`

```
主仓库（clean）：  ⎇ main      │ · martin │ GLM 5h:6% wk:80% max │ glm-5.2[1m] │ ctx 12%
主仓库（dirty）：  ⎇ main ●3 ↑1 │ · martin │ GLM 5h:6% wk:80% max │ glm-5.2[1m] │ ctx 42%
worktree：        ⎇ feat-x ⌥wt-name │ · martin │ GLM 5h:6% wk:80% max │ ctx 45%
非 git 目录：     · tmp │ GLM 5h:6% wk:80% max │ glm-5.2[1m] │ ctx 5%
```

**色彩语义**（随用量/状态自动切换）：

- 分支名 / 项目名 → 苔浅 `Sage Light`
- `⎇` 标记：主仓库用苔绿 `Sage`，worktree 用琥 `Amber`
- dirty 计数 `●N` → 朱 `Vermillion`
- GLM / context 用量：< 60% 苔绿 `Sage`，60–85% 琥 `Amber`，≥ 85% 朱 `Vermillion`
- 模型名 → 天 `Sky`，分隔符 `│` → 烟 `Smoke`

---

## 特性

| 模块 | 能力 |
|------|------|
| **路径压缩** | 项目名 + worktree 优先。主仓库只显示项目名（`martin`），worktree 额外用 `⌥wt-name` 标注；不再裸露 `/Users/.../long/path` |
| **git 状态** | 分支 / detached short-hash / dirty 计数 `●N` / ahead-behind `↑N↓N` / **worktree 自动识别**（基于 `--absolute-git-dir` vs `--git-common-dir`） |
| **GLM 限额** | 双窗口 token limit（短周期 `5h` + 长周期 `wk`）+ 套餐等级（`max`/`pro`/...），60s 缓存 + 后台静默刷新 |
| **上下文** | context window 使用百分比，兼容 `used_percentage` / `remaining_percentage` 多版本字段 |
| **模型** | 当前模型 `display_name` |
| **性能** | 缓存命中 ~0.35s，冷启动一次性同步获取 ~0.85s；git 调用合并到 3 次 |

---

## 快速安装

```bash
git clone <本仓库>   # 或直接进入 statusline-sage/ 目录
cd statusline-sage
bash install.sh
```

`install.sh` 会：

1. 检查依赖（`bash` / `jq` / `git` / `curl`）
2. 复制 `statusline-sage.sh` → `~/.claude/statusline-sage.sh`
3. 在 `~/.claude/settings.json` 写入 `statusLine` 配置（**自动备份**原文件为 `settings.json.bak.<时间戳>`）

新开 Claude Code 会话即生效（或在当前会话执行 `/statusline` 重载）。

> macOS 缺依赖时：`brew install jq`（`git`/`curl`/`bash` 系统自带）。

### 手动安装

```bash
cp statusline-sage.sh ~/.claude/statusline-sage.sh
chmod +x ~/.claude/statusline-sage.sh
# 然后在 ~/.claude/settings.json 加入：
#   "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-sage.sh", "padding": 0 }
```

> `~` 在 `settings.json` 的 `command` 里不会被 shell 展开，需写绝对路径，例如 `bash /Users/<you>/.claude/statusline-sage.sh`。`install.sh` 已自动处理。

---

## 配色体系（[stringzhao.life/colors](https://stringzhao.life/colors)）

以「苔绿 Sage」为品牌主色，暖黑/暖白构成基底，遵循**克制原则**：品牌色仅作小面积点睛，不大面积铺陈。脚本使用 truecolor（24-bit）ANSI，需现代终端支持。

### 核心色板

| 名称 | HEX | RGB | 严格用途 |
|------|-----|-----|----------|
| 苔绿 Sage | `#3A7D68` | 58,125,104 | 品牌主色、clean git `⎇`、低用量指标 |
| 苔浅 Sage Light | `#52A688` | 82,166,136 | 路径 / 分支名（活跃态） |
| 琥 Amber | `#D4920A` | 212,146,10 | warning、中用量、worktree `⎇` 标记 |
| 朱 Vermillion | `#D94F3D` | 217,79,61 | error、高用量、dirty `●N` |
| 天 Sky | `#3B87CC` | 59,135,204 | 模型名 / info |

### 基底与灰阶

| 名称 | HEX | RGB | 用途 |
|------|-----|-----|------|
| 暖黑 Ink | `#1A1A18` | 26,26,24 | 暗终端标题基底（备用） |
| 暖白 Warm White | `#F7F6F1` | 247,246,241 | 亮终端基底（备用） |
| 炭 Charcoal | `#595957` | 89,89,87 | 副文本（备用） |
| 烟 Smoke | `#8F8F8D` | 143,143,141 | 分隔符 `│` / 辅助标签 |
| 苔淡 Sage Mist | `#E8F2EE` | 232,242,238 | tag 背景（备用，浅色场景） |

> 想换配色：编辑 `statusline-sage.sh` 顶部的 `_sage()` / `_amber()` / `_vermillion()` 等函数里的 RGB 三元组即可。

---

## GLM token limit 原理

参考开源项目 [jeongsk/glm-coding-plan-statusline](https://github.com/jeongsk/glm-coding-plan-statusline) 的接口与数据结构，用纯 bash + curl 自实现（无 node 依赖）。

**接口**

```
GET {domain}/api/monitor/usage/quota/limit
Header: Authorization: <ANTHROPIC_AUTH_TOKEN>
        Accept-Language: en-US,en
```

- `domain` 从 `ANTHROPIC_BASE_URL` 提取协议+主机，例如 `https://open.bigmodel.cn`（也支持 `api.z.ai` / `dev.bigmodel.cn`）
- `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` 优先读环境变量，回退读 `~/.claude/settings.json` 的 `env` 字段

**返回数据**（节选）

```jsonc
{ "code": 200, "data": {
    "level": "max",                  // 套餐等级
    "limits": [
      { "type": "TOKENS_LIMIT", "percentage": 6,  "nextResetTime": 1781880989425 }, // 短周期(5h)
      { "type": "TOKENS_LIMIT", "percentage": 80, "nextResetTime": 1782097284978 }, // 长周期(weekly)
      { "type": "TIME_LIMIT",   "percentage": 1,  ... }                              // MCP 工具次数
    ]
  }
}
```

**窗口判定（启发式）**：把所有 `TOKENS_LIMIT` 按 `nextResetTime` 升序排列 —— reset 最近的为短周期窗口（标 `5h`），reset 最远的为长周期窗口（标 `wk`）。这样不依赖 `unit` 字段的语义猜测，自适应官方调整。

**缓存策略**（避免每次渲染打 API）

| 场景 | 行为 |
|------|------|
| 缓存有效（< 60s） | 直接用缓存，**秒回** |
| 缓存过期（有旧值） | 输出旧缓存 + `nohup` 后台 curl 刷新，**不阻塞** |
| 冷启动（无缓存） | 同步 curl 获取一次（一次性 ≤ 2s），之后靠缓存/后台 |
| API 失败 | 缓存标记 `ok:0`，TTL 降到 15s 以便尽快重试 |

缓存文件：`~/.claude/.statusline-sage-quota.json`（JSON，可手动编辑/删除）。

---

## 可配置项

编辑 `statusline-sage.sh` 顶部：

```bash
CACHE_TTL_OK=60        # API 成功缓存有效期（秒）
CACHE_TTL_FAIL=15      # API 失败缓存有效期（秒）
REFRESH_DEBOUNCE=30    # 后台刷新防抖（秒），避免每次渲染都 fork curl
GLM_API_TIMEOUT=3      # 后台刷新 curl 超时（秒）
GLM_FIRST_TIMEOUT=2    # 冷启动首次同步获取 curl 超时（秒）
GLM_HIGH=85            # 用量 ≥ 此值 → 朱红
GLM_MID=60             # 用量 ≥ 此值 → 琥珀
```

`install.sh` 写入的 `padding: 0` 让状态栏贴边紧凑，可在 `settings.json` 改为 `1`/`2` 增加左右留白。

---

## 排障

| 现象 | 排查 |
|------|------|
| 一直显示 `GLM …` | API 未通或未配置 token。检查 `~/.claude/settings.json` 的 `env.ANTHROPIC_BASE_URL` / `env.ANTHROPIC_AUTH_TOKEN`；手动测：`curl -sH "Authorization: <token>" https://open.bigmodel.cn/api/monitor/usage/quota/limit`；删缓存重试：`rm ~/.claude/.statusline-sage-quota.json` |
| 颜色显示为乱码/原始码 | 终端不支持 truecolor。换用 iTerm2 / WezTerm / Ghostty / Kitty / 现代版 Terminal.app |
| worktree 未识别 | git 版本需 ≥ 2.5（`--git-common-dir` 支持）。`git --version` 检查 |
| 渲染偏慢 | 常态应 < 0.4s。若 git 仓库巨大，`git status --porcelain` 会变慢，属正常 |
| 想看 reset 倒计时 | 当前版本未显示倒计时（保持简洁），如需可在 `_render_glm_cache` 加 `nextResetTime` 换算 |

---

## 卸载

```bash
rm ~/.claude/statusline-sage.sh ~/.claude/.statusline-sage-quota.json
# 从 ~/.claude/settings.json 删除 "statusLine" 字段（或恢复 .bak 备份）
```

旧的 `~/.claude/statusline-avit.sh` / `statusline-command.sh` 不受影响，安装时仅切换引用、不删除。

---

## 致谢

- **[jeongsk/glm-coding-plan-statusline](https://github.com/jeongsk/glm-coding-plan-statusline)** —— GLM Coding Plan 用量查询的 API 接口与数据结构参考
- **[stringzhao.life/colors](https://stringzhao.life/colors)** —— Sage 色彩设计体系

## License

MIT
