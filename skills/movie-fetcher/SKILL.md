---
name: movie-fetcher
description: "一键下载电影/剧集到绿联 NAS 并自动配字幕（教父 BT + qBit + zimuku/SubHD + whisper 兜底）；每周一新片速递（教父站筛选 + 豆瓣评分过滤 + 回复下载）"
version: 0.5.0
metadata:
  hermes:
    tags:
      - movie
      - download
      - subtitle
      - magnet
      - bt
      - nas
      - qbittorrent
      - 电影
      - 字幕
      - 下载
      - 看电影
      - 字幕组
      - 新片
      - 周报
      - 豆瓣
      - 每周
    category: media
    requires_toolsets:
      - terminal
---

# movie-fetcher

把一句"我想看 X"翻译成"NAS 上下好 X 并配好字幕"。**默认不等视频下载完**——qBit 拿到 metadata（文件名就绪，~30s）就立即配字幕并返回。

## When to use

- 用户说"下载《XXX》"、"我想看 XXX"、"NAS 上下个 XXX"、"找 XXX 的资源"
- 用户说"给 XXX 补字幕"、"扫一下哪些电影没字幕"
- 用户给一个 `magnet:?xt=...` 链接，希望推到 NAS
- 用户说"最近/上周有什么新片"、"本周看什么"、"豆瓣 8 分以上的新电影/剧集"（→ `weekly`）

**不要**用在：剧集追更（电视剧批量订阅）、流媒体在线播放、视频转码。

## 前置依赖（首次使用前必须自检）

| 项 | 检查命令 | 期望 |
|---|---|---|
| Chrome 扩展（opencli） | `opencli doctor` | `Extension: connected` |
| 教父站登录 | 用户手动在 chrome 登录 `https://www.xn--wcv59z.com/` | tab 显示用户名 |
| SubHD 登录 | 用户手动在 chrome 登录 `https://subhd.tv/` | 同上 |
| zimuku 登录 | 用户手动在 chrome 登录 `https://zimuku.org/` | 同上（用于 Yunsuo WAF cookie） |
| 本地 Qwen 多模态服务 | `curl -s --max-time 3 http://127.0.0.1:8001/v1/models -H "Authorization: Bearer qwen-local-key"` | 返 model list 含 `qwen3.6-35b`（zimuku/SubHD captcha 都靠它） |
| qBittorrent 可达 | `cd ~/.hermes/skills/media/movie-fetcher && $PYTHON -m scripts.cli status` | 列出现有任务 |

`$PYTHON = /Users/stringzhao/workspace/martin/.venv/bin/python`，所有命令的工作目录都是
`~/.hermes/skills/media/movie-fetcher/`。

## Setup（仅首次）

NAS 凭据/路径已经写在 `config.yaml`（0600，.gitignore）。如果换 NAS 或重装，重跑：

```bash
$PYTHON -m scripts.cli setup --qbit-password '<qBit Web 密码>' \
    --nas-internal '<qBit 容器内电影目录，如 /m>'
```

## 子命令

| 命令 | 行为 |
|---|---|
| `fetch <title> [-c movie|tv]` | **主入口**：教父 BT 搜 → 自动选最佳 magnet → 推 qBit → 等 metadata → 配字幕 |
| `fetch <title> --wait-download [-c movie|tv]` | 同上但等视频 100% 下完（数十分钟~数小时） |
| `download <magnet\|title> [-c movie|tv]` | 只推 magnet，不等也不配字幕 |
| `status [hash]` | 查任务进度 |
| `subtitle <movie_dir>` | 为已下完的电影目录补字幕（含 whisper 兜底） |
| `scan-missing [--apply]` | 扫所有分类目录列出缺字幕的电影/剧集；`--apply` 批量补 |
| `search <title> [--limit N]` | 只搜不下，看候选 |
| `embed <mkv\|dir> [--delete-external] [--no-default]` | 把外挂字幕用 ffmpeg `-c copy` 内嵌到 mkv 容器（视频不重编码，几分钟）。默认标新字幕为 default 轨道，外挂保留 |
| `weekly [-k mv\|tv\|all] [--min-score N] [--pages P] [--dry-run]` | **新片速递**：教父站按首播时间拉最新 → 豆瓣≥N 过滤 → 剧集只留全集完成 → 去重 → markdown 周报到 stdout（供 hermes 定时推送） |

## 分类支持（v0.4 自动识别）

`config.yaml` 的 `paths.categories` 定义分类映射：

```yaml
paths:
  categories:
    movie: "电影"
    tv: "剧集"
  default_category: "movie"   # 无法识别时的兜底
```

**自动识别**（v0.4）：`fetch`/`download` 不指定 `-c` 时，自动从搜索词+结果标题判断是否为剧集。
匹配模式：`全\d+集`、`全集打包`、`S\d{2,}`、`Season \d+`、`第\d+季`、`E\d{2,}`、`EP\d{2,}`、`第\d+部`、`\bTV\b`。

- `fetch "信条"` → 自动识别为电影 → 迅雷下载/电影/  ✅
- `fetch "绝命毒师"` → 标题含 S01 → 自动识别为剧集 → 迅雷下载/剧集/  ✅
- `fetch "铁拳教育"` → 搜索结果含「全10集」→ 自动识别为剧集 ✅
- `fetch "XXX" -c tv` → 显式指定，跳过自动识别

