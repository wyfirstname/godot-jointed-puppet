"""表情对照图：6 种表情 × 3 个可见脸的视图（s / sw / w）。

只合成 head + face + hair_front 三层（z 30 / 32 / 34），
裁出头部区域放大 —— 检查表情时不需要整身。

用法：python tools/preview_expressions.py
输出：docs/faces_expr.png
"""

from pathlib import Path

from PIL import Image

ROOT = Path("assets/parts")
VIEWS = ["s", "sw", "w"]
EXPRS = ["neutral", "smile", "angry", "sad", "surprise", "blink"]
BOX = (76, 44, 180, 112)      # 头部裁剪窗口（画布坐标）
SCALE = 3


def head_image(view, expr):
    base = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    for name in (f"head/head_puppet_{view}.png",
                 f"face/face_{expr}_puppet_{view}.png",
                 f"hair_front/hair_front_puppet_{view}.png"):
        p = ROOT / name
        if p.exists():
            base.alpha_composite(Image.open(p).convert("RGBA"))
    return base


def main():
    w = (BOX[2] - BOX[0]) * SCALE
    h = (BOX[3] - BOX[1]) * SCALE
    pad = 8
    sheet = Image.new("RGB", (len(VIEWS) * (w + pad) + pad,
                              len(EXPRS) * (h + pad) + pad), (238, 240, 248))
    for r, expr in enumerate(EXPRS):
        for c, view in enumerate(VIEWS):
            cell = head_image(view, expr).crop(BOX).resize((w, h), Image.NEAREST)
            sheet.paste(cell, (pad + c * (w + pad), pad + r * (h + pad)), cell)
    out = Path("docs/faces_expr.png")
    out.parent.mkdir(exist_ok=True)
    sheet.save(out)
    print("saved", out, sheet.size)


if __name__ == "__main__":
    main()
