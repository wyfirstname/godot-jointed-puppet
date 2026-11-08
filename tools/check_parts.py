"""检查「身体和头是不是朝同一侧转」。

背景：八向最容易出的错不是某个部件画歪了，而是各部件对「转到哪边了」
给出互相矛盾的信号 —— 头转了、身子没转，或者身子转了、暗面在另一边。
这类错误单看一张图不容易发现，摆到环上一起看又容易被美术风格带偏，
所以用数值断言把它钉住。

判据：每个部位的暗部（WOOD_SHADE / WOOD_FAR）重心，减去亮部
（WOOD / WOOD_L）重心，取符号。同一个视图里，头、躯干、远侧肢体
必须同号 —— 也就是"暗的那一半"必须在同一侧。

    python tools/check_parts.py            检查，失败返回 1
    python tools/check_parts.py -v         打印每个部位的数值
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"

DARK = [(176, 118, 64), (146, 98, 56)]          # WOOD_SHADE / WOOD_FAR
LIGHT = [(198, 137, 76), (224, 168, 104)]       # WOOD / WOOD_L
VIEWS = ["s", "sw", "w", "nw", "n"]
# 期望的暗面朝向：正面 3/4 暗面在屏幕右（背面转过去了），背面 3/4 暗面在屏幕左
EXPECT = {"s": "=", "sw": "R", "w": "R", "nw": "L", "n": "="}

# z 表里的近侧（与 core/character/joint_doll.gd 的 NEAR_SIDE 一致）。
# "" = 正/背面，两侧到镜头等距，不该分出远近。
NEAR_SIDE = {"s": "", "sw": "r", "w": "r", "nw": "l", "n": ""}


def arm_far_side(view: str):
    """美术把哪一侧胳膊画成远侧 —— 比平均亮度，暗的那条就是远侧。

    这条断言就是 NW 那格的病历：美术把 "r" 压暗收窄（= 远侧），
    z 表却把 "r" 抬到躯干前面（= 近侧）。两个信号相反，合成出来是
    「暗的、缩小的胳膊压在身体上，亮的沉到背后」，读起来就是
    「近侧肩膀长到背后去了」。美术和 z 序必须同侧，这里用像素把它钉住。
    """
    means = {}
    for side in ("l", "r"):
        p = PARTS / f"arm_{side}" / f"arm_{side}_puppet_{view}.png"
        im = np.array(Image.open(p).convert("RGBA")).astype(float)
        a = im[:, :, 3] > 200
        means[side] = float(im[:, :, :3][a].mean()) if a.any() else 0.0
    if abs(means["l"] - means["r"]) < 2.0:
        return "=", means
    return ("l" if means["l"] < means["r"] else "r"), means


def centroid(rgb, mask, colors, tol=42):
    sel = np.zeros(mask.shape, dtype=bool)
    for c in colors:
        sel |= (np.abs(rgb - np.array(c)).sum(axis=2) < tol) & mask
    xs = np.nonzero(sel)[1]
    return (float(xs.mean()), int(sel.sum())) if xs.size else (None, 0)


def side_of(path: Path):
    im = np.array(Image.open(path).convert("RGBA")).astype(int)
    mask = im[:, :, 3] > 200
    rgb = im[:, :, :3]
    dx, dn = centroid(rgb, mask, DARK)
    lx, ln = centroid(rgb, mask, LIGHT)
    # 头上的暗面带很窄（3/4 时大半被后脑的头发压住），样本数门槛要比躯干低
    if dx is None or lx is None or dn < 20 or ln < 60:
        return "?", dx, lx
    d = dx - lx
    return ("R" if d > 0.6 else "L" if d < -0.6 else "="), dx, lx


def main() -> int:
    verbose = "-v" in sys.argv
    bad = 0
    print("%-4s %-16s %-16s %-10s %s" % ("view", "head", "body", "expect", "结果"))
    for v in VIEWS:
        hs, hd, hl = side_of(PARTS / "head" / f"head_puppet_{v}.png")
        bs, bd, bl = side_of(PARTS / "body" / f"body_puppet_{v}.png")
        ok = hs == bs == EXPECT[v]
        if not ok:
            bad += 1
        if verbose or not ok:
            print("%-4s %-16s %-16s %-10s %s" % (
                v,
                "%s (%.1f/%.1f)" % (hs, hd or -1, hl or -1),
                "%s (%.1f/%.1f)" % (bs, bd or -1, bl or -1),
                EXPECT[v], "OK" if ok else "X 不一致"))
        else:
            print("%-4s %-16s %-16s %-10s %s" % (v, hs, bs, EXPECT[v], "OK"))
    print()
    # 第二条：美术的「远侧」和 z 表的「远侧」必须是同一侧
    print("%-4s %-8s %-8s %-8s %s" % ("view", "美术远侧", "期望远侧", "亮度 l/r", "结果"))
    for v in VIEWS:
        far, means = arm_far_side(v)
        want = "=" if NEAR_SIDE[v] == "" else ("l" if NEAR_SIDE[v] == "r" else "r")
        ok = far == want
        if not ok:
            bad += 1
        print("%-4s %-8s %-8s %-8s %s" % (
            v, far, want, "%.0f/%.0f" % (means["l"], means["r"]),
            "OK" if ok else "X 美术压暗的一侧 != z 表当远侧的一侧"))

    print()
    if bad:
        print("失败：%d 处朝向/远近不自洽" % bad)
        return 1
    print("全部通过：5 个视图的头/躯干暗面同侧，且美术近远与 z 表一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
