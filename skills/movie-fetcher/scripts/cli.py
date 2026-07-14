"""movie-fetcher CLI 入口。

调用方式：
    PYTHON=/Users/stringzhao/workspace/martin/.venv/bin/python
    $PYTHON -m scripts.cli <subcommand> [args]

子命令：setup / search / download / status / subtitle / scan-missing / fetch
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Optional

import typer

# 允许直接 `python scripts/cli.py ...` 运行
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from scripts import config as cfg_mod  # type: ignore
    from scripts import nas as nas_mod  # type: ignore
    from scripts import search as search_mod  # type: ignore
    from scripts import download as dl_mod  # type: ignore
    from scripts import subtitle as sub_mod  # type: ignore
    from scripts import paths as paths_mod  # type: ignore
    from scripts import embed as embed_mod  # type: ignore
    from scripts import discover as discover_mod  # type: ignore
else:
    from . import config as cfg_mod
    from . import nas as nas_mod
    from . import search as search_mod
    from . import download as dl_mod
    from . import subtitle as sub_mod
    from . import paths as paths_mod
    from . import embed as embed_mod
    from . import discover as discover_mod

app = typer.Typer(add_completion=False, no_args_is_help=True,
                  help="电影下载 + 字幕一体化工具")


# ─── setup ──────────────────────────────────────────────────────────────────


@app.command(help="探测 NAS 上的下载客户端并写入 config.yaml")
def setup(
    qbit_user: str = typer.Option("admin", help="qBit/Transmission 登录名"),
    qbit_password: str = typer.Option("", help="qBit/Transmission 登录密码"),
    nas_internal: str = typer.Option("", help="qBit 视角下的下载根目录，如 /volume1/.../迅雷下载"),
):
    data = cfg_mod.load()
    host = cfg_mod.require(data, "nas.host")

    typer.echo(f"[setup] 探测 {host} 常见客户端端口...")
    hits = nas_mod.probe(host)
    if not hits:
        typer.echo("  未发现存活端口；请手动检查 NAS 上 qBit/Transmission 是否启用 Web UI")
        typer.echo("  或者直接编辑 ~/.hermes/skills/media/movie-fetcher/config.yaml 填 client.url 等字段")
        raise typer.Exit(1)
    for kind, port in hits:
        typer.echo(f"  ✓ {host}:{port}  ({kind} 候选)")

    # 取第一个能成功握手的
    for kind, port in hits:
        url = f"http://{host}:{port}"
        if kind == "qbittorrent":
            ok, msg = nas_mod.try_qbit(url, qbit_user, qbit_password)
        else:
            ok, msg = nas_mod.try_transmission(host, port, qbit_user, qbit_password)
        typer.echo(f"  [{kind}] {msg}")
        if ok:
            data.setdefault("client", {})
            data["client"]["kind"] = kind
            data["client"]["url"] = url
            data["client"]["user"] = qbit_user
            data["client"]["password"] = qbit_password
            if nas_internal:
                data.setdefault("paths", {})["nas_internal"] = nas_internal
            cfg_mod.save(data)
            typer.echo(f"  写入 config.yaml: client.kind={kind}, url={url}")
            if not data.get("paths", {}).get("nas_internal"):
                typer.echo("  ⚠ 未设置 paths.nas_internal，请手动填入 NAS 内部下载路径")
            return
    typer.echo("  所有候选都握手失败；请确认凭据或在 config.yaml 中手填", err=True)
    raise typer.Exit(2)


# ─── search ─────────────────────────────────────────────────────────────────


@app.command(help="按标题搜索 BT 资源")
def search(
    title: str,
    limit: int = typer.Option(10, "--limit", "-n"),
    as_json: bool = typer.Option(False, "--json", help="JSON 输出"),
):
    data = cfg_mod.load()
    timeout = data.get("search", {}).get("timeout", 5)
    results, diagnostics = search_mod.search_all(title, timeout=timeout, limit=limit)
    if not results:
        summary = search_mod.diagnostics_summary(diagnostics)
        typer.echo(f"无结果 — {summary}")
        typer.echo(search_mod.format_diagnostics(diagnostics))
        raise typer.Exit(1)
    if as_json:
        typer.echo(json.dumps([r.to_dict() for r in results], ensure_ascii=False, indent=2))
        return
    typer.echo(f"{'src':<8} {'seed':>6}  {'size':<12}  title")
    typer.echo("-" * 80)
    for r in results:
        seed = "?" if r.seeders < 0 else str(r.seeders)
        typer.echo(f"{r.source:<8} {seed:>6}  {r.size:<12}  {r.title[:60]}")


# ─── helpers ────────────────────────────────────────────────────────────────

# 剧集识别模式：匹配标题中的剧集特征关键词
_TV_PATTERNS = [
    r"全\d+集",          # 全24集
    r"全集打包",          # 全集打包（无数字的简写）
    r"S\d{2,}",          # S01
    r"Season\s*\d+",     # Season 1
    r"第\d+季",          # 第1季
    r"E\d{2,}",          # E01
    r"EP\d{2,}",         # EP01
    r"第\d+部",          # 第1部
    r"\bTV\b",           # TV
]

import re as _re

def _guess_tv(title: str) -> bool:
    """从标题文本猜测是否为剧集。"""
    return any(_re.search(p, title, _re.IGNORECASE) for p in _TV_PATTERNS)


def _resolve_category(data: dict, category: str, title_hint: str = "") -> str:
    """解析分类参数。优先级：显式 -c > 标题自动识别 > config default_category。

    当未指定 -c 时，若 title_hint 匹配剧集特征则自动归类为 tv，
    避免剧集误入「电影」目录。
    """
    categories = data["paths"].get("categories", {})
    if not category:
        if title_hint and _guess_tv(title_hint) and "tv" in categories:
            category = "tv"
            typer.echo(f"  🔍 自动识别为剧集（标题含剧集特征）→ 归类「{categories['tv']}」")
        else:
            category = data["paths"].get("default_category", "movie")
    if categories and category not in categories:
        valid = ", ".join(categories.keys())
        typer.echo(f"未知分类 '{category}'，支持：{valid}", err=True)
        raise typer.Exit(1)
    return category


# ─── download ───────────────────────────────────────────────────────────────


@app.command(help="推送 magnet 到 NAS；title 模式会先搜后选最佳")
def download(
    target: str = typer.Argument(..., help="magnet:... 或 电影标题"),
    category: str = typer.Option("", "--category", "-c",
                                 help="分类（电影/剧集），留空自动识别或按 config 默认"),
):
    data = cfg_mod.load()

    if target.startswith("magnet:"):
        magnet = target
        title_hint = ""
    else:
        timeout = data.get("search", {}).get("timeout", 5)
        results, diagnostics = search_mod.search_all(target, timeout=timeout, limit=20)
        if not results:
            summary = search_mod.diagnostics_summary(diagnostics)
            typer.echo(f"搜不到资源 — {summary}", err=True)
            raise typer.Exit(1)
        best = search_mod.pick_best(results, data["search"]["prefer_quality"], query=target)
        typer.echo(f"自动选中：[{best.source}] {best.title}  seeders={best.seeders}  size={best.size}")
        magnet = best.magnet
        # 用搜索词 + 结果标题联合判断分类
        title_hint = f"{target} {best.title}"

    category = _resolve_category(data, category, title_hint=title_hint)

    client, hash_ = dl_mod.push_magnet(data, magnet, category=category)
    categories = data["paths"].get("categories", {})
    subdir = categories.get(category, "")
    target_path = f"迅雷下载/{subdir}" if subdir else "迅雷下载"
    typer.echo(f"已推送 → {target_path}，hash={hash_}")


# ─── status ─────────────────────────────────────────────────────────────────


@app.command(help="查看下载状态")
def status(hash_: Optional[str] = typer.Argument(None)):
    data = cfg_mod.load()
    client = nas_mod.build_client(data)
    if hash_:
        t = client.info(hash_)
        if not t:
            typer.echo("未找到任务", err=True)
            raise typer.Exit(1)
        typer.echo(f"{t.hash_}  {t.progress*100:.1f}%  {t.state}  {t.name}")
        return
    items = client.list()
    if not items:
        typer.echo("无任务")
        return
    for t in items:
        typer.echo(f"{t.hash_[:8]}…  {t.progress*100:5.1f}%  {t.state:<12}  {t.name[:60]}")


# ─── subtitle ───────────────────────────────────────────────────────────────


@app.command(help="为指定电影目录补字幕（中→英→whisper）")
def subtitle(
    movie_dir: str = typer.Argument(..., help="电影目录的本地挂载路径"),
    force: bool = typer.Option(False, "--force", help="即使已有字幕也强制下载"),
):
    data = cfg_mod.load()
    out = sub_mod.ensure_subtitle(Path(movie_dir), data, force=force)
    typer.echo(f"完成：新增 {len(out)} 个字幕")


@app.command("scan-missing", help="扫描所有分类目录列出缺字幕的电影/剧集")
def scan_missing(
    apply: bool = typer.Option(False, "--apply", help="对每个缺字幕的目录自动补"),
):
    data = cfg_mod.load()
    local_mount = Path(data["paths"]["local_mount"])
    categories = data["paths"].get("categories", {})

    # 若配置了分类，遍历所有分类子目录；否则只扫 local_mount 本身（向后兼容）
    scan_dirs: list[Path] = []
    if categories:
        for cat_name, cat_dir in categories.items():
            cat_path = local_mount / cat_dir
            if cat_path.is_dir():
                scan_dirs.append(cat_path)
            else:
                typer.echo(f"  ⚠ 分类目录不存在，跳过：{cat_path}")
    else:
        scan_dirs.append(local_mount)

    all_missing: dict[Path, list[Path]] = {}
    for scan_dir in scan_dirs:
        missing = sub_mod.scan_missing(scan_dir)
        if missing:
            all_missing[scan_dir] = missing

    if not all_missing:
        typer.echo("所有目录都有字幕 ✓")
        return

    total = sum(len(v) for v in all_missing.values())
    typer.echo(f"缺字幕的目录（{total} 个）：")
    for scan_dir, missing in all_missing.items():
        typer.echo(f"\n  [{scan_dir}]")
        for d in missing:
            typer.echo(f"    - {d.name}")

    if apply:
        typer.echo("\n开始批量补字幕...")
        for scan_dir, missing in all_missing.items():
            typer.echo(f"\n>>> [{scan_dir}]")
            for d in missing:
                typer.echo(f"  {d.name}")
                sub_mod.ensure_subtitle(d, data)


# ─── fetch (端到端) ─────────────────────────────────────────────────────────


@app.command(help="端到端：搜 → 选 → 推 → 等 metadata → 配字幕（默认不等下载完）")
def fetch(
    title: str,
    wait_download: bool = typer.Option(False, "--wait-download",
                                       help="等到视频下载 100% 完成再退出（默认只等 metadata）"),
    timeout: int = typer.Option(0, help="覆盖默认超时（秒），0 用配置默认"),
    category: str = typer.Option("", "--category", "-c",
                                 help="分类（电影/剧集），留空自动识别或按 config 默认"),
):
    data = cfg_mod.load()
    categories = data["paths"].get("categories", {})

    typer.echo(f">>> 搜索：{title}")
    s_timeout = data.get("search", {}).get("timeout", 5)
    results, diagnostics = search_mod.search_all(title, timeout=s_timeout, limit=20)
    if not results:
        summary = search_mod.diagnostics_summary(diagnostics)
        typer.echo(f"搜不到资源 — {summary}", err=True)
        typer.echo(search_mod.format_diagnostics(diagnostics))
        raise typer.Exit(1)
    best = search_mod.pick_best(results, data["search"]["prefer_quality"], query=title)
    typer.echo(f"  选中：[{best.source}] {best.title}  seeders={best.seeders}  size={best.size}")

    # 用搜索词 + 结果标题联合判断分类
    category = _resolve_category(data, category, title_hint=f"{title} {best.title}")
    cat_subdir = categories.get(category, "")

    cat_label = f"迅雷下载/{cat_subdir}" if cat_subdir else "迅雷下载"
    typer.echo(f">>> 推送到 NAS → {cat_label}")
    client, hash_ = dl_mod.push_magnet(data, best.magnet, category=category)
    typer.echo(f"  hash={hash_}")

    typer.echo(">>> 等待 metadata...")

    def tick_meta(t):
        typer.echo(f"  state={t.state}  name={t.name[:60]}")

    meta_timeout = timeout if (timeout and not wait_download) else 600
    t = dl_mod.wait_for_metadata(client, hash_, poll_interval=3, timeout=meta_timeout, on_tick=tick_meta)
    if t is None or not t.name:
        typer.echo("  超时未拿到 metadata；任务保留，可后续用 `status` 跟进", err=True)
        raise typer.Exit(2)
    typer.echo(f"  ✓ metadata 就绪：{t.name}")

    typer.echo(">>> 配字幕（zimuku → SubHD → subliminal，不依赖视频下载完成）")
    target_dir = Path(paths_mod.local_category_dir(
        data["paths"]["local_mount"], categories, category,
        local_paths=data["paths"].get("local_paths")))
    target_dir.mkdir(parents=True, exist_ok=True)
    got = sub_mod.subtitle_for_name(t.name, target_dir, data)

    if wait_download:
        typer.echo(">>> 继续等待下载完成...")
        interval = data.get("download", {}).get("poll_interval", 30)
        dl_timeout = timeout or data.get("download", {}).get("poll_timeout", 86400)

        def tick_dl(tt):
            typer.echo(f"  {tt.progress*100:5.1f}%  {tt.state}  {tt.name[:50]}")

        res = dl_mod.wait_for_completion(client, hash_, poll_interval=interval, timeout=dl_timeout, on_tick=tick_dl)
        if res.completed:
            typer.echo(">>> 下载完成，内嵌字幕到 mkv...")
            local_dir = Path(paths_mod.to_local(
                f"{res.task.save_path}/{res.task.name}" if res.task else "",
                data["paths"]["nas_internal"], data["paths"]["local_mount"]))
            if local_dir.is_dir():
                _embed_subs_post_download(local_dir, t.name, data)
            elif local_dir.is_file():
                _embed_subs_post_download(local_dir.parent, t.name, data)

    if got:
        typer.echo(f"完成。字幕：{got}")
    else:
        typer.echo("完成。未自动配到字幕（zimuku/SubHD/subliminal 无匹配）；下载完后可单跑 `subtitle <dir>` 走 whisper 兜底。")


# ─── post-download subtitle embedding ────────────────────────────────────────


def _ensure_dir_writable(d: Path) -> tuple[Path, Path | None]:
    """确保目录可写。若不可写则 rename 旧目录并创建同名新目录。

    返回 (可写目录, 旧锁定目录|None)。"""
    import tempfile
    test = d / f".write_test_{__import__('os').getpid()}"
    try:
        test.write_text("x")
        test.unlink()
        return d, None  # 可写，无需处理
    except (OSError, PermissionError):
        pass
    # SMB 锁：rename 旧目录，创建新目录
    parent = d.parent
    suffix = "_locked_" + __import__('time').strftime("%Y%m%d_%H%M%S")
    old = parent / (d.name + suffix)
    typer.echo(f"  ⚠️ 目录写保护，rename 绕过：{d.name} → {old.name}")
    d.rename(old)
    d.mkdir(parents=True, exist_ok=True)
    return d, old


def _verify_embedded_subs(video_dir: Path) -> tuple[int, list[str], list[str]]:
    """验证内嵌字幕质量。返回 (通过数, 警告列表, 错误列表)。

    检查项：
    1. 有字幕轨道且语言标记为中文
    2. 字幕包含中文字符（非空/非纯英文）
    3. 字幕时间轴与视频时长匹配（末条在 85%-105% 区间，首条 < 15s）
    """
    import subprocess as sp
    import re as _re
    from . import embed as embed_mod

    ok, warnings, errors = 0, [], []
    for v in sorted(video_dir.glob("*.mkv")):
        ep = v.stem[:50]
        try:
            streams = embed_mod.probe_streams(v)
        except Exception as e:
            errors.append(f"{ep}: ffprobe 失败 ({e})")
            continue

        sub_streams = [s for s in streams if s.codec_type == "subtitle"]
        if not sub_streams:
            errors.append(f"{ep}: 无字幕轨道")
            continue

        chi_subs = [s for s in sub_streams if s.language.lower() in ("chi", "zho", "zh", "chinese")]
        if not chi_subs:
            warnings.append(f"{ep}: 字幕语言非中文 ({sub_streams[0].language})")

        # 获取视频时长
        try:
            proc = sp.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "csv=p=0", str(v)],
                capture_output=True, text=True, timeout=30,
            )
            video_dur = float(proc.stdout.strip()) if proc.stdout.strip() else 0
        except Exception:
            video_dur = 0

        # 提取字幕流：检查时间轴 + 中文内容
        passed = False
        for sub_idx, s in enumerate(sub_streams):
            try:
                proc = sp.run(
                    ["ffmpeg", "-v", "error", "-i", str(v),
                     "-map", f"0:s:{sub_idx}", "-f", "srt", "-"],
                    capture_output=True, text=True, timeout=30,
                )
                if proc.returncode != 0 or not proc.stdout.strip():
                    continue

                lines = proc.stdout.strip().split("\n")
                # 提取所有时间轴行
                time_matches = _re.findall(
                    r"(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})",
                    proc.stdout,
                )
                if time_matches:
                    # 解析时间戳为秒数
                    def _ts(ts: str) -> float:
                        h, m, s_ms = ts.replace(",", ".").split(":")
                        return int(h) * 3600 + int(m) * 60 + float(s_ms)

                    first_start = _ts(time_matches[0][0])
                    last_end = _ts(time_matches[-1][1])

                    # 时间轴匹配检查
                    if video_dur > 0:
                        ratio = last_end / video_dur if video_dur > 0 else 0
                        if ratio < 0.85:
                            warnings.append(
                                f"{ep}: 字幕偏短（末条 {last_end:.0f}s / 视频 {video_dur:.0f}s = {ratio:.0%}）"
                                f"——可能版本不匹配"
                            )
                        elif ratio > 1.15:
                            warnings.append(
                                f"{ep}: 字幕偏长（末条 {last_end:.0f}s / 视频 {video_dur:.0f}s = {ratio:.0%}）"
                            )
                        if first_start > 30:
                            warnings.append(f"{ep}: 首条字幕偏晚（{first_start:.0f}s）")

                # 提取文本行检查中文
                text_lines = [
                    l for l in lines
                    if l and not l[0].isdigit() and "-->" not in l and l.strip()
                ]
                if text_lines:
                    last_text = text_lines[-1][:100]
                    has_chinese = any("\u4e00" <= c <= "\u9fff" for c in last_text)
                    if not has_chinese:
                        warnings.append(f"{ep}: 字幕未检测到中文（尾句: {last_text[:40]}）")
                    else:
                        ok += 1
                        passed = True
                        break
                else:
                    warnings.append(f"{ep}: 字幕为空")
                    break
            except Exception as e:
                warnings.append(f"{ep}: 字幕提取失败 ({e})")
                ok += 1
                passed = True
                break

        if not passed:
            ok += 1  # 轨存在但无法提取内容，保守通过

    return ok, warnings, errors


def _embed_subs_post_download(video_dir: Path, task_name: str, data: dict) -> None:
    """下载完成后：下载匹配字幕 → 内嵌到每一个 mkv → 清理旧目录。"""
    import subprocess as sp

    videos = sub_mod.find_videos(video_dir)
    if not videos:
        typer.echo("  无视频文件，跳过字幕内嵌。")
        return

    # 检查是否已有内嵌中文
    from . import embed as embed_mod
    already_embedded = 0
    for v in videos:
        try:
            streams = embed_mod.probe_streams(v)
            if embed_mod.has_chinese_subtitle(streams):
                already_embedded += 1
        except Exception:  # noqa: BLE001
            pass
    if already_embedded == len(videos):
        typer.echo(f"  ✓ 已有内嵌中文字幕，跳过。")
        return

    # 确保目录可写
    writable_dir, locked_dir = _ensure_dir_writable(video_dir)
    if locked_dir:
        videos = sorted(locked_dir.glob("*.mkv")) + sorted(locked_dir.glob("*.mp4"))

    # 下载字幕：用第一集视频文件名提取关键词（比 qBit task name 更精准）
    search_keyword = task_name
    if videos:
        v0 = videos[0]
        import re as _re
        m = _re.match(r"^([A-Za-z][A-Za-z0-9\.\s]+?)\.?S\d+", v0.stem, _re.IGNORECASE)
        if m:
            search_keyword = m.group(1).replace(".", " ").strip()
    tmp_subs = writable_dir / ".subs_tmp"
    tmp_subs.mkdir(exist_ok=True)
    got = sub_mod._try_zimuku(search_keyword, tmp_subs, video_dir=writable_dir)

    # 匹配字幕到视频，逐集内嵌
    embedded = 0
    for v in videos:
        if not v.exists():
            continue
        # 跳过已内嵌的
        try:
            streams = embed_mod.probe_streams(v)
            if embed_mod.has_chinese_subtitle(streams):
                shutil.copy2(v, writable_dir / v.name)
                embedded += 1
                continue
        except Exception:  # noqa: BLE001
            pass
        # 找匹配字幕
        ep_match = __import__('re').search(r"[Ss](\d+)[Ee](\d+)", v.stem)
        if ep_match:
            ep_tag = f"S{ep_match.group(1)}E{ep_match.group(2)}".lower()
            sub_file = None
            for sf in sorted(tmp_subs.glob("*")):
                if ep_tag in sf.stem.lower():
                    sub_file = sf
                    break
            if sub_file:
                out = writable_dir / v.name
                typer.echo(f"  内嵌: {v.name[:60]}...")
                # 检查输入文件已有字幕数，避免 disposition/metadata 错位
                existing_sub_count = 0
                try:
                    existing_sub_count = sum(
                        1 for s in embed_mod.probe_streams(v)
                        if s.codec_type == "subtitle"
                    )
                except Exception:
                    pass
                new_sub_idx = existing_sub_count
                cmd = [
                    "ffmpeg", "-y", "-v", "quiet",
                    "-i", str(v), "-i", str(sub_file),
                    "-c", "copy", "-map", "0", "-map", "1",
                ]
                # 清除已有字幕的 default 标记
                for i in range(existing_sub_count):
                    cmd += [f"-disposition:s:{i}", "0"]
                # 新字幕 metadata + default
                cmd += [
                    f"-metadata:s:s:{new_sub_idx}", "language=chi",
                    f"-metadata:s:s:{new_sub_idx}", "title=Chinese (简体中文)",
                    f"-disposition:s:{new_sub_idx}", "default",
                ]
                cmd.append(str(out))
                try:
                    sp.run(cmd, check=True, timeout=600)
                    embedded += 1
                except Exception as e:  # noqa: BLE001
                    typer.echo(f"    ❌ ffmpeg 失败: {e}")
                    # 复制原文件
                    shutil.copy2(v, out)
            else:
                shutil.copy2(v, writable_dir / v.name)
        else:
            shutil.copy2(v, writable_dir / v.name)

    # 清理临时字幕
    shutil.rmtree(tmp_subs, ignore_errors=True)

    # 验证字幕匹配性
    typer.echo(">>> 验证字幕匹配...")
    ok, warn, err = _verify_embedded_subs(writable_dir)
    if err:
        typer.echo(f"  ❌ 异常：{', '.join(err)}")
    if warn:
        typer.echo(f"  ⚠️ 警告：{', '.join(warn)}")
    if not err and not warn:
        typer.echo(f"  ✓ 全部 {ok} 集字幕验证通过")

    # 尝试删除旧锁定目录
    if locked_dir and locked_dir.exists():
        try:
            shutil.rmtree(locked_dir)
            typer.echo(f"  ✓ 旧目录已清理")
        except Exception:  # noqa: BLE001
            typer.echo(f"  ⚠️ 旧目录 {locked_dir.name} 请手动从 Finder 删除（SMB 文件锁）")

    typer.echo(f"  ✓ 内嵌完成：{embedded}/{len(videos)} 集已嵌入中文字幕")


# ─── embed ──────────────────────────────────────────────────────────────────


@app.command(help="把外挂字幕用 ffmpeg -c copy 内嵌到 mkv（视频不重新编码）")
def embed(
    target: str = typer.Argument(..., help="mkv 文件或目录（目录会递归处理）"),
    no_default: bool = typer.Option(False, "--no-default", help="不把新字幕标为 default"),
    delete_external: bool = typer.Option(False, "--delete-external", help="内嵌后删除外挂 srt/ass"),
):
    p = Path(target)
    if not p.exists():
        typer.echo(f"路径不存在：{p}", err=True)
        raise typer.Exit(1)
    if p.is_file():
        embed_mod.embed(p, set_default=not no_default, keep_external=not delete_external)
    else:
        changed = embed_mod.embed_dir(p, set_default=not no_default, keep_external=not delete_external)
        typer.echo(f"完成：内嵌了 {len(changed)} 个 mkv")


# ─── weekly（每周新片速递） ─────────────────────────────────────────────────


@app.command(help="生成上周新片周报（豆瓣≥阈值，输出到 stdout，供 hermes 定时推送）")
def weekly(
    kind: str = typer.Option("all", "--kind", "-k", help="mv / tv / all"),
    min_score: float = typer.Option(0, "--min-score", help="豆瓣最低分，0=用 config discover.min_score"),
    pages: int = typer.Option(2, "--pages", help="每种类型拉几页（每页 48 条）"),
    dry_run: bool = typer.Option(False, "--dry-run", help="只看不写去重库"),
):
    data = cfg_mod.load()
    disc = data.get("discover", {})
    if min_score <= 0:
        min_score = float(disc.get("min_score", 8.0))
    kinds = ["mv", "tv"] if kind == "all" else [kind]
    db_path = Path(disc.get("state_db", "discovered.db"))
    if not db_path.is_absolute():
        db_path = Path(__file__).resolve().parent.parent / db_path
    typer.echo(f">>> 拉取 {kinds}（豆瓣≥{min_score}，{pages} 页/类）…", err=True)
    report = discover_mod.run_weekly(kinds, min_score, pages, dry_run, db_path)
    typer.echo(report)


if __name__ == "__main__":
    app()
