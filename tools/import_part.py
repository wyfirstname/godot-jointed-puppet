#!/usr/bin/env python3
"""把外来素材收进部件库 —— 裁画布、对挂点、二值化硬边、自动生成染色遮罩。

    python tools/import_part.py --art 我画的帽子.png \
        --slot hat --variant tophat --view s \
        [--pivot 128,64] [--scale 1.0] \
        [--main-colors "#333344,#22222e"] [--skin-colors ...] [--metal-colors ...]

五个视图各跑一次（--view s / sw / w / nw / n）。全部收完跑：

    python tools/check_part.py --slot hat --variant tophat   # 验收
    python tools/gen_character_designer.py                   # 上货架

它做了什么：
  1. 任意尺寸 RGBA -> 缩放（--scale）-> alpha 二值化（128 阈值，边缘变硬边，
     遮罩判定和描边都靠硬边；--no-binarize 可关）
  2. 把 --pivot 指的源像素对齐到该槽位挂点（默认用包围盒中心）
  3. 遮罩自动分类：像素和 --skin-colors / --metal-colors 里任一颜色的
     曼哈顿距离 < --tol 就算皮肤/金属，暗于 --outline-dark 的算描边（不染），
     其余可见像素全部算主色。三份色表都不给 = 整件主色。
  4. 写出 assets/parts/{slot}/{slot}[_{variant}]_puppet_{view}.png 和 _mask_

注意：这工具管「进场」，不管「好看」。风格不搭、比例不对，它一句都查不出来 ——
进场前先拿 docs/templates/guide_{槽位}.png 当参考比一比。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
RULES = ROOT / "data" / "layer_rules.json"
CELL = 256


def hexes(s: str | None) -> list[tuple[int, int, int]]:
    if not s:
        return []
    out = []
    for tok in s.split(","):
        tok = tok.strip().lstrip("#")
        if len(tok) == 3:
            tok = "".join(c * 2 for c in tok)
        out.append((int(tok[0:2], 16), int(tok[2:4], 16), int(tok[4:6], 16)))
    return out


def parse_pivot(s: str | None, w: int, h: int):
    if not s:
        return w / 2.0, h / 2.0
    x, y = s.split(",")
    return float(x), float(y)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", type=Path, required=True)
    ap.add_argument("--slot", required=True)
    ap.add_argument("--variant", default="")
    ap.add_argument("--view", required=True, choices=["s", "sw", "w", "nw", "n"])
    ap.add_argument("--pivot", help="源图上要对到挂点的像素 x,y（默认包围盒中心）")
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--main-colors", default="")
    ap.add_argument("--skin-colors", default="")
    ap.add_argument("--metal-colors", default="")
    ap.add_argument("--tol", type=float, default=60.0, help="颜色匹配的曼哈顿距离容差")
    ap.add_argument("--outline-dark", type=float, default=0.0,
                    help="亮度低于此值的算描边不染色；默认 0 = 关闭。"
                         "注意深色布料（深蓝/紫的亮度 60~90）很容易被误伤，"
                         "开了之后看一眼遮罩报告里的主色占比对不对")
    ap.add_argument("--no-binarize", action="store_true")
    args = ap.parse_args()

    if not args.art.exists():
        print("找不到 %s" % args.art)
        return 1
    rig = __import__("json").loads(RULES.read_text(encoding="utf-8"))["_rig"]
    jn = rig["slot_joint"].get(args.slot)
    if not jn:
        print("slot_joint 里没有槽位 %s —— 新槽位要先登记，见素材清单 §9" % args.slot)
        return 1
    jx, jy = next(j["pos"] for j in rig["joints"] if j["name"] == jn)

    im = Image.open(args.art).convert("RGBA")
    if args.scale != 1.0:
        im = im.resize((max(1, round(im.width * args.scale)),
                        max(1, round(im.height * args.scale))), Image.LANCZOS)
    a = np.asarray(im).copy()

    # alpha 二值化：AI 生成图普遍带抗锯齿边，半透明像素会让遮罩和描边串色
    if not args.no_binarize:
        a[:, :, 3] = np.where(a[:, :, 3] >= 128, 255, 0)

    vis = a[:, :, 3] > 8
    if not vis.any():
        print("整张图透明，没什么可收的")
        return 1

    # 挂点对齐
    px, py = parse_pivot(args.pivot, im.width, im.height)
    dx, dy = int(round(jx - px)), int(round(jy - py))
    canvas = np.zeros((CELL, CELL, 4), dtype=np.uint8)
    x0, y0 = dx, dy
    x1, y1 = dx + im.width, dy + im.height
    cx0, cy0 = max(0, x0), max(0, y0)
    cx1, cy1 = min(CELL, x1), min(CELL, y1)
    if cx1 <= cx0 or cy1 <= cy0:
        print("挂点对齐后部件完全落在画布外：pivot(%g,%g) -> 挂点 %s(%g,%g)"
              % (px, py, jn, jx, jy))
        return 1
    canvas[cy0:cy1, cx0:cx1] = a[cy0 - y0:cy1 - y0, cx0 - x0:cx1 - x0]

    lost = int(vis.sum() - (canvas[:, :, 3] > 8).sum())
    if lost > vis.sum() * 0.02:
        print("[警告] 有 %d px（%.0f%%）在缩放/对齐后落到画布外 —— 调整 --scale 或 --pivot"
              % (lost, lost / max(1, vis.sum()) * 100))

    # ---- 自动遮罩 ----
    skin = hexes(args.skin_colors)
    metal = hexes(args.metal_colors)
    rgb = canvas[:, :, :3].astype(int)
    alpha = canvas[:, :, 3]
    vis = alpha > 8

    def dist_to(colors):
        if not colors:
            return np.full((CELL, CELL), 1e9)
        d = None
        for c in colors:
            dd = np.abs(rgb - np.array(c)).sum(axis=2)
            d = dd if d is None else np.minimum(d, dd)
        return d

    lum = (rgb * [3, 6, 1]).sum(axis=2) / 10.0
    m_skin = (dist_to(skin) < args.tol) & vis
    m_metal = (dist_to(metal) < args.tol) & vis & ~m_skin
    m_outline = ((lum < args.outline_dark) & vis & ~m_skin & ~m_metal
                 if args.outline_dark > 0 else np.zeros_like(vis))
    m_main = vis & ~m_skin & ~m_metal & ~m_outline

    m_free = vis & ~m_main & ~m_skin & ~m_metal     # 描边等免染的可见像素

    mask = np.zeros((CELL, CELL, 4), dtype=np.uint8)
    mask[m_main] = (255, 0, 0, 255)
    mask[m_skin] = (255, 255, 0, 255)
    mask[m_metal] = (255, 0, 255, 255)

    stem = args.slot if not args.variant else "%s_%s" % (args.slot, args.variant)
    out_dir = PARTS / args.slot
    out_dir.mkdir(parents=True, exist_ok=True)
    p_png = out_dir / ("%s_puppet_%s.png" % (stem, args.view))
    p_mask = out_dir / ("%s_mask_%s.png" % (stem, args.view))
    Image.fromarray(canvas, "RGBA").save(p_png)
    Image.fromarray(mask, "RGBA").save(p_mask)

    n = int(vis.sum())
    print("收进 %s" % p_png.relative_to(ROOT))
    print("     +  %s" % p_mask.relative_to(ROOT))
    print("  挂点 %s(%g,%g) <- pivot(%g,%g)  可见 %d px" % (jn, jx, jy, px, py, n))
    print("  遮罩：主色 %.0f%% / 皮肤 %.0f%% / 金属 %.0f%% / 免染 %.0f%%" % (
        m_main.sum() / n * 100, m_skin.sum() / n * 100,
        m_metal.sum() / n * 100, m_free.sum() / n * 100))
    if lost:
        print("  [!] %d px 落到画布外被裁掉" % lost)
    print()
    print("下一步：")
    print("  python tools/check_part.py --slot %s %s" % (
        args.slot, ("--variant " + args.variant) if args.variant else ""))
    print("  python tools/gen_character_designer.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
