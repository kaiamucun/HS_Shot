#!/usr/bin/env python3
"""Render the Japanese HS Shot quick-start from safe, real-app stills.

Requires macOS `say` (Kyoko), Pillow, and ffmpeg. This is an illustrated
walkthrough made from real UI screenshots, not a continuous screen recording.
Raw capture material is kept in the ignored .build/tutorial directory.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
from pathlib import Path
import subprocess
import unicodedata

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build/tutorial"
OUT = ROOT / "website/hs-shot-download/dist/assets"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
W, H, FPS = 1920, 1080, 30
INK = (36, 49, 70)
MUTED = (100, 116, 139)
BLUE = (46, 110, 221)
BG = (246, 248, 252)

CHAPTERS = [
    dict(id="intro", step="START", title="撮って、伝えて、すぐ共有。", sub="HS Shot かんたんガイド", frame=None,
         caption="撮影 → 左下のプレビュー → 編集 → 保存",
         speech="エイチエスショットの使い方です。撮影から編集、保存まで、順番に見ていきましょう。"),
    dict(id="install", step="01 / INSTALL", title="まずは、インストール。", sub="配布ページから PKG をダウンロード", frame=None,
         caption="PKG を開いてインストール → アプリケーションから起動",
         speech="配布ページから、ピーケージーをダウンロードして開きます。インストールが終わったら、アプリケーションから、エイチエスショットを起動します。"),
    dict(id="permission", step="02 / FIRST SETUP", title="初回は「画面収録」を許可。", sub="システム設定 → プライバシーとセキュリティ", frame="08-permission.jpg",
         caption="HS Shot をオンにしたら、アプリを再起動してください",
         speech="初回は画面収録を許可します。システム設定の、プライバシーとセキュリティで、エイチエスショットをオンにして、アプリを再起動します。"),
    dict(id="capture", step="03 / CAPTURE", title="「新規キャプチャ」をクリック。", sub="いつでも ⌘ ⇧ 2 でも範囲を選んで撮影できます", frame="01-library.jpg",
         caption="「新規キャプチャ」または ⌘ ⇧ 2",
         speech="新規キャプチャ、を押します。ショートカットは、コマンド、シフト、数字の2です。"),
    dict(id="area", step="03 / CAPTURE", title="必要なところだけ、囲む。", sub="ドラッグして範囲を決め、マウスを離す", frame="02-area.jpg",
         caption="ドラッグで範囲を選択。Esc でキャンセルできます",
         speech="撮りたい部分を、ドラッグで囲みます。範囲を決めてマウスを離せば、撮影完了です。"),
    dict(id="preview", step="04 / PREVIEW", title="画像は、左下で待っています。", sub="210 × 150 ポイントの固定サイズ・自動では消えません", frame="03-preview.jpg",
         caption="作業を続けても、左下のプレビューに残ります",
         speech="撮った画像は、左下の小さなプレビューに残ります。大きさは固定で、自動では消えません。"),
    dict(id="hover", step="04 / PREVIEW", title="重ねると、操作が現れます。", sub="コピー・保存・画像クリックで編集", frame="04-hover.jpg",
         caption="そのまま渡すならコピー。編集するなら画像をクリック",
         speech="マウスを重ねると、コピーと保存が表示されます。画像をクリックすると、編集画面が開きます。"),
    dict(id="editor", step="05 / EDIT", title="伝えたい場所に、矢印や文字。", sub="左のツールを選び、画像に直接追加", frame="05-editor.jpg",
         caption="矢印・文字・切り抜き。色と太さは右側で調整",
         speech="左のツールから矢印や文字を選び、画像に直接追加します。右側で色や太さを変えられます。"),
    dict(id="annotated", step="05 / EDIT", title="ひと目で伝わる、1 枚に。", sub="不要な部分は切り抜き・⌘ Z で取り消し", frame="06-annotated.jpg",
         caption="間違えたら ⌘ Z。ひとつ前に戻せます",
         speech="不要な部分は切り抜き。間違えたら、コマンド、ゼットで、ひとつ前に戻せます。"),
    dict(id="library-save", step="06 / SAVE", title="編集版を、ライブラリに残す。", sub="「ライブラリに保存」で、原本とは別に保存", frame="06-annotated.jpg",
         caption="原本を残したまま、編集版を保存できます",
         speech="ライブラリに保存すると、原本を残して編集版を保存できます。"),
    dict(id="save", step="07 / EXPORT", title="ファイルで渡すなら、書き出す。", sub="PNG / JPEG で保存できます", frame="07-export.jpg",
         caption="「書き出す」→ 保存先とファイル名を決める → Save",
         speech="ファイルで渡すときは、書き出す、から、保存先を選びます。"),
    dict(id="finish", step="READY", title="撮って、編集して、渡す。", sub="使い方に迷ったら、このページへ", frame="06-annotated.jpg",
         caption="画像は Mac 内に保存。クラウドへの自動送信はありません",
         speech="エイチエスショットは、画像をマックの中に保存します。撮って、編集して、コピーか書き出し。これで準備完了です。"),
]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def duration(path: Path) -> float:
    return float(subprocess.check_output([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(path)]))


def font(size: int, bold=False):
    for p in glob.glob("/System/Library/Fonts/*.ttc"):
        if unicodedata.normalize("NFC", Path(p).name) == f"ヒラギノ角ゴシック W{6 if bold else 3}.ttc":
            return ImageFont.truetype(p, size)
    return ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", size)


def wrap(draw, text, f, width):
    lines, line = [], ""
    for c in text:
        if c == "\n" or draw.textlength(line + c, font=f) > width:
            lines.append(line)
            line = "" if c == "\n" else c
        else:
            line += c
    if line:
        lines.append(line)
    return lines


def text_center(draw, text, y, f, fill=INK, width=1720, spacing=14):
    for line in wrap(draw, text, f, width):
        tw = draw.textlength(line, font=f)
        draw.text(((W - tw) / 2, y), line, font=f, fill=fill)
        y += f.size + spacing
    return y


def rounded_image(canvas, im, box, radius=28):
    x, y, width, height = box
    shadow = Image.new("RGBA", canvas.size)
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((x, y + 14, x + width, y + height + 14), radius, fill=(36, 49, 70, 38))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))
    card = Image.new("RGB", (width, height), "white")
    im = im.convert("RGB")
    scale = min(width / im.width, height / im.height, 2.5)
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.Resampling.LANCZOS)
    card.paste(im, ((width - im.width) // 2, (height - im.height) // 2))
    mask = Image.new("L", card.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width, height), radius, fill=255)
    canvas.paste(card, (x, y), mask)
    return (x + (width - im.width) // 2, y + (height - im.height) // 2, im.width, im.height)


def ui_callout(draw, source_size, placed, region, label, label_xy):
    """Point to an observed region of a real screenshot; never draw app UI."""
    px, py, pw, ph = placed
    sx, sy = source_size
    x0, y0, x1, y1 = region
    rect = (px + x0 * pw / sx - 5, py + y0 * ph / sy - 5,
            px + x1 * pw / sx + 5, py + y1 * ph / sy + 5)
    draw.rounded_rectangle(rect, 10, outline=BLUE, width=4)
    lx, ly = label_xy
    f = font(27, True)
    lw = draw.textlength(label, font=f) + 42
    lh = 66
    midx, midy = ((rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2)
    anchorx = lx + lw if lx < midx else lx
    draw.line((anchorx, ly + lh / 2, midx, midy), fill=BLUE, width=3)
    draw.rounded_rectangle((lx, ly, lx + lw, ly + lh), 18, fill=(235, 241, 252), outline=(205, 221, 249), width=2)
    draw.text((lx + 21, ly + 15), label, font=f, fill=BLUE)


def area_diagram(hint_path, progress=1.0):
    """An explicitly labelled diagram, never a fabricated recording."""
    card = Image.new("RGB", (1680, 560), "white")
    d = ImageDraw.Draw(card)
    sample_path = WORK / "HS Shot 使い方サンプル.png"
    sample = Image.open(sample_path).convert("RGB").crop((80, 100, 2320, 1160))
    sample = sample.resize((950, 450), Image.Resampling.LANCZOS)
    card.paste(sample, (365, 100))
    hint = Image.open(hint_path).convert("RGB")
    hint = hint.resize((678, 86), Image.Resampling.LANCZOS)
    hint_mask = Image.new("L", hint.size)
    ImageDraw.Draw(hint_mask).rounded_rectangle((0, 0, 677, 85), 43, fill=255)
    card.paste(hint, (500, 6), hint_mask)
    d.rounded_rectangle((1280, 18, 1635, 69), 15, fill=(235, 241, 252))
    d.text((1299, 31), "範囲選択のイメージ", font=font(23, True), fill=BLUE)
    x0, y0, x1, y1 = 390, 286, 1300, 470
    f = min(1.0, max(0.03, progress))
    cx, cy = round(x0 + (x1 - x0) * f), round(y0 + (y1 - y0) * f)
    d.rectangle((x0, y0, cx, cy), outline=BLUE, width=5)
    for x, y in ((x0, y0), (cx, cy)):
        d.ellipse((x - 7, y - 7, x + 7, y + 7), fill=BLUE)
    d.polygon([(cx + 3, cy + 3), (cx + 5, cy + 40), (cx + 15, cy + 30), (cx + 23, cy + 48),
               (cx + 30, cy + 45), (cx + 22, cy + 27), (cx + 37, cy + 26)], fill="white", outline=INK, width=2)
    d.text((50, 337), "ドラッグで囲む", font=font(29, True), fill=BLUE)
    d.line((280, 357, x0 - 16, 357), fill=BLUE, width=3)
    return card


def render_still(chapter, index, total, area_progress=1.0, output=None):
    im = Image.new("RGBA", (W, H), BG + (255,))
    d = ImageDraw.Draw(im)
    d.text((92, 49), "HS Shot", font=font(31, True), fill=INK)
    d.text((W - 525, 55), "かんたんガイド  /  音声・字幕つき", font=font(21), fill=MUTED)
    d.line((92, 110, W - 92, 110), fill=(220, 227, 237), width=2)
    d.text((92, 143), chapter["step"], font=font(23, True), fill=BLUE)
    d.text((92, 188), chapter["title"], font=font(49, True), fill=INK)
    d.text((95, 261), chapter["sub"], font=font(26), fill=MUTED)

    if chapter["frame"]:
        path = WORK / "frames" / chapter["frame"]
        if not path.exists() and chapter["id"] == "hover":
            path = WORK / "frames/03-preview.jpg"
        if not path.exists():
            raise FileNotFoundError(f"Missing actual app screenshot: {path}")
        source = area_diagram(path, area_progress) if chapter["id"] == "area" else Image.open(path)
        if chapter["id"] == "permission" and source.size == (1180, 800):
            # A close-up of the real permission card makes its path legible.
            source = source.crop((280, 168, 1110, 312))
        placed = rounded_image(im, source, (120, 330, 1680, 560))
        d = ImageDraw.Draw(im)
        if chapter["id"] == "capture" and source.size == (1180, 800):
            ui_callout(d, source.size, placed, (16, 158, 208, 198), "新規キャプチャ", (170, 408))
        if chapter["id"] == "editor" and source.size == (1180, 822):
            ui_callout(d, source.size, placed, (12, 160, 55, 195), "① 矢印", (190, 418))
            ui_callout(d, source.size, placed, (12, 398, 55, 432), "② 文字", (190, 582))
            ui_callout(d, source.size, placed, (959, 234, 1161, 365), "色・太さ", (1480, 493))
        if chapter["id"] == "annotated" and source.size == (1180, 822):
            ui_callout(d, source.size, placed, (12, 548, 55, 584), "切り抜き", (180, 690))
        if chapter["id"] == "library-save" and source.size == (1180, 822):
            ui_callout(d, source.size, placed, (1021, 53, 1158, 83), "ここで保存", (1450, 377))
        if chapter["id"] == "permission":
            text_center(d, "「設定を開く」→ HS Shot を許可 → アプリを再起動", 815, font(27, True), BLUE)
        footnote = "範囲選択の操作を説明する図です" if chapter["id"] == "area" else "実際のアプリ画面を使用した操作ガイド"
        d.text((140, 859), footnote, font=font(17), fill=MUTED)
    elif chapter["id"] == "intro":
        d.rounded_rectangle((120, 344, 1800, 880), 32, fill=(235, 241, 252))
        text_center(d, "HS Shot", 420, font(108, True))
        text_center(d, "スクリーンショットを、もっと手軽に。", 590, font(40), MUTED)
        text_center(d, "macOS 14 以降  /  Apple Silicon・Intel 対応", 695, font(27), BLUE)
    else:
        labels = [("1", "ダウンロード", "配布ページの PKG"), ("2", "インストール", "PKG を開いて進める"), ("3", "起動", "アプリケーションの HS Shot")]
        for j, (n, title, desc) in enumerate(labels):
            x = 120 + j * 570
            d.rounded_rectangle((x, 360, x + 540, 830), 32, fill="white", outline=(222, 229, 239), width=2)
            d.rounded_rectangle((x + 206, 410, x + 334, 538), 32, fill=(235, 241, 252))
            d.text((x + 250, 433), n, font=font(58, True), fill=BLUE)
            tw = d.textlength(title, font=font(35, True))
            d.text((x + (540 - tw) / 2, 600), title, font=font(35, True), fill=INK)
            tw = d.textlength(desc, font=font(23))
            d.text((x + (540 - tw) / 2, 665), desc, font=font(23), fill=MUTED)
        text_center(d, "署名・公証のない開発版です。インストール手順は配布ページで確認。", 854, font(21), MUTED)

    d.rounded_rectangle((80, 930, 1840, 1022), 24, fill="white", outline=(219, 228, 240), width=2)
    text_center(d, chapter["caption"], 955, font(31, True), INK, width=1660)
    # A segmented progress strip is an orientation aid, not interactive UI.
    strip_w = 1740 / total
    for j in range(total):
        d.rounded_rectangle((90 + j * strip_w, 1052, 90 + (j + 1) * strip_w - 7, 1058), 3, fill=BLUE if j <= index else (214, 223, 236))
    p = output or WORK / "cards" / f"{index:02d}-{chapter['id']}.png"
    p.parent.mkdir(parents=True, exist_ok=True)
    im.convert("RGB").save(p)
    return p


def stamp(seconds):
    ms = round(seconds * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}.{ms % 1000:03}"


def make_audio(chapter, rate):
    p = WORK / "audio" / f"{chapter['id']}-{rate}.aiff"
    p.parent.mkdir(parents=True, exist_ok=True)
    textfile = p.with_suffix(".txt")
    old = textfile.read_text() if textfile.exists() else ""
    if not p.exists() or old != chapter["speech"]:
        textfile.write_text(chapter["speech"])
        run(["say", "-v", "Kyoko", "-r", rate, "-f", textfile, "-o", p])
    return p


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-only", action="store_true")
    parser.add_argument("--cards-only", action="store_true")
    parser.add_argument("--rate", type=int, default=220)
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    schedule = []
    cursor = 0.0
    for i, chapter in enumerate(CHAPTERS):
        audio = make_audio(chapter, args.rate)
        # Speech starts after 0.35 seconds; the final still lingers for 0.65 seconds.
        seconds = math.ceil((duration(audio) + 1.0) * FPS) / FPS
        schedule.append(dict(**chapter, audio=str(audio), start=cursor, duration=seconds))
        cursor += seconds
    (WORK / "guide-timeline.json").write_text(json.dumps(schedule, ensure_ascii=False, indent=2))
    print(json.dumps({"duration_seconds": cursor, "chapters": [{"id": c["id"], "seconds": c["duration"]} for c in schedule]}, ensure_ascii=False), flush=True)
    if args.audio_only:
        return
    segments = []
    for i, chapter in enumerate(schedule):
        still = render_still(chapter, i, len(schedule))
        if args.cards_only:
            continue
        segment = WORK / "segments" / f"{i:02}-{chapter['id']}.mp4"
        segment.parent.mkdir(parents=True, exist_ok=True)
        input_args = ["-loop", "1", "-framerate", FPS, "-i", still]
        if chapter["id"] == "area":
            frames_dir = WORK / "area-animation"
            frames_dir.mkdir(parents=True, exist_ok=True)
            for frame_no in range(math.ceil(chapter["duration"] * 12)):
                fraction = min(1.0, max(0.0, (frame_no / 12 - 0.5) / 2.0))
                render_still(chapter, i, len(schedule), fraction, frames_dir / f"{frame_no:04d}.jpg")
            input_args = ["-framerate", "12", "-i", frames_dir / "%04d.jpg"]
        run([FFMPEG, "-y", "-v", "warning", *input_args,
             "-i", chapter["audio"], "-t", chapter["duration"],
             "-vf", f"fade=t=in:st=0:d=0.18,fade=t=out:st={chapter['duration'] - 0.18}:d=0.18,format=yuv420p",
             "-af", "loudnorm=I=-18:TP=-2:LRA=7,adelay=350|350,apad", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-tune", "stillimage",
             "-c:a", "aac", "-b:a", "96k", "-ar", "48000", "-ac", "2", "-r", FPS, "-movflags", "+faststart", segment])
        segments.append(segment)
        print(f"Rendered {i + 1}/{len(schedule)} {chapter['id']}", flush=True)
    if args.cards_only:
        return
    concat = WORK / "segments/concat.txt"
    concat.write_text("".join(f"file '{s}'\n" for s in segments))
    video = OUT / "hs-shot-guide.mp4"
    # Encode the audio once more across chapter boundaries to remove each AAC
    # segment's priming samples and provide one continuous, monotonic timeline.
    run([FFMPEG, "-y", "-v", "warning", "-f", "concat", "-safe", "0", "-i", concat,
         "-c:v", "copy", "-c:a", "aac", "-b:a", "96k", "-af", "aresample=async=1:first_pts=0",
         "-movflags", "+faststart", video])
    vtt = "WEBVTT\n\n"
    for chapter in schedule:
        vtt += f"{stamp(chapter['start'])} --> {stamp(chapter['start'] + chapter['duration'])}\n{chapter['title']}\n{chapter['caption']}\n\n"
    (OUT / "hs-shot-guide.vtt").write_text(vtt)
    (OUT / "hs-shot-guide-transcript.txt").write_text("HS Shot かんたんガイド\n実機の静止画と範囲選択の説明図に音声と字幕を付けた操作ガイドです。連続した画面録画ではありません。\n\n" + "\n\n".join(f"{c['title']}\n{c['speech']}" for c in schedule))
    poster = render_still(CHAPTERS[0], 0, len(CHAPTERS))
    Image.open(poster).save(OUT / "guide-poster.jpg", quality=88, optimize=True)
    print(json.dumps({"video": str(video), "bytes": video.stat().st_size, "duration": duration(video)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
