---
name: movie-fetcher
description: "一键下载电影/剧集到绿联 NAS 并自动配字幕（教父 BT + qBit + zimuku/SubHD + whisper 兜底）；每周一新片速递"
version: 0.9.0
metadata:
  hermes:
    tags: [movie, download, subtitle, magnet, bt, nas, qbittorrent, 电影, 字幕, 下载, 看电影, 字幕组, 新片, 周报, 豆瓣, 每周]
    category: media
    requires_toolsets: [terminal]
---

# movie-fetcher

把一句"我想看 X"翻译成"NAS 上下好 X 并配好字幕"。

## When to use

- 下载电影/剧集到 NAS
- 给已下载内容补字幕
- 每周新片速递

## 前置依赖

| 项 | 检查命令 | 期望 |
|---|---|---|
| qBittorrent 可达 | `$PYTHON -m scripts.cli status` | 列出现有任务 |

`$PYTHON = /Users/stringzhao/workspace/martin/.venv/bin/python`，工作目录 `~/.hermes/skills/media/movie-fetcher/`。

## 子命令

| 命令 | 行为 |
|---|---|
| `fetch <title> [-c movie\|tv]` | 主入口：多源搜索 → pick_best → 推 qBit → 配字幕 |
| `search <title> [--limit N] [--json]` | 只搜不下；`--json` 输出含 magnet |
| `download <magnet\|title> [-c movie\|tv]` | 只推 magnet |
| `status [hash]` | 查任务进度 |
| `subtitle <movie_dir>` | 为目录补字幕 |
| `weekly [-k mv\|tv\|all] [--min-score N]` | 每周新片速递 |

## 搜索与 pick_best (v0.9)

### 多源合并 + per-source 诊断

`search_all` 合并 jiaofu → yts → apibay → btdig 四个源（标题去重），不再短路返回。每个源返回独立的 `SearchDiagnostic`（状态、详情、结果数），源间加 1 秒延迟避免安全封控。

搜索无结果时不再只显示「无结果」，而是输出每个源的详细状态：

```
无结果 — 1个源被安全封控（btdig）；1个源不支持中文搜索（apibay）；1个源无匹配（yts）
搜索诊断：
  — 无结果  jiaofu — jiaofu 无匹配「xxx」的结果
  — 不支持中文  apibay — apibay 不支持中文搜索「xxx」
  — 无结果  yts — YTS 无匹配（仅英文片源）
  🚫 被封  btdig — btdig 触发安全验证: 「Checking your browser」
```

**不要看到「无结果」就放弃**——先看诊断，判断是封控/超时/真的没资源。

### 安全封控检测

btdig 返回 HTML 时检测 Cloudflare challenge / captcha / 静默封控（页面内容极少且无搜索结果）。apibay 检测 rate limit 响应。检测到封控时，`SourceStatus=BLOCKED` 并携带具体匹配到的封控特征。

### 源间延迟

连续搜索源之间强制 sleep 1 秒，避免 btdig 等站触发频率限制（429 或静默封控）。

### pick_best 相关性过滤

排序维度：1) config `prefer_quality` 画质偏好  2) seeders 数量。关键词匹配率过滤（≥30%），拦截 btdig 等源的噪音结果。

### btdig 精确搜索

btdig 搜索自动加双引号做 AND 精确匹配。

## 字幕系统 (v0.7)

### 来源匹配

`_try_zimuku` 从视频文件名提取来源关键词（BluRay/WEBRip/NF 等），优先下载同版本字幕包。避免时间轴不匹配。

### 剧集多文件字幕

剧集字幕包（含多集独立 ass/srt）解压后**全部返回**，按集数（S01E01）匹配视频文件命名。不再只取第一个文件。

### 自动内嵌（`fetch --wait-download`）

`fetch` 命令在下载完成后自动：
1. 检查是否已有内嵌中文字幕
2. 下载匹配的字幕包
3. `ffmpeg -c copy` 将字幕内嵌到每个 mkv（不重编码）
4. 处理 SMB 目录写保护（rename 旧目录 → 新建可写目录 → 嵌入 → 清理旧目录）
5. 验证字幕匹配性：检查字幕轨道语言、提取尾句确认含中文、时间轴与视频时长匹配

### 默认字幕处理

嵌入字幕时自动：
1. **清除原有字幕的 default 标记**：原文件自带的 PGS/VobSub 字幕标记为非默认
2. **新字幕设为默认**：嵌入的 ASS 中文字幕标记 `language=chi`、`title=Chinese (简体中文)`、`default=1`
3. **删除冲突字幕轨道**：若播放器不认 `default_track` 标记（按 track 顺序选第一个），用 `mkvmerge` 删除原 PGS/VobSub 轨道，只留 ASS

**mkvmerge 删除原字幕（不改编码，~20s/集）**：
```bash
# 查看轨道：Track ID 0=video, 1=audio, 2=PGS, 3=ASS
mkvmerge -i video.mkv

# 只保留 0+1+3，删 Track 2（PGS）
mkvmerge -o output.mkv -d 0 -a 1 -s 3 video.mkv
```
> `-d` 选视频轨，`-a` 选音轨，`-s` 选字幕轨

