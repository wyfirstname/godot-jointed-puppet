#!/usr/bin/env python3
"""为每个槽位出一张对齐参考图，垫在画布下面画新部件。

    python tools/part_guide.py            # 全部槽位
    python tools/part_guide.py --slot hat # 只出一个

产物 docs/templates/guide_{槽位}.png：五个视图并排，每格 256×256，
带下面这些东西 ——

    · 地面线 y=216 / 中轴 x=128
    · 该槽位挂的关节（红十字）+ 关节名
    · 现有变体的包围盒（虚线框）：新部件画进这个范围就基本不会错位
    · 半透明的现有素材：直接描着画，比看数字快

为什么用「现成素材垫底」而不是只给框：包围盒只说明外接矩形，
姿势、胖瘦、暗面朝向全在像素里。垫着画能把这三样一起对上。
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
RULES = ROOT / "data" / "layer_rules.json"
OUT_DIR = ROOT / "docs" / "templates"

VIEWS = ["s", "sw", "w", "nw", "n"]
CELL, GAP, HEAD = 256, 10, 30
GROUND, AXIS = 216, 128


def load_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def find_variants(slot: str) -> dict[str, dict[str, Path]]:
    d = PARTS / slot
    if not d.is_dir():
        return {}
    out: dict[str, dict[str, Path]] = {}
    for f in sorted(d.glob("*_puppet_*.png")):
        stem = f.name.split("_puppet_")[0]
        view = f.name.rsplit("_", 1)[1].removesuffix(".png")
        if view not in VIEWS:
            continue
        var = stem[len(slot) + 1:] if stem != slot else "default"
        out.setdefault(var, {})[view] = f
    return out


def bbox_of(p: Path):
    im = Image.open(p).convert("RGBA")
    bb = im.getchannel("A").getbbox()
    return im, bb


def dashed(d: ImageDraw.ImageDraw, box, color, dash=5, width=1):
    x0, y0, x1, y1 = box
    for x in range(x0, x1, dash * 2):
        d.line([(x, y0), (min(x + dash, x1), y0)], fill=color, width=width)
        d.line([(x, y1), (min(x + dash, x1), y1)], fill=color, width=width)
    for y in range(y0, y1, dash * 2):
        d.line([(x0, y), (x0, min(y + dash, y1))], fill=color, width=width)
        d.line([(x1, y), (x1, min(y + dash, y1))], fill=color, width=width)


def sheet(slot: str, joint: str, joint_pos, variants: dict[str, dict[str, Path]]) -> Image.Image:
    W = len(VIEWS) * CELL + (len(VIEWS) + 1) * GAP
    H = HEAD + CELL + GAP
    out = Image.new("RGBA", (W, H), (24, 28, 34, 255))
    d = ImageDraw.Draw(out)
    d.text((8, 8), "%s  ->  joint %s @ (%.0f,%.0f)   ground y=%d  axis x=%d"
           % (slot, joint, joint_pos[0], joint_pos[1], GROUND, AXIS),
           fill=(210, 218, 230, 255))

    ref = variants.get("default") or (variants[sorted(variants)[0]] if variants else {})
    for i, view in enumerate(VIEWS):
        ox = GAP + i * (CELL + GAP)
        oy = HEAD
        cell = Image.new("RGBA", (CELL, CELL), (18, 20, 25, 255))
        cd = ImageDraw.Draw(cell)

        # 网格：每 32px 一条淡线，方便数像素
        for g in range(0, CELL + 1, 32):
            cd.line([(g, 0), (g, CELL)], fill=(38, 42, 50, 255))
            cd.line([(0, g), (CELL, g)], fill=(38, 42, 50, 255))

        # 现有素材垫底（半透明）
        src = ref.get(view)
        if src and src.exists():
            im, bb = bbox_of(src)
            if bb:                       # 全透明的视图（比如某些槽位没画背面）就只画参考线
                fade = im.copy()
                a = fade.getchannel("A").point(lambda v: int(v * 0.30))
                fade.putalpha(a)
                cell.alpha_composite(fade)
                dashed(cd, bb, (90, 140, 200, 255))
                cd.text((6, CELL - 14), "bbox %d,%d-%d,%d" % bb, fill=(120, 170, 220, 255))
            else:
                cd.text((6, CELL - 14), "blank art", fill=(150, 110, 90, 255))
        else:
            cd.text((6, CELL - 14), "no art yet", fill=(150, 110, 90, 255))

        # 中轴 / 地面线
        cd.line([(AXIS, 0), (AXIS, CELL)], fill=(70, 80, 95, 255))
        cd.line([(0, GROUND), (CELL, GROUND)], fill=(120, 90, 60, 255))

        # 关节十字
        jx, jy = joint_pos
        r = 4
        cd.ellipse([jx - r, jy - r, jx + r, jy + r], outline=(255, 90, 90, 255))
        cd.line([(jx - 9, jy), (jx + 9, jy)], fill=(255, 90, 90, 255))
        cd.line([(jx, jy - 9), (jx, jy + 9)], fill=(255, 90, 90, 255))

        cd.text((6, 6), view, fill=(200, 210, 225, 255))
        out.alpha_composite(cell, (ox, oy))
        d.rectangle([ox - 1, oy - 1, ox + CELL, oy + CELL], outline=(55, 60, 70, 255))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slot", default=None)
    args = ap.parse_args()

    rig = load_json(RULES)["_rig"]
    joints = {j["name"]: j["pos"] for j in rig["joints"]}
    slot_joint = rig["slot_joint"]

    slots = [args.slot] if args.slot else sorted(
        {p.name for p in PARTS.iterdir() if p.is_dir()})
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    n = 0
    for slot in slots:
        variants = find_variants(slot)
        jn = slot_joint.get(slot)
        if not jn:
            print("跳过 %s：layer_rules.json 的 slot_joint 里没有它" % slot)
            continue
        img = sheet(slot, jn, joints[jn], variants)
        p = OUT_DIR / ("guide_%s.png" % slot)
        img.save(p)
        print("写出 %s  %dx%d" % (p.relative_to(ROOT), img.width, img.height))
        n += 1
    print("共 %d 张参考图" % n)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
