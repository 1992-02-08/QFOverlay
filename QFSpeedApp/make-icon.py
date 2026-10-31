#!/usr/bin/env python3
"""给 App 生成图标：深色底 + 一条亮色浮条 + 上下箭头。尺寸按 iOS 规范出 120 / 180。"""
import sys
import os
from PIL import Image, ImageDraw

BG_TOP = (30, 44, 66, 255)
BG_BOTTOM = (12, 16, 24, 255)
ACCENT = (10, 132, 255, 255)
DOWN = (124, 208, 255, 255)
UP = (150, 232, 172, 255)


def render(size):
    S = size * 4
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    grad = Image.new("RGBA", (1, S))
    for y in range(S):
        t = y / max(S - 1, 1)
        grad.putpixel((0, y), tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(4)))
    img.paste(grad.resize((S, S)), (0, 0))

    d = ImageDraw.Draw(img)
    # 浮条
    bar = [S * 0.13, S * 0.40, S * 0.87, S * 0.62]
    d.rounded_rectangle(bar, radius=int(S * 0.075), fill=(255, 255, 255, 26))
    d.rounded_rectangle(bar, radius=int(S * 0.075), outline=ACCENT, width=max(2, int(S * 0.012)))

    # 两个箭头
    def arrow(cx, color, up):
        top, bottom = S * 0.455, S * 0.565
        head_w, head_h, shaft_w = S * 0.075, S * 0.048, S * 0.024
        if up:
            d.polygon([(cx - head_w / 2, top + head_h), (cx + head_w / 2, top + head_h), (cx, top)], fill=color)
            d.rectangle([cx - shaft_w / 2, top + head_h - 1, cx + shaft_w / 2, bottom], fill=color)
        else:
            d.polygon([(cx - head_w / 2, bottom - head_h), (cx + head_w / 2, bottom - head_h), (cx, bottom)], fill=color)
            d.rectangle([cx - shaft_w / 2, top, cx + shaft_w / 2, bottom - head_h + 1], fill=color)

    arrow(S * 0.40, DOWN, False)
    arrow(S * 0.60, UP, True)

    # 底部三条速度刻度
    for i, w in enumerate([0.16, 0.10, 0.06]):
        y = S * (0.70 + i * 0.045)
        d.rounded_rectangle([S * 0.13, y, S * (0.13 + w), y + S * 0.018],
                            radius=S * 0.009, fill=(255, 255, 255, int(150 - i * 40)))

    return img.resize((size, size), Image.LANCZOS)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    for name, size in (("Icon-60@2x.png", 120), ("Icon-60@3x.png", 180), ("AppIcon.png", 1024)):
        path = os.path.join(out_dir, name)
        render(size).save(path, "PNG")
        print(f"    {name} {size}x{size}")


if __name__ == "__main__":
    main()
