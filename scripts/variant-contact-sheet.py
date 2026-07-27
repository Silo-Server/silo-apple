#!/usr/bin/env python3
"""Assemble Home variant screenshots into one side-by-side contact sheet.

Usage:
    variant-contact-sheet.py OUT.png LABEL=shot.png [LABEL=shot.png ...]

Built for the Design Lab evaluation: the whole point is judging five layouts
against each other, which needs them on one canvas at the same scale rather
than five separate images the eye has to compare from memory.
"""

import sys

from PIL import Image, ImageDraw, ImageFont

# Layout constants, in pixels of the output canvas.
PANEL_WIDTH = 420          # each phone shot is scaled to this width
GUTTER = 28                # space between panels
MARGIN = 34                # canvas edge padding
LABEL_HEIGHT = 58          # caption strip above each panel
BACKGROUND = (16, 16, 18)
LABEL_COLOR = (238, 238, 238)
SUBLABEL_COLOR = (150, 150, 155)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
]


def load_font(size):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    out_path = argv[1]
    entries = []
    for pair in argv[2:]:
        if "=" not in pair:
            print(f"bad argument (want LABEL=path): {pair}", file=sys.stderr)
            return 2
        label, path = pair.split("=", 1)
        entries.append((label, path))

    panels = []
    for label, path in entries:
        image = Image.open(path).convert("RGB")
        scale = PANEL_WIDTH / image.width
        resized = image.resize(
            (PANEL_WIDTH, max(1, round(image.height * scale))),
            Image.LANCZOS,
        )
        panels.append((label, resized))

    panel_height = max(p.height for _, p in panels)
    width = MARGIN * 2 + PANEL_WIDTH * len(panels) + GUTTER * (len(panels) - 1)
    height = MARGIN * 2 + LABEL_HEIGHT + panel_height

    canvas = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title_font = load_font(24)
    sub_font = load_font(16)

    x = MARGIN
    for label, panel in panels:
        # Caption: "V2" on the first line, the rest of the label beneath it.
        parts = label.split("·", 1)
        heading = parts[0].strip()
        sub = parts[1].strip() if len(parts) > 1 else ""

        draw.text((x, MARGIN), heading, font=title_font, fill=LABEL_COLOR)
        if sub:
            draw.text((x, MARGIN + 28), sub, font=sub_font, fill=SUBLABEL_COLOR)

        canvas.paste(panel, (x, MARGIN + LABEL_HEIGHT))
        x += PANEL_WIDTH + GUTTER

    canvas.save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path} ({width}x{height}, {len(panels)} panels)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
