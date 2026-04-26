#!/usr/bin/env python3
"""Generate the AudioBridge ("Bridge" in the Public Works suite) app icon.

Design system pulled directly from publicworks.design's CSS tokens:
  --dusk-blue-deep: 230 40% 22%
  --dusk-blue:      220 35% 38%
  --dusk-lavender:  260 25% 55%
  --dusk-amber:     30 95% 60%
  --dusk-gold:      42 95% 65%
  --ember:          18 85% 55%
  --cream:          40 30% 93%

Composition:
  - macOS squircle, dusk-sky gradient (deep navy -> lavender -> ember -> amber)
  - Glassmorphic overlay: soft top-left highlight + faint inner stroke
  - Mark: two mirrored Public Works stepped spirals joined by a horizontal
    bridge beam — the spiral is the PW house mark; mirroring + connecting
    them reads as "Bridge" within the suite (Pitch / Prism / Slice / Bridge).
  - Dusk-gold dots at the bridge endpoints for the connection accent.

The mark and the favicon spiral share the same stepped, rectilinear stroke
language so the suite reads as a family.

Outputs PNGs at every macOS-required size, then assembles AppIcon.icns.
"""

import colorsys
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "AppIcon.iconset")
ICNS_PATH = os.path.join(HERE, "AppIcon.icns")

SUPERSAMPLE = 4


def hsl(h_deg, s_pct, l_pct):
    r, g, b = colorsys.hls_to_rgb(h_deg / 360.0, l_pct / 100.0, s_pct / 100.0)
    return (int(r * 255), int(g * 255), int(b * 255))


# Public Works palette (HSL → RGB tuples).
DUSK_BLUE_DEEP = hsl(230, 40, 22)   # ~#222B5C
DUSK_BLUE      = hsl(220, 35, 38)   # ~#3F517F
DUSK_LAVENDER  = hsl(260, 25, 55)   # ~#7766A6
DUSK_AMBER     = hsl(30,  95, 60)   # ~#FA9333
DUSK_GOLD      = hsl(42,  95, 65)   # ~#FBC74D
EMBER          = hsl(18,  85, 55)   # ~#EE6A2B
CREAM          = hsl(40,  30, 93)   # ~#F2EBDD