**已修复的问题**：剧集误入「电影」目录（根因：opencli `@jackwener` 模块解析失败导致 jiaofu 搜索静默回退英文源，已在 `workspace/martin/node_modules/` 建软链接）

## 字幕兜底策略（subtitle_for_name 内部，自动）

1. **内嵌检测**：文件名含「国语中字 / 中字 / 内嵌 / 双语 / CHS&ENG」等 → 跳过外挂搜索（资源自带）
2. **zimuku**（**主源**）：opencli adapter 搜 → 自动绕过 Yunsuo WAF 图片 captcha（Qwen OCR）→ 5 镜像下 → 解压 → 命名对齐。zimuku 中文片库覆盖最全
3. **SubHD**（备源）：opencli adapter 搜 → 自动解 SVG captcha（Qwen）→ CDN 下 → 解压。当 zimuku 没有结果时启用（也用于 zimuku 宕机时兜底）
4. **subliminal**：OpenSubtitles/Podnapisi（不稳定，podnapisi 经常 SSL 抖动）
5. **whisper**：本机 `scripts/transcribe.py large-v3-turbo`（**需视频文件下完才能跑**，fetch 默认流程跳过；可单独 `subtitle <dir>` 触发）

## 典型工作流

```bash
PYTHON=/Users/stringzhao/workspace/martin/.venv/bin/python
cd ~/.hermes/skills/media/movie-fetcher

# 一句话下载电影 + 配字幕（默认不等下完）
$PYTHON -m scripts.cli fetch "信条"

# 下载剧集 → 迅雷下载/剧集/
$PYTHON -m scripts.cli fetch "绝命毒师" -c tv

# 已有 magnet，指定分类只推
$PYTHON -m scripts.cli download "magnet:?xt=urn:btih:..." -c movie

# 看进度
$PYTHON -m scripts.cli status

# 扫整个迅雷下载目录缺字幕的
$PYTHON -m scripts.cli scan-missing            # 看哪些缺
$PYTHON -m scripts.cli scan-missing --apply    # 批量补（电影+剧集都扫）

# 把外挂字幕烧进 mkv（不重新编码视频，几分钟一部）
$PYTHON -m scripts.cli embed "<电影目录或单个 mkv>"
$PYTHON -m scripts.cli embed "/Volumes/.../迅雷下载"  # 批量整库

# 每周新片速递（电影+剧集，豆瓣≥8，输出周报到 stdout）
$PYTHON -m scripts.cli weekly
$PYTHON -m scripts.cli weekly -k tv --min-score 9 --dry-run  # 调试：只剧集/9分/不写库
```

## 每周新片速递（v0.5）

把"上周有什么值得看的新片"自动化。**数据全部来自教父站**（列表卡片自带豆瓣分，绕过豆瓣反爬）：

- **电影**：最近首播的（`sort=date`）
- **剧集**：全集完成的（状态 `全N集`，非连载）
- **过滤**：豆瓣 ≥ `discover.min_score`（默认 8.0）；卡片无分（`--`，预告/未开分）直接跳过

**hermes 串联**（定时/推送由 hermes 配置，不在本 skill 内）：
- cron 每周一 → `weekly` → stdout 周报 → gateway 推微信
- 用户回复「下 铁拳教育」→ hermes 调 `download "铁拳教育" -c tv`（或 `fetch`）

## 关键路径

- `~/.opencli/clis/jiaofu/list.js` — 教父站列表/筛选 adapter（weekly 用，卡片自带豆瓣分）
- `~/.opencli/clis/jiaofu/detail.js` — 教父站详情 adapter（评分/首播日期/简介/magnet）
- `~/.opencli/clis/jiaofu/search.js` — 教父 BT 搜索 adapter（要 Chrome 登录）
- `~/.opencli/clis/subhd/{search,download}.js` — SubHD 字幕 adapter（Qwen SVG captcha 解码）
- `~/.opencli/clis/zimuku/{search,download}.js` — zimuku 字幕 adapter（Qwen 图片 captcha 解 Yunsuo WAF）
- `~/.opencli/clis/zimuku/_lib.js` — 共享：`ensureBypassed()` + `ocrCaptcha()`
- `~/.hermes/skills/media/movie-fetcher/scripts/` — Python 主体
- `config.yaml` — NAS 凭据 + 路径（不要 git commit）

## 排错

- `setup` 报"未发现存活端口"：检查 NAS 上 qBit 是否启用 Web UI，端口配置是否对
- `fetch` 超时/搜不到资源：教父站可能临时挂或被封；用 `search "标题"` 看候选；若都无结果，用户手贴 magnet
- `subtitle` Qwen 报错：`curl http://127.0.0.1:8001/v1/models` 验证服务，必要时 `pm2 restart qwen-35b`
- SubHD captcha 多次解错：调高 `--max-cap-tries`（默认 3），或 SubHD 服务端 token 超时（间隔几秒后重试）
- `config.yaml` 权限错：会被自动 chmod 0600，但不入 git
