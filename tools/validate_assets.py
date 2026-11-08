#!/usr/bin/env python3
"""部件资产校验器（v4 枢轴人偶版）

v4 = 每块碎片一张静态图，钉在关节上，没有动画帧。
    命名：{slot}_puppet_{view}.png（variant 位置放部件变体名，如 puppet / knight_a）
    view：s / sw / w / nw / n      （NE、E、SE 由镜像得出，不需要出图）
    尺寸：每张必须 256x256，锚点 (128,216)

用法:
    python tools/validate_assets.py assets/parts
    python tools/validate_assets.py assets/parts --slot hat      # 只查某个槽位
    python tools/validate_assets.py assets/parts --strict        # 警告也当失败

校验项:
    1. 命名规范
    2. 画布尺寸 256x256
    3. Alpha 通道存在且非全透明
    4. 安全区 不透明像素不越出 x:[32,224] y:[16,240]
    5. 锚点   触地类部件（shin_l/shin_r 的脚）底边贴近 y=216
    6. 视图完整 同一变体的 5 个视图是否齐备（缺图只警告，允许按需裁剪）
    7. 遮罩   同名 _mask.png 尺寸一致

退出码: 0 通过 / 1 有错误
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

CELL = 256
VIEWS = ("s", "sw", "w", "nw", "n")
SAFE_X = (32, 224)
SAFE_Y = (16, 240)
ANCHOR_Y = 216
ANCHOR_TOL = 24

NAME_RE = re.compile(r"^(?P<slot>[a-z_]+)_(?P<variant>[a-z0-9]+)_(?P<view>[a-z]+)\.png$")

errors: list[str] = []
warnings: list[str] = []


def err(name: str, msg: str) -> None:
    errors.append(f"[错误] {name}: {msg}")


def warn(name: str, msg: str) -> None:
    warnings.append(f"[警告] {name}: {msg}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    ap.add_argument("--slot", default=None, help="只校验某个槽位")
    ap.add_argument("--strict", action="store_true", help="警告也视为失败")
    args = ap.parse_args()

    if not args.root.is_dir():
        print(f"目录不存在: {args.root}")
        return 1

    try:
        from PIL import Image
    except ImportError:
        print("需要 Pillow：pip install pillow")
        return 1

    files = sorted(p for p in args.root.rglob("*.png") if not p.stem.endswith("_mask"))
    if args.slot:
        files = [p for p in files if p.parent.name == args.slot]
    if not files:
        print(f"未找到部件图片: {args.root}")
        return 1

    seen: dict[tuple[str, str], set[str]] = defaultdict(set)

    for path in files:
        m = NAME_RE.match(path.name)
        if not m:
            err(path.name, "命名应为 {slot}_{variant}_{view}.png")
            continue

        slot, variant, view = m.group("slot"), m.group("variant"), m.group("view")
        if view not in VIEWS:
            err(path.name, f"未知视图 '{view}'，只允许 {list(VIEWS)}")
            continue
        seen[(slot, variant)].add(view)

        img = Image.open(path)
        if img.size != (CELL, CELL):
            err(path.name, f"画布 {img.size} != ({CELL},{CELL})")
            continue
        if img.mode not in ("RGBA", "LA"):
            err(path.name, f"模式 {img.mode} 无 alpha，必须导出 RGBA")
            continue

        alpha = img.getchannel("A")
        if alpha.getextrema()[1] == 0:
            err(path.name, "整张图全透明")
            continue

        bbox = alpha.getbbox()
        x0, y0, x1, y1 = bbox
        if x0 < SAFE_X[0] or x1 > SAFE_X[1] or y0 < SAFE_Y[0] or y1 > SAFE_Y[1]:
            warn(path.name, f"越出安全区 bbox={bbox}")

        # v4 里只有小腿（连带脚）触地，躯干不再落地
        if slot in ("shin_l", "shin_r", "shoes_l", "shoes_r") and abs(y1 - ANCHOR_Y) > ANCHOR_TOL:
            warn(path.name, f"脚底 y={y1}，距锚点 {ANCHOR_Y} 超 {ANCHOR_TOL}px")

        mask = path.with_name(path.stem + "_mask.png")
        if mask.exists() and Image.open(mask).size != img.size:
            err(mask.name, "遮罩尺寸与主图不一致")

    # 视图完整性：缺图只警告（可先只做一个视图跑通）
    for (slot, variant), got in sorted(seen.items()):
        missing = [v for v in VIEWS if v not in got]
        if missing:
            warn(f"{slot}_{variant}", f"缺视图 {missing}（镜像方向需要 nw/w/sw）")

    print(f"检查 {len(files)} 个文件，{len(seen)} 个部件变体")
    for w in warnings[:40]:
        print(w)
    if len(warnings) > 40:
        print(f"... 另有 {len(warnings) - 40} 条警告")
    for e in errors[:60]:
        print(e)
    if len(errors) > 60:
        print(f"... 另有 {len(errors) - 60} 条错误")

    print(f"\n结果: {len(errors)} 错误 / {len(warnings)} 警告")
    failed = bool(errors) or (args.strict and bool(warnings))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
