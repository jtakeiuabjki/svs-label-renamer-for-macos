#!/usr/bin/env python3
"""Render the v0.3.0 walkthrough from synthetic-only demo assets.

This maintainer utility intentionally accepts explicit screenshots and extracted
PNG paths.  The release video must never be rendered from patient data.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


WIDTH = 1600
HEIGHT = 1000
BACKGROUND = "#071425"
BACKGROUND_2 = "#102A43"
INK = "#122033"
MUTED = "#607080"
ACCENT = "#1D9BF0"
ACCENT_2 = "#31D0AA"
WHITE = "#FFFFFF"

JP_FONT = Path("/System/Library/Fonts/Hiragino Sans GB.ttc")
EN_FONT = Path("/System/Library/Fonts/SFNS.ttf")
EN_ROUNDED_FONT = Path("/System/Library/Fonts/SFNSRounded.ttf")


def font(size: int, *, english: bool = False, rounded: bool = False) -> ImageFont.FreeTypeFont:
    path = EN_ROUNDED_FONT if rounded else (EN_FONT if english else JP_FONT)
    return ImageFont.truetype(str(path), size=size)


def gradient_background() -> Image.Image:
    top = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    bottom = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND_2)
    mask = Image.linear_gradient("L").resize((WIDTH, HEIGHT))
    canvas = Image.composite(bottom, top, mask)
    draw = ImageDraw.Draw(canvas, "RGBA")
    for x, y, radius, alpha in [
        (1420, 120, 280, 34),
        (180, 920, 360, 25),
        (860, 520, 460, 18),
    ]:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(29, 155, 240, alpha))
    return canvas


def rounded_panel(canvas: Image.Image, box: tuple[int, int, int, int], *, fill: str = WHITE, radius: int = 30) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shifted = (box[0] + 8, box[1] + 14, box[2] + 8, box[3] + 14)
    shadow_draw.rounded_rectangle(shifted, radius=radius, fill=(0, 0, 0, 60))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(shadow)
    ImageDraw.Draw(canvas).rounded_rectangle(box, radius=radius, fill=fill)


def place_image(
    canvas: Image.Image,
    source: Image.Image,
    box: tuple[int, int, int, int],
    *,
    radius: int = 20,
    contain: bool = True,
    background: str | tuple[int, int, int, int] = WHITE,
) -> None:
    target_size = (box[2] - box[0], box[3] - box[1])
    rgba = source.convert("RGBA")
    if contain:
        fitted = ImageOps.contain(rgba, target_size, Image.Resampling.LANCZOS)
        layer = Image.new("RGBA", target_size, background)
        layer.alpha_composite(fitted, ((target_size[0] - fitted.width) // 2, (target_size[1] - fitted.height) // 2))
    else:
        layer = ImageOps.fit(rgba, target_size, Image.Resampling.LANCZOS)
    mask = Image.new("L", target_size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, target_size[0], target_size[1]), radius=radius, fill=255)
    layer.putalpha(mask)
    canvas.alpha_composite(layer, (box[0], box[1]))


def draw_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    size: int,
    *,
    fill: str = WHITE,
    anchor: str | None = None,
    english: bool = False,
    rounded: bool = False,
    spacing: int = 8,
    align: str = "left",
) -> None:
    draw.multiline_text(
        xy,
        text,
        font=font(size, english=english, rounded=rounded),
        fill=fill,
        anchor=anchor,
        spacing=spacing,
        align=align,
    )


def header(canvas: Image.Image, step: str, title: str, subtitle: str) -> None:
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((70, 58, 208, 112), radius=27, fill=ACCENT)
    draw_text(draw, (139, 85), step, 25, anchor="mm", english=True, rounded=True)
    draw_text(draw, (235, 55), title, 42)
    draw_text(draw, (238, 112), subtitle, 22, fill="#BED4E8", english=True)


def footer(canvas: Image.Image, section: int, total: int = 6) -> None:
    draw = ImageDraw.Draw(canvas)
    x0, x1, y = 70, 1530, 952
    draw.rounded_rectangle((x0, y, x1, y + 8), radius=4, fill=(255, 255, 255, 55))
    progress = x0 + int((x1 - x0) * section / total)
    draw.rounded_rectangle((x0, y, progress, y + 8), radius=4, fill=ACCENT_2)


def title_card(app_icon: Image.Image, processed: Image.Image, label: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rounded_rectangle((72, 66, 268, 112), radius=23, fill=(49, 208, 170, 230))
    draw_text(draw, (170, 89), "v0.3.0  BETA", 23, anchor="mm", english=True, rounded=True)
    draw_text(draw, (74, 176), "SVS Label Renamer", 74, english=True, rounded=True)
    draw_text(draw, (76, 266), "for macOS", 52, fill="#B9D9F5", english=True, rounded=True)
    draw_text(draw, (78, 355), "SVSラベルを読み取り、確認して安全にリネーム", 31)
    draw_text(draw, (80, 405), "55-second walkthrough · fully synthetic SVS", 24, fill="#9FC0DB", english=True)

    rounded_panel(canvas, (70, 490, 1110, 900), fill="#EEF5FA", radius=34)
    place_image(canvas, processed, (96, 516, 1084, 874), radius=22, contain=True, background="#EEF5FA")
    rounded_panel(canvas, (1160, 160, 1515, 900), fill="#FCF9EF", radius=38)
    place_image(canvas, label, (1192, 245, 1483, 755), radius=20, contain=True, background="#FCF9EF")
    place_image(canvas, app_icon, (1262, 60, 1415, 205), radius=30, contain=True, background=(0, 0, 0, 0))
    draw.rounded_rectangle((1210, 786, 1464, 842), radius=28, fill="#E4EEF2")
    draw_text(draw, (1337, 814), "NO PATIENT DATA", 20, fill="#41515A", anchor="mm", english=True)
    footer(canvas, 0)
    return canvas


def quicklook_card(overview: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    header(canvas, "01", "Finderで、開く前に確認", "Select an SVS file and press Space for Quick Look")
    rounded_panel(canvas, (70, 185, 500, 910), fill="#F7F9FC")
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rounded_rectangle((95, 214, 475, 275), radius=16, fill="#E8EDF3")
    draw_text(draw, (120, 245), "Finder", 26, fill=INK, anchor="lm", english=True)
    for index, width in enumerate([280, 235, 300, 210]):
        y = 310 + index * 58
        draw.rounded_rectangle((118, y, 118 + width, y + 15), radius=7, fill="#D9E1E8")
    draw.rounded_rectangle((120, 590, 448, 790), radius=26, fill="#E7F4FD", outline=ACCENT, width=4)
    draw.rounded_rectangle((150, 625, 245, 715), radius=18, fill=ACCENT)
    draw_text(draw, (197, 670), "SVS", 26, anchor="mm", english=True, rounded=True)
    draw_text(draw, (270, 650), "demo_input.svs", 23, fill=INK, english=True)
    draw_text(draw, (270, 690), "Synthetic demo", 18, fill=MUTED, english=True)
    draw.rounded_rectangle((250, 738, 360, 790), radius=14, fill="#192A3C")
    draw_text(draw, (305, 764), "space", 19, anchor="mm", english=True, rounded=True)

    rounded_panel(canvas, (540, 185, 1530, 910), fill="#F8F5F7")
    draw_text(draw, (585, 225), "Quick Look preview", 26, fill=INK, english=True, rounded=True)
    draw_text(draw, (585, 264), "低倍率の全体像を数秒で確認", 23, fill=MUTED)
    place_image(canvas, overview, (585, 315, 1485, 850), radius=24, contain=True, background="#FFFDFE")
    footer(canvas, 1)
    return canvas


def choose_card(initial: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    header(canvas, "02", "SVSをドロップ、または選択", "No installation wizard · Japanese / English")
    rounded_panel(canvas, (70, 185, 1530, 910), fill="#EFF3F6")
    place_image(canvas, initial, (95, 210, 1505, 880), radius=20, contain=True, background="#EFF3F6")
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rounded_rectangle((600, 685, 1000, 758), radius=36, fill=(29, 155, 240, 220))
    draw_text(draw, (800, 721), "フォルダ／SVSを選択", 27, anchor="mm")
    footer(canvas, 2)
    return canvas


def ocr_card(processed: Image.Image, label: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    header(canvas, "03", "ラベル抽出とOCR", "Spatial hints favor the printed edge number and lower stain text")
    rounded_panel(canvas, (70, 185, 1530, 910), fill="#F4F7FA")
    place_image(canvas, processed, (90, 205, 985, 875), radius=20, contain=True, background="#F4F7FA")
    rounded_panel(canvas, (1015, 215, 1495, 875), fill="#FCF9EF", radius=26)
    place_image(canvas, label, (1040, 240, 1240, 645), radius=16, contain=True, background="#FCF9EF")
    draw = ImageDraw.Draw(canvas, "RGBA")
    fields = [("病理番号", "DEMO0001"), ("ブロック", "2"), ("染色", "CD68")]
    for index, (name, value) in enumerate(fields):
        y = 270 + index * 118
        draw_text(draw, (1270, y), name, 20, fill=MUTED)
        draw.rounded_rectangle((1265, y + 32, 1465, y + 91), radius=14, fill="#E9F5FD")
        draw_text(draw, (1365, y + 61), value, 27, fill=INK, anchor="mm", english=True, rounded=True)
    draw.rounded_rectangle((1048, 720, 1465, 830), radius=22, fill="#12263A")
    draw_text(draw, (1070, 744), "提案された名前", 19, fill="#AFC9DD")
    draw_text(draw, (1257, 790), "DEMO0001_2_CD68.svs", 25, anchor="mm", english=True, rounded=True)
    footer(canvas, 3)
    return canvas


def quality_card(overview: Image.Image, macro: Image.Image, label: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    header(
        canvas,
        "04",
        "全体像・macro・labelを保存",
        "Overview quality check runs locally and flags slides that need review",
    )
    rounded_panel(canvas, (70, 185, 1125, 910), fill="#FCFAFC")
    place_image(canvas, overview, (95, 210, 1100, 665), radius=20, contain=True, background="#FCFAFC")
    place_image(canvas, macro, (95, 690, 1100, 870), radius=18, contain=True, background="#EEF2F4")
    rounded_panel(canvas, (1155, 185, 1530, 910), fill="#F7FAFC")
    place_image(canvas, label, (1190, 220, 1335, 470), radius=14, contain=True, background="#FCF9EF")
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rounded_rectangle((1360, 220, 1495, 270), radius=25, fill="#DDF8EF")
    draw_text(draw, (1427, 245), "警告なし", 20, fill="#17624D", anchor="mm")
    draw_text(draw, (1190, 520), "自動チェック", 26, fill=INK)
    metrics = [("組織率", "43.0%"), ("明るさ", "83.2%"), ("コントラスト", "8.5%"), ("鮮鋭度", "10.24")]
    for index, (name, value) in enumerate(metrics):
        y = 580 + index * 62
        draw_text(draw, (1190, y), name, 19, fill=MUTED)
        draw_text(draw, (1490, y), value, 22, fill=INK, anchor="ra", english=True, rounded=True)
        draw.line((1190, y + 34, 1490, y + 34), fill="#DDE5EB", width=2)
    footer(canvas, 4)
    return canvas


def confirm_card(processed: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    header(
        canvas,
        "05",
        "確認してからリネーム",
        "The original SVS stays untouched until you explicitly confirm",
    )
    rounded_panel(canvas, (70, 185, 1530, 910), fill="#EEF3F6")
    place_image(canvas, processed, (95, 210, 1505, 880), radius=20, contain=True, background="#EEF3F6")
    veil = Image.new("RGBA", canvas.size, (7, 20, 37, 0))
    ImageDraw.Draw(veil).rounded_rectangle((70, 185, 1530, 910), radius=30, fill=(7, 20, 37, 92))
    canvas.alpha_composite(veil)
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rounded_rectangle((790, 610, 1470, 855), radius=34, fill=(255, 255, 255, 244))
    draw.rounded_rectangle((835, 658, 881, 704), radius=8, fill="#DFF7EF", outline=ACCENT_2, width=4)
    draw.line((846, 681, 859, 694), fill="#16886B", width=6)
    draw.line((859, 694, 878, 668), fill="#16886B", width=6)
    draw_text(draw, (905, 681), "ラベルと名前を確認", 25, fill=INK, anchor="lm")
    draw.rounded_rectangle((835, 740, 1418, 818), radius=22, fill="#269B63")
    draw_text(draw, (1126, 779), "確認済み1件の名前を変更", 27, anchor="mm")
    draw.rounded_rectangle((105, 735, 680, 835), radius=26, fill=(18, 38, 58, 238))
    draw_text(draw, (392, 766), "demo_input.svs", 23, anchor="mm", english=True)
    draw_text(draw, (392, 809), "→  DEMO0001_2_CD68.svs", 25, anchor="mm", fill="#6FE4C4", english=True)
    footer(canvas, 5)
    return canvas


def output_card() -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    header(
        canvas,
        "06",
        "PNGとCSVをまとめて出力",
        "Original and proposed filenames are recorded for traceability",
    )
    rounded_panel(canvas, (70, 185, 950, 910), fill="#F7F9FC")
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw_text(draw, (110, 225), "SVS_Label_Renamer_Output", 27, fill=INK, english=True, rounded=True)
    files = [
        ("PNG", "demo_input_label.png", "label image"),
        ("PNG", "demo_input_macro.png", "scanner macro"),
        ("PNG", "demo_input_overview.png", "WSI overview"),
        ("CSV", "rename_preview.csv", "audit trail"),
    ]
    for index, (kind, name, description) in enumerate(files):
        y = 310 + index * 122
        draw.rounded_rectangle((110, y, 205, y + 76), radius=18, fill=ACCENT if kind == "PNG" else ACCENT_2)
        draw_text(draw, (158, y + 38), kind, 22, anchor="mm", english=True, rounded=True)
        draw_text(draw, (235, y + 20), name, 25, fill=INK, english=True)
        draw_text(draw, (235, y + 58), description, 18, fill=MUTED, english=True)
        draw.line((110, y + 98, 900, y + 98), fill="#DCE4EA", width=2)

    rounded_panel(canvas, (990, 185, 1530, 910), fill="#10263B")
    draw_text(draw, (1040, 235), "rename_preview.csv", 26, english=True, rounded=True)
    draw_text(draw, (1040, 300), "original_filename", 18, fill="#91ABC0", english=True)
    draw_text(draw, (1040, 340), "demo_input.svs", 23, fill=WHITE, english=True)
    draw_text(draw, (1040, 405), "new_filename", 18, fill="#91ABC0", english=True)
    draw_text(draw, (1040, 445), "DEMO0001_2_CD68.svs", 23, fill="#6FE4C4", english=True)
    draw.line((1040, 500, 1480, 500), fill="#35546C", width=2)
    draw_text(draw, (1040, 550), "pathology_number", 18, fill="#91ABC0", english=True)
    draw_text(draw, (1040, 590), "DEMO0001", 23, fill=WHITE, english=True)
    draw_text(draw, (1040, 650), "block / stain", 18, fill="#91ABC0", english=True)
    draw_text(draw, (1040, 690), "2 / CD68", 23, fill=WHITE, english=True)
    draw.rounded_rectangle((1040, 755, 1480, 835), radius=22, fill="#143D37")
    draw_text(draw, (1260, 795), "処理はすべてMac内で完結", 23, fill="#6FE4C4", anchor="mm")
    footer(canvas, 6)
    return canvas


def end_card(app_icon: Image.Image) -> Image.Image:
    canvas = gradient_background().convert("RGBA")
    draw = ImageDraw.Draw(canvas, "RGBA")
    place_image(canvas, app_icon, (640, 95, 960, 395), radius=65, contain=True, background=(0, 0, 0, 0))
    draw_text(draw, (800, 495), "SVS Label Renamer for macOS", 55, anchor="mm", english=True, rounded=True)
    draw_text(draw, (800, 570), "v0.3.0 Beta", 34, fill="#6FE4C4", anchor="mm", english=True, rounded=True)
    draw.rounded_rectangle((435, 650, 1165, 735), radius=42, fill=ACCENT)
    draw_text(draw, (800, 692), "GitHub Releases から無料でダウンロード", 28, anchor="mm")
    draw_text(
        draw,
        (800, 805),
        "ローカル処理 · 合成データのデモ · 診断用途ではありません",
        23,
        fill="#B9D2E5",
        anchor="mm",
    )
    draw_text(
        draw,
        (800, 856),
        "github.com/jtakeiuabjki/svs-label-renamer-for-macos",
        21,
        fill="#8FB5D1",
        anchor="mm",
        english=True,
    )
    footer(canvas, 6)
    return canvas


def load_image(path: Path) -> Image.Image:
    image = Image.open(path)
    image.load()
    return image.convert("RGBA")


def render_video(cards: list[Path], durations: list[float], output: Path, ffmpeg: str) -> None:
    transition = 0.5
    command = [ffmpeg, "-hide_banner", "-y"]
    for card, duration in zip(cards, durations, strict=True):
        command.extend(["-loop", "1", "-framerate", "30", "-t", str(duration), "-i", str(card)])

    filters: list[str] = []
    for index, duration in enumerate(durations):
        direction = 1 if index % 2 == 0 else -1
        zoom = "min(max(zoom,pzoom)+0.00018,1.025)"
        x = f"iw/2-(iw/zoom/2)+{direction}*4*sin(on/45)"
        y = "ih/2-(ih/zoom/2)"
        filters.append(
            f"[{index}:v]scale={WIDTH}:{HEIGHT},"
            f"zoompan=z='{zoom}':x='{x}':y='{y}':d=1:s={WIDTH}x{HEIGHT}:fps=30,"
            f"trim=duration={duration},setpts=PTS-STARTPTS,format=yuv420p[v{index}]"
        )

    current = "v0"
    elapsed = durations[0]
    for index in range(1, len(cards)):
        offset = elapsed - transition
        output_label = f"x{index}"
        filters.append(
            f"[{current}][v{index}]xfade=transition=fade:duration={transition}:offset={offset:.3f}[{output_label}]"
        )
        current = output_label
        elapsed += durations[index] - transition

    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            f"[{current}]",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "19",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "-map_metadata",
            "-1",
            str(output),
        ]
    )
    subprocess.run(command, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initial", type=Path, required=True, help="Synthetic-only initial app screenshot")
    parser.add_argument("--processed", type=Path, required=True, help="Synthetic-only processed app screenshot")
    parser.add_argument("--label", type=Path, required=True)
    parser.add_argument("--macro", type=Path, required=True)
    parser.add_argument("--overview", type=Path, required=True)
    parser.add_argument("--app-icon", type=Path, default=Path("Resources/AppIcon.icns"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--poster", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.poster.parent.mkdir(parents=True, exist_ok=True)

    initial = load_image(args.initial)
    processed = load_image(args.processed)
    label = load_image(args.label)
    macro = load_image(args.macro)
    overview = load_image(args.overview)
    app_icon = load_image(args.app_icon)

    rendered = [
        title_card(app_icon, processed, label),
        quicklook_card(overview),
        choose_card(initial),
        ocr_card(processed, label),
        quality_card(overview, macro, label),
        confirm_card(processed),
        output_card(),
        end_card(app_icon),
    ]
    card_paths: list[Path] = []
    for index, card in enumerate(rendered):
        path = args.work_dir / f"card-{index:02d}.png"
        card.convert("RGB").save(path, quality=95)
        card_paths.append(path)

    # Poster is a lossless copy of the opening card and remains small enough for README.
    rendered[0].convert("RGB").save(args.poster, optimize=True)
    durations = [5.0, 8.0, 7.0, 10.0, 9.0, 8.0, 7.0, 4.5]
    render_video(card_paths, durations, args.output, args.ffmpeg)
    expected_duration = sum(durations) - 0.5 * (len(durations) - 1)
    print(f"Rendered {args.output} ({expected_duration:.1f} seconds)")
    print(f"Poster: {args.poster}")


if __name__ == "__main__":
    main()