def squircle_mask(size, radius_ratio=0.2235):
    """Apple's squircle approximated as a rounded rect at ~22.35% radius —
    the convention used by every third-party icon template; the difference
    from the true continuous curve is sub-pixel at icon resolutions."""
    s = size * SUPERSAMPLE
    r = int(s * radius_ratio)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=r, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def dusk_gradient(size):
    """Diagonal sunset gradient through the dusk palette: deep navy at the
    top-left, lavender at mid, ember through amber at the bottom-right."""
    s = size * SUPERSAMPLE
    img = Image.new("RGB", (s, s), DUSK_BLUE_DEEP)
    px = img.load()

    # Stops are placed along the top-left -> bottom-right diagonal (t in 0..1).
    stops = [
        (0.00, DUSK_BLUE_DEEP),
        (0.30, DUSK_BLUE),
        (0.52, DUSK_LAVENDER),
        (0.72, EMBER),
        (0.92, DUSK_AMBER),
        (1.00, DUSK_GOLD),
    ]

    def sample(t):
        for i in range(len(stops) - 1):
            t0, c0 = stops[i]
            t1, c1 = stops[i + 1]
            if t0 <= t <= t1:
                k = (t - t0) / (t1 - t0)
                # Smoothstep so band transitions stay gentle.
                k = k * k * (3 - 2 * k)
                return tuple(int(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
        return stops[-1][1]

    for y in range(s):
        for x in range(s):
            t = (x + y) / (2 * (s - 1))
            px[x, y] = sample(t)
    return img.resize((size, size), Image.LANCZOS)


def glass_highlight(size):
    """Soft white radial highlight near the top-left to read as a frosted
    glass surface picking up light. Public Works' site uses backdrop-blur
    glassmorphism; this is the static-image equivalent."""
    s = size * SUPERSAMPLE
    layer = Image.new("L", (s, s), 0)
    cx, cy = s * 0.30, s * 0.18
    rmax = s * 0.65
    px = layer.load()
    for y in range(s):
        for x in range(s):
            d = math.hypot(x - cx, y - cy)
            if d < rmax:
                v = (1 - d / rmax) ** 1.6
                px[x, y] = int(v * 95)
    rgba = Image.new("RGBA", (s, s), (255, 255, 255, 0))
    rgba.putalpha(layer)
    return rgba.resize((size, size), Image.LANCZOS)


def inner_glass_stroke(size):
    """A 1px-equivalent inner stroke at low opacity — the glass-edge highlight
    that makes glassmorphic surfaces read as 'lit from inside'."""
    s = size * SUPERSAMPLE
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r = int(s * 0.2235)
    inset = int(s * 0.012)
    d.rounded_rectangle(
        (inset, inset, s - 1 - inset, s - 1 - inset),
        radius=r - inset,
        outline=(255, 255, 255, 70),
        width=max(2, int(s * 0.005)),
    )
    return layer.resize((size, size), Image.LANCZOS)


def _draw_bridge(draw, s, color, stroke):
    """Stylized suspension-bridge pictogram in the rectilinear stroke
    language of Public Works.

    Composition on a 32-unit virtual grid scaled to canvas size s:
      - Two vertical pylons at x=10 and x=22, top y=6, bottom y=26
      - A horizontal cable spanning the pylon tops
      - Two diagonal suspension cables falling from each pylon top to the
        deck endpoints — these are what make it unambiguously a bridge
        rather than a generic frame
      - A heavier horizontal deck at y=18, extending past the pylons
    Visual hierarchy: deck > pylons > cables (thinner)."""
    u = s / 32.0

    def L(p1, p2, w=stroke):
        draw.line(
            [(p1[0] * u, p1[1] * u), (p2[0] * u, p2[1] * u)],
            fill=color,
            width=int(w),
        )

    deck_w  = max(int(stroke * 1.3), int(stroke + 2))
    cable_w = max(int(stroke * 0.75), 2)

    # Suspension cables (drawn first so the deck and pylons sit on top).
    L((10, 6),  (4, 18),  w=cable_w)
    L((22, 6),  (28, 18), w=cable_w)

    # Top cable + two pylons.
    L((10, 6),  (22, 6))
    L((10, 6),  (10, 26))
    L((22, 6),  (22, 26))

    # Deck — the thickest line in the mark.
    L((4, 18),  (28, 18), w=deck_w)


def _draw_anchors(draw, s, color, stroke):
    """Warm anchor dots where the deck meets each pylon — connection points
    that read as routing endpoints at every size."""
    u = s / 32.0
    dot_r = stroke * 1.25
    for cx in (10, 22):
        x, y = cx * u, 18 * u
        draw.ellipse((x - dot_r, y - dot_r, x + dot_r, y + dot_r), fill=color)


def draw_mark(size):
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    stroke = max(2, int(s * 0.033))

    _draw_bridge(d, s, CREAM, stroke)
    _draw_anchors(d, s, DUSK_GOLD, stroke)

    # Drop shadow rendered at the same geometry, blurred, low alpha.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    _draw_bridge(sd, s, (0, 0, 0, 130), stroke)
    _draw_anchors(sd, s, (0, 0, 0, 130), stroke)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=s * 0.014))

    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.alpha_composite(shadow, dest=(int(s * 0.004), int(s * 0.014)))
    out.alpha_composite(img)
    return out.resize((size, size), Image.LANCZOS)


def render_icon(size):
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    grad = dusk_gradient(size).convert("RGBA")
    grad.alpha_composite(glass_highlight(size))
    grad.alpha_composite(inner_glass_stroke(size))
    grad.alpha_composite(draw_mark(size))

    base.paste(grad, (0, 0), squircle_mask(size))
    return base


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    sizes = [
        (16,   "icon_16x16.png"),
        (32,   "icon_16x16@2x.png"),
        (32,   "icon_32x32.png"),
        (64,   "icon_32x32@2x.png"),
        (128,  "icon_128x128.png"),
        (256,  "icon_128x128@2x.png"),
        (256,  "icon_256x256.png"),
        (512,  "icon_256x256@2x.png"),
        (512,  "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    master = render_icon(1024)
    master.save(os.path.join(HERE, "AppIcon-1024.png"))

    for size, name in sizes:
        # Re-render below 256 so the stroke weights stay crisp; downsample
        # the 1024 master for everything else.
        img = master.resize((size, size), Image.LANCZOS) if size >= 256 else render_icon(size)
        img.save(os.path.join(OUT_DIR, name))
        print(f"  wrote {name}  ({size}x{size})")

    print("\nRunning iconutil...")
    subprocess.run(["iconutil", "-c", "icns", OUT_DIR, "-o", ICNS_PATH], check=True)
    print(f"  -> {ICNS_PATH}")


if __name__ == "__main__":
    main()
