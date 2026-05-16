#!/Users/stringzhao/workspace/martin/.venv/bin/python3
"""whisper 语音转写 CLI — 支持 mlx-whisper / faster-whisper / openai-whisper 三引擎"""

import argparse
import json
import os
import sys
import time
from pathlib import Path


MLX_REPO_MAP = {
    "tiny": "mlx-community/whisper-tiny", "tiny.en": "mlx-community/whisper-tiny.en",
    "base": "mlx-community/whisper-base", "base.en": "mlx-community/whisper-base.en",
    "small": "mlx-community/whisper-small", "small.en": "mlx-community/whisper-small.en",
    "medium": "mlx-community/whisper-medium", "medium.en": "mlx-community/whisper-medium.en",
    "large": "mlx-community/whisper-large-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
}


def transcribe_mlx(audio_path: str, model_name: str, language: str, output_dir: str, word_timestamps: bool = False, initial_prompt: str = None):
    """使用 mlx-whisper 引擎转写（Apple MLX GPU/ANE 加速）"""
    import mlx_whisper

    repo = MLX_REPO_MAP.get(model_name, f"mlx-community/whisper-{model_name}")
    print(f"[mlx-whisper] 加载模型 '{model_name}' (repo: {repo}, word_ts={word_timestamps}, prompt={bool(initial_prompt)}) ...")
    lang = None if language == "auto" else language
    kwargs = dict(path_or_hf_repo=repo, language=lang, word_timestamps=word_timestamps)
    if initial_prompt:
        kwargs["initial_prompt"] = initial_prompt
    result = mlx_whisper.transcribe(audio_path, **kwargs)
    detected_lang = result.get("language") or lang or "auto"
    return result["text"], result.get("segments", []), detected_lang


def transcribe_faster(audio_path: str, model_name: str, language: str, output_dir: str, word_timestamps: bool = False, initial_prompt: str = None):
    """使用 faster-whisper 引擎转写（CTranslate2 后端）"""
    import os as _os
    from faster_whisper import WhisperModel

    model_size_map = {"large": "large-v3"}
    size = model_size_map.get(model_name, model_name)
    lang = None if language == "auto" else language
    # int8_float32 = int8 weights + float32 accumulator: better precision than
    # pure int8 on Apple Silicon (float16 is unsupported by CTranslate2 on macOS).
    compute_type = _os.environ.get("FASTER_WHISPER_COMPUTE", "int8_float32" if size.startswith("large") else "int8")

    print(f"[faster-whisper] 加载模型 '{size}' (device=auto, compute_type={compute_type}, word_ts={word_timestamps}, prompt={bool(initial_prompt)}) ...")
    model = WhisperModel(size, device="auto", compute_type=compute_type)
    # Use VAD filter to skip silent/non-speech segments — drastically reduces hallucinations
    kw = dict(
        language=lang,
        word_timestamps=word_timestamps,
        vad_filter=True,
        vad_parameters=dict(min_silence_duration_ms=500),
    )
    if initial_prompt:
        kw["initial_prompt"] = initial_prompt
    segments, info = model.transcribe(audio_path, **kw)
    print(f"[faster-whisper] 检测语言: {info.language} (概率: {info.language_probability:.2f})")

    text_parts = []
    segs = []
    for seg in segments:
        text_parts.append(seg.text)
        item = {"start": seg.start, "end": seg.end, "text": seg.text}
        if word_timestamps and getattr(seg, "words", None):
            item["words"] = [
                {
                    "start": w.start,
                    "end": w.end,
                    "word": w.word,
                    "probability": getattr(w, "probability", None),
                }
                for w in seg.words
            ]
        segs.append(item)
    return "".join(text_parts), segs, info.language


def transcribe_whisper(audio_path: str, model_name: str, language: str, output_dir: str, word_timestamps: bool = False, initial_prompt: str = None):
    """使用 openai-whisper 引擎转写（PyTorch 后端）"""
    import whisper

    print(f"[openai-whisper] 加载模型 '{model_name}' (word_ts={word_timestamps}, prompt={bool(initial_prompt)}) ...")
    lang = None if language == "auto" else language
    model = whisper.load_model(model_name)
    kw = dict(language=lang, word_timestamps=word_timestamps)
    if initial_prompt:
        kw["initial_prompt"] = initial_prompt
    result = model.transcribe(audio_path, **kw)
    return result["text"], result.get("segments", []), result.get("language") or lang or "auto"


ENGINES = {"mlx": transcribe_mlx, "faster": transcribe_faster, "whisper": transcribe_whisper}


