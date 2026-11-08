#!/usr/bin/env python3
"""出 docs 用的两张对照图：

    docs/cape_wrap_compare.png   披风「平板模型」vs「圆弧包络」在 5 个视图上的范围差
    docs/nw_arm_compare.png      背面 3/4 的远侧胳膊：沉在披风后面 vs 压到披风前面

用法：python tools/make_layer_compare.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent


def _font(size: int):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf",
              "/System/Library/Fonts/PingFang.ttc",
              "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"):
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


F_T, F_S = _font(18), _font(15)
sys.path.insert(0, str(ROOT / "tools"))
import check_joint_gap as C  # noqa: E402

VIEWS = ["s", "sw", "w", "nw", "n"]
NAMES = ["S", "SW", "W", "NW", "N"]
BACK = {"s": False, "sw": False, "w": False, "nw": True, "n": True}
# 旧的「平板模型」：宽度按 (1-0.30·turn) 收，上沿偏 shift、下摆只偏一半
OLD = {
    "s":  dict(turn=0.00, narrow=1.00, look=0),
    "sw": dict(turn=0.80, narrow=0.90, look=-11),
    "w":  dict(turn=1.00, narrow=0.78, look=-15),
    "nw": dict(turn=0.80, narrow=0.90, look=-11),
    "n":  dict(turn=0.00, narrow=1.00, look=0),
}


def old_poly(v):
    p = OLD[v]
    t, cx = p["turn"], 128.0
    w = 28 * (0.86 + 0.14 * p["narrow"]) * (1.0 - 0.30 * t)
    shift = -p["look"] * 0.5
    return [(cx - w * 0.6 + shift, 106), (cx + w * 0.6 + shift, 106),
            (cx + w + shift * 0.5, 190), (cx - w + shift, 190)]


def cape_compare():
    CW, CH, PAD = 250, 470, 12
    sheet = Image.new("RGB", (CW * 5, CH * 2 + 46), (246, 247, 250))
    d0 = ImageDraw.Draw(sheet)
    d0.text((PAD, 8), "披风包络范围　上排：新（圆弧）　下排：粉线为旧（平板）模型", font=F_T, fill=(30, 32, 40))
    for i, v in enumerate(VIEWS):
        canvas, _ = C.composite(v, BACK[v], False)
        bg = Image.new("RGBA", (256, 256), (246, 247, 250, 255))
        bg.alpha_composite(canvas)
        crop = bg.crop((88, 96, 168, 200)).resize((CW - 2 * PAD, CH - 2 * PAD - 24),
                                                  Image.LANCZOS).convert("RGB")
        base = Image.new("RGB", (CW, CH), (246, 247, 250))
        base.paste(crop, (PAD, 34))
        db = ImageDraw.Draw(base)
        db.text((PAD, 8), NAMES[i], font=F_T, fill=(180, 0, 0))
        sheet.paste(base, (i * CW, 30))

        # 右格：同一张合成图 + 旧模型的多边形（洋红虚线）
        alt = base.copy()
        da = ImageDraw.Draw(alt)
        sx = (CW - 2 * PAD) / 80.0
        sy = (CH - 2 * PAD - 24) / 104.0
        pts = [((x - 88) * sx + PAD, (y - 96) * sy + 34) for x, y in old_poly(v)]
        da.line(pts + [pts[0]], fill=(220, 0, 140), width=2)
        da.text((PAD, 8), NAMES[i] + "　旧模型", font=F_T, fill=(220, 0, 140))
        sheet.paste(alt, (i * CW, CH + 44))
    out = ROOT / "docs" / "cape_wrap_compare.png"
    sheet.save(out)
    print("写出", out.relative_to(ROOT), sheet.size)


def nw_arm_compare():
    saved = {k: dict(row) for k, row in C.EXT_Z.items()}
    try:
        # 改前：远侧 arm_r 沉在披风(22) 后面
        C.EXT_Z.setdefault("nw", {})["arm_r"] = 8
        C.EXT_Z["nw"]["fore_r"] = 9
        before, _ = C.composite("nw", True, False)
        C.EXT_Z["nw"]["arm_r"] = 23
        C.EXT_Z["nw"]["fore_r"] = 24
        after, _ = C.composite("nw", True, False)
    finally:
        C.EXT_Z.clear()
        C.EXT_Z.update(saved)

    CW, CH = 300, 470
    sheet = Image.new("RGB", (CW * 2, CH + 30), (246, 247, 250))
    for i, (img, tag, col) in enumerate([(before, "改前：远臂 8（披风 22 之下）", (200, 0, 0)),
                                         (after, "改后", (0, 120, 60))]):
        bg = Image.new("RGBA", (256, 256), (246, 247, 250, 255))
        bg.alpha_composite(img)
        crop = bg.crop((100, 60, 176, 200)).resize((CW - 20, CH - 40), Image.LANCZOS)
        cell = Image.new("RGB", (CW, CH), (246, 247, 250))
        cell.paste(crop.convert("RGB"), (10, 30))
        ImageDraw.Draw(cell).text((10, 8), tag, font=F_T, fill=col)
        sheet.paste(cell, (i * CW, 0))
    out = ROOT / "docs" / "nw_arm_compare.png"
    sheet.save(out)
    print("写出", out.relative_to(ROOT), sheet.size)


if __name__ == "__main__":
    cape_compare()
    nw_arm_compare()
