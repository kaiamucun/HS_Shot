#!/usr/bin/env python3
"""Render the v1.3.0 Japanese guide from safe screenshots of the actual app.

This is a narrated still-image walkthrough, not a continuous screen recording.
The source frames and intermediate files stay in ignored .build/tutorial-v130.
macOS say (Kyoko), Pillow and ffmpeg are required. Run --audio-only first to
obtain exact chapter times; --cards-only allows visual review before encoding.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import glob
import json
import math
from pathlib import Path
import subprocess
import unicodedata

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build/tutorial-v130"
OUT = ROOT / "website/hs-shot-download/dist/assets"
VERSION = "1.3.0"
BASENAME = f"hs-shot-guide-v{VERSION}"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
W, H, FPS = 1920, 1080, 30
INK = (36, 49, 70)
MUTED = (94, 111, 134)
BLUE = (46, 110, 221)
BG = (246, 248, 252)

# The screenshots are genuine app states. Crops are normalized to accommodate
# Retina and non-Retina captures without manufacturing or retouching app UI.
CHAPTERS = [
    dict(id="intro", step="START", title="閉じても、続きから。", sub="HS Shot 1.3.0 — 撮影から自動保存・再編集まで", frame=None,
         caption="自動保存 → アプリ終了 → 履歴から再編集",
         speech=["最新版、エイチエスショット、1.3 の使い方です。", "途中の編集を自動で残し、アプリを終了した後も、続きから調整できます。"]),
    dict(id="setup", step="01 / はじめて使うとき", title="インストールして、画面収録を許可。", sub="初回の設定は、配布ページでも案内しています", frame=None,
         caption="配布ページの PKG → インストール → 画面収録を許可 → 再起動",
         speech=["配布ページのピーケージーを開いて、インストールします。", "初回は画面収録を許可して、アプリを再起動してください。"]),
    dict(id="capture", step="02 / 撮影", title="必要な範囲を、ドラッグで撮影。", sub="「範囲を選択」または ⌘ ⇧ 2", frame="01-library.png", crop=(0, 0.07, 1, 0.57),
         detail="画面上部を拡大", caption="範囲をドラッグして、マウスを離すと撮影できます",
         speech=["範囲を選択、を押すか、コマンド、シフト、数字の2。", "必要な範囲をドラッグして、マウスを離すと撮影できます。"]),
    dict(id="preview", step="03 / 左下のプレビュー", title="撮った画像は、左下に残ります。", sub="固定サイズのプレビューから、すぐに編集へ", frame="02-preview.png", layout="preview",
         caption="画像をクリックすると編集画面が開きます",
         speech=["撮った画像は、左下の小さなプレビューに残ります。", "画像をクリックして、編集画面を開きましょう。"]),
    dict(id="editor", step="04 / 編集", title="矢印や文字を、画像に追加。", sub="左でツールを選び、右で色や太さを調整します", frame="03-editor.png",
         caption="左のツール → 画像上で操作 → 右側で見た目を調整",
         speech=["左のツールから矢印や文字を選んで、画像に追加します。", "色や太さは、右側で調整できます。"]),
    dict(id="text", step="04 / 編集", title="文字は、入力途中でも大丈夫。", sub="この例では、文字を入力したまま操作を続けます", frame="04-text.png", crop=(0.075, 0.27, 0.775, 0.81), detail="画像と注釈を拡大",
         caption="このあと「完了」を押さずに、アプリを終了してみます",
         speech=["ここでは文字を入力して、矢印も付けました。", "このあと、完了を押さずにアプリを終了してみます。"]),
    dict(id="autosave", step="05 / 自動保存", title="「自動保存済み」を確認。", sub="編集内容は、少し待つと Mac 内に保存されます", frame="05-autosaved.png", layout="autosave",
         caption="「完了」を押さなくても、途中の文字や矢印が残ります",
         speech=["編集すると、少し待って、自動保存済み、と表示されます。", "完了を押さなくても、途中の文字や矢印が、マックの中に残ります。"]),
    dict(id="quit", step="06 / アプリを終了", title="「完了」を押さずに、終了。", sub="HS Shot メニュー →「HS Shotを終了」。ショートカットは ⌘ Q", frame="05-autosaved.png", layout="quit",
         caption="「HS Shot」メニュー →「HS Shotを終了」／ ショートカットは ⌘ Q",
         speech=["ここでは、完了を押さずに、メニューから、エイチエスショットを終了します。", "編集画面の、閉じるボタンで閉じた場合も、変更は保存されます。"]),
    dict(id="relaunch", step="07 / アプリを起動", title="HS Shot を、もう一度起動。", sub="アプリケーションから HS Shot を開きます", frame=None,
         caption="アプリを終了したあと、同じ Mac で再起動しています",
         speech=["アプリケーションから、エイチエスショットを、もう一度起動します。"]),
    dict(id="history", step="08 / 履歴から開く", title="履歴に、途中の編集が残っています。", sub="「編集中」の画像を選び、編集画面を開きます", frame="07-restarted-history.png", crop=(0.20, 0.5, 0.98, 0.93), detail="履歴と、選択した画像の操作を拡大",
         caption="「編集中」の画像を選択 → 画面下の「編集」",
         speech=["履歴から、編集中の画像を選びます。", "画面下の、編集、を押すと、続きから開けます。"]),
    dict(id="restored", step="09 / 続きから再編集", title="文字も矢印も、再び選べます。", sub="画像に焼き込まず、編集できる状態で保存しています", frame="08-restored-editor.png", crop=(0.075, 0.27, 0.775, 0.81), detail="画像と注釈を拡大",
         caption="再起動後も、文字と矢印を個別に選んで調整できます",
         speech=["さっきの文字と矢印が、そのまま戻りました。", "再起動後も、それぞれを選んで、調整できます。"]),
    dict(id="reedited", step="09 / 続きから再編集", title="文字を書き換え、矢印の向きを調整。", sub="文字をダブルクリック。矢印は選択して端をドラッグ", frame="09-reedited.png", crop=(0.075, 0.27, 0.775, 0.81), detail="画像と注釈を拡大",
         sequence=["09a-reedit-text.png", "09b-arrow-before.png", "09-reedited.png"],
         caption="文字をダブルクリックで修正 ／ 矢印の端をドラッグで調整",
         speech=["文字をダブルクリックして、内容を書き換えます。", "矢印は選択して、端をドラッグ。位置や向きを、もう一度調整できます。"]),
    dict(id="done", step="10 / 編集を終える", title="調整できたら、「完了」。", sub="編集結果が、左下のプレビューに戻ります", frame="09-reedited.png", layout="done",
         caption="「完了」で編集を閉じる → 左下のプレビューへ",
         speech=["調整できたら、右上の、完了、を押します。", "編集した画像が、左下のプレビューに戻ります。"]),
    dict(id="completed", step="10 / 編集を終える", title="プレビューから、保存へ。", sub="もう一度クリックすれば、引き続き編集できます", frame="10-completed-preview.png", layout="preview",
         caption="マウスを重ねて「保存」。または右クリックして「保存」",
         speech=["プレビューにマウスを重ねて、保存を押します。", "もう一度画像をクリックすれば、続けて編集できます。"]),
    dict(id="export", step="11 / ファイルに保存", title="保存先とファイル名を決める。", sub="「書き出す」を押すと、画像ファイルを保存できます", frame="11-export.png",
         caption="履歴への自動保存と、画像ファイルの書き出しは別の操作です",
         speech=["保存先とファイル名を決めて、書き出す、を押します。", "履歴への自動保存と、画像ファイルとしての保存は、別の操作です。"]),
    dict(id="finish", step="READY", title="途中で閉じても、続きから。", sub="必要なときに履歴から開いて、何度でも調整できます", frame="09-reedited.png", crop=(0.075, 0.27, 0.775, 0.81), detail="画像と注釈を拡大",
         caption="撮影 → 自動保存 → 履歴から再編集 → 画像を書き出す",
         speech=["撮影、自動保存、履歴から再編集。", "途中で閉じても、続きから。エイチエスショット、1.3 です。"]),
]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def duration(path: Path) -> float:
    return float(subprocess.check_output([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(path)]))


@lru_cache(maxsize=64)
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


def centered(draw, text, y, f, fill=INK, width=1720, spacing=12):
    for line in wrap(draw, text, f, width):
        tw = draw.textlength(line, font=f)
        draw.text(((W - tw) / 2, y), line, font=f, fill=fill)
        y += f.size + spacing
    return y


def rounded_image(canvas, im, box, radius=24, max_scale=4):
    x, y, width, height = box
    shadow = Image.new("RGBA", canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 10, x + width, y + height + 10), radius, fill=(36, 49, 70, 32))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    card = Image.new("RGB", (width, height), "white")
    im = im.convert("RGB")
    scale = min(width / im.width, height / im.height, max_scale)
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.Resampling.LANCZOS)
    card.paste(im, ((width - im.width) // 2, (height - im.height) // 2))
    mask = Image.new("L", card.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width, height), radius, fill=255)
    canvas.paste(card, (x, y), mask)
    return (x + (width - im.width) // 2, y + (height - im.height) // 2, im.width, im.height)


def crop_fraction(image, box):
    return image.crop(tuple(round(v * (image.width if i % 2 == 0 else image.height)) for i, v in enumerate(box)))


def label(draw, text, xy, size=28):
    x, y = xy
    f = font(size, True)
    width = round(draw.textlength(text, font=f)) + 36
    draw.rounded_rectangle((x, y, x + width, y + size + 32), 16, fill=(232, 240, 253))
    draw.text((x + 18, y + 12), text, font=f, fill=BLUE)


def actual_detail(canvas, source, box, heading, crop):
    """A labeled zoom inset of source pixels; the app UI itself is untouched."""
    x, y, width, height = box
    d = ImageDraw.Draw(canvas)
    d.text((x, y), heading, font=font(25, True), fill=BLUE)
    rounded_image(canvas, crop_fraction(source, crop), (x, y + 48, width, height - 48), radius=20)


def callout(draw, placed, point, text, xy):
    """Label an observed control without replacing any screenshot pixels."""
    px, py, width, height = placed
    tx, ty = px + width * point[0], py + height * point[1]
    lx, ly = xy
    label_width = draw.textlength(text, font=font(28, True)) + 36
    anchor = lx + label_width if lx < tx else lx
    draw.line((anchor, ly + 30, tx, ty), fill=BLUE, width=3)
    draw.ellipse((tx - 16, ty - 16, tx + 16, ty + 16), outline=BLUE, width=3)
    label(draw, text, xy)


def diagram(canvas, kind):
    d = ImageDraw.Draw(canvas)
    if kind == "intro":
        d.rounded_rectangle((120, 258, 1800, 886), 32, fill=(232, 240, 253))
        centered(d, "HS Shot", 345, font(104, True))
        centered(d, "撮影 → 自動保存 → 終了 → 履歴から再編集", 535, font(42, True), BLUE)
        centered(d, "macOS 14 以降  /  Apple Silicon・Intel 対応", 652, font(28), MUTED)
        centered(d, "実際のアプリ画面を使った、音声・字幕つきガイド", 740, font(26), MUTED)
    elif kind == "setup":
        labels = [("1", "インストール", "配布ページの PKG を開く"), ("2", "画面収録を許可", "システム設定で HS Shot をオン"), ("3", "アプリを再起動", "初回の設定はこれで完了")]
        for j, (n, title, desc) in enumerate(labels):
            x = 120 + j * 570
            d.rounded_rectangle((x, 280, x + 540, 840), 28, fill="white", outline=(222, 229, 239), width=2)
            d.ellipse((x + 215, 345, x + 325, 455), fill=(232, 240, 253))
            d.text((x + 251, 367), n, font=font(52, True), fill=BLUE)
            tw = d.textlength(title, font=font(34, True))
            d.text((x + (540 - tw) / 2, 540), title, font=font(34, True), fill=INK)
            tw = d.textlength(desc, font=font(24))
            d.text((x + (540 - tw) / 2, 625), desc, font=font(24), fill=MUTED)
        centered(d, "画面収録：システム設定 → プライバシーとセキュリティ", 860, font(25), MUTED)
    else:
        d.rounded_rectangle((120, 280, 1800, 850), 32, fill="white", outline=(222, 229, 239), width=2)
        centered(d, "アプリ終了", 378, font(62, True))
        centered(d, "↓", 490, font(68), BLUE)
        centered(d, "アプリケーションから HS Shot を起動", 620, font(46, True), BLUE)
        centered(d, "この場面は、終了と再起動の手順を示す説明図です", 785, font(24), MUTED)


def render_still(chapter, index, total, output=None):
    im = Image.new("RGBA", (W, H), BG + (255,))
    d = ImageDraw.Draw(im)
    d.text((90, 29), "HS Shot 1.3.0", font=font(25, True), fill=INK)
    right = "実画面ガイド / 日本語の音声・字幕つき"
    d.text((W - 90 - d.textlength(right, font=font(21)), 34), right, font=font(21), fill=MUTED)
    d.line((90, 83, W - 90, 83), fill=(220, 227, 237), width=2)
    d.text((90, 108), chapter["step"], font=font(23, True), fill=BLUE)
    d.text((90, 151), chapter["title"], font=font(47, True), fill=INK)
    d.text((92, 218), chapter["sub"], font=font(26), fill=MUTED)

    if chapter["frame"]:
        path = WORK / "frames" / chapter["frame"]
        if not path.exists():
            raise FileNotFoundError(f"Missing actual app screenshot: {path}")
        source = Image.open(path).convert("RGB")
        layout = chapter.get("layout")
        if layout == "preview":
            # A neutral diagram establishes location; the enlarged preview is
            # genuine screenshot pixels, not a reconstruction of the app.
            d.rounded_rectangle((120, 288, 1800, 890), 28, fill="white", outline=(222, 229, 239), width=2)
            d.rounded_rectangle((166, 334, 1050, 844), 20, fill=(245, 247, 251), outline=(216, 225, 239), width=2)
            d.text((198, 360), "画面内の位置（説明図）", font=font(24), fill=MUTED)
            rounded_image(im, source, (196, 556, 350, 250), radius=20)
            d = ImageDraw.Draw(im)
            d.line((580, 682, 1050, 682), fill=BLUE, width=3)
            d.polygon(((1050, 682), (1033, 672), (1033, 692)), fill=BLUE)
            d.text((684, 634), "拡大", font=font(27, True), fill=BLUE)
            rounded_image(im, source, (1110, 375, 620, 443), radius=24)
        elif layout == "autosave":
            rounded_image(im, source, (120, 285, 1090, 605))
            # Footer location is established by the real v1.3 editor frames.
            actual_detail(im, source, (1260, 375, 540, 245), "画面下の保存状態を拡大", (0.765, 0.963, 0.845, 1.0))
            d = ImageDraw.Draw(im)
            label(d, "「完了」は押していません", (1260, 690), 26)
        elif layout == "done":
            rounded_image(im, source, (120, 285, 1090, 605))
            actual_detail(im, source, (1260, 375, 540, 245), "画面右上の「完了」を拡大", (0.91, 0.05, 0.99, 0.115))
            d = ImageDraw.Draw(im)
            label(d, "編集を終えてプレビューへ", (1260, 690), 26)
        elif layout == "quit":
            rounded_image(im, source, (120, 285, 1090, 605))
            d = ImageDraw.Draw(im)
            d.rounded_rectangle((1260, 365, 1800, 735), 28, fill="white", outline=(222, 229, 239), width=2)
            d.text((1310, 405), "終了操作の説明図", font=font(27, True), fill=BLUE)
            d.text((1370, 485), "⌘ Q", font=font(88, True), fill=INK)
            d.text((1300, 635), "HS Shot を終了", font=font(38, True), fill=INK)
        else:
            shown = crop_fraction(source, chapter["crop"]) if "crop" in chapter else source
            placed = rounded_image(im, shown, (120, 285, 1680, 605))
            if chapter["id"] == "editor":
                d = ImageDraw.Draw(im)
                callout(d, placed, (0.027, 0.216), "矢印ツール", (180, 385))
                callout(d, placed, (0.027, 0.501), "文字ツール", (180, 570))
                callout(d, placed, (0.89, 0.398), "色・太さを調整", (1490, 490))
        d = ImageDraw.Draw(im)
        note = chapter.get("detail", "実際の HS Shot 1.3.0 の画面")
        d.text((136, 901), note, font=font(17), fill=MUTED)
    else:
        diagram(im, chapter["id"])
        d = ImageDraw.Draw(im)

    d.rounded_rectangle((80, 946, 1840, 1025), 22, fill="white", outline=(219, 228, 240), width=2)
    centered(d, chapter["caption"], 965, font(29, True), INK, width=1680)
    strip_w = 1740 / total
    for j in range(total):
        d.rounded_rectangle((90 + j * strip_w, 1050, 90 + (j + 1) * strip_w - 7, 1057), 3, fill=BLUE if j <= index else (214, 223, 236))
    p = output or WORK / "cards" / f"{index:02d}-{chapter['id']}.png"
    p.parent.mkdir(parents=True, exist_ok=True)
    im.convert("RGB").save(p)
    return p


def stamp(seconds):
    ms = round(seconds * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}.{ms % 1000:03}"


def make_audio(chapter, rate):
    folder = WORK / "audio" / chapter["id"]
    folder.mkdir(parents=True, exist_ok=True)
    parts = []
    for i, speech in enumerate(chapter["speech"]):
        audio = folder / f"{i:02d}-{rate}.aiff"
        textfile = audio.with_suffix(".txt")
        old = textfile.read_text() if textfile.exists() else ""
        if not audio.exists() or old != speech:
            textfile.write_text(speech)
            run(["say", "-v", "Kyoko", "-r", rate, "-f", textfile, "-o", audio])
        parts.append(dict(text=speech, audio=str(audio), duration=duration(audio)))
    concat = folder / "concat.txt"
    concat.write_text("".join(f"file '{p['audio']}'\n" for p in parts))
    combined = folder / f"chapter-{rate}.aiff"
    run([FFMPEG, "-y", "-v", "warning", "-f", "concat", "-safe", "0", "-i", concat, "-c:a", "pcm_s16be", combined])
    return combined, parts


def subtitle_lines(text, max_chars=34):
    # Short sentence-level cues are aligned to separately synthesized speech.
    lines = []
    while len(text) > max_chars:
        split = text.rfind("、", 12, max_chars + 1)
        if split < 0:
            split = max_chars - 1
        lines.append(text[:split + 1])
        text = text[split + 1:]
    return "\n".join(lines + [text])


def main():
    global WORK, OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-only", action="store_true")
    parser.add_argument("--cards-only", action="store_true")
    parser.add_argument("--rate", type=int, default=220)
    parser.add_argument("--work", type=Path, default=WORK)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()
    WORK, OUT = args.work.resolve(), args.out.resolve()
    WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    schedule = []
    cursor = 0.0
    for chapter in CHAPTERS:
        audio, speech_parts = make_audio(chapter, args.rate)
        seconds = math.ceil((duration(audio) + 1.2) * FPS) / FPS
        schedule.append(dict(**chapter, audio=str(audio), speech_parts=speech_parts, start=cursor, duration=seconds))
        cursor += seconds
    (WORK / "guide-timeline.json").write_text(json.dumps(schedule, ensure_ascii=False, indent=2))
    print(json.dumps({"duration_seconds": cursor, "chapters": [{"id": c["id"], "start": c["start"], "seconds": c["duration"]} for c in schedule]}, ensure_ascii=False), flush=True)
    if args.audio_only:
        return
    segments = []
    for i, chapter in enumerate(schedule):
        still = render_still(chapter, i, len(schedule))
        input_args = ["-loop", "1", "-framerate", FPS, "-i", still]
        if chapter.get("sequence"):
            # Display the actual input field, selected arrow, and moved endpoint
            # in order. This is a clearly disclosed still-image sequence, not
            # synthetic cursor motion or a claim of continuous screen capture.
            first = 0.35 + chapter["speech_parts"][0]["duration"]
            lengths = [first, 2.0, chapter["duration"] - first - 2.0]
            sequence_files = []
            for n, frame in enumerate(chapter["sequence"]):
                p = WORK / "cards" / f"{i:02d}-{chapter['id']}-{n}.png"
                render_still(dict(chapter, frame=frame), i, len(schedule), output=p)
                sequence_files.append(p)
            sequence_list = WORK / "cards" / f"{i:02d}-{chapter['id']}-sequence.txt"
            sequence_list.write_text("".join(f"file '{p}'\nduration {seconds:.8f}\n" for p, seconds in zip(sequence_files, lengths)) + f"file '{sequence_files[-1]}'\n")
            input_args = ["-f", "concat", "-safe", "0", "-i", sequence_list]
        if args.cards_only:
            continue
        segment = WORK / "segments" / f"{i:02}-{chapter['id']}.mp4"
        segment.parent.mkdir(parents=True, exist_ok=True)
        # Convert sparse still-sequence timestamps to FPS before fading, or the
        # first black fade frame would be held until the next source image.
        run([FFMPEG, "-y", "-v", "warning", *input_args,
             "-i", chapter["audio"], "-t", chapter["duration"],
             "-vf", f"fps={FPS},fade=t=in:st=0:d=0.18,fade=t=out:st={chapter['duration'] - 0.18}:d=0.18,format=yuv420p",
             "-af", "loudnorm=I=-18:TP=-2:LRA=7,adelay=350|350,apad", "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-tune", "stillimage",
             "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-r", FPS, "-movflags", "+faststart", segment])
        segments.append(segment)
        print(f"Rendered {i + 1}/{len(schedule)} {chapter['id']}", flush=True)
    if args.cards_only:
        return
    concat = WORK / "segments/concat.txt"
    concat.write_text("".join(f"file '{s}'\n" for s in segments))
    video = OUT / f"{BASENAME}.mp4"
    # One final AAC encode removes per-segment priming samples and keeps A/V
    # timestamps continuous across chapter boundaries.
    run([FFMPEG, "-y", "-v", "warning", "-f", "concat", "-safe", "0", "-i", concat,
         "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-af", "aresample=async=1:first_pts=0",
         "-movflags", "+faststart", video])
    vtt = "WEBVTT\n\n"
    for chapter in schedule:
        start = chapter["start"] + 0.35
        for speech in chapter["speech_parts"]:
            end = start + speech["duration"]
            vtt += f"{stamp(start)} --> {stamp(end)}\n{subtitle_lines(speech['text'])}\n\n"
            start = end
    (OUT / f"{BASENAME}.vtt").write_text(vtt)
    (OUT / f"{BASENAME}-transcript.txt").write_text(
        "HS Shot 1.3.0 使い方ガイド\n"
        "実際のアプリ画面の静止画と、終了・再起動などの説明図に、日本語音声と字幕を付けた動画です。連続した画面録画ではありません。\n"
        "この例は通常のアプリ終了です。強制終了の場合は、最後に自動保存された状態から再開します。\n\n"
        + "\n\n".join(f"[{stamp(c['start'])}] {c['title']}\n{' '.join(c['speech'])}" for c in schedule))
    poster = render_still(CHAPTERS[0], 0, len(CHAPTERS))
    Image.open(poster).save(OUT / f"guide-poster-v{VERSION}.jpg", quality=90, optimize=True)
    print(json.dumps({"video": str(video), "bytes": video.stat().st_size, "duration": duration(video)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
