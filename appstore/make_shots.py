#!/usr/bin/env python3
"""Composite raw simulator captures into captioned App Store screenshots.

Usage:
    python3 appstore/make_shots.py <raw_dir> <out_dir>

<raw_dir> is a fastlane snapshot language folder, e.g.
appstore/screenshots/raw/en-US, holding files named "<device>-<NN-name>.png".

Each capture is placed on a canvas at the exact App Store Connect pixel size for
its device, under a caption band. Output is written to <out_dir>/<slot>/ where
slot is the display size ("6.9", "6.5"), RGB with no alpha channel.
"""

import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

# Device -> (exact ASC canvas size, slot folder name).
DEVICES = {
    "iPhone 17 Pro Max": ((1320, 2868), "6.9"),
    "iPhone 11 Pro Max": ((1242, 2688), "6.5"),
}

CAPTIONS = {
    "01-pairing": "Scan once. Your Mac and phone are paired.",
    "02-prompt": "Your Mac asks. Your phone shows you exactly what.",
    "03-faceid": "Face ID before a single keystroke leaves your phone.",
    "04-unlocked": "Typed into the dialog. Never stored, never logged.",
    "05-logins": "CLI sign-ins land on your phone as a tap.",
}

BG = (11, 13, 18)          # matches Theme.background 0x0B0D12
FG = (255, 255, 255)
BAND_FRACTION = 0.11       # caption band height as a fraction of canvas height
SIDE_MARGIN = 0.075        # horizontal padding inside the band, per side
MAX_LINES = 2

FONT_CANDIDATES = [
    ("/System/Library/Fonts/SFNS.ttf", ["Semibold", "SFNS Semibold", "Display Semibold"]),
    ("/System/Library/Fonts/SFNSDisplay.ttf", ["Semibold"]),
    ("/System/Library/Fonts/Helvetica.ttc", []),
]


def load_font(size):
    """SF Semibold at `size`, falling back through the system font list."""
    for path, variations in FONT_CANDIDATES:
        if not os.path.exists(path):
            continue
        try:
            font = ImageFont.truetype(path, size)
        except OSError:
            continue
        for name in variations:
            try:
                font.set_variation_by_name(name)
                return font
            except Exception:
                continue
        return font
    return ImageFont.load_default()


def text_size(draw, text, font):
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    return right - left, bottom - top


def wrap(draw, text, font, max_width):
    """Greedy wrap. Returns None if any single word overflows max_width."""
    lines, current = [], ""
    for word in text.split():
        trial = word if not current else current + " " + word
        if text_size(draw, trial, font)[0] <= max_width:
            current = trial
        else:
            if not current:
                return None
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def fit_caption(draw, text, max_width, max_height):
    """Largest font size whose wrapped text fits the band. Returns (font, lines)."""
    for size in range(140, 17, -2):
        font = load_font(size)
        lines = wrap(draw, text, font, max_width)
        if not lines or len(lines) > MAX_LINES:
            continue
        line_h = size * 1.22
        if line_h * len(lines) <= max_height:
            return font, lines
    font = load_font(18)
    return font, [text]


def compose(raw_path, canvas_size, caption):
    canvas_w, canvas_h = canvas_size
    canvas = Image.new("RGB", canvas_size, BG)
    draw = ImageDraw.Draw(canvas)

    band_h = int(round(canvas_h * BAND_FRACTION))
    max_text_w = int(canvas_w * (1 - 2 * SIDE_MARGIN))
    font, lines = fit_caption(draw, caption, max_text_w, band_h * 0.72)

    # Vertically center the caption block inside the band.
    ascent, descent = font.getmetrics()
    line_h = int(round(font.size * 1.22))
    block_h = line_h * len(lines)
    y = (band_h - block_h) // 2 + (line_h - (ascent + descent)) // 2
    for line in lines:
        w = text_size(draw, line, font)[0]
        bbox_left = draw.textbbox((0, 0), line, font=font)[0]
        draw.text(((canvas_w - w) // 2 - bbox_left, y), line, font=font, fill=FG)
        y += line_h

    # Scale the capture to fit the area below the band, centered.
    shot = Image.open(raw_path).convert("RGB")
    avail_w, avail_h = canvas_w, canvas_h - band_h
    scale = min(avail_w / shot.width, avail_h / shot.height)
    new_size = (max(1, int(shot.width * scale)), max(1, int(shot.height * scale)))
    shot = shot.resize(new_size, Image.LANCZOS)
    canvas.paste(shot, ((canvas_w - new_size[0]) // 2,
                        band_h + (avail_h - new_size[1]) // 2))

    assert canvas.size == canvas_size, "%s != %s" % (canvas.size, canvas_size)
    return canvas


def parse(filename):
    """'iPhone 17 Pro Max-01-pairing.png' -> ('iPhone 17 Pro Max', '01-pairing')."""
    stem = re.sub(r"\.png$", "", filename, flags=re.I)
    for device in DEVICES:
        if stem.startswith(device + "-"):
            return device, stem[len(device) + 1:]
    return None, None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make_shots.py <raw_dir> <out_dir>")
    raw_dir, out_dir = sys.argv[1], sys.argv[2]

    written = 0
    for filename in sorted(os.listdir(raw_dir)):
        if not filename.lower().endswith(".png"):
            continue
        device, key = parse(filename)
        if device is None:
            print("skip (unknown device): %s" % filename)
            continue
        if key not in CAPTIONS:
            print("skip (no caption): %s" % filename)
            continue

        canvas_size, slot = DEVICES[device]
        out_folder = os.path.join(out_dir, slot)
        os.makedirs(out_folder, exist_ok=True)
        out_path = os.path.join(out_folder, "%s.png" % key.replace("-", "_"))

        compose(os.path.join(raw_dir, filename), canvas_size, CAPTIONS[key]).save(
            out_path, "PNG", optimize=True
        )
        print("%-16s %s  %dx%d" % (slot, out_path, canvas_size[0], canvas_size[1]))
        written += 1

    if written == 0:
        sys.exit("no screenshots composed from %s" % raw_dir)
    print("\ncomposed %d screenshot(s)" % written)


if __name__ == "__main__":
    main()
