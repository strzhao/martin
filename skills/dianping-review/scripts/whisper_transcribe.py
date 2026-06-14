#!/usr/bin/env python3
"""Transcribe audio file using faster-whisper turbo model.
Usage: python3 whisper_transcribe.py <audio_file> [language]
Output: prints transcript to stdout with timestamps.
"""
import sys
import os

def transcribe(audio_path: str, language: str = "zh") -> str:
    from faster_whisper import WhisperModel
    
    model = WhisperModel("turbo", device="cpu", compute_type="int8")
    segments, info = model.transcribe(
        audio_path,
        language=language,
        beam_size=5
    )
    
    lines = [f"Language: {info.language}, Duration: {info.duration:.1f}s"]
    lines.append("--- TRANSCRIPT ---")
    for segment in segments:
        lines.append(f"[{segment.start:.1f}s - {segment.end:.1f}s] {segment.text}")
    
    return "\n".join(lines)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 whisper_transcribe.py <audio_file> [language]")
        sys.exit(1)
    
    audio_path = sys.argv[1]
    language = sys.argv[2] if len(sys.argv) > 2 else "zh"
    
    if not os.path.exists(audio_path):
        print(f"Error: file not found: {audio_path}")
        sys.exit(1)
    
    print(transcribe(audio_path, language))
