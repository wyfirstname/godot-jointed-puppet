#!/usr/bin/env python3
"""视图级锚点纠偏工具（v2 骨骼版）

v2 里每个部件每个视图都是 256x256 单张图，所以这里是「单图对单图」的比对：
把部件的 alpha 包围盒和同视图底图的包围盒对齐，给出偏移建议。

定位：纠偏工具，不是对齐工具。
     v2 的对齐主要靠「统一画布 + 统一 rest 姿势」在绘制阶段保证；
     本工具用来兜底检查——新画的部件是不是整体偏了。

用法:
    # 报告
    python tools/align_parts.py --base assets/base/base_w.png \\
        --part assets/parts/hat/hat_wiz_01_w.png --anchor head

    # 修正 + 出合成预览
    python tools/align_parts.py --base ... --part ... --anchor head --apply --preview preview/

anchor 策略:
    bottom  底边中心对齐（落地部件：body / shoes）
    center  包围盒中心对齐（头戴部件：hat / hair）
    head    横向中心 + 纵向顶边（头顶饰品，最贴合帽子/发饰）
    none    只报告不修正（武器/手套这类包围盒本就不该相等的部件）

退出码: 0 容差内 / 2 超容差（未 apply）/ 1 出错
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

TOLERANCE_PX = 3
CELL = 256
ANCHOR_Y = 216


def bbox_of(img):
    return img.getchannel("A").getbbox()


def compute_delta(base_bb, part_bb, anchor: str) -> tuple[float, float]:
    bx0, by0, bx1, by1 = base_bb
    px0, py0, px1, py1 = part_bb
    cx_b, cx_p = (bx0 + bx1) / 2, (px0 + px1) / 2

    if anchor == "bottom":
        return (cx_b - cx_p, by1 - py1)
    if anchor == "center":
        return (cx_b - cx_p, (by0 + by1) / 2 - (py0 + py1) / 2)
    if anchor == "head":
        return (cx_b - cx_p, by0 - py0)
    return (0.0, 0.0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", type=Path, required=True, help="同视图的底图")
    ap.add_argument("--part", type=Path, required=True, help="待检查的部件图")
    ap.add_argument("--anchor", choices=["bottom", "center", "head", "none"], default="center")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--preview", type=Path, default=None)
    ap.add_argument("--tolerance", type=int, default=TOLERANCE_PX)
    args = ap.parse_args()

    try:
        from PIL import Image
    except ImportError:
        print("需要 Pillow：pip install pillow")
        return 1

    if not args.base.exists() or not args.part.exists():
        print("文件不存在")
        return 1

    base = Image.open(args.base).convert("RGBA")
    part = Image.open(args.part).convert("RGBA")

    if base.size != part.size:
        print(f"[错误] 尺寸不一致 base={base.size} part={part.size}，应同为 {CELL}x{CELL}")
        return 1

    bb_base, bb_part = bbox_of(base), bbox_of(part)
    if bb_base is None or bb_part is None:
        print("[错误] 底图或部件为全透明，无法比对")
        return 1

    dx, dy = compute_delta(bb_base, bb_part, args.anchor)
    print(f"底图 bbox={bb_base}")
    print(f"部件 bbox={bb_part}")
    print(f"建议偏移 Δ=({dx:+.0f}, {dy:+.0f})  anchor={args.anchor}")

    worst = max(abs(dx), abs(dy))
    if args.anchor == "none":
        print("anchor=none：只报告不修正")
        return 0

    if not args.apply:
        if worst > args.tolerance:
            print(f"偏移 {worst:.0f}px 超容差 {args.tolerance}px，加 --apply 修正")
            return 2
        print("在容差内")
        return 0

    shifted = Image.new("RGBA", part.size, (0, 0, 0, 0))
    shifted.paste(part, (int(round(dx)), int(round(dy))))
    shifted.save(args.part)
    print(f"已平移并写回 {args.part}")

    if args.preview:
        args.preview.mkdir(parents=True, exist_ok=True)
        comp = base.copy()
        comp.alpha_composite(shifted)
        out = args.preview / f"{args.part.stem}_aligned.png"
        comp.save(out)
        print(f"合成预览: {out}")

    # 复检
    bb2 = bbox_of(shifted)
    dx2, dy2 = compute_delta(bb_base, bb2, args.anchor)
    print(f"复检偏移 Δ=({dx2:+.0f}, {dy2:+.0f})")
    return 0 if max(abs(dx2), abs(dy2)) <= args.tolerance else 2


if __name__ == "__main__":
    sys.exit(main())