def _ts(seconds: float, dot: bool = False) -> str:
    h, r = divmod(int(seconds), 3600)
    m, s = divmod(r, 60)
    ms = int((seconds % 1) * 1000)
    sep = "." if dot else ","
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


def format_txt(text: str, segments: list) -> str:
    return text


def format_srt(text: str, segments: list) -> str:
    lines = []
    for i, seg in enumerate(segments, 1):
        lines.append(f"{i}\n{_ts(seg['start'])} --> {_ts(seg['end'])}\n{seg['text'].strip()}\n")
    return "\n".join(lines)


def format_vtt(text: str, segments: list) -> str:
    lines = ["WEBVTT", ""]
    for i, seg in enumerate(segments, 1):
        lines.append(f"{i}\n{_ts(seg['start'], dot=True)} --> {_ts(seg['end'], dot=True)}\n{seg['text'].strip()}\n")
    return "\n".join(lines)


def format_json_obj(text: str, segments: list, language: str = "auto") -> str:
    out_segs = []
    for s in segments:
        seg = {"start": s["start"], "end": s["end"], "text": s["text"]}
        if "words" in s and s["words"]:
            seg["words"] = s["words"]
        out_segs.append(seg)
    return json.dumps({
        "text": text,
        "language": language,
        "segments": out_segs,
    }, ensure_ascii=False, indent=2)


FORMATTERS = {"txt": format_txt, "srt": format_srt, "vtt": format_vtt, "json": format_json_obj}


def main():
    parser = argparse.ArgumentParser(
        description="whisper 语音转写 CLI — M4 Max / Metal GPU 高性能模式",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s audio.wav                                    # 默认 mlx + tiny + zh
  %(prog)s audio.wav --engine mlx --model base          # mlx-whisper base 模型
  %(prog)s audio.wav --engine faster --model large-v3   # faster-whisper large-v3
  %(prog)s audio.wav --output-format srt                # SRT 字幕输出
  %(prog)s audio.wav --language en --output-format vtt  # 英语 VTT 字幕
        """,
    )
    parser.add_argument("audio", help="输入音频文件路径")
    parser.add_argument("--engine", choices=["mlx", "faster", "whisper"], default="mlx",
                        help="推理引擎（默认: mlx）")
    parser.add_argument("--model", default="tiny",
                        choices=["tiny", "tiny.en", "base", "base.en", "small", "small.en",
                                 "medium", "medium.en", "large-v3", "large-v3-turbo", "large"],
                        help="模型尺寸（默认: tiny）")
    parser.add_argument("--language", choices=["zh", "en", "auto"], default="zh",
                        help="语言（默认: zh）")
    parser.add_argument("--output-format", choices=["txt", "srt", "vtt", "json"], default="txt",
                        dest="output_format", help="输出格式（默认: txt）")
    parser.add_argument("--output-dir", default=".", dest="output_dir",
                        help="输出目录（默认: 当前目录）")
    parser.add_argument("--word-timestamps", action="store_true", dest="word_timestamps",
                        help="启用词级时间戳（仅 JSON 输出有意义；mlx/faster/openai 三引擎均支持）")
    parser.add_argument("--initial-prompt", default=None, dest="initial_prompt",
                        help="initial_prompt：领域上下文 / 专有名词列表，可提升识别精度")

    args = parser.parse_args()
    if not os.path.isfile(args.audio):
        print(f"错误: 音频文件不存在: {args.audio}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)

    print(f"引擎: {args.engine} | 模型: {args.model} | 语言: {args.language}")
    print(f"输入: {args.audio}")

    start = time.time()
    try:
        text, segments, detected_lang = ENGINES[args.engine](
            audio_path=args.audio, model_name=args.model,
            language=args.language, output_dir=args.output_dir,
            word_timestamps=args.word_timestamps,
            initial_prompt=args.initial_prompt,
        )
    except ImportError as e:
        print(f"错误: 引擎 '{args.engine}' 未安装: {e}", file=sys.stderr)
        sys.exit(2)

    elapsed = time.time() - start

    stem = Path(args.audio).stem
    fmt = args.output_format
    out_path = os.path.join(args.output_dir, f"{stem}.{fmt}")

    if fmt == "json":
        content = format_json_obj(text, segments, detected_lang)
    else:
        content = FORMATTERS[fmt](text, segments)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"输出: {out_path}")
    print(f"耗时: {elapsed:.1f}s | 文本长度: {len(text)} 字")


if __name__ == "__main__":
    main()
