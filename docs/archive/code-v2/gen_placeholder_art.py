"""生成占位美术：11 个部件 x 5 套视图，全部画在 256x256 画布、锚点 (128,216)。

画布坐标即骨架局部坐标（见 character_rig.gd），所以每块部件都按骨骼位置直接落笔，
运行时就自动对齐——这正是纯 2D 路线的核心纪律：所有部件共享同一张画布坐标系。

用法：python tools/gen_placeholder_art.py
"""

from pathlib import Path
from PIL import Image, ImageDraw

CELL = 256
VIEWS = ["s", "sw", "w", "nw", "n"]

SKIN = (239, 195, 155, 255)
SKIN_D = (198, 148, 110, 255)
HAIR = (104, 72, 46, 255)
TUNIC = (92, 126, 196, 255)
TUNIC_D = (64, 92, 152, 255)
TRIM = (232, 206, 128, 255)
HAT = (140, 96, 196, 255)
HAT_D = (102, 66, 152, 255)
PANTS = (72, 82, 104, 255)
BOOT = (122, 82, 48, 255)
OL = (34, 30, 44, 255)
EYE = (30, 28, 40, 255)

ASSETS = Path(__file__).resolve().parent.parent / "assets" / "parts"


def canvas():
    im = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def capsule(d, p0, p1, w, fill, ol=OL, ow=3):
    """带宽度的线段 + 两端圆头，模拟四肢。"""
    d.line([p0, p1], fill=ol, width=w + ow * 2)
    for p in (p0, p1):
        d.ellipse([p[0] - (w + ow * 2) / 2, p[1] - (w + ow * 2) / 2,
                   p[0] + (w + ow * 2) / 2, p[1] + (w + ow * 2) / 2], fill=ol)
    d.line([p0, p1], fill=fill, width=w)
    for p in (p0, p1):
        d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=fill)


def poly(d, pts, fill, ol=OL, ow=3):
    d.polygon(pts, fill=fill)
    d.line(list(pts) + [pts[0]], fill=ol, width=ow, joint="curve")


def blob(d, box, fill, ol=OL, ow=3):
    d.ellipse(box, fill=fill, outline=ol, width=ow)


# ---------------------------------------------------------------- 各部件

def torso(view):
    im, d = canvas()
    w = {"s": 36, "sw": 32, "nw": 28, "w": 24, "n": 36}[view]
    x0, x1 = 128 - w // 2, 128 + w // 2
    # 上身：肩宽 -> 收腰
    poly(d, [(x0, 104), (x1, 104), (x1 - 3, 166), (x0 + 3, 166)], TUNIC)
    # 腰带
    d.rectangle([x0 + 2, 152, x1 - 2, 162], fill=TRIM, outline=OL, width=3)
    # 领口
    d.polygon([(128 - 9, 104), (128 + 9, 104), (128, 118)], fill=TUNIC_D, outline=OL)
    return im


def head(view):
    im, d = canvas()
    # 脖子
    d.rectangle([121, 84, 135, 106], fill=SKIN_D, outline=OL, width=3)
    # 头
    blob(d, [102, 40, 154, 92], SKIN)
    # 头发
    if view == "n":
        blob(d, [100, 38, 156, 94], HAIR)
    else:
        d.chord([100, 36, 156, 90], 180, 360, fill=HAIR, outline=OL, width=3)
        d.rectangle([100, 56, 108, 74], fill=HAIR, outline=OL, width=3)
    # 五官：全部朝向屏幕左侧（西为基准，向东靠整骨架镜像）
    if view != "n":
        if view == "s":
            for ex in (119, 137):
                d.ellipse([ex - 4, 60, ex + 4, 68], fill=EYE)
        elif view in ("sw", "nw"):
            for ex in (116, 132):
                d.ellipse([ex - 3, 60, ex + 3, 67], fill=EYE)
        else:  # w 侧视只露一只眼，靠近朝向侧的边缘
            d.ellipse([110, 59, 117, 67], fill=EYE)
    return im


def hat(view):
    im, d = canvas()
    if view == "w":
        poly(d, [(112, 44), (150, 44), (132, 4)], HAT)
        d.rectangle([106, 40, 152, 48], fill=HAT_D, outline=OL, width=3)
    else:
        poly(d, [(100, 44), (156, 44), (130, 4)], HAT)
        d.rectangle([96, 40, 160, 49], fill=HAT_D, outline=OL, width=3)
        d.ellipse([124, 26, 138, 34], fill=TRIM, outline=OL, width=2)
    return im


def upper_arm(side):
    im, d = canvas()
    if side == "l":
        p0, p1 = (110, 108), (98, 128)
    else:
        p0, p1 = (146, 108), (158, 128)
    capsule(d, p0, p1, 13, SKIN)
    # 短袖
    d.ellipse([p0[0] - 9, p0[1] - 9, p0[0] + 9, p0[1] + 9], fill=TUNIC, outline=OL, width=3)
    return im


def fore_arm(side):
    im, d = canvas()
    if side == "l":
        p0, p1 = (98, 128), (92, 148)
    else:
        p0, p1 = (158, 128), (164, 148)
    capsule(d, p0, p1, 11, SKIN)
    blob(d, [p1[0] - 8, p1[1] - 8, p1[0] + 8, p1[1] + 8], SKIN)
    return im


def thigh(side):
    im, d = canvas()
    if side == "l":
        p0, p1 = (116, 158), (114, 186)
    else:
        p0, p1 = (140, 158), (142, 186)
    capsule(d, p0, p1, 15, PANTS)
    return im


def shin(side):
    im, d = canvas()
    if side == "l":
        p0, p1 = (114, 182), (114, 206)
    else:
        p0, p1 = (142, 182), (142, 206)
    capsule(d, p0, p1, 13, PANTS)
    # 靴子
    x = p0[0]
    d.ellipse([x - 13, 196, x + 11, 220], fill=BOOT, outline=OL, width=3)
    return im


def main():
    builders = {
        "body": ("body_human_01", lambda v: torso(v)),
        "head": ("head_human_01", lambda v: head(v)),
        "hat": ("hat_wiz_01", lambda v: hat(v)),
        "arm_l": ("arm_human_01_l", lambda v: upper_arm("l")),
        "arm_r": ("arm_human_01_r", lambda v: upper_arm("r")),
        "fore_l": ("fore_human_01_l", lambda v: fore_arm("l")),
        "fore_r": ("fore_human_01_r", lambda v: fore_arm("r")),
        "leg_l": ("leg_human_01_l", lambda v: thigh("l")),
        "leg_r": ("leg_human_01_r", lambda v: thigh("r")),
        "shin_l": ("shin_human_01_l", lambda v: shin("l")),
        "shin_r": ("shin_human_01_r", lambda v: shin("r")),
    }
    n = 0
    for slot, (variant, build) in builders.items():
        out = ASSETS / slot
        out.mkdir(parents=True, exist_ok=True)
        for view in VIEWS:
            build(view).save(out / f"{variant}_{view}.png")
            n += 1
    print(f"generated {n} png in {ASSETS}")


if __name__ == "__main__":
    main()
