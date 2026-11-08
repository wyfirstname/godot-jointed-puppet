#!/usr/bin/env python3
"""三套服装的合成对照图（给美术看，不参与运行时）。

    python tools/preview_outfits.py  ->  docs/outfits.png

每行一套衣服、每列一个视图，按 layer_rules.json 的 z 表排序合成。
换装只要给槽位指定变体名，z 序完全不用动 —— 这张图就是验证这件事的。
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
VIEWS = ["s", "sw", "w", "nw", "n"]

# 槽位 -> (默认文件 stem, 变体 stem 模板)
BASE = ["cape", "hair_back", "leg_l", "leg_r", "shin_l", "shin_r",
        "body", "arm_l", "arm_r", "fore_l", "fore_r", "head", "face",
        "hair_front", "weapon"]


def stem(slot: str, variants: dict) -> str | None:
    """variants[slot] = 变体名 | None(=不戴) | 缺省(=默认)"""
    if slot not in variants:
        return slot if slot in BASE else None
    v = variants[slot]
    # v 为 None 表示「摘掉这个部件」——第一版把条件写反了，
    # 结果变成「只有 None 时才显示」，该藏的披风全冒了出来
    return None if v is None else f"{slot}_{v}"


OUTFITS = [
    # face 槽位没有"默认文件"——它全是变体命名（face_neutral_*），
    # 所以每套都要显式指一个表情，否则合成出来是一张没有五官的脸
    ("骑士（默认）", {"face": "neutral"}),
    ("法师长袍", {"cape": None, "hair_front": None, "face": "neutral",
                  "body": "robe", "arm_l": "robe", "arm_r": "robe",
                  "fore_l": "robe", "fore_r": "robe", "hat": "wizard"}),
    ("游侠皮甲", {"cape": None, "face": "smile",
                  "body": "leather", "arm_l": "leather", "arm_r": "leather",
                  "fore_l": "leather", "fore_r": "leather",
                  "shin_l": "boot", "shin_r": "boot", "hat": "hood"}),
]


def compose(view: str, variants: dict, z: dict, z_s: dict) -> Image.Image:
    base = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    # z 表是逐视图导出的，新槽位（face）可能还没进某些视图 —— 用 s 视图兜底
    zz = dict(z_s)
    zz.update(z)
    layers = []
    for slot in list(zz.keys()) + [s for s in BASE if s not in zz]:
        s = stem(slot, variants)
        if not s:
            continue
        p = PARTS / slot / f"{s}_puppet_{view}.png"
        if p.exists():
            layers.append((zz.get(slot, 0), slot, p))
    for _, _, p in sorted(layers, key=lambda t: t[0]):
        base.alpha_composite(Image.open(p).convert("RGBA"))
    return base


def main() -> int:
    rules = json.loads((ROOT / "data" / "layer_rules.json").read_text(encoding="utf-8"))
    cell, pad = 240, 8
    zoom = 1.5
    w = int(cell * zoom) + pad
    grid = Image.new("RGB", (w * len(VIEWS) + pad, (int(cell * zoom) + pad) * len(OUTFITS) + pad),
                     (238, 240, 248))
    for r, (name, variants) in enumerate(OUTFITS):
        for c, view in enumerate(VIEWS):
            im = compose(view, variants, rules["z"][view], rules["z"]["s"])
            # 裁掉锚点以下和两侧的空白，人像才占满格子
            im = im.crop((60, 30, 200, 232))
            im = im.resize((int(im.width * zoom), int(im.height * zoom)), Image.NEAREST)
            bg = Image.new("RGBA", im.size, (238, 240, 248, 255))
            bg.alpha_composite(im)
            grid.paste(bg.convert("RGB"), (pad + c * w, pad + r * (int(cell * zoom) + pad)))
    out = ROOT / "docs" / "outfits.png"
    grid.save(out)
    print("写出", out.relative_to(ROOT), grid.size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