> **注意**：`-c copy` 模式不重编码音视频，只改容器 metadata；若存量文件默认字幕轨道有误，可用 `mkvpropedit` 修复（见排错章节）。

## 典型工作流

```bash
PYTHON=/Users/stringzhao/workspace/martin/.venv/bin/python
cd ~/.hermes/skills/media/movie-fetcher

# 先搜后确认（推荐）
$PYTHON -m scripts.cli search "Stranger Things S01" --json --limit 15
# 确认后直接 push magnet
$PYTHON -m scripts.cli download "magnet:?xt=urn:btih:..." -c tv

# 一句话下载
$PYTHON -m scripts.cli fetch "怪奇物语" -c tv

# 看进度 / 配字幕
$PYTHON -m scripts.cli status <hash>
$PYTHON -m scripts.cli subtitle "<本地目录路径>"
```

## 排错

### 搜索返回「无结果」——先看诊断，别直接放弃

**症状**：搜索"低智商犯罪"等中文内容显示「无结果」。

**错误做法**：「无结果」就认为资源不存在，换关键词反复搜。

**正确做法**：看 per-source 诊断输出。每次搜索无结果时会打印类似：

```
无结果 — 1个源被安全封控（btdig）；1个源不支持中文搜索（apibay）
搜索诊断：
  — 无结果  jiaofu — jiaofu 无匹配「xxx」的结果
  🚫 被封  btdig — btdig 触发安全验证: 「Checking your browser」
```

常见状态解读：
| 状态 | 含义 | 对策 |
|------|------|------|
| `— 无结果` | 源正常但真的没这个资源 | 换英文名/别名重试 |
| `🚫 被封` | 触发安全验证（Cloudflare/captcha） | 等几分钟重试，或手动浏览器访问验证 |
| `⏱ 超时` | 网络超时/被墙 | 检查代理，重试 |
| `— 不支持中文` | apibay CJK 查询返回 noise | 正常，用英文名搜 apibay |
| `✗ 不可用` | opencli 未安装 / Chrome 登录态失效 | 修复 opencli 或跳过此源 |

### fetch 选到完全不相关的资源

**症状**：搜索 "Stranger Things S01" 却推了 1227GB 的 "My Movies"
**原因**：btdig 噪音覆盖了 apibay 结果（v0.6 已修复）
**方案**：用 `search --json` 获取正确 magnet，再 `download "magnet:..."` 直接推送

### 字幕写入 NAS 报 Permission denied（qBit 做种锁）

**症状**：`subtitle` / `cp` / `touch` 写任务子目录报 `Permission denied`，但：
- `ls -la` 显示 owner 是当前用户且 `rwx------`
- 上级目录（`电视剧/`）✅ 可写
- 老的已下载目录 ✅ 可写
- 只有**正在做种（stalledUP/seeding）的任务子目录** ❌ 不可写

**根因**：qBit 容器在做种时持有任务子目录的文件锁，SMB 客户端无法写入。

**诊断步骤**：参见 `references/qbit-seeder-lock.md`

**解决方案**：
1. （推荐）qBit Web UI → 暂停任务 → 释放锁 → `cp` 字幕进去 → 恢复做种
2. （兜底）字幕下载到 `~/Downloads/`，Finder 手动拖入 NAS 目录

### 内嵌后默认字幕不是中文（PGS 变成默认）

**症状**：播放器打开后显示 "dvd subtitle"（PGS/VobSub），需手动切换到 ASS 中文字幕。

**根因**：原文件自带的 PGS 字幕在嵌入前已是 `default=1`，ffmpeg 命令未清除它的默认标记。

**修复（已嵌入的文件，无需重编码）**：
```bash
# 查看字幕轨道
mkvmerge -J video.mkv | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['tracks']:
    if t['type'] == 'subtitles':
        print(f\"Track {t['id']}: {t.get('codec','')}  lang={t['properties'].get('language','')}  default={t['properties'].get('default_track',False)}\")
"

# 修复：PGS 取消默认，ASS 设为默认 + 命名
mkvpropedit video.mkv \
  --edit track:=<PGS_UID> --set flag-default=0 --delete name \
  --edit track:=<ASS_UID> --set flag-default=1 --set name="Chinese (简体中文)" --set language=chi
```

> 此问题已在 v0.8 embed 代码中修复：`_embed_mkv` 和 `_embed_subs_post_download` 都会先清旧字幕 default，再设新字幕 default。

### 播放器不认 default_track 标记（仍然选原字幕）

**症状**：`mkvpropedit` 修复后 `default=True` 在 ASS 上，但播放器仍然选 PGS/dvd subtitle。

**根因**：部分播放器（如某些智能电视、Infuse、Plex）忽略 Matroska `default_track` 标志，按 track 顺序选第一个字幕。

**修复：删除原 PGS 轨道**
```bash
# 查看轨道顺序
mkvmerge -i video.mkv

# 只保留 video(0) + audio(1) + ASS(3)，删 PGS(2)
mkvmerge -o output.mkv -d 0 -a 1 -s 3 video.mkv
mv output.mkv video.mkv
```
> `mkvmerge` 只改容器不改编码，文件大小几乎不变，~20s 一集。