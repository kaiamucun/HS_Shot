#!/usr/bin/env python3
"""Edit a genuine desktop recording into the Japanese HS Shot guide.

The manifest selects continuous portions of real screen video. Every selected
frame runs at its original speed: no screenshots, synthetic cursor, freeze
frames, time stretching or reconstructed UI are used. Japanese labels occupy
space outside the captured desktop. The source capture must already contain
the real cursor and native click indicators.

Example manifest (times are seconds in the source recording)::

    {
      "source": ".build/live-guide/take-01.mp4",
      "clips": [
        {"id": "capture", "start": 2, "end": 25,
         "title": "01 範囲を選んで撮影",
         "caption": "範囲をドラッグして、マウスを離します",
         "speech": ["範囲を選択を押します。", "必要な範囲をドラッグします。"]}
      ]
    }

Run --plan first to synthesize speech and check timings. A voice-over that does
not fit fails explicitly; add genuine source seconds or shorten the narration.
The script never manufactures an idle picture to fill a narration gap.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import glob
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import unicodedata

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build/live-guide/edit"
DEFAULT_OUT = ROOT / "website/hs-shot-download/dist/assets"
VERSION = "1.3.0"
BASENAME = f"hs-shot-guide-live-v{VERSION}"
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
WIDTH, HEIGHT, FPS = 1920, 1080, 30
HEADER, FOOTER = 64, 76
VIDEO_HEIGHT = HEIGHT - HEADER - FOOTER
BG = (243, 246, 251)
INK = (34, 48, 68)
MUTED = (89, 105, 126)
BLUE = (35, 104, 215)


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def probe(path: Path):
    return json.loads(subprocess.check_output([
        FFPROBE, "-v", "error", "-show_format", "-show_streams",
        "-of", "json", path,
    ]))


def seconds(path: Path):
    return float(probe(path)["format"]["duration"])


def resolve_path(value: str, base=ROOT):
    path = Path(value).expanduser()
    return path if path.is_absolute() else base / path


@lru_cache(maxsize=8)
def font(size: int, bold=False):
    desired = f"ヒラギノ角ゴシック W{6 if bold else 3}.ttc"
    for name in glob.glob("/System/Library/Fonts/*.ttc"):
        if unicodedata.normalize("NFC", Path(name).name) == desired:
            return ImageFont.truetype(name, size)
    return ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", size)


def overlay(clip, output):
    """Only labels and recording margins; the real video remains unobscured."""
    picture = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(picture)
    draw.rectangle((0, 0, WIDTH, HEADER - 1), fill=BG + (255,))
    draw.rectangle((0, HEIGHT - FOOTER, WIDTH, HEIGHT), fill=BG + (255,))
    draw.text((38, 17), "HS Shot 1.3.0", font=font(23, True), fill=INK)
    title = clip["title"]
    draw.text((WIDTH - 38 - draw.textlength(title, font=font(25, True)), 15),
              title, font=font(25, True), fill=BLUE)
    caption = clip.get("caption", "")
    caption_font = font(29, True)
    if draw.textlength(caption, font=caption_font) > WIDTH - 80:
        raise ValueError(f"Caption too long: {clip['id']}; shorten it to one line")
    draw.text(((WIDTH - draw.textlength(caption, font=caption_font)) / 2,
               HEIGHT - FOOTER + 20), caption, font=caption_font, fill=INK)
    picture.save(output)


def speech_audio(clip, rate):
    folder = WORK / "audio" / clip["id"]
    folder.mkdir(parents=True, exist_ok=True)
    entries = clip.get("speech", [])
    if isinstance(entries, str):
        entries = [entries]
    parts = []
    for i, entry in enumerate(entries):
        if isinstance(entry, str):
            entry = {"text": entry}
        text = entry["text"].strip()
        if not text:
            continue
        digest = hashlib.sha256(f"{rate}:{text}".encode()).hexdigest()[:12]
        source = folder / f"{i:02}-{digest}.txt"
        audio = folder / f"{i:02}-{digest}.aiff"
        source.write_text(text + "\n")
        if not audio.exists():
            run(["say", "-v", "Kyoko", "-r", rate, "-f", source, "-o", audio])
        parts.append({"text": text, "audio": str(audio),
                      "duration": seconds(audio), "at": entry.get("at")})
    # By default, sentence blocks are separated by a brief natural pause.
    cursor = float(clip.get("speech_delay", 0.6))
    for part in parts:
        if part["at"] is not None:
            cursor = float(part["at"])
        part["offset"] = cursor
        cursor += part["duration"] + 0.35
    return parts


def read_manifest(path, rate):
    manifest = json.loads(path.read_text())
    source = resolve_path(manifest["source"])
    if not source.is_file():
        raise FileNotFoundError(f"Actual source recording missing: {source}")
    source_duration = seconds(source)
    clips, cursor = [], 0.0
    identifiers = set()
    for item in manifest["clips"]:
        clip = dict(item)
        clip["source"] = str(resolve_path(clip.get("source", str(source))))
        if "crop" in clip:
            crop = clip["crop"]
            if len(crop) != 4 or any(not isinstance(v, int) or v < 0 for v in crop) or not crop[2] or not crop[3]:
                raise ValueError(f"Invalid real-video crop for {clip['id']}: {crop}; use [x,y,width,height]")
            picture = next(s for s in probe(Path(clip["source"]))["streams"] if s["codec_type"] == "video")
            if crop[0] + crop[2] > picture["width"] or crop[1] + crop[3] > picture["height"]:
                raise ValueError(f"Crop leaves source recording: {clip['id']}")
        source_end = source_duration if clip["source"] == str(source) else seconds(Path(clip["source"]))
        clip["start"], clip["end"] = float(clip["start"]), float(clip["end"])
        if not 0 <= clip["start"] < clip["end"] <= source_end + 0.05:
            raise ValueError(f"Invalid source interval for {clip['id']}: {clip['start']}–{clip['end']} / {source_end}")
        if clip["id"] in identifiers or not all(c.isalnum() or c in "-_" for c in clip["id"]):
            raise ValueError(f"Clip IDs must be unique safe names: {clip['id']}")
        identifiers.add(clip["id"])
        # Frame-align each kept interval, preserving source speed.
        clip["duration"] = math.floor((clip["end"] - clip["start"]) * FPS + 1e-6) / FPS
        clip["timeline_start"] = cursor
        clip["speech_parts"] = speech_audio(clip, rate)
        for part in clip["speech_parts"]:
            needed = part["offset"] + part["duration"] + 0.25
            if needed > clip["duration"]:
                raise ValueError(f"Narration for {clip['id']} needs {needed:.2f}s; clip has {clip['duration']:.2f}s. Keep more real footage or shorten speech.")
        clips.append(clip)
        cursor += clip["duration"]
    if not clips:
        raise ValueError("Manifest must select actual video clips")
    return manifest, clips, cursor


def stamp(value):
    ms = round(value * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}.{ms % 1000:03}"


def metadata(clips, duration, output):
    vtt = ["WEBVTT", ""]
    transcript = ["HS Shot 1.3.0 — 実際の操作を録画した使い方ガイド", "",
                  "マウスの動きとクリック位置を含む実画面の録画です。", ""]
    chapters = []
    for clip in clips:
        start = clip["timeline_start"]
        chapters.append({"id": clip["id"], "title": clip["title"], "time": round(start, 3), "duration": round(clip["duration"], 3)})
        transcript.extend([f"[{stamp(start)[:-4]}] {clip['title']}", clip.get("caption", "")])
        for part in clip["speech_parts"]:
            at = start + part["offset"]
            vtt.extend([f"{stamp(at)} --> {stamp(at + part['duration'])}", part["text"], ""])
            transcript.append(part["text"])
        transcript.append("")
    (output / f"{BASENAME}.vtt").write_text("\n".join(vtt))
    (output / f"{BASENAME}-transcript.txt").write_text("\n".join(transcript))
    (output / f"{BASENAME}-chapters.json").write_text(json.dumps({"duration": duration, "chapters": chapters}, ensure_ascii=False, indent=2) + "\n")


def encode_clip(clip, index, crf, preset):
    target = WORK / "segments" / f"{index:02}-{clip['id']}.mp4"
    label = WORK / "overlays" / f"{index:02}-{clip['id']}.png"
    overlay(clip, label)
    args = [FFMPEG, "-hide_banner", "-loglevel", "warning", "-y",
            "-ss", clip["start"], "-t", clip["duration"], "-i", clip["source"],
            "-loop", "1", "-i", label]
    for part in clip["speech_parts"]:
        args += ["-i", part["audio"]]
    crop = ""
    if "crop" in clip:
        x, y, width, height = clip["crop"]
        crop = f"crop={width}:{height}:{x}:{y},"
    filters = [
        f"[0:v]setpts=PTS-STARTPTS,{crop}scale={WIDTH}:{VIDEO_HEIGHT}:force_original_aspect_ratio=decrease:force_divisible_by=2,"
        f"pad={WIDTH}:{HEIGHT}:(ow-iw)/2:{HEADER}+( {VIDEO_HEIGHT}-ih)/2:color=0xf3f6fb,setsar=1,fps={FPS}[desktop]",
        "[desktop][1:v]overlay=0:0:shortest=1,format=yuv420p[video]",
    ]
    if clip["speech_parts"]:
        labels = []
        for i, part in enumerate(clip["speech_parts"]):
            delay = round(part["offset"] * 1000)
            filters.append(f"[{i + 2}:a]aresample=48000,adelay={delay}|{delay}[a{i}]")
            labels.append(f"[a{i}]")
        filters.append("".join(labels) + f"amix=inputs={len(labels)}:normalize=0,apad=whole_dur={clip['duration']}[audio]")
    else:
        filters.append(f"anullsrc=r=48000:cl=stereo,atrim=duration={clip['duration']}[audio]")
    args += ["-filter_complex", ";".join(filters), "-map", "[video]", "-map", "[audio]",
             "-t", clip["duration"], "-c:v", "libx264", "-preset", preset,
             "-crf", crf, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
             "-ar", "48000", "-ac", "2", "-movflags", "+faststart", target]
    run(args)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--plan", action="store_true", help="Create speech and timing receipts without video encoding")
    parser.add_argument("--rate", type=int, default=180)
    parser.add_argument("--crf", type=int, default=19)
    parser.add_argument("--preset", default="medium")
    args = parser.parse_args()
    for directory in (WORK, WORK / "segments", WORK / "overlays", args.output):
        directory.mkdir(parents=True, exist_ok=True)
    manifest, clips, duration = read_manifest(args.manifest, args.rate)
    receipt = {"source": manifest["source"], "duration": duration, "fps": FPS,
               "mode": "continuous-screen-recording-original-speed", "clips": clips}
    (WORK / "timeline.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    metadata(clips, duration, args.output)
    for clip in clips:
        speech_end = max((p["offset"] + p["duration"] for p in clip["speech_parts"]), default=0)
        print(f"{stamp(clip['timeline_start'])}  {clip['id']:<14} {clip['duration']:6.2f}s  narration ends {speech_end:6.2f}s")
    print(f"Total: {duration:.2f}s")
    if args.plan:
        return
    segments = [encode_clip(clip, i, args.crf, args.preset) for i, clip in enumerate(clips)]
    concat = WORK / "concat.txt"
    # AAC packets can outlast the final video frame by up to one audio packet.
    # Explicit demuxer durations keep chapter positions tied to actual frames.
    concat.write_text("".join("file '" + str(path).replace("'", "'\\''") + "'\n"
                               + f"duration {clip['duration']:.9f}\n"
                               for path, clip in zip(segments, clips)))
    video = args.output / f"{BASENAME}.mp4"
    run([FFMPEG, "-hide_banner", "-loglevel", "warning", "-y", "-f", "concat", "-safe", "0", "-i", concat,
         "-map", "0:v", "-map", "0:a", "-t", duration, "-c:v", "copy", "-c:a", "aac", "-b:a", "128k",
         "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000", "-movflags", "+faststart", video])
    poster = args.output / f"poster-live-v{VERSION}.jpg"
    poster_time = min(float(manifest.get("poster_time", 3)), duration - 0.1)
    run([FFMPEG, "-hide_banner", "-loglevel", "warning", "-y", "-ss", poster_time, "-i", video,
         "-frames:v", "1", "-q:v", "2", "-update", "1", poster])
    actual = probe(video)
    receipt["output"] = {"path": str(video), "duration": float(actual["format"]["duration"]),
                         "bytes": video.stat().st_size, "sha256": hashlib.sha256(video.read_bytes()).hexdigest(),
                         "streams": [{k: s[k] for k in ("codec_type", "codec_name", "width", "height", "pix_fmt", "r_frame_rate", "sample_rate", "channels") if k in s} for s in actual["streams"]]}
    (WORK / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(receipt["output"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
