"""字幕兜底：SubHD（opencli adapter）→ subliminal → whisper 本地生成。"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import Any

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".wmv", ".flv", ".webm", ".ts"}
SUBTITLE_EXTS = {".srt", ".ass", ".ssa", ".vtt", ".sub"}
ARCHIVE_EXTS = {".zip", ".rar", ".7z"}


def _is_archive_magic(data: bytes) -> str | None:
    """检测 bytes magic header，返回 'zip' / 'rar' / '7z' / None。"""
    if data[:2] == b"PK":
        return "zip"
    if data[:4] == b"Rar!":
        return "rar"
    if data[:6] == b"\x37\x7a\xbc\xaf\x27\x1c":
        return "7z"
    return None


def _extract_archive(archive_path: Path, dest_dir: Path) -> list[Path]:
    """解压压缩包，返回提取出的 srt/ass/ssa 文件路径列表。"""
    dest_dir.mkdir(parents=True, exist_ok=True)
    with archive_path.open("rb") as f:
        magic = _is_archive_magic(f.read(16))
    extracted: list[Path] = []
    try:
        if magic == "zip":
            with zipfile.ZipFile(archive_path) as z:
                z.extractall(dest_dir)
        elif magic == "7z":
            import py7zr  # type: ignore
            with py7zr.SevenZipFile(archive_path) as z:
                z.extractall(dest_dir)
        elif magic == "rar":
            import rarfile  # type: ignore
            with rarfile.RarFile(archive_path) as z:
                z.extractall(dest_dir)
        else:
            print(f"[subtitle] 未知压缩格式（{archive_path.name}）")
            return []
    except Exception as e:  # noqa: BLE001
        print(f"[subtitle] 解压 {archive_path.name} 失败：{e}")
        return []
    for p in dest_dir.rglob("*"):
        if p.is_file() and p.suffix.lower() in SUBTITLE_EXTS:
            extracted.append(p)
    return extracted


def _try_zimuku(filename: str, target_dir: Path) -> list[Path]:
    """调 opencli zimuku adapter：search → 选最匹配 → download → 解压。"""
    if not shutil.which("opencli"):
        return []
    stem = Path(filename).stem
    import re

    # 中文关键词优先（zimuku 主要收录中文字幕，按中文标题索引）
    m = re.search(r"[一-鿿][一-鿿，：·、！？]+", stem)
    if m and sum(1 for c in m.group(0) if "一" <= c <= "鿿") >= 2:
        keyword = m.group(0)
    else:
        m2 = re.match(r"^([A-Za-z][A-Za-z0-9\.\s]+?)\.?\d{4}", stem)
        keyword = m2.group(1).replace(".", " ").strip() if m2 else stem

    print(f"[subtitle][zimuku] 搜索：{keyword}")
    try:
        proc = subprocess.run(
            ["opencli", "zimuku", "search", keyword, "--limit", "10", "-f", "json"],
            capture_output=True, text=True, timeout=180,
        )
    except subprocess.TimeoutExpired:
        print("[subtitle][zimuku] 搜索超时")
        return []
    if proc.returncode != 0:
        print(f"[subtitle][zimuku] 搜索失败：{proc.stderr.strip()[:200]}")
        return []
    try:
        candidates = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    if not candidates:
        print("[subtitle][zimuku] 无候选字幕")
        return []

    # zimuku 已按简中→繁中→中文→下载量排序，直接 top-3 尝试
    target_dir.mkdir(parents=True, exist_ok=True)
    for cand in candidates[:3]:
        did = cand.get("detail_id")
        if not did:
            continue
        print(f"[subtitle][zimuku] 尝试下载：[{did}] {cand.get('title','')[:60]}")
        with tempfile.TemporaryDirectory() as tmpd:
            tmpd_path = Path(tmpd)
            out_path = tmpd_path / f"zimuku_{did}.bin"
            try:
                proc = subprocess.run(
                    ["opencli", "zimuku", "download", str(did), "--out", str(out_path), "-f", "json"],
                    capture_output=True, text=True, timeout=240,
                    env={**__import__("os").environ, "OPENCLI_BROWSER_COMMAND_TIMEOUT": "240000"},
                )
            except subprocess.TimeoutExpired:
                print(f"[subtitle][zimuku]   下载超时 {did}")
                continue
            if proc.returncode != 0:
                print(f"[subtitle][zimuku]   下载失败：{proc.stderr.strip()[:150]}")
                continue
            if not out_path.exists():
                continue
            with out_path.open("rb") as f:
                magic = _is_archive_magic(f.read(16))
            if magic:
                extracted = _extract_archive(out_path, tmpd_path / "ex")
                if not extracted:
                    continue
                srts = [p for p in extracted if p.suffix.lower() == ".srt"]
                pick = (srts or extracted)[0]
            else:
                pick = out_path
            video_stem = Path(filename).stem
            ext = pick.suffix.lower() if pick.suffix.lower() in SUBTITLE_EXTS else ".srt"
            final = target_dir / f"{video_stem}.zh{ext}"
            shutil.copyfile(pick, final)
            print(f"[subtitle][zimuku]   ✓ 落地：{final}")
            return [final]
    return []


def _try_subhd(filename: str, target_dir: Path) -> list[Path]:
    """调 opencli subhd adapter：search → 自动选最匹配 → download → 解压。"""
    if not shutil.which("opencli"):
        return []
    # 取文件名（去扩展名）做关键词
    stem = Path(filename).stem
    import re

    # 中文片名提取：含中文/中文标点，至少 2 个中文字符；停在 . [ ( 空格 或英文/数字前
    m = re.search(r"[一-鿿][一-鿿，：·、！？]+", stem)
    if m and sum(1 for c in m.group(0) if "一" <= c <= "鿿") >= 2:
        keyword = m.group(0)
    else:
        # 取首段连续英文+数字主标题
        m2 = re.match(r"^([A-Za-z][A-Za-z0-9\.\s]+?)\.?\d{4}", stem)
        keyword = m2.group(1).replace(".", " ").strip() if m2 else stem

    print(f"[subtitle][SubHD] 搜索：{keyword}")
    try:
        proc = subprocess.run(
            ["opencli", "subhd", "search", keyword, "--limit", "10", "-f", "json"],
            capture_output=True, text=True, timeout=120,
        )
    except subprocess.TimeoutExpired:
        print("[subtitle][SubHD] 搜索超时")
        return []
    if proc.returncode != 0:
        print(f"[subtitle][SubHD] 搜索失败：{proc.stderr.strip()[:200]}")
        return []
    try:
        candidates = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    if not candidates:
        print("[subtitle][SubHD] 无候选字幕")
        return []

    # 按文件名相似度 + 简体中文优先 排序
    def _score(c: dict[str, Any]) -> tuple[int, int]:
        title = (c.get("title") or "").lower()
        fname = filename.lower()
        # 共同 token 数（粗略匹配）
        toks = set(re.findall(r"[a-z0-9]+", fname)) & set(re.findall(r"[a-z0-9]+", title))
        chs = 1 if "简" in (c.get("title") or "") + (c.get("language") or "") else 0
        return (chs, len(toks))

    candidates.sort(key=_score, reverse=True)

    target_dir.mkdir(parents=True, exist_ok=True)
    # 尝试 top-3：第一个能拿到 srt/ass 内容的就行
    for cand in candidates[:3]:
        sid = cand.get("sid")
        if not sid:
            continue
        print(f"[subtitle][SubHD] 尝试下载：[{sid}] {cand.get('title','')[:60]}")
        with tempfile.TemporaryDirectory() as tmpd:
            tmpd_path = Path(tmpd)
            # adapter 下载文件名由 CDN 决定；让它落 tmp 后再处理
            out_path = tmpd_path / f"subhd_{sid}.bin"
            try:
                proc = subprocess.run(
                    ["opencli", "subhd", "download", sid, "--out", str(out_path), "-f", "json"],
                    capture_output=True, text=True, timeout=180,
                    env={**__import__("os").environ, "OPENCLI_BROWSER_COMMAND_TIMEOUT": "180000"},
                )
            except subprocess.TimeoutExpired:
                print(f"[subtitle][SubHD]   下载超时 {sid}")
                continue
            if proc.returncode != 0:
                print(f"[subtitle][SubHD]   下载失败：{proc.stderr.strip()[:150]}")
                continue
            if not out_path.exists():
                continue
            # 判断：直接是字幕文件 / 压缩包
            with out_path.open("rb") as f:
                magic = _is_archive_magic(f.read(16))
            if magic:
                extracted = _extract_archive(out_path, tmpd_path / "ex")
                if not extracted:
                    continue
                # 把最大的（或第一个 .srt 优先）复制到 target_dir，文件名跟视频对齐
                srts = [p for p in extracted if p.suffix.lower() == ".srt"]
                pick = (srts or extracted)[0]
            else:
                pick = out_path
            # 命名：和视频文件名对齐，加 .zh 中缀让 embed 自动识别为中文
            video_stem = Path(filename).stem
            ext = pick.suffix.lower() if pick.suffix.lower() in SUBTITLE_EXTS else ".srt"
            final = target_dir / f"{video_stem}.zh{ext}"
            shutil.copyfile(pick, final)
            print(f"[subtitle][SubHD]   ✓ 落地：{final}")
            return [final]
    return []


def find_videos(movie_dir: Path) -> list[Path]:
    """返回该目录下所有视频文件（递归 2 层）。"""
    out: list[Path] = []
    for p in movie_dir.rglob("*"):
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS:
            # 跳过样本片
            if "sample" in p.name.lower():
                continue
            out.append(p)
    return out


def existing_subtitles(movie_dir: Path) -> list[Path]:
    out: list[Path] = []
    for p in movie_dir.rglob("*"):
        if p.is_file() and p.suffix.lower() in SUBTITLE_EXTS:
            out.append(p)
    return out


def has_subtitle(movie_dir: Path) -> bool:
    return bool(existing_subtitles(movie_dir))


def _download_subliminal(video: Path, languages: list[str]) -> Path | None:
    """用 subliminal 下载首个匹配语言的字幕。返回新生成的字幕路径或 None。"""
    try:
        from babelfish import Language  # type: ignore
        from subliminal import Video, download_best_subtitles, save_subtitles, region  # type: ignore
    except Exception:  # noqa: BLE001
        return None

    # subliminal 用 dogpile.cache，第一次跑要初始化
    if not region.is_configured:
        region.configure("dogpile.cache.memory")

    try:
        v = Video.fromname(video.name)
    except Exception:  # noqa: BLE001
        return None

    for lang_code in languages:
        try:
            lang = Language.fromietf(lang_code)
        except Exception:  # noqa: BLE001
            try:
                lang = Language(lang_code)
            except Exception:  # noqa: BLE001
                continue
        try:
            subs = download_best_subtitles([v], {lang})
        except Exception:  # noqa: BLE001
            continue
        sublist = subs.get(v) or []
        if sublist:
            save_subtitles(v, sublist, directory=str(video.parent))
            # subliminal 保存为 {basename}.{lang}.srt
            candidate = video.parent / f"{video.stem}.{lang.alpha2}.srt"
            if candidate.exists():
                return candidate
            # fallback：找最近改动的 .srt
            srts = sorted(video.parent.glob("*.srt"), key=lambda p: p.stat().st_mtime, reverse=True)
            if srts:
                return srts[0]
    return None


def _whisper_generate(video: Path, script: str, model: str, language: str) -> Path | None:
    """调 transcribe.py 生成 srt。"""
    python = "/Users/stringzhao/workspace/martin/.venv/bin/python"
    cmd = [
        python, script, str(video),
        "--model", model,
        "--language", language,
        "--output-format", "srt",
        "--output-dir", str(video.parent),
    ]
    try:
        subprocess.run(cmd, check=True, timeout=60 * 60 * 4)  # 4h cap
    except Exception as e:  # noqa: BLE001
        print(f"[subtitle] whisper 失败：{e}")
        return None
    # transcribe.py 输出 {video_stem}.srt
    out = video.parent / f"{video.stem}.srt"
    return out if out.exists() else None


def ensure_subtitle(movie_dir: Path, cfg: dict[str, Any], force: bool = False) -> list[Path]:
    """为目录下每个视频补字幕。返回新生成的字幕路径列表。"""
    if not movie_dir.exists():
        raise FileNotFoundError(f"目录不存在：{movie_dir}")

    videos = find_videos(movie_dir)
    if not videos:
        print(f"[subtitle] {movie_dir} 无视频文件")
        return []

    prefer = cfg["subtitle"]["prefer"]
    zh_langs = [l for l in prefer if l.lower().startswith("zh")]
    en_langs = [l for l in prefer if l.lower().startswith("en")]
    use_whisper = bool(cfg["subtitle"].get("whisper_fallback"))
    whisper_script = cfg["subtitle"].get("whisper_script")
    whisper_model = cfg["subtitle"].get("whisper_model", "large-v3-turbo")

    generated: list[Path] = []
    for v in videos:
        if not force and any(s for s in existing_subtitles(v.parent) if v.stem in s.name):
            print(f"[subtitle] 已存在：{v.name}")
            continue

        # 1) 中文
        if zh_langs:
            got = _download_subliminal(v, zh_langs)
            if got:
                print(f"[subtitle] 中文字幕已下载：{got.name}")
                generated.append(got)
                continue

        # 2) 英文
        if en_langs:
            got = _download_subliminal(v, en_langs)
            if got:
                print(f"[subtitle] 英文字幕已下载：{got.name}")
                generated.append(got)
                continue

        # 3) Whisper 本地
        if use_whisper and whisper_script and Path(whisper_script).exists():
            print(f"[subtitle] 在线源失败，启动 whisper 转写：{v.name}")
            got = _whisper_generate(v, whisper_script, whisper_model, "zh")
            if got:
                print(f"[subtitle] whisper 已生成：{got.name}")
                generated.append(got)
                continue

        print(f"[subtitle] 三级兜底全部失败：{v.name}")

    return generated


_EMBEDDED_HINTS = (
    "国语中字", "中字", "简繁中字", "内嵌", "内封", "hardcoded", "hardsub",
    "简体中字", "繁体中字", "中英双字", "双语", "中英", "CHS&ENG", "CHS-ENG",
)


def subtitle_for_name(filename: str, output_dir: Path, cfg: dict[str, Any]) -> Path | None:
    """根据"虚拟"文件名（来自 qBit task.name）配字幕，不依赖视频文件已下载完。

    顺序：内嵌字幕预检（按文件名关键词跳过） → SubHD → subliminal → 跳过 whisper。
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # 0) 内嵌字幕预检：文件名暗示已带中字 → 跳过外挂搜索
    low = filename.lower()
    for hint in _EMBEDDED_HINTS:
        if hint in filename or hint.lower() in low:
            print(f"[subtitle] 文件名含「{hint}」，判定为内嵌字幕，跳过外挂搜索。")
            return None

    # 1) zimuku（中文字幕主源，Yunsuo WAF 自动绕过）
    got_list = _try_zimuku(filename, output_dir)
    if got_list:
        return got_list[0]

    # 2) SubHD（中文备源）
    got_list = _try_subhd(filename, output_dir)
    if got_list:
        return got_list[0]

    # 3) subliminal 兜底
    placeholder = output_dir / filename
    prefer = cfg["subtitle"]["prefer"]
    zh_langs = [l for l in prefer if l.lower().startswith("zh")]
    en_langs = [l for l in prefer if l.lower().startswith("en")]

    for langs, label in [(zh_langs, "中文"), (en_langs, "英文")]:
        if not langs:
            continue
        got = _download_subliminal(placeholder, langs)
        if got:
            print(f"[subtitle][subliminal] {label}字幕已下载：{got}")
            return got

    print("[subtitle] SubHD + subliminal 均失败；视频还在下载，跳过 whisper 兜底。")
    return None


def scan_missing(local_mount: Path) -> list[Path]:
    """扫描根目录下缺字幕的电影目录。"""
    out: list[Path] = []
    if not local_mount.exists():
        raise FileNotFoundError(f"目录不存在：{local_mount}")
    for sub in sorted(local_mount.iterdir()):
        if not sub.is_dir():
            continue
        if find_videos(sub) and not has_subtitle(sub):
            out.append(sub)
    return out
