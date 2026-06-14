"""把外挂字幕用 ffmpeg `-c copy` 内嵌到视频容器（视频/音频不重新编码）。

支持容器：mkv / mp4。
- mkv：原生支持 srt/ass/ssa，全部 `-c copy`
- mp4：仅原生支持 mov_text（srt 风格）。
  * 外挂 .srt 直接转 mov_text
  * 外挂 .ass/.ssa 先用 ffmpeg 转成 srt（丢弃样式），再转 mov_text
- avi：不支持嵌入（容器限制），跳过

安全：tmp 文件先写好 → 原子 rename 覆盖（失败保留原文件）。
"""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

VIDEO_EXTS = {".mkv", ".mp4"}
SUBTITLE_EXTS = {".srt", ".ass", ".ssa"}
CHINESE_LANG_TAGS = {"chi", "zho", "zh", "chinese", "中文", "简体", "繁体"}


@dataclass
class StreamInfo:
    index: int
    codec_type: str
    codec_name: str
    language: str
    title: str


def probe_streams(video: Path) -> list[StreamInfo]:
    proc = subprocess.run(
        ["ffprobe", "-v", "error",
         "-show_entries", "stream=index,codec_type,codec_name",
         "-show_entries", "stream_tags=language,title",
         "-of", "json", str(video)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffprobe 失败：{proc.stderr.strip()[:200]}")
    data = json.loads(proc.stdout)
    out: list[StreamInfo] = []
    for s in data.get("streams", []):
        tags = s.get("tags") or {}
        out.append(StreamInfo(
            index=int(s["index"]),
            codec_type=s.get("codec_type", ""),
            codec_name=s.get("codec_name", ""),
            language=(tags.get("language") or "").lower(),
            title=tags.get("title", ""),
        ))
    return out


def has_chinese_subtitle(streams: list[StreamInfo]) -> bool:
    for s in streams:
        if s.codec_type != "subtitle":
            continue
        if s.language in CHINESE_LANG_TAGS:
            return True
        if any(tag in s.title.lower() for tag in ("chinese", "中文", "简体", "繁体", "chs", "cht")):
            return True
    return False


def find_external_subtitle(video: Path) -> Path | None:
    """同目录平铺 + Subs/ 子目录里挑配对的外挂字幕（中文优先）。"""
    candidates: list[Path] = []
    parent = video.parent
    for p in parent.iterdir():
        if p.is_file() and p.suffix.lower() in SUBTITLE_EXTS:
            candidates.append(p)
    for sub_dir_name in ("Subs", "subs", "字幕", "Sub", "sub"):
        sub_dir = parent / sub_dir_name
        if sub_dir.is_dir():
            for p in sub_dir.iterdir():
                if p.is_file() and p.suffix.lower() in SUBTITLE_EXTS:
                    candidates.append(p)
    if not candidates:
        return None

    def _chinese_score(p: Path) -> int:
        low = p.name.lower()
        # 明确简体 > 繁体 > 中文 hint > 通用
        if re.search(r"\.(zh-cn|zh-hans|chs|sc)\.", low) or "简体" in p.name or "Simplified" in p.name:
            return 5
        if re.search(r"\.(zh|chi|zho)\.", low) and ("繁" not in p.name and "trad" not in low and "cht" not in low and "tc" not in low):
            return 4
        if re.search(r"\.(cht|tc|zh-tw|zh-hant)\.", low) or "繁体" in p.name or "Traditional" in p.name:
            return 3
        if any(t in p.name for t in ("中文", "国语", "中字", "汉语", "中英")):
            return 2
        # 文件名含 >=2 个中文字符（含 zmk.pw / 中文站点名）→ 视作中文字幕（zmk 是字幕库通用前缀）
        if sum(1 for c in p.name if "一" <= c <= "鿿") >= 2:
            return 1
        return 0
    candidates.sort(key=_chinese_score, reverse=True)
    # 至少要 Chinese 得分>0，否则视作没找到中文字幕（避免烧错语言）
    if _chinese_score(candidates[0]) == 0:
        return None
    return candidates[0]


def _convert_ass_to_srt(ass: Path, dest: Path) -> bool:
    """用 ffmpeg 把 .ass/.ssa 转成 .srt（丢弃样式）。"""
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
           "-i", str(ass), str(dest)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def _ensure_utf8(sub: Path, tmpdir: Path) -> Path:
    """确保字幕是 UTF-8 编码。若不是，转码到 tmpdir，返回新路径。"""
    raw = sub.read_bytes()
    # BOM 检测
    if raw[:3] == b"\xef\xbb\xbf":
        return sub
    # 试 UTF-8（严格）
    try:
        raw.decode("utf-8")
        return sub
    except UnicodeDecodeError:
        pass
    # 依次尝试中文常见编码
    for enc in ("gb18030", "gbk", "big5", "utf-16", "utf-16-le", "utf-16-be"):
        try:
            text = raw.decode(enc)
            # 重写为 UTF-8（带 BOM 让 ffmpeg 100% 识别）
            converted = tmpdir / (sub.stem + ".utf8" + sub.suffix)
            converted.write_text(text, encoding="utf-8-sig")
            print(f"[embed] 字幕编码 {enc} → UTF-8 转换：{sub.name}")
            return converted
        except (UnicodeDecodeError, UnicodeError):
            continue
    # 全失败，让 ffmpeg 自己报错
    return sub


def _embed_mkv(mkv: Path, srt: Path, set_default: bool, streams: list[StreamInfo]) -> Path:
    """重打包 mkv，返回临时输出路径。"""
    existing_sub_count = sum(1 for s in streams if s.codec_type == "subtitle")
    new_sub_idx = existing_sub_count
    tmp_out = mkv.with_suffix(".embedding.tmp.mkv")
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(mkv), "-i", str(srt),
        "-map", "0", "-map", "1",
        "-c", "copy",
        f"-metadata:s:s:{new_sub_idx}", "language=zho",
        f"-metadata:s:s:{new_sub_idx}", f"title=中文 ({srt.suffix.lstrip('.').upper()})",
    ]
    if set_default:
        for i in range(existing_sub_count):
            cmd += [f"-disposition:s:{i}", "0"]
        cmd += [f"-disposition:s:{new_sub_idx}", "default"]
    cmd.append(str(tmp_out))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60 * 30)
    except subprocess.TimeoutExpired:
        if tmp_out.exists():
            tmp_out.unlink(missing_ok=True)
        raise RuntimeError("ffmpeg 内嵌超时（30 分钟）")
    if proc.returncode != 0:
        if tmp_out.exists():
            tmp_out.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg 失败：{proc.stderr.strip()[:300]}")
    return tmp_out


