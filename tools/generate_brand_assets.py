#!/usr/bin/env python3
"""
Lexora v2.0.0 — Brand Asset Generator
Pure Python standard library (zero external dependencies) with 4x4 SSAA anti-aliasing.
Generates all mipmap-mdpi..xxxhdpi ic_launcher.png and ic_launcher_round.png icons
and cleans up default Flutter launcher assets.
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# Brand palette (RGBA 0..255)
BG_NAVY = (0x10, 0x15, 0x20)        # #101520 deep night navy
BG_GLOW = (0x1A, 0x23, 0x36)        # subtle center glow
EMERALD = (0x2A, 0x6F, 0x5E)        # #2A6F5E emerald spine / inner arc
EMERALD_BRIGHT = (0x3A, 0x95, 0x7E) # #3A957E open page accent / inner wave
SAPPHIRE = (0x3B, 0x7D, 0xD8)       # #3B7DD8 sapphire book base / outer wave
SAPPHIRE_LIGHT = (0x5E, 0x9D, 0xF0) # #5E9DF0 highlight crest

MIPMAP_SIZES: dict[str, int] = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def encode_rgba_png(width: int, height: int, pixels: bytearray) -> bytes:
    """Encode an RGBA bytearray (width * height * 4) into a valid PNG."""
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # Filter type 0 (None)
        start = y * stride
        raw.extend(pixels[start : start + stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    compressed = zlib.compress(bytes(raw), level=9)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def _sd_rounded_box(px: float, py: float, cx: float, cy: float, hx: float, hy: float, r: float) -> float:
    dx = abs(px - cx) - (hx - r)
    dy = abs(py - cy) - (hy - r)
    ox = dx if dx > 0.0 else 0.0
    oy = dy if dy > 0.0 else 0.0
    inside = min(max(dx, dy), 0.0)
    return math.hypot(ox, oy) + inside - r


def _sd_segment(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    pax = px - ax
    pay = py - ay
    bax = bx - ax
    bay = by - ay
    denom = bax * bax + bay * bay
    h = 0.0 if denom == 0.0 else max(0.0, min(1.0, (pax * bax + pay * bay) / denom))
    dx = pax - bax * h
    dy = pay - bay * h
    return math.hypot(dx, dy)


def _sd_arc(
    px: float,
    py: float,
    cx: float,
    cy: float,
    radius: float,
    half_thick: float,
    ang_min: float,
    ang_max: float,
) -> float:
    """Signed distance to a circular arc in standard screen coords (y down).
    Angles are in radians from +x axis (up-right quadrant has negative angles: -pi/2..0).
    """
    dx = px - cx
    dy = py - cy
    ang = math.atan2(dy, dx)
    if ang_min <= ang <= ang_max:
        return abs(math.hypot(dx, dy) - radius) - half_thick
    # Distance to nearest rounded endcap
    e1x = cx + radius * math.cos(ang_min)
    e1y = cy + radius * math.sin(ang_min)
    e2x = cx + radius * math.cos(ang_max)
    e2y = cy + radius * math.sin(ang_max)
    d1 = math.hypot(px - e1x, py - e1y)
    d2 = math.hypot(px - e2x, py - e2y)
    return min(d1, d2) - half_thick


def _sample_lexora_icon(u: float, v: float, is_round: bool) -> tuple[float, float, float, float]:
    """
    Evaluate icon color (r, g, b, a in 0..255) at normalized coordinate u, v in [0, 108].
    Matches Android adaptive icon 108dp viewport with 66dp safe zone (center 54,54, r=33).
    """
    # Shape mask
    if is_round:
        mask_d = math.hypot(u - 54.0, v - 54.0) - 52.0
    else:
        # Clean rounded-square legacy launcher icon (Android Material proportions)
        mask_d = _sd_rounded_box(u, v, 54.0, 54.0, 49.0, 49.0, 13.0)

    if mask_d > 0.0:
        return (0.0, 0.0, 0.0, 0.0)

    # Background: deep navy #101520 with subtle center radial lift
    dist_c = math.hypot(u - 54.0, v - 50.0) / 68.0
    glow = max(0.0, 1.0 - dist_c * dist_c)
    r = BG_NAVY[0] + (BG_GLOW[0] - BG_NAVY[0]) * glow
    g = BG_NAVY[1] + (BG_GLOW[1] - BG_NAVY[1]) * glow
    b = BG_NAVY[2] + (BG_GLOW[2] - BG_NAVY[2]) * glow

    # Subtle outer inner-rim hairline
    if mask_d > -1.4:
        r = r * 0.72 + 0x2A * 0.28
        g = g * 0.72 + 0x3A * 0.28
        b = b * 0.72 + 0x52 * 0.28

    # Emblem elements inside safe zone (x in [31..77], y in [28..78], all within r <= 31 of (54,54)):
    # 1) Secondary open-book under-page leaf (Emerald bright accent)
    d_underpage = _sd_segment(u, v, 42.0, 74.5, 73.0, 71.0) - 2.3
    if d_underpage <= 0.0:
        r, g, b = EMERALD_BRIGHT

    # 2) Horizontal open-book base stroke of 'L' (Sapphire #3B7DD8, sweeping slightly upward like an open page)
    d_base = _sd_segment(u, v, 39.5, 70.5, 72.5, 65.5) - 5.2
    if d_base <= 0.0:
        # Subtle top-edge sheen along the page
        t = max(0.0, min(1.0, (u - 39.5) / 33.0))
        r = SAPPHIRE[0] + (SAPPHIRE_LIGHT[0] - SAPPHIRE[0]) * (0.25 * t)
        g = SAPPHIRE[1] + (SAPPHIRE_LIGHT[1] - SAPPHIRE[1]) * (0.25 * t)
        b = SAPPHIRE[2] + (SAPPHIRE_LIGHT[2] - SAPPHIRE[2]) * (0.25 * t)

    # 3) Vertical spine / stem of 'L' (Emerald #2A6F5E)
    d_stem = _sd_rounded_box(u, v, 39.0, 52.5, 5.4, 21.5, 4.4)
    if d_stem <= 0.0:
        # Slight vertical highlight on left spine edge
        t = max(0.0, min(1.0, (44.4 - u) / 10.8))
        r = EMERALD[0] + (EMERALD_BRIGHT[0] - EMERALD[0]) * (0.35 * t)
        g = EMERALD[1] + (EMERALD_BRIGHT[1] - EMERALD[1]) * (0.35 * t)
        b = EMERALD[2] + (EMERALD_BRIGHT[2] - EMERALD[2]) * (0.35 * t)

    # 4) Book spine fold accent notch at the L elbow (deep navy crease)
    d_fold = _sd_segment(u, v, 44.4, 65.5, 44.4, 72.5) - 0.85
    if d_fold <= 0.0:
        r, g, b = BG_NAVY

    # 5) Acoustic sound wave arcs radiating from the inner elbow of 'L' (top-right negative space)
    # Center of wave emission: (48.0, 58.0)
    # Inner dot
    if math.hypot(u - 51.0, v - 55.0) <= 2.7:
        r, g, b = EMERALD_BRIGHT

    # Inner wave arc (Emerald bright)
    d_arc1 = _sd_arc(u, v, 48.0, 58.0, 12.2, 2.0, -1.32, -0.22)
    if d_arc1 <= 0.0:
        r, g, b = EMERALD_BRIGHT

    # Outer wave arc (Sapphire)
    d_arc2 = _sd_arc(u, v, 48.0, 58.0, 20.8, 2.0, -1.36, -0.14)
    if d_arc2 <= 0.0:
        r, g, b = SAPPHIRE_LIGHT

    return (r, g, b, 255.0)


def render_icon(size: int, is_round: bool) -> bytes:
    """Render size x size RGBA icon using 4x4 Super-Sampled Anti-Aliasing (SSAA)."""
    pixels = bytearray(size * size * 4)
    scale = 108.0 / float(size)
    # 4x4 stratified subpixel offsets
    offsets = (0.125, 0.375, 0.625, 0.875)
    inv_samples = 1.0 / 16.0

    idx = 0
    for y in range(size):
        for x in range(size):
            sr = 0.0
            sg = 0.0
            sb = 0.0
            sa = 0.0
            for oy in offsets:
                v = (y + oy) * scale
                for ox in offsets:
                    u = (x + ox) * scale
                    cr, cg, cb, ca = _sample_lexora_icon(u, v, is_round)
                    # Premultiplied alpha accumulation avoids dark fringe halos
                    a_norm = ca / 255.0
                    sr += cr * a_norm
                    sg += cg * a_norm
                    sb += cb * a_norm
                    sa += ca

            avg_a = sa * inv_samples
            if avg_a > 0.5:
                inv_a = 255.0 / (avg_a * 16.0)
                out_r = min(255, max(0, int(round(sr * inv_a))))
                out_g = min(255, max(0, int(round(sg * inv_a))))
                out_b = min(255, max(0, int(round(sb * inv_a))))
                out_a = min(255, max(0, int(round(avg_a))))
            else:
                out_r = out_g = out_b = out_a = 0

            pixels[idx] = out_r
            pixels[idx + 1] = out_g
            pixels[idx + 2] = out_b
            pixels[idx + 3] = out_a
            idx += 4

    return encode_rgba_png(size, size, pixels)


def cleanup_legacy_flutter_icons(res_dir: Path) -> None:
    """Remove any stray default Flutter launcher assets (e.g., webp) from mipmap folders."""
    for folder in MIPMAP_SIZES:
        d = res_dir / folder
        if not d.exists():
            continue
        for fname in ("ic_launcher.webp", "ic_launcher_round.webp", "ic_launcher_foreground.png"):
            p = d / fname
            if p.exists():
                p.unlink()


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    res_dir = repo_root / "android" / "app" / "src" / "main" / "res"
    res_dir.mkdir(parents=True, exist_ok=True)
    cleanup_legacy_flutter_icons(res_dir)

    generated = 0
    for folder, size in MIPMAP_SIZES.items():
        out_dir = res_dir / folder
        out_dir.mkdir(parents=True, exist_ok=True)

        sq_path = out_dir / "ic_launcher.png"
        sq_bytes = render_icon(size, is_round=False)
        sq_path.write_bytes(sq_bytes)
        generated += 1

        rnd_path = out_dir / "ic_launcher_round.png"
        rnd_bytes = render_icon(size, is_round=True)
        rnd_path.write_bytes(rnd_bytes)
        generated += 1

        print(f"Generated {folder}: ic_launcher.png ({size}x{size}), ic_launcher_round.png ({size}x{size})")

    print(f"Lexora brand assets complete ({generated} PNG icons with 4x4 SSAA).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
