#!/usr/bin/env python3
"""Create a small, fully synthetic Aperio SVS for demos and smoke tests.

The generated slide contains no patient material or identifiers.  It follows the
directory layout documented by OpenSlide for Aperio SVS files: a tiled baseline,
a stripped thumbnail, tiled pyramid levels, and stripped label/macro images.
"""

from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageDraw, ImageFont


FONT_REGULAR = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
FONT_BOLD = Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf")


def font(path: Path, size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    try:
        return ImageFont.truetype(str(path), size=size)
    except OSError:
        return ImageFont.load_default()


def synthetic_tissue(width: int = 2048, height: int = 1280) -> Image.Image:
    rng = random.Random(230)
    image = Image.new("RGB", (width, height), (250, 246, 247))
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer, "RGBA")

    # Broad eosin-like tissue islands.
    for island in range(24):
        cx = rng.randint(120, width - 120)
        cy = rng.randint(100, height - 100)
        rx = rng.randint(90, 260)
        ry = rng.randint(55, 160)
        points = []
        for step in range(36):
            angle = (2 * math.pi * step) / 36
            wobble = 0.78 + 0.30 * rng.random()
            points.append((
                cx + math.cos(angle) * rx * wobble,
                cy + math.sin(angle) * ry * wobble,
            ))
        color = (
            230 + rng.randint(0, 18),
            145 + rng.randint(0, 35),
            180 + rng.randint(0, 35),
            105,
        )
        draw.polygon(points, fill=color)
        draw.line(points + [points[0]], fill=(182, 99, 145, 90), width=3)

    # Fine purple nuclei and pale lumina make the overview look tissue-like,
    # while remaining clearly synthetic.
    for _ in range(1700):
        x = rng.randint(35, width - 35)
        y = rng.randint(35, height - 35)
        radius = rng.randint(2, 6)
        draw.ellipse(
            (x - radius, y - radius, x + radius, y + radius),
            fill=(91, 46, 122, rng.randint(90, 175)),
        )
    for _ in range(95):
        x = rng.randint(60, width - 60)
        y = rng.randint(60, height - 60)
        rx = rng.randint(12, 38)
        ry = rng.randint(8, 28)
        draw.ellipse(
            (x - rx, y - ry, x + rx, y + ry),
            fill=(255, 249, 250, 190),
            outline=(191, 119, 157, 120),
            width=2,
        )

    image = Image.alpha_composite(image.convert("RGBA"), layer).convert("RGB")
    overlay = ImageDraw.Draw(image)
    overlay.rounded_rectangle(
        (24, 24, 385, 78), radius=14, fill=(255, 255, 255), outline=(211, 205, 213), width=2
    )
    overlay.text(
        (45, 37), "SYNTHETIC WSI • DEMO ONLY", font=font(FONT_BOLD, 25), fill=(55, 47, 64)
    )
    return image


def synthetic_label() -> Image.Image:
    width, height = 560, 820
    image = Image.new("RGB", (width, height), (250, 248, 239))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((16, 16, width - 16, height - 16), radius=28, outline=(67, 85, 105), width=5)
    draw.rounded_rectangle((34, 35, 85, height - 35), radius=18, fill=(45, 116, 157))
    draw.text((116, 50), "DEMO • LOCAL ONLY", font=font(FONT_BOLD, 24), fill=(70, 78, 84))
    draw.text((112, 125), "DEMO0001", font=font(FONT_BOLD, 60), fill=(18, 27, 38))
    draw.line((112, 236, width - 45, 236), fill=(151, 157, 158), width=3)
    draw.text((115, 300), "BLOCK", font=font(FONT_REGULAR, 30), fill=(90, 93, 95))
    draw.text((310, 275), "2", font=font(FONT_BOLD, 76), fill=(24, 31, 39))
    draw.text((115, 480), "STAIN", font=font(FONT_REGULAR, 30), fill=(90, 93, 95))
    draw.text((112, 530), "CD68", font=font(FONT_BOLD, 90), fill=(40, 44, 50))
    draw.rounded_rectangle((112, 690, width - 48, 752), radius=14, fill=(230, 237, 238))
    draw.text((130, 708), "NO PATIENT DATA", font=font(FONT_BOLD, 23), fill=(65, 79, 84))
    return image


def synthetic_macro(tissue: Image.Image, label: Image.Image) -> Image.Image:
    width, height = 1400, 420
    image = Image.new("RGB", (width, height), (220, 226, 229))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        (40, 50, width - 40, height - 50),
        radius=34,
        fill=(249, 249, 246),
        outline=(135, 146, 151),
        width=4,
    )
    label_thumb = label.resize((180, 264), Image.Resampling.LANCZOS)
    tissue_thumb = tissue.resize((790, 260), Image.Resampling.LANCZOS)
    image.paste(label_thumb, (90, 78))
    image.paste(tissue_thumb, (390, 80))
    draw.rounded_rectangle((1210, 126, 1320, 294), radius=20, outline=(154, 164, 169), width=5)
    draw.text((490, 355), "SYNTHETIC MACRO • NO PATIENT DATA", font=font(FONT_BOLD, 24), fill=(70, 78, 84))
    return image


def write_demo_svs(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    tissue = synthetic_tissue()
    label = synthetic_label()
    macro = synthetic_macro(tissue, label)
    thumbnail = tissue.resize((512, 320), Image.Resampling.LANCZOS)
    level_one = tissue.resize((1024, 640), Image.Resampling.LANCZOS)
    level_two = tissue.resize((512, 320), Image.Resampling.LANCZOS)

    description = (
        "Aperio Image Library v12.4.3\n"
        "2048x1280 (256x256) RGB|Filename = DEMO_SAMPLE|AppMag = 20|MPP = 0.50"
    )
    common = dict(photometric="rgb", compression="deflate", metadata=None)
    with tifffile.TiffWriter(output, bigtiff=False) as writer:
        writer.write(
            np.asarray(tissue), tile=(256, 256), description=description,
            resolution=(20000, 20000), resolutionunit="CENTIMETER", **common
        )
        # Directory 1 is the Aperio thumbnail by position.
        writer.write(np.asarray(thumbnail), rowsperstrip=32, description="Aperio thumbnail", **common)
        writer.write(np.asarray(level_one), tile=(256, 256), description="Aperio pyramid level 1", **common)
        writer.write(np.asarray(level_two), tile=(256, 256), description="Aperio pyramid level 2", **common)
        # OpenSlide maps stripped directories with NewSubfileType 1/9 to
        # label/macro associated images.
        writer.write(
            np.asarray(label), rowsperstrip=32, subfiletype=1,
            description="Aperio synthetic label", **common
        )
        writer.write(
            np.asarray(macro), rowsperstrip=32, subfiletype=9,
            description="Aperio synthetic macro", **common
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", type=Path,
        default=Path("/private/tmp/SVSLabelRenamerDemo/demo_input.svs"),
    )
    args = parser.parse_args()
    write_demo_svs(args.output)
    print(args.output)


if __name__ == "__main__":
    main()
