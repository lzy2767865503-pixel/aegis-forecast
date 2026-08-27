#!/usr/bin/env python3
"""Generate first-party Quant Scenario Studio MSIX/Store artwork."""

from __future__ import annotations

import argparse
import io
from pathlib import Path

from PIL import Image, ImageDraw


PROJECT_ROOT = Path(__file__).resolve().parents[2]
ASSET_ROOT = PROJECT_ROOT / "desktop" / "windows" / "AegisForecast" / "Assets"
SCALES = (100, 125, 150, 200, 400)
TARGET_SIZES = (16, 24, 32, 48, 256)


def _scaled(value: int, scale: int) -> int:
    return (value * scale + 50) // 100


def _background(width: int, height: int, *, transparent: bool = False) -> Image.Image:
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    if transparent:
        return image
    draw = ImageDraw.Draw(image)
    for y in range(height):
        mix = y / max(1, height - 1)
        color = (
            round(7 + 3 * mix),
            round(19 + 23 * mix),
            round(31 + 35 * mix),
            255,
        )
        draw.line((0, y, width, y), fill=color)
    return image


def _draw_mark(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int]) -> None:
    left, top, right, bottom = box
    width = right - left
    height = bottom - top
    unit = min(width, height)
    cx = (left + right) / 2
    cy = (top + bottom) / 2

    shield = [
        (cx, top + unit * 0.03),
        (left + unit * 0.86, top + unit * 0.18),
        (left + unit * 0.81, top + unit * 0.68),
        (cx, top + unit * 0.96),
        (left + unit * 0.19, top + unit * 0.68),
        (left + unit * 0.14, top + unit * 0.18),
    ]
    outline = max(2, round(unit * 0.045))
    draw.polygon(shield, fill=(8, 42, 67, 245))
    draw.line(shield + [shield[0]], fill=(73, 154, 255, 255), width=outline, joint="curve")

    ring_box = (
        round(cx - unit * 0.23),
        round(cy - unit * 0.25),
        round(cx + unit * 0.23),
        round(cy + unit * 0.21),
    )
    ring_width = max(2, round(unit * 0.075))
    draw.ellipse(ring_box, outline=(224, 242, 255, 255), width=ring_width)
    draw.line(
        (
            cx + unit * 0.11,
            cy + unit * 0.11,
            cx + unit * 0.31,
            cy + unit * 0.32,
        ),
        fill=(224, 242, 255, 255),
        width=ring_width,
    )

    # Three scenario bars make the symbol recognizably quantitative even at
    # taskbar size, without depending on fonts or third-party artwork.
    bar_width = max(2, round(unit * 0.035))
    for offset, start, end in (
        (-0.12, 0.08, -0.03),
        (0.00, 0.03, -0.11),
        (0.12, -0.04, -0.18),
    ):
        x = cx + unit * offset
        draw.line(
            (x, cy + unit * start, x, cy + unit * end),
            fill=(79, 207, 183, 255),
            width=bar_width,
        )


def render_square(width: int, height: int, *, unplated: bool = False) -> Image.Image:
    supersample = 4 if max(width, height) <= 600 else 2
    w, h = width * supersample, height * supersample
    image = _background(w, h, transparent=unplated)
    draw = ImageDraw.Draw(image)
    if not unplated:
        radius = round(min(w, h) * 0.18)
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=255)
        image.putalpha(mask)
    padding = min(w, h) * (0.08 if unplated else 0.10)
    _draw_mark(draw, (round(padding), round(padding), round(w - padding), round(h - padding)))
    return image.resize((width, height), Image.Resampling.LANCZOS)


def render_landscape(width: int, height: int) -> Image.Image:
    supersample = 3 if width <= 620 else 2
    w, h = width * supersample, height * supersample
    image = _background(w, h)
    draw = ImageDraw.Draw(image)
    grid = (37, 73, 99, 150)
    for x in range(round(w * 0.43), w, max(1, round(w * 0.08))):
        draw.line((x, round(h * 0.18), x, round(h * 0.82)), fill=grid, width=max(1, w // 700))
    for y in (0.30, 0.50, 0.70):
        draw.line((round(w * 0.39), round(h * y), round(w * 0.92), round(h * y)), fill=grid, width=max(1, w // 700))
    mark_size = h * 0.72
    _draw_mark(
        draw,
        (
            round(w * 0.08),
            round((h - mark_size) / 2),
            round(w * 0.08 + mark_size),
            round((h + mark_size) / 2),
        ),
    )
    points = [
        (w * 0.43, h * 0.66),
        (w * 0.52, h * 0.57),
        (w * 0.60, h * 0.62),
        (w * 0.70, h * 0.43),
        (w * 0.79, h * 0.49),
        (w * 0.91, h * 0.27),
    ]
    draw.line(points, fill=(79, 207, 183, 255), width=max(3, round(h * 0.025)), joint="curve")
    for x, y in points:
        radius = max(3, round(h * 0.025))
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(139, 184, 255, 255))
    return image.resize((width, height), Image.Resampling.LANCZOS)


def expected_assets() -> dict[str, Image.Image]:
    assets: dict[str, Image.Image] = {
        "BrandMaster-1024.png": render_square(1024, 1024),
        "StoreListingLogo-300x300.png": render_square(300, 300),
    }
    nominal = {
        "Square44x44Logo": (44, 44, "square"),
        "Square150x150Logo": (150, 150, "square"),
        "StoreLogo": (50, 50, "square"),
        "Wide310x150Logo": (310, 150, "landscape"),
        "SplashScreen": (620, 300, "landscape"),
    }
    for stem, (width, height, kind) in nominal.items():
        renderer = render_square if kind == "square" else render_landscape
        assets[f"{stem}.png"] = renderer(width, height)
        for scale in SCALES:
            assets[f"{stem}.scale-{scale}.png"] = renderer(
                _scaled(width, scale), _scaled(height, scale)
            )
    for size in TARGET_SIZES:
        assets[f"Square44x44Logo.targetsize-{size}.png"] = render_square(size, size)
        assets[f"Square44x44Logo.targetsize-{size}_altform-unplated.png"] = render_square(
            size, size, unplated=True
        )
    return assets


def encoded_png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True, compress_level=9)
    return buffer.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    assets = expected_assets()
    ASSET_ROOT.mkdir(parents=True, exist_ok=True)
    drift: list[str] = []
    for name, image in assets.items():
        path = ASSET_ROOT / name
        content = encoded_png(image)
        if args.check:
            if not path.is_file() or path.read_bytes() != content:
                drift.append(name)
        else:
            path.write_bytes(content)
    if drift:
        raise SystemExit("Store artwork is missing or stale: " + ", ".join(drift))
    verb = "verified" if args.check else "generated"
    print(f"Store artwork {verb}: {len(assets)} first-party PNG files")


if __name__ == "__main__":
    main()
