#!/usr/bin/env python3
"""Genera assets/CandyIA.icns (requiere Pillow)."""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "assets")


def build_image() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    c1, c2 = (255, 77, 141), (139, 92, 246)
    grad = Image.new("RGB", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        col = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
        gd.line([(0, y), (S, y)], fill=col)

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=220, fill=255)
    img.paste(grad, (0, 0), mask)

    shine = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shine).ellipse([-180, -440, S + 180, 340], fill=70)
    img.paste((255, 255, 255), (0, 0), Image.composite(shine, Image.new("L", (S, S), 0), mask))

    cx = cy = S // 2
    r = 300

    halo = Image.new("L", (S, S), 0)
    ImageDraw.Draw(halo).ellipse(
        [cx - r - 60, cy - r - 60, cx + r + 60, cy + r + 60], fill=90
    )
    halo = halo.filter(ImageFilter.GaussianBlur(50))
    img.paste((255, 230, 245), (0, 0), halo)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - r, cy - r, cx + r, cy + r], fill=(139, 92, 246, 255))
    img.alpha_composite(shadow)

    sphere = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sg = ImageDraw.Draw(sphere)
    for i in range(r, 0, -1):
        t = i / r
        sg.ellipse([cx - i, cy - i, cx + i, cy + i],
                   fill=(255, int(255 - 60 * t), int(245 - 40 * t), 255))
    sphere_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sphere_mask).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    img.paste(sphere, (0, 0), sphere_mask)

    gl = Image.new("L", (S, S), 0)
    ImageDraw.Draw(gl).ellipse([cx - 130, cy - 210, cx + 20, cy - 90], fill=210)
    gl = gl.filter(ImageFilter.GaussianBlur(28))
    img.paste((255, 255, 255), (0, 0), Image.composite(gl, Image.new("L", (S, S), 0), sphere_mask))

    d = ImageDraw.Draw(img)
    d.ellipse([cx - 26, cy - 26, cx + 26, cy + 26], fill=(255, 255, 255, 235))
    return img


def main():
    img = build_image()
    iconset = os.path.join(OUT, "CandyIA.iconset")
    os.makedirs(iconset, exist_ok=True)
    sizes = [(16, "16"), (32, "16x16@2x"), (32, "32"), (64, "32x32@2x"),
             (128, "128"), (256, "128x128@2x"), (256, "256"), (512, "256x256@2x"),
             (512, "512"), (1024, "512x512@2x")]
    for px, name in sizes:
        img.resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{name}x{name}.png")
        )
    icns = os.path.join(OUT, "CandyIA.icns")
    rc = os.system(f'iconutil -c icns "{iconset}" -o "{icns}"')
    sys.exit(rc)


if __name__ == "__main__":
    main()
