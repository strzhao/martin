# stringzhao-life 色彩体系

> 本文件是 [stringzhao.life/colors](https://stringzhao.life/colors) 设计体系的本地沉淀，作为 statusline-sage 及后续 UI 的统一取色来源。脚本（`statusline-sage.sh`）用 truecolor（24-bit）ANSI 实现其中的语义色，见文末「statusline 取色映射」。

## 品牌色
苔 Sage — oklch(0.488 0.088 158) / #3A7D68 — CTA、品牌强调
关键词：温润 · 克制 · 有机 · 清醒

## 核心色板
- 墨 Ink: oklch(0.155 0.006 95) / #1A1A18 — 正文、标题 [AAA vs Paper]
- 纸 Paper: oklch(0.975 0.010 95) / #F7F6F1 — 页面背景
- 雾 Mist: oklch(0.928 0.005 95) / #EBEBEA — 卡片、次级背景
- 烟 Smoke: oklch(0.595 0.005 95) / #8F8F8D — 描述、辅助文字 [AA18 vs Paper]
- 炭 Charcoal: oklch(0.400 0.005 95) / #595957 — placeholder、标签 [AA vs Paper]
- 苔 Sage: oklch(0.488 0.088 158) / #3A7D68 — CTA、品牌强调 [AA18 vs Paper]

## 辅助色板
- 苔浅 Sage Light: oklch(0.620 0.075 160) / #52A688 — hover、选中态
- 苔淡 Sage Mist: oklch(0.940 0.025 158) / #E8F2EE — tag 背景、浅色填充
- 琥 Amber: oklch(0.668 0.155 68) / #D4920A — warning、highlight
- 朱 Vermillion: oklch(0.548 0.168 23) / #D94F3D — error、delete
- 天 Sky: oklch(0.568 0.118 242) / #3B87CC — link、info badge

## 色彩关系
- 文字层级：Ink(标题) → Charcoal(副标题) → Smoke(描述) on Paper
- 品牌状态：Sage(default) → Sage Light(hover) → Sage(active)
- 品牌填充：Sage Mist(背景) + Sage(文字/边框)
- 语义状态：Amber(warning) / Vermillion(destructive) / Sky(info)

## 使用原则
- 纸/墨用于大面积背景与文本，苔绿仅作点睛
- 三级灰阶（雾/烟/炭）承接信息层级
- 琥/朱/天对应 warning / destructive / info 语义状态

## 交互原则
本体系遵循五项交互设计指导原则：
- 即时反馈 (Feedback)：每个动作都应有即时、明确的视觉回应（hover 100ms / 点击 50ms / 复制确认 2s）
- 渐进揭示 (Progressive Disclosure)：默认简洁，交互时按需展现更多信息
- 直接操控 (Direct Manipulation)：所见即所得，点击色值即复制，格式切换即时生效，无中间步骤
- 一致性 (Consistency)：所有可复制元素使用统一的 hover 虚线下划线 + 点击反馈模式
- 可供性 (Affordance)：交互元素通过视觉暗示自身的操作方式（虚线下划线、cursor 变化、hover 边框）

微交互时序：hover 反馈 100ms / 点击反馈 50ms / 复制确认显示 2s / 入场动画 400ms ease-out / 状态切换 200ms

## CSS Tokens
基础层:
  --home-bg: oklch(0.975 0.010 95) — 纸白主背景
  --home-fg: oklch(0.155 0.006 95) — 墨黑主文本
  --home-muted: oklch(0.595 0.005 95) — 烟灰辅助文字
品牌层:
  --home-accent: oklch(0.488 0.088 158) — 苔绿品牌色
  --home-accent-hover: oklch(0.620 0.075 160) — 苔浅 hover 态
  --home-accent-foreground: oklch(0.975 0.010 95) — 苔色上的文字
  --home-accent-mist: oklch(0.940 0.025 158) — 苔淡背景填充
组件层:
  --home-border: oklch(0.850 0.012 120 / 0.40) — 暖灰细边框
  --home-surface: oklch(0.992 0.006 95 / 0.72) — 卡片半透明面
  --home-shadow: oklch(0.300 0.050 158 / 0.28) — 苔色调阴影
  --home-focus: oklch(0.488 0.088 158) — focus ring

---

## statusline 取色映射

`statusline-sage.sh` 按本体系的语义状态取色，用 truecolor（`\033[38;2;R;G;Bm`）输出。语义对应关系：

| 色彩 | HEX | RGB | statusline 用途 |
|------|-----|-----|-----------------|
| 苔 Sage | `#3A7D68` | 58,125,104 | clean git `⎇`、低用量指标（<60%）、`_level_color` 低档 |
| 苔浅 Sage Light | `#52A688` | 82,166,136 | 路径 / 分支名 / 项目名（活跃态） |
| 琥 Amber | `#D4920A` | 212,146,10 | warning、中用量（60–85%）、worktree `⎇` 标记、output_style |
| 朱 Vermillion | `#D94F3D` | 217,79,61 | error、高用量（≥85%）、dirty `●N`、**高峰期倍率 `×3`** |
| 天 Sky | `#3B87CC` | 59,135,204 | 模型名 / info |
| 烟 Smoke | `#8F8F8D` | 143,143,141 | 分隔符 `│`、辅助标签（`GLM` 前缀、`·`） |

**语义一致性**：朱红 Vermillion 在本体系中即「destructive / 高消耗」语义，因此高峰期 3 倍 token 消耗（一种"高代价/警示"状态）复用朱红，与 dirty 文件计数、高用量阈值共享同一警示色，符合「一致性」交互原则。

> 换配色：编辑 `statusline-sage.sh` 顶部 `_sage()` / `_amber()` / `_vermillion()` 等函数里的 RGB 三元组。本文件是设计来源，脚本色彩函数保持内联（单文件部署、零运行时依赖）。