def _embed_mp4(mp4: Path, srt: Path, set_default: bool, streams: list[StreamInfo],
               tmpdir: Path) -> Path:
    """重打包 mp4：先把非 srt 字幕转 srt，再用 mov_text muxer。"""
    if srt.suffix.lower() != ".srt":
        converted = tmpdir / "converted.zh.srt"
        if not _convert_ass_to_srt(srt, converted):
            raise RuntimeError(f"无法把 {srt.name} 转 srt 给 mp4 用")
        srt = converted

    existing_sub_count = sum(1 for s in streams if s.codec_type == "subtitle")
    new_sub_idx = existing_sub_count
    tmp_out = mp4.with_suffix(".embedding.tmp.mp4")
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(mp4), "-i", str(srt),
        "-map", "0", "-map", "1",
        "-c:v", "copy", "-c:a", "copy",
        "-c:s", "mov_text",
        f"-metadata:s:s:{new_sub_idx}", "language=zho",
        f"-metadata:s:s:{new_sub_idx}", f"title=中文",
    ]
    if set_default:
        for i in range(existing_sub_count):
            cmd += [f"-disposition:s:{i}", "0"]
        cmd += [f"-disposition:s:{new_sub_idx}", "default"]
    cmd.append(str(tmp_out))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60 * 30)
    except subprocess.TimeoutExpired:
        if tmp_out.exists():
            tmp_out.unlink(missing_ok=True)
        raise RuntimeError("ffmpeg 内嵌超时（30 分钟）")
    if proc.returncode != 0:
        if tmp_out.exists():
            tmp_out.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg 失败：{proc.stderr.strip()[:300]}")
    return tmp_out


def embed(video: Path, srt: Path | None = None, set_default: bool = True,
          keep_external: bool = True) -> bool:
    ext = video.suffix.lower()
    if ext not in VIDEO_EXTS:
        print(f"[embed] 跳过：{video.name} 容器 {ext} 不支持内嵌（仅 mkv/mp4）")
        return False

    streams = probe_streams(video)
    if has_chinese_subtitle(streams):
        print(f"[embed] 跳过：{video.name} 已含中文字幕轨道")
        return False

    if srt is None:
        srt = find_external_subtitle(video)
    if srt is None or not srt.exists():
        print(f"[embed] 跳过：{video.name} 找不到中文外挂字幕")
        return False

    print(f"[embed] 重打包：{video.name}  +  {srt.name}")
    with tempfile.TemporaryDirectory() as tmpd:
        tmpdir = Path(tmpd)
        # 保证字幕是 UTF-8，否则 ffmpeg 解码会失败
        srt_for_mux = _ensure_utf8(srt, tmpdir)
        if ext == ".mkv":
            tmp_out = _embed_mkv(video, srt_for_mux, set_default, streams)
        else:  # .mp4
            tmp_out = _embed_mp4(video, srt_for_mux, set_default, streams, tmpdir)

        backup = video.with_suffix(video.suffix + ".bak")
        video.rename(backup)
        try:
            tmp_out.rename(video)
        except Exception:
            backup.rename(video)
            raise
        backup.unlink(missing_ok=True)

    if not keep_external:
        srt.unlink(missing_ok=True)

    print(f"[embed] ✓ 完成：{video.name}")
    return True


def embed_dir(directory: Path, **kw) -> list[Path]:
    changed: list[Path] = []
    targets: list[Path] = []
    for ext in VIDEO_EXTS:
        targets.extend(directory.rglob(f"*{ext}"))
    for p in sorted(set(targets)):
        if "sample" in p.name.lower():
            continue
        # 跳过临时文件
        if ".embedding.tmp." in p.name or p.name.endswith(".bak"):
            continue
        try:
            if embed(p, **kw):
                changed.append(p)
        except Exception as e:
            print(f"[embed] {p.name} 失败：{e}")
    return changed
