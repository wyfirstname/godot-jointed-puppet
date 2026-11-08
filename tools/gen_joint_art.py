"""生成关节人偶占位美术（v4）：可分离的木质碎片，每片自带可见球关节。

设计依据：参考视频「每块都是一张静止的图，钉在关节上」。
可见球关节不是装饰——它是 cutout 动画的美术解法：把刚性拼接的缝
变成设定的一部分，于是不需要蒙皮、不需要无缝。

5 套视图的分工（对应 8 方向 = 5 张 + 3 张镜像）：
    s   正面        sw  前左 3/4    w   左侧面
    nw  背左        n   背面
镜像补出 NE / E / SE，所以 NW 必须是「背面偏左」而不是「正面偏左」。

输出：assets/parts/{slot}/{slot}_puppet_{view}.png  256x256，锚点 (128,216)
"""

from __future__ import annotations

import math
import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

CELL = 256

# 关节枢轴（画布坐标）——与 core/character/joint_doll.gd 的 JOINTS 表必须一致
JOINTS = {
    "hip": (128, 146),
    "chest": (128, 110),
    "head": (128, 100),
    # 肩枢轴必须在躯干轮廓（128±16）**里面 4px**，即 108/148。
    # 放在轮廓外面的 104/152 时，肩球只能和桶边相切 —— 看上去胳膊是贴在身体外面。
    # 肘也一起平移，上臂的斜度才不变；只挪肩会让腋下裂得更开。
    "shoulder_l": (108, 108),
    "elbow_l": (102, 130),
    "shoulder_r": (148, 108),
    "elbow_r": (154, 130),
    "hip_l": (120, 152),
    "knee_l": (119, 182),
    "hip_r": (136, 152),
    "knee_r": (137, 182),
}

WOOD = (198, 137, 76, 255)
WOOD_D = (150, 96, 48, 255)
WOOD_L = (224, 168, 104, 255)
WOOD_SHADE = (176, 118, 64, 255)   # 转过去那一侧的受光衰减（同一块木头）
WOOD_FAR = (146, 98, 56, 255)      # 远侧肢体：比 WOOD_SHADE 再暗一档，靠明度分层
FACE = (232, 192, 140, 255)
GOLD = (240, 196, 92, 255)
GOLD_D = (150, 104, 36, 255)
OUTLINE = (56, 34, 18, 255)
CAPE = (168, 52, 62, 255)
CAPE_D = (112, 32, 42, 255)

# ---- 服装变体用的布料色 ----
# 全部要进 MAIN_COLORS（mask 按颜色分类，漏一个这套衣服就不跟着换了）。
# 选色时刻意和已有色拉开曼哈顿距离 ≥ 44：描边色 OUTLINE 只有 40 的容差，
# 布料色一旦贴住描边，整圈轮廓线就会被当"可染区"一起染色。
ROBE = (86, 92, 158, 255)        # 法袍：蓝紫
ROBE_D = (56, 60, 112, 255)
ROBE_L = (112, 120, 190, 255)
LEATHER = (104, 78, 48, 255)     # 皮甲：暗棕
LEATHER_D = (78, 56, 34, 255)
LEATHER_L = (138, 106, 72, 255)
HOOD = (72, 64, 92, 255)         # 兜帽 / 尖帽：深紫灰
HOOD_D = (48, 44, 66, 255)
HOOD_L = (100, 92, 126, 255)

FOOT_L, FOOT_W = 21.0, 15.0   # 脚长（沿朝向）/ 脚宽，见 foot()
FOOT_Y0, FOOT_Y1 = 202, 213   # 脚的上沿 / 地面线

# ---------------- 分区染色 mask ----------------
#
# 美术是程序画的，每个像素的颜色都精确已知，所以 mask 不用描、直接按颜色分类：
#   R = 主色区（木头身 + 布料 + 头发）—— hue/sat/val 整体偏移，染出"不同木材/布料"的角色
#   G = 皮肤区（脸板 + 手）           —— 走 skin_tint，保证脸和手永远是同一肤色
#   B = 金属区（球关节 + 剑的护手/柄头）—— 独立一套参数，染金属不伤木头
# 其余（轮廓线、眼白、瞳孔、O 嘴内色）不在任何集合里 → mask 全黑 → 保持原样。
#
# 新画服装时只要用调色板里的颜色，mask 自动跟上；用新颜色就要往这三个集合里加。
SKIN_COLORS = [FACE]
METAL_COLORS = [GOLD, GOLD_D]
MAIN_COLORS = [WOOD, WOOD_D, WOOD_L, WOOD_SHADE, WOOD_FAR,
               CAPE, CAPE_D,
               (96, 62, 36, 255), (72, 46, 26, 255),   # 头发也是"可染主体"
               # 服装变体的布料色（robe / leather / hood 三套）
               ROBE, ROBE_D, ROBE_L,
               LEATHER, LEATHER_D, LEATHER_L,
               HOOD, HOOD_D, HOOD_L]
COLOR_TOL = 40   # 曼哈顿色距阈值。PIL 是硬边填充，同色像素距离恒为 0


def make_mask(im) -> Image.Image:
    a = np.asarray(im).astype(int)
    out = np.zeros(a.shape[:2] + (4,), dtype=np.uint8)
    rgb = a[..., :3]
    vis = a[..., 3] > 8

    def region(colors):
        m = np.zeros(a.shape[:2], bool)
        for c in colors:
            m |= np.abs(rgb - np.array(c[:3])).sum(axis=2) < COLOR_TOL
        return m & vis

    skin = region(SKIN_COLORS)
    metal = region(METAL_COLORS)
    # 描边必须显式排除：OUTLINE(56,34,18) 和头发色(72,46,26)的色距只有 36，
    # 落在 40 的容差里 —— 不排的话**每个部件的整圈描边**都被当成可染主色，
    # 基色被暗棕拉歪（尖帽的基色从蓝紫变成红紫，怎么染都对不上色板）。
    # 排除后描边保持深色不上色，轮廓反而更清楚。
    outline = region([OUTLINE])
    main = region(MAIN_COLORS) & ~skin & ~metal & ~outline
    # R 通道是「最终门控」：shader 末尾 mix(base, c, mk.r) 按 R 决定保不保留调色。
    # 所以遮罩内**所有**可见像素 R 必须是 255 —— 以前金属区写成 (0,0,255)，
    # R=0 直接把金属调色整个丢掉，球永远原色（tint_grid 那次的验证结论是错的）。
    # G=皮肤、B=金属只负责「选哪套参数」，不负责开关。
    out[main] = (255, 0, 0, 255)
    out[skin] = (255, 255, 0, 255)
    out[metal] = (255, 0, 255, 255)
    return Image.fromarray(out, "RGBA")

# 披风的包络：它是一段包住背部的圆柱面，不是平板。见 cape()
CAPE_PHI = 75.0                        # 半包角（度）：从背中线往两侧各包 75°
CAPE_R_TOP, CAPE_R_HEM = 17.0, 29.0    # 肩线 / 下摆的包络半径

VIEWS = {
    # narrow : 躯干横向收缩
    # look   : 头部水平偏移（负=朝左走）
    # turn   : 转头程度 0=正对镜头 0.5=45° 3/4 1.0=纯侧面。五官按它收窄/偏移
    # profile: 纯侧面（肢体收拢到中线、单眼、鼻子外凸）
    # face   : 是否画五官（背面视图不画）
    # back   : 背面视图
    # foot   : 脚的长轴在**屏幕横轴**上的投影，0=正对镜头（几乎不横向展开），
    #          -1=脚尖完全朝屏幕左。正/背面必须是 0，否则脚就成了横躺的胶囊。
    # deg    : 身体绕竖直轴真正转过的角度。turn 是给五官用的夸张值（0.8 就当 72° 用），
    #          而"一块平板转动后投影多宽"必须用真实角度 —— 披风就是靠这个算的。
    "s":  dict(narrow=1.00, look=0,   turn=0.00, face=True,  profile=False, back=False,
               foot=0.0,  deg=0.0),
    "sw": dict(narrow=0.90, look=-11, turn=0.80, face=True,  profile=False, back=False,
               foot=-0.55, deg=45.0),
    "w":  dict(narrow=0.78, look=-15, turn=1.00, face=True,  profile=True,  back=False,
               foot=-1.0, deg=90.0),
    "nw": dict(narrow=0.90, look=-11, turn=0.80, face=False, profile=False, back=True,
               foot=-0.55, deg=135.0),
    "n":  dict(narrow=1.00, look=0,   turn=0.00, face=False, profile=False, back=True,
               foot=0.0,  deg=180.0),
}


def canvas():
    im = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def ball(d, x, y, r=6.5, far=False):
    """可见球关节。

    远侧的那颗不删掉——删了整条胳膊就变成一块没有关节的板。
    改成缩小 + 压暗：既有深度信息，又还看得出"这是肘"。
    """
    if far:
        r *= 0.72
        d.ellipse([x - r, y - r, x + r, y + r], fill=(150, 112, 52, 255),
                  outline=OUTLINE, width=2)
        return
    d.ellipse([x - r, y - r, x + r, y + r], fill=GOLD, outline=OUTLINE, width=2)
    d.ellipse([x - r * 0.42, y - r * 0.42, x + r * 0.42, y + r * 0.42], fill=GOLD_D)


def capsule(d, p0, p1, w, fill):
    d.line([p0, p1], fill=OUTLINE, width=int(w + 4))
    d.line([p0, p1], fill=fill, width=int(w))


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def far_limb(v, side):
    """屏幕左侧（x 更小）那条肢体在转身后是远侧。

    "l" 是屏幕左：肩 104 / 肘 98 / 胯 120。

    前后 3/4 的远侧**不是同一侧**。绕竖直轴转过 90° 之后，原本在屏幕左的
    那一半已经转到屏幕右去了：
        θ=45°  (sw) 远侧 = 屏幕左 "l"
        θ=135° (nw) 远侧 = 屏幕右 "r"
    所以背面必须翻过来。这条和 core/character/joint_doll.gd 的 NEAR_SIDE
    是同一个结论，两边改动必须一起改，否则远侧胳膊会被 z 序排到躯干前面。
    """
    if not (v["profile"] or v["turn"] > 0.35):
        return False
    return side == ("r" if v["back"] else "l")


def _limb_tuck(v, p, side):
    """远侧肢体朝中线收。

    不是"摆到正确位置"—没有位置可摆，关节像素必须和运行时枢轴严格对齐。
    但远侧肢体在 z 序里低于躯干，收进去的那段会被躯干整块盖住，
    露出来的从躯干边缘开始 —— 正好是"这条胳膊在身体后面"的样子。
    """
    if v["profile"]:
        return lerp(p, (128.0, p[1]), 0.62)
    if far_limb(v, side):
        # 3/4 只收一点点。严格按 cos 投影收会让远侧胳膊整条埋进躯干里，
        # 看着像断了一只手；收到"仍能整条露出、只是贴得更近"就够读懂了
        return lerp(p, (128.0, p[1]), 0.18)
    return p


def _tilt(pts, c, deg):
    """把一组点绕 c 旋转 deg 度（y 向下，正角度 = 顺时针）。"""
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    out = []
    for x, y in pts:
        dx, dy = x - c[0], y - c[1]
        out.append((c[0] + dx * ca - dy * sa, c[1] + dx * sa + dy * ca))
    return out


def torso(im, d, v):
    """木桶躯干。

    转身时**轮廓宽度基本不变**——圆柱绕竖直轴转，正投影宽度恒定
    （x = R·sin(φ−θ)，极值永远是 ±R）。变的是「主面板 / 侧面」的分界线。
    之前只按 narrow 收窄、分界线固定在中线，所以躯干永远是正对镜头的，
    配上已经转过去的头，就成了"头转过来了、身子还杵着"。

    主面板：正视时是胸口，背视时是后背。侧面：转动后从主面板旁边翻出来的那一块。
    """
    t = v["turn"]
    cx = 128
    half = 16 * v["narrow"]
    y0, y1 = 100, 152

    # 整个桶先画出来：轮廓宽度不随转身变化（圆柱正投影宽度恒定）
    d.rounded_rectangle([cx - half, y0, cx + half, y1], radius=9,
                        fill=WOOD, outline=OUTLINE, width=2)

    # 腰带上下一道木箍
    d.rectangle([cx - half, 140, cx + half, 147], fill=WOOD_D)
    d.line([(cx - half, 113), (cx + half, 113)], fill=WOOD_D, width=3)

    # 木桶竖条
    n = 4
    for i in range(1, n):
        x = cx - half + 2 * half * i / n
        d.line([(x, y0 + 7), (x, y1 - 5)], fill=WOOD_D, width=2)

    # 转过去的那一侧压暗。**不画中间那道描边** —— 一画就成了"两块板拼的"，
    # 这里要的是同一根桶上的明暗，不是两块东西
    # 暗面 = 「背面 / 侧面板」所在的那一侧，**不是**远侧肢体那一侧。
    # 两者确实不同：远侧肢体在屏幕左（正面 3/4）时，躯干转过去露出来的是
    # 后侧那一块，在屏幕右。各部件必须按同一条「背面在哪边」来定暗面，
    # 否则头和身子就会一边一个颜色。
    dark = half * 0.80 * t
    if t > 0.02 and dark >= 1.0:
        if v["back"]:
            box = [cx - half, y0 + 2, cx - half + dark, y1 - 2]
        else:
            box = [cx + half - dark, y0 + 2, cx + half, y1 - 2]
        d.rectangle(box, fill=WOOD_SHADE)
        # 被压暗那侧只剩一条很淡的条纹，暗示曲面还在
        xs = (box[0] + box[2]) / 2.0
        d.line([(xs, y0 + 8), (xs, y1 - 6)], fill=WOOD_D, width=2)

    # 描边重画：上面的色块会盖掉外轮廓
    d.rounded_rectangle([cx - half, y0, cx + half, y1], radius=9,
                        outline=OUTLINE, width=2)

    lit = (cx - half, cx + half - dark) if not v["back"] else (cx - half + dark, cx + half)
    lw = lit[1] - lit[0]
    if not v["back"] and lw > 10:
        # 胸甲纹章跟着受光面走；侧面露出来的那半格不该有纹章
        mx = (lit[0] + lit[1]) / 2.0
        d.ellipse([mx - 7, 122, mx + 7, 132], fill=WOOD_D, outline=OUTLINE, width=2)
    if v["back"] and lw > 10:
        # 背视：一条脊线代替纹章
        bxp = (lit[0] + lit[1]) / 2.0
        d.line([(bxp, y0 + 8), (bxp, 138)], fill=WOOD_D, width=3)

    # 脖子：头换上任何视角、任何偏移都盖得住这段，转身时不会在肩上开个豁口
    d.rounded_rectangle([cx - 7, 88, cx + 7, 104], radius=4,
                        fill=WOOD_D, outline=OUTLINE, width=2)
    ball(d, *JOINTS["hip"])


# ---------------- 服装变体 ----------------
#
# 三套服装 = 同一具木偶身上的三件衣服。骨架、枢轴、视图全不变，
# 只换「这一层怎么画」—— 所以换装不会错位，z 序也不用动。
# 关节球该露还是该藏，是每套衣服自己的决定：
#   法师长袍  → 下摆盖到脚踝，胯球和膝球全都藏进布里（这就是"长袍盖关节"）
#   游侠皮甲  → 短打，胯球露出来（皮甲不是裙子，露关节才看得出是木偶）
#   兜帽/尖帽 → 戴在 hat 槽位（z=36，压过 hair_front 34），跟着 head 关节转


def _edge_band(cx, half_at, y0, y1, side, ratio, n=13):
    """沿轮廓边缘取一条带子（暗面用）。

    不能拿矩形当暗面：长袍下摆是钟形的，矩形会溢出轮廓，
    在布外面糊出一块深色方块。必须让它跟着 half_at(y) 走。
    """
    outer, inner = [], []
    for i in range(n + 1):
        y = y0 + (y1 - y0) * i / n
        h = half_at(y) * side
        outer.append((cx + h, y))
        inner.append((cx + h - h * ratio * side, y))
    return outer + inner[::-1]


def torso_robe(im, d, v):
    """法师长袍：高领 + 束腰 + 钟形长摆，盖到脚踝上方。"""
    cx, n = 128, v["narrow"]
    sh, wa, hem = 17 * n, 15 * n, 27 * n
    top, waist, bot = 98, 136, 193

    def half(y):
        if y <= waist:
            return sh + (wa - sh) * (y - top) / float(waist - top)
        return wa + (hem - wa) * (y - waist) / float(bot - waist)

    d.polygon([(cx - sh, top), (cx + sh, top), (cx + wa, waist),
               (cx + hem, bot), (cx - hem, bot), (cx - wa, waist)],
              fill=ROBE, outline=OUTLINE)
    if v["turn"] > 0.02:
        side = -1 if v["back"] else 1
        d.polygon(_edge_band(cx, half, top + 2, bot - 2, side, 0.75 * v["turn"]),
                  fill=ROBE_D)
    # 竖褶：腰线以下越张越开
    for i in range(-2, 3):
        d.line([(cx + i * wa * 0.36, waist + 5), (cx + i * hem * 0.44, bot - 5)],
               fill=ROBE_D, width=2)
    # 束腰 + 金扣（扣走金属通道，能单独染铜/银）
    d.rectangle([cx - wa - 1, 130, cx + wa + 1, 141], fill=HOOD_D)
    d.rounded_rectangle([cx - 5, 129, cx + 5, 142], radius=3,
                        fill=GOLD, outline=OUTLINE, width=2)
    # 布褶压出的高光，给平涂的布一点体积
    d.line([(cx - wa * 0.55, top + 8), (cx - wa * 0.75, waist - 2)], fill=ROBE_L, width=2)
    d.line([(cx - hem * 0.8, waist + 8), (cx - hem * 0.9, bot - 6)], fill=ROBE_L, width=2)

    # 脖子（木头）——衣服再厚，脖子还是木偶自己的
    d.rounded_rectangle([cx - 7, 86, cx + 7, 104], radius=4,
                        fill=WOOD_D, outline=OUTLINE, width=2)
    # 立领：只包两侧，中间留出脖子
    for sx in (-1, 1):
        d.rounded_rectangle([cx + sx * 10 - 4, 94, cx + sx * 10 + 4, 106], radius=3,
                            fill=ROBE_L, outline=OUTLINE, width=2)
    # 外轮廓重描（褶子和暗面会盖掉边）
    d.line([(cx - sh, top), (cx - wa, waist)], fill=OUTLINE, width=2)
    d.line([(cx + sh, top), (cx + wa, waist)], fill=OUTLINE, width=2)
    d.line([(cx - wa, waist), (cx - hem, bot)], fill=OUTLINE, width=2)
    d.line([(cx + wa, waist), (cx + hem, bot)], fill=OUTLINE, width=2)
    d.line([(cx - hem, bot), (cx + hem, bot)], fill=OUTLINE, width=2)


def torso_leather(im, d, v):
    """游侠皮甲：短背心 + 斜挎带 + 束腰。下缘停在胯线，露关节。"""
    cx, n = 128, v["narrow"]
    half = 17 * n
    y0, y1 = 99, 156

    d.rounded_rectangle([cx - half, y0, cx + half, y1], radius=8,
                        fill=LEATHER, outline=OUTLINE, width=2)
    if v["turn"] > 0.02:
        dw = half * 0.80 * v["turn"]
        bx0 = cx - half if v["back"] else cx + half - dw
        d.rectangle([bx0, y0 + 2, bx0 + dw, y1 - 2], fill=LEATHER_D)
        d.rounded_rectangle([cx - half, y0, cx + half, y1], radius=8,
                            outline=OUTLINE, width=2)
    # 皮片拼线（中缝 + 胸线）
    d.line([(cx, y0 + 6), (cx, 138)], fill=LEATHER_D, width=2)
    d.line([(cx - half + 3, 116), (cx + half - 3, 116)], fill=LEATHER_D, width=2)
    # 斜挎带：正面从左肩到右胯，背面同一条带子的另一侧
    sg = 1 if v["back"] else -1
    d.line([(cx + sg * half * 0.72, y0 + 5), (cx - sg * half * 0.60, 141)],
           fill=HOOD_D, width=5)
    # 束腰 + 扣
    d.rectangle([cx - half, 141, cx + half, 151], fill=LEATHER_D)
    d.rounded_rectangle([cx - 5, 140, cx + 5, 152], radius=3,
                        fill=GOLD, outline=OUTLINE, width=2)
    # 高领
    d.rounded_rectangle([cx - 11, 92, cx + 11, 103], radius=4,
                        fill=LEATHER_L, outline=OUTLINE, width=2)
    d.rounded_rectangle([cx - 7, 86, cx + 7, 96], radius=4,
                        fill=WOOD_D, outline=OUTLINE, width=2)
    ball(d, *JOINTS["hip"])


def body(im, d, v, style="wood"):
    if style == "robe":
        torso_robe(im, d, v)
    elif style == "leather":
        torso_leather(im, d, v)
    else:
        torso(im, d, v)


def hat(im, d, v, style="hood"):
    """帽子（hat 槽位，z=36 / 挂 head 关节）。两套：兜帽、法师尖帽。"""
    cx = 128 + v["look"] * 0.55
    half = 22 * (0.86 + 0.14 * v["narrow"])
    hw = half * (1.0 - 0.14 * v["turn"])

    if style == "wizard":
        # 尖帽：帽檐 + 锥体 + 金帽箍。锥尖朝**脑后**歪一点（朝左走的视图脑后在右），
        # 不歪的话五个视图是同一顶正圆锥，转身完全读不出来；
        # 朝脸前歪就成了「帽子扣在眼睛上」
        apex = (cx + hw * 0.20 * v["turn"] + 2, 14)
        d.polygon([(cx - hw * 0.80, 56), (cx + hw * 0.80, 56), apex],
                  fill=HOOD, outline=OUTLINE)
        if v["turn"] > 0.02:
            side = -1 if v["back"] else 1
            d.polygon([(cx + side * hw * 0.10, 56), (cx + side * hw * 0.80, 56),
                       (apex[0] + side * 1.5, apex[1] + 6)], fill=HOOD_D)
        d.ellipse([cx - hw - 7, 50, cx + hw + 7, 62], fill=HOOD_L,
                  outline=OUTLINE, width=2)
        d.rectangle([cx - hw * 0.62, 46, cx + hw * 0.62, 53], fill=GOLD,
                    outline=OUTLINE, width=2)
        for dx, dy in ((-4, 40), (3, 34), (-1, 27)):
            d.ellipse([cx + dx - 1.5, dy - 1.5, cx + dx + 1.5, dy + 1.5], fill=GOLD)
        return

    # 兜帽：正面是"围住脸的一圈"，背面是一整块布。
    # 不能画一块大布再把脸盖上——脸在 head 槽位（z=30），帽子在 36，
    # 真盖上去脸就没了。所以只在脸板**外面**留边。
    if not v["face"]:
        d.rounded_rectangle([cx - hw - 3, 46, cx + hw + 3, 104], radius=13,
                            fill=HOOD, outline=OUTLINE, width=2)
        d.rounded_rectangle([cx - hw + 2, 52, cx + hw * 0.2, 100], radius=10,
                            fill=HOOD_D)
        # 帽尖往后垂
        d.polygon([(cx + hw * 0.2, 50), (cx + hw * 0.95, 66), (cx + hw * 0.1, 70)],
                  fill=HOOD, outline=OUTLINE)
        return
    fx0, fw = face_box(v)
    fx1 = fx0 + fw
    # 顶盖（包到额头上沿，刘海在它下面）
    d.chord([cx - hw - 2, 42, cx + hw + 2, 74], 180, 360,
            fill=HOOD, outline=OUTLINE, width=2)
    # 两侧护耳：紧贴脸板边缘。往里挤 1px 就够，压多了脸会被切窄
    d.rounded_rectangle([cx - hw - 3, 60, fx0 + 1, 104], radius=8,
                        fill=HOOD, outline=OUTLINE, width=2)
    d.rounded_rectangle([fx1 - 1, 60, cx + hw + 3, 104], radius=8,
                        fill=HOOD, outline=OUTLINE, width=2)
    # 帽檐内侧的暗部，让脸像"嵌"在帽子里，不是贴在帽子上
    d.line([(fx0 + 2, 64), (fx1 - 2, 64)], fill=HOOD_D, width=3)
    # 帽尖垂在脑后那一侧。方向不能按 back 判：侧面视图（w）back=False，
    # 但脑后在**屏幕右**（人朝左）—— 按 look 判才对：
    # look<0 朝左走 → 脑后在右；look>0 朝右走（镜像视图）→ 在左；
    # 正/背面（look==0）帽尖藏在头正后方，屏幕上画不出来，直接不画
    if v["look"] != 0:
        tip = 1 if v["look"] < 0 else -1
        d.polygon([(cx + tip * hw * 0.5, 46), (cx + tip * (hw + 7), 72),
                   (cx + tip * hw * 0.2, 76)], fill=HOOD, outline=OUTLINE)


def face_box(v):
    """脸板（前面板）的 x 范围。head 和 face 两层共用，否则换个表情五官会漂。

    规则见 head() 的 docstring：脸锚在脸骨朝向侧的边缘往里收，宽度随 turn 收缩，
    绝不越过轮廓。抽成函数是为了让 face 层能拿到完全一样的坐标。
    """
    t = v["turn"]
    cx = 128 + v["look"] * 0.55
    half = 22 * (0.86 + 0.14 * v["narrow"])
    hw = half * (1.0 - 0.14 * t)
    fx0 = cx - hw + 1.5
    fw = (2.0 * hw - 3.0) * (1.0 - 0.55 * t)
    return fx0, fw


def head(im, d, v):
    """木桶脑袋（不含五官）。

    转身靠四件事一起表达，掉一件就变成「正脸贴歪了」：
      1. 头骨（桶）宽度几乎不变 —— 圆柱正投影宽度恒定，只按 narrow 微收
      2. 脸（前面板）只占朝向前侧的那一截，随 turn 收缩，绝不越过脸骨边缘
      3. 远侧那只眼被鼻尖压扁、往脸缘挤，近侧的保持圆 —— 方向感主要靠这个
      4. 后脑那侧压暗 + 头发压下来

    改之前是「整张脸等比缩小 + 整体左移」，脸从左边溢出脸骨（脸比头还宽），
    而压扁的偏偏是**近侧**那只眼。两个方向信号互相打架，所以斜角那四格
    看着不但和身体不一致，自己内部也不自洽。

    **五官（眼/嘴）已经搬到 face 槽位**（见 face_layer）：
    表情要能换，就不能画死在这张图里。head 只留头骨、脸板、鼻尖、后脑、耳朵。
    鼻尖必须留在这里 —— 它是轮廓的一部分（从脸骨边缘鼓出去），
    放 face 层的话换个表情鼻子就没了。
    """
    t = v["turn"]
    cx = 128 + v["look"] * 0.55
    half = 22 * (0.86 + 0.14 * v["narrow"])
    y0, y1 = 56, 100
    hw = half * (1.0 - 0.14 * t)

    d.rounded_rectangle([cx - hw, y0, cx + hw, y1], radius=11,
                        fill=WOOD, outline=OUTLINE, width=2)
    # 转过去那一侧压暗：和躯干用同一套明暗，两个部件才不会一个转一个不转
    if t > 0.05:
        dw = min(2 * hw - 10, hw * 0.85 * t)
        # 和躯干同一条规则：背面/侧面板在哪边，暗面就在哪边
        bx0 = cx + hw - dw if not v["back"] else cx - hw
        d.rectangle([bx0, y0 + 3, bx0 + dw, y1 - 3], fill=WOOD_SHADE)
        d.rounded_rectangle([cx - hw, y0, cx + hw, y1], radius=11,
                            outline=OUTLINE, width=2)
    # 木纹顶盖（木桶感）
    d.ellipse([cx - hw, y0 - 6, cx + hw, y0 + 11], fill=WOOD_L, outline=OUTLINE, width=2)
    d.arc([cx - hw * 0.5, y0 - 2, cx + hw * 0.5, y0 + 9], 200, 340, fill=WOOD_D, width=2)

    if v["face"]:
        fx0, fw = face_box(v)
        fx1 = fx0 + fw
        d.rounded_rectangle([fx0, 63, fx1, 96], radius=7,
                            fill=FACE, outline=OUTLINE, width=2)
        # 鼻尖：轮廓凸起，留在这里（原因见 docstring）
        if v["profile"]:
            d.ellipse([fx0 - 6, 82, fx0 + 5, 92], fill=FACE, outline=OUTLINE, width=2)
        elif t > 0.22:
            # 3/4 也要露鼻尖，否则分不清朝哪边
            d.ellipse([fx0 - 5, 82, fx0 + 6, 91], fill=FACE, outline=OUTLINE, width=2)
        # 3/4 起：后脑那侧由头发接管。hair_back 的 z 低于 head，靠它盖不住
        if t > 0.30:
            d.rounded_rectangle([fx1 - 3, y0 + 1, cx + hw - 1, y1 - 1], radius=10,
                                fill=(96, 62, 36, 255), outline=OUTLINE, width=2)
            for i in range(3):
                x = fx1 + 1 + i * 5
                if x < cx + hw - 5:
                    d.line([(x, y0 + 13), (x, y1 - 9)], fill=(72, 46, 26, 255), width=2)
            d.rounded_rectangle([cx - hw, y0, cx + hw, y1], radius=11,
                                outline=OUTLINE, width=2)
    else:
        # 背面：整个后脑就是头发。转身时头发块朝朝向后侧偏，
        # 另一侧露出耳朵和一小条脸颊 —— 不偏的话 NW 和 N 是同一张图
        boff = hw * 0.34 * t
        # 右边必须钉在头骨轮廓上。写成 cx + hw + boff 会让后脑露出发块，
        # 像头右侧多长了一个包
        d.rounded_rectangle([cx - hw + boff, y0 + 2, cx + hw - 1, y1 - 2], radius=10,
                            fill=(96, 62, 36, 255), outline=OUTLINE, width=2)
        for i in (-1, 0, 1):
            x = cx + i * hw * 0.40 + boff
            if cx - hw + 4 < x < cx + hw - 5:
                d.line([(x, y0 + 10), (x, y1 - 8)], fill=(72, 46, 26, 255), width=2)
        if t > 0.3:
            # 露出来的那一侧：耳朵 + 一小条脸颊，说明人转过来了、不是正背对。
            # 脸颊要和耳朵连成一片，两块分开画会像贴了两张创可贴
            earx = cx - hw + boff
            d.rounded_rectangle([earx - 3, 74, earx + 3, 94], radius=3,
                                fill=FACE, outline=OUTLINE, width=2)
            d.ellipse([earx - 5, 66, earx + 3, 78], fill=WOOD, outline=OUTLINE, width=2)
    ball(d, *JOINTS["head"])


# 表情表：一个表情 = 一组眼睛形状 + 一种嘴形。
#
# 为什么不做眉毛：刘海（hair_front）压到 y=68，眼睛上沿在 71，中间只剩 2px。
# 硬塞一对眉毛要么被刘海盖掉，要么把眼睛往下挤破脸板。像素画风里
# 「眼形 + 嘴形」已经够表达情绪，怒的那道眉就贴着上眼睑画（narrow 里的斜线）。
#
#   open   普通圆眼        narrow 眯眼 + 压眉（怒）    arc  弯月笑眼
#   wide   瞪大（惊）       droop  外眼角下垂（悲）     shut 闭眼（横线）
FACE_EXPR = {
    "neutral":  dict(eye="open",   mouth="line"),
    "smile":    dict(eye="arc",    mouth="smile"),
    "angry":    dict(eye="narrow", mouth="frown"),
    "sad":      dict(eye="droop",  mouth="sad"),
    "surprise": dict(eye="wide",   mouth="o"),
    "blink":    dict(eye="shut",   mouth="line"),
}

WHITE = (252, 248, 240, 255)
PUPIL = (40, 30, 24, 255)


def _eye(d, x, y, ew, cfg, far=False):
    """画一只眼。x,y 是眼中心，ew 是半宽（远侧眼更小，见 head 的转身规则）。"""
    shape = cfg["eye"]
    if shape == "shut":
        d.line([(x - ew, y), (x + ew, y)], fill=OUTLINE, width=3)
        return
    if shape == "arc":
        # 笑眼就是「闭着眼往上弯」：一段上凸的弧，不画眼球
        d.arc([x - ew, y - 3, x + ew, y + 7], 200, 340, fill=OUTLINE, width=3)
        return
    if shape == "narrow":
        eh = 3.4
        d.ellipse([x - ew, y - eh, x + ew, y + eh], fill=WHITE, outline=OUTLINE, width=2)
        d.ellipse([x - ew * 0.36, y - eh * 0.75, x + ew * 0.36, y + eh * 0.75], fill=PUPIL)
        # 怒眉：贴着上眼睑的一条斜线，内侧（靠中线）低。只占 4px 高，
        # 在刘海下沿（68）和安全区内，不会像独立眉毛那样被盖住
        if x < 128:
            d.line([(x + ew, y - eh - 1), (x - ew - 1, y - eh - 5)], fill=OUTLINE, width=2)
        else:
            d.line([(x - ew, y - eh - 1), (x + ew + 1, y - eh - 5)], fill=OUTLINE, width=2)
        return
    if shape == "wide":
        eh = 7.4
        d.ellipse([x - ew * 1.1, y - eh, x + ew * 1.1, y + eh], fill=WHITE,
                  outline=OUTLINE, width=2)
        d.ellipse([x - 2.2, y - 2.6, x + 2.2, y + 2.6], fill=PUPIL)
        return
    if shape == "droop":
        # 悲：眼睛略扁，外侧上眼睑往下跌一道 —— 就是「眼角耷拉」
        eh = 4.6
        d.ellipse([x - ew, y - eh, x + ew, y + eh], fill=WHITE, outline=OUTLINE, width=2)
        d.ellipse([x - 2, y - 1.6, x + 2.6, y + 2.6], fill=PUPIL)
        if x < 128:
            d.line([(x - ew, y - eh + 1), (x - ew + 4, y - eh - 1)], fill=OUTLINE, width=2)
        else:
            d.line([(x + ew, y - eh + 1), (x + ew - 4, y - eh - 1)], fill=OUTLINE, width=2)
        return
    # open（默认）
    d.ellipse([x - ew, y - 6, x + ew, y + 6], fill=WHITE, outline=OUTLINE, width=2)
    d.ellipse([x - 2, y - 2, x + 3, y + 4], fill=PUPIL)


def _mouth(d, mx, shape, profile=False):
    """嘴。y 区间 84~94，和脸板底部（96）、鼻尖（82~92）错开。

    PIL 的 y 轴朝下：arc(20,160) 画的是**下半段**弧「‿」（两端上翘 = 笑）；
    arc(200,340) 是**上半段**「⌒」（两端下垂 = 生气/难过）。
    第一次写反过一次：smile 用了 200,340，渲染出来全是哭脸。
    """
    if shape == "smile":
        d.arc([mx - 9, 80, mx + 9, 94], 40, 140, fill=OUTLINE, width=2)
    elif shape == "frown":
        d.arc([mx - 7, 84, mx + 7, 92], 200, 340, fill=OUTLINE, width=2)
    elif shape == "sad":
        d.arc([mx - 6, 86, mx + 6, 93], 210, 330, fill=OUTLINE, width=2)
    elif shape == "o":
        d.ellipse([mx - 3, 85, mx + 3, 93], fill=(120, 60, 52, 255),
                  outline=OUTLINE, width=2)
    elif profile:
        # 侧面：短横线，别越过鼻尖
        d.line([(mx - 4, 90), (mx + 5, 90)], fill=OUTLINE, width=2)
    else:
        # line：中性。「‿」极浅，不像笑也不像苦
        d.arc([mx - 7, 85, mx + 7, 93], 30, 150, fill=OUTLINE, width=2)


def face_layer(im, d, v, expr="neutral"):
    """五官层（face 槽位：眼 + 嘴）。

    挂 head 关节、z=32（head 是 30），换表情 = 换一张图，
    头骨/头发/鼻尖一个像素都不用重画。

    坐标和 head() 共用 face_box()，否则换个表情五官会整体漂。
    背面视图（nw/n）不画 —— Z_ON_BACK 里 face=0 已经把它压到底，
    但空图更保险：万一哪天 z 表被改坏，也糊不到后脑上。
    """
    if not v["face"]:
        return
    cfg = FACE_EXPR[expr]
    fx0, fw = face_box(v)
    fx1 = fx0 + fw
    t = v["turn"]

    if v["profile"]:
        ex = fx0 + fw * 0.55
        _eye(d, ex, 77, 6.0, cfg)
        _mouth(d, ex, cfg["mouth"], profile=True)
    else:
        # 远侧（屏幕左）那只眼被鼻梁压扁、往脸缘挤 —— 和 head 的转身规则一致
        ew_far = 6.0 * (1.0 - 0.45 * t)
        far_x = fx0 + max(fw * 0.28, ew_far + 1.0)
        near_x = fx1 - fw * 0.28
        _eye(d, far_x, 77, ew_far, cfg)
        _eye(d, near_x, 77, 6.0, cfg)
        _mouth(d, (fx0 + fx1) / 2.0, cfg["mouth"])


def arm(im, d, v, side, style="wood"):
    """上臂。肩球必须**压进躯干**，不能只是"贴着"。

    根因是枢轴位置，不是画法：原来肩枢轴在 (104/152, 108)，木桶只有 128±16
    → 桶边在 112/144，**球心整整落在轮廓外面 8px**。球半径 7 + 1px 描边
    刚好和桶边相切，于是：

      · 静止时就是一条 1~2px 的背景缝（斜角那一侧更宽，因为 narrow 把桶又收窄了）；
      · 肩绕这个枢轴摆 ±20°，内缘直接甩出去，缝张到 3px。

    看上去就是"胳膊挂在身体外面"，而肘、膝、胯的球都有大半个埋在肢体里，
    唯独肩没埋 —— 所以只有胳膊显得是贴上去的。

    修法是把肩枢轴（和肘枢轴一起）平移 4px 进躯干：球心到桶边只剩 4px，
    球半径 8.5 就压进去 4~6px。**必须同时挪肘**，否则上臂变成向外张 10px，
    腋下反而裂得更开。

    为什么不是"在肩端补一根伸进桶里的肩根"：那根肩根会跟着肩一起转，
    攻击动作里肩转 −95°，肩根就整个甩到桶外面去了（实测压入从 4px 掉到 0）。
    球心在枢轴上，绕自身转多少度都还是那个圆 —— 只有挪枢轴才是旋转不变的。
    """
    sh = _limb_tuck(v, JOINTS[f"shoulder_{side}"], side)
    el = _limb_tuck(v, JOINTS[f"elbow_{side}"], side)
    far = far_limb(v, side)
    # 远侧手臂画细一点：透视缩小。端点是固定的（要和枢轴对齐），只改粗细
    w = 15 * (0.78 + 0.22 * v["narrow"]) * (0.80 if far else 1.0)
    if style != "wood":
        # 袖子：比木头胳膊粗一圈，把肩球包进布里 —— 「长袍盖住关节」就靠这一点。
        # 远侧照旧压暗，否则转身后两条袖子一样亮，看不出前后
        cloth = (ROBE_D if far else ROBE) if style == "robe" else (LEATHER_D if far else LEATHER)
        capsule(d, sh, el, w + 3.5, cloth)
        d.ellipse([sh[0] - 8, sh[1] - 8, sh[0] + 8, sh[1] + 8],
                  fill=cloth, outline=OUTLINE, width=2)
        return
    capsule(d, sh, el, w, WOOD_FAR if far else WOOD)
    # 肩球比肘球（6）、胯球（6.5）大一圈：它是唯一"半个露在外面"的球，
    # 半径不足就没法同时做到"看得出是关节"和"压进躯干 4px 以上"
    ball(d, *sh, r=8.5 if not far else 7, far=far)


def forearm(im, d, v, side, style="wood"):
    sx = -1 if side == "l" else 1
    el = _limb_tuck(v, JOINTS[f"elbow_{side}"], side)
    far = far_limb(v, side)
    hand = (el[0] - 3 * sx, el[1] + 22)
    w = 13 * (0.78 + 0.22 * v["narrow"]) * (0.82 if far else 1.0)
    if style != "wood":
        # 前臂袖子：一路包到手踝，末端一道外翻袖口。
        # 手改成皮肤色（FACE）—— 袖子伸出木头手怎么看怎么怪，
        # 而 FACE 是皮肤通道的颜色，会和脸板一起跟着 skin_tint 走。
        cloth = (ROBE_D if far else ROBE_L) if style == "robe" else (LEATHER_D if far else LEATHER_L)
        capsule(d, el, hand, w + 4.0, cloth)
        d.ellipse([hand[0] - 8, hand[1] - 8, hand[0] + 8, hand[1] + 8],
                  fill=cloth, outline=OUTLINE, width=2)
        d.ellipse([hand[0] - 6, hand[1] + 1, hand[0] + 6, hand[1] + 12],
                  fill=WOOD_FAR if far else FACE, outline=OUTLINE, width=2)
        # 袖口 / 护腕的两道箍
        for yy in (hand[1] - 6, el[1] + 8):
            d.line([(hand[0] - 8, yy), (hand[0] + 8, yy)], fill=HOOD_D, width=2)
        return
    capsule(d, el, hand, w, WOOD_FAR if far else WOOD_L)
    hr = 8 if not far else 6
    d.ellipse([hand[0] - hr, hand[1] - hr, hand[0] + hr, hand[1] + hr],
              fill=WOOD_FAR if far else WOOD, outline=OUTLINE, width=2)
    ball(d, *el, r=6, far=far)


def thigh(im, d, v, side):
    hp = _limb_tuck(v, JOINTS[f"hip_{side}"], side)
    kn = _limb_tuck(v, JOINTS[f"knee_{side}"], side)
    far = far_limb(v, side)
    capsule(d, hp, kn, 16 * (0.84 if far else 1.0), WOOD_FAR if far else WOOD)
    ball(d, *hp, r=6.5, far=far)


def foot(d, v, kn, far, fill=None):
    """脚。**形状由「朝向在屏幕横轴上投影了多少」决定**，不能所有视图都画一条横躺胶囊。

    S / N 原来就错在这：正对（正背）镜头时脚的长轴指向屏幕里外，投影到画面上
    只剩「脚宽」；可它一律画成 22x9 的横条，比小腿(14)还宽 8px，两只脚在中线
    连成一条 40px 的长板 —— 看上去脚是横着长的、朝左右，而不是朝镜头。
    正面要的是：和脚踝同宽的一小块、**居中在踝上**、两脚之间留缝。
    侧面(w)才该是横条，而且是朝**朝向那一侧**伸长、脚跟留在踝后。

    f = 朝向在屏幕横轴上的投影：0 正面/背面、-1 完全朝屏幕左（脚特长在左边）。
    """
    f = float(v["foot"])
    ext = abs(f)
    k = 0.86 if far else 1.0
    w = (FOOT_W + (FOOT_L - FOOT_W) * ext) * k
    # 脚尖朝朝向侧伸出；正面时偏移为 0，脚正好骑在脚踝上（这就是"不左右偏移"）
    cx = kn[0] + f * (FOOT_L - FOOT_W) * 0.5
    d.rounded_rectangle([cx - w / 2, FOOT_Y0, cx + w / 2, FOOT_Y1], radius=4,
                        fill=fill or (WOOD_FAR if far else WOOD_D), outline=OUTLINE, width=2)
    # 鞋底压深一档：脚是踩在地上的，正面看也该有一条底
    d.line([(cx - w / 2 + 3, FOOT_Y1 - 2), (cx + w / 2 - 3, FOOT_Y1 - 2)],
           fill=(92, 58, 30, 255), width=2)
    if ext > 0.25:
        # 侧面 / 3-4：脚尖那道缝，标出脚的长轴方向
        tx = cx + f * (w / 2 - 4)
        d.line([(tx, FOOT_Y0 + 4), (tx, FOOT_Y1 - 4)], fill=WOOD_D, width=2)


def shin(im, d, v, side, style="wood"):
    kn = _limb_tuck(v, JOINTS[f"knee_{side}"], side)
    far = far_limb(v, side)
    ft = (kn[0], 206)
    if style == "boot":
        # 皮靴：靴筒比小腿粗一圈，膝下留一道外翻靴口。
        # 膝盖球**保留**——靴筒停在膝下，球还在外面，才看得出这是关节不是木棍
        boot = LEATHER_D if far else LEATHER
        capsule(d, (kn[0], kn[1] + 5), ft, 15 * (0.86 if far else 1.0), boot)
        d.ellipse([kn[0] - 9, kn[1] + 1, kn[0] + 9, kn[1] + 11],
                  fill=boot, outline=OUTLINE, width=2)
        d.line([(kn[0] - 8, kn[1] + 5), (kn[0] + 8, kn[1] + 5)], fill=WOOD_D, width=1)
        foot(d, v, kn, far, LEATHER_D if far else LEATHER)
        ball(d, *kn, r=6, far=far)
        return
    capsule(d, kn, ft, 14 * (0.86 if far else 1.0), WOOD_FAR if far else WOOD_L)
    foot(d, v, kn, far)
    ball(d, *kn, r=6, far=far)


def hair_back(im, d, v):
    """后发。钉死在头骨上——它是硬片，不参与弹簧摆动。

    一整条辫子，不是两片板。之前是左右各一根宽 14 的圆角矩形，
    两条加起来比躯干还宽，背视时把整个身体糊成一块棕色的板，
    于是 NW/N 两格根本看不出"身体朝哪边"。辫子收窄到 11、
    挪成一条，躯干和披风才透得出来。
    """
    t = v["turn"]
    cx = 128 + v["look"] * 0.55
    half = 24 * (0.86 + 0.14 * v["narrow"])
    # 后脑勺那一圈（正面会被 head 盖住，只有背向时才露出来）
    d.rounded_rectangle([cx - half * 0.85, 52, cx + half * 0.85, 78], radius=8,
                        fill=(96, 62, 36, 255), outline=OUTLINE, width=2)
    # 辫子：转身后落在朝向后侧（+x），纯正/背面时在中线
    bx = cx + half * 0.34 * t
    bw = 5.5
    d.rounded_rectangle([bx - bw, 62, bx + bw, 152], radius=5,
                        fill=(96, 62, 36, 255), outline=OUTLINE, width=2)
    # 辫子分节：四道箍，读了才像编过的，不像一块板
    for k in range(4):
        y = 78 + k * 18
        d.line([(bx - bw + 1, y), (bx + bw - 1, y)], fill=(72, 46, 26, 255), width=3)
    d.rounded_rectangle([bx - bw - 2, 148, bx + bw + 2, 156], radius=3,
                        fill=(120, 78, 44, 255), outline=OUTLINE, width=2)


def hair_front(im, d, v):
    """刘海 + 鬓角。只覆盖额头（y 50~68），眼睛在 71~83 —— 绝不遮眼。

    参考视频里刘海是贴在额头的一小片，眼睛完整露出；这也是"脸的角度"
    能不能被看出来的前提：眼睛全露才分得清正脸/3/4/侧脸。

    鬓角原来画到 y=84，正好压在嘴的位置上，正面看像长了胡子。
    收到 y 58~74（眼睛下沿之上），并且只贴在脸的外侧，不侵入脸面。
    """
    if v["back"]:
        return   # 背面没有刘海
    t = v["turn"]
    cx = 128 + v["look"] * 0.55
    half = 24 * (0.86 + 0.14 * v["narrow"])
    # 额头那一弯：跟着脸（前面板）走，不跟着整颗头走
    cap = half * (1.0 - 0.30 * t)
    d.chord([cx - cap, 50, cx + cap, 82], 180, 360,
            fill=(120, 78, 44, 255), outline=OUTLINE, width=2)
    for i in (-1, 0, 1):
        x = cx + i * 8 * (1.0 - 0.60 * t) - cap * 0.25 * t
        d.line([(x, 55), (x - cap * 0.10 * t, 66)], fill=(84, 52, 28, 255), width=2)
    # 鬓角：正面两侧各一绺；转过去以后只在朝向侧留，另一侧交给 back 面的头发
    sides = (-1,) if t > 0.45 else (-1, 1)
    for sx in sides:
        x0 = cx + sx * (cap * 0.90 + 2.0)
        d.rounded_rectangle([x0 - 4, 58, x0 + 4, 74], radius=4,
                            fill=(120, 78, 44, 255), outline=OUTLINE, width=2)


def arc_span(r, phi_deg, theta_deg, n=64):
    """半径 r、半包角 phi 的一段圆弧，绕竖直轴转 theta 后投影到屏幕 x 的 [lo, hi]。

    这是披风唯一的几何依据：布是**包在背上的一段弧**，不是一块平板。
    """
    th = math.radians(theta_deg)
    lo = 1e9
    hi = -1e9
    for i in range(n + 1):
        a = math.radians(-phi_deg + 2.0 * phi_deg * i / n) + th
        x = r * math.sin(a)
        lo = min(lo, x)
        hi = max(hi, x)
    return lo, hi


def cape(im, d, v):
    """披风。挂在下巴以下到膝上的一块布，包住整个背。

    **这里原来是按「宽度 × (1−0.30·turn)」收的，那是错的，错法还很有欺骗性。**

    披风不是平板，是包住背部的一段圆柱面（半包角 CAPE_PHI）。
    平板旋转时投影宽度 = W·cosθ，转到 90° 侧面会塌成一条零宽的线；
    圆弧不会 —— 侧面看到的是这一圈弧"从背后绕出来"的那一段，正好最厚。
    两条曲线的差别不在于 45°，而在于两端的**位置**：

        视图   θ     正确地占的 x 区间（含廓半径 17→29）
        S      0°    111.6 … 144.4   (对称)
        SW     45°   119.5 … 142.7   (整体偏右，右缘 = 背后)
        W      90°   132.4 … 144.4   (整段都跑到中线右边)
        NW     135°  119.5 … 142.7   (和 SW 一样，深度靠 z 序区分)

    旧公式在 W 给出的区间是 124…146（下摆 116…150），**左缘跨过中线到了人的正面**，
    于是侧面看是一块斜挂着的红板、背面看是一块盖住全身的板 —— 前者就是
    "披风挂在围裙位置"，后者让远侧胳膊被布整块吃掉。

    圆弧公式同时解决三件事：
      · 斜角不再往正面溢（左缘钉在 119.5，而不是 112）；
      · 侧面自动收成 12px 宽的一条（不是 35px 的板）；
      · 上沿和下摆各自算，不再出现"上沿移 5.5、下摆只移 2.75"的拧麻花。
    """
    cx = 128.0
    deg = v["deg"]
    lo_t, hi_t = arc_span(CAPE_R_TOP, CAPE_PHI, deg)
    lo_h, hi_h = arc_span(CAPE_R_HEM, CAPE_PHI, deg)
    d.polygon([(cx + lo_t, 106), (cx + hi_t, 106),
               (cx + hi_h, 190), (cx + lo_h, 190)],
              fill=CAPE, outline=OUTLINE)
    # 布褶：走可见那一段的中线，不是走布本身的中线
    # （布的中线是「背中心」，斜角时会贴着右缘，看着像描边）
    x0 = cx + (lo_t + hi_t) / 2.0
    x1 = cx + (lo_h + hi_h) / 2.0
    d.line([(x0, 116), (x1, 184)], fill=CAPE_D, width=2)
    # 这里原来是 chest 枢轴上的金球，但它跟着披风一起染色，
    # 披风一染成青色就变成一颗蓝点。遮罩烘焙之前先不放球。


def weapon(im, d, v):
    """右手长剑。

    两条几何约束，少一条就穿帮：

    1. 枢轴必须和 forearm 的 hand 算在同一个点上。剑和 forearm 都挂在 elbow_r、
       绕同一个枢轴转，所以只要美术里「柄正好落在手心」，跑起来永远是握着的。
    2. 剑身相对手臂要**前倾 18°**。画成完全竖直的话，手臂一前伸，剑身就正好压在
       手臂上（两者都沿 -x），视觉上剑消失了，只剩一个柄在飞。
    """
    el = JOINTS["elbow_r"]
    if v["profile"]:
        el = lerp(el, (126, el[1]), 0.62)
    hx = el[0] - 3          # side = r -> sx = +1 -> hand.x = el.x - 3
    hy = el[1] + 22
    c = (hx, hy)
    tilt = 0                # 竖直握持：站姿最好看，挥剑时剑身会压在前臂上（正常，剑在最上层）

    guard_y = hy - 9
    blade_y = guard_y - 58

    # 剑身（带收尖）。金属蓝必须够深——太浅会融进浅色背景
    d.polygon(_tilt([(hx - 3.5, guard_y), (hx + 3.5, guard_y),
                     (hx + 3.0, blade_y + 9), (hx, blade_y),
                     (hx - 3.0, blade_y + 9)], c, tilt),
              fill=(116, 134, 168, 255), outline=OUTLINE)
    d.line(_tilt([(hx, guard_y - 3), (hx, blade_y + 10)], c, tilt),
           fill=(190, 206, 232, 255), width=2)
    # 护手
    d.polygon(_tilt([(hx - 9, guard_y - 3), (hx + 9, guard_y - 3),
                     (hx + 9, guard_y + 2), (hx - 9, guard_y + 2)], c, tilt),
              fill=GOLD, outline=OUTLINE)
    # 柄 + 柄头（金球，呼应「可见球关节」这套设定）
    grip = _tilt([(hx, guard_y + 2), (hx, hy + 6)], c, tilt)
    capsule(d, grip[0], grip[1], 7, (110, 70, 40, 255))
    pom = _tilt([(hx, hy + 9)], c, tilt)[0]
    ball(d, pom[0], pom[1], r=5)


DRAW = {
    "body": body,
    "head": head,
    "face": face_layer,
    "hair_back": hair_back,
    "hair_front": hair_front,
    "cape": cape,
    "hat": hat,
    "arm_l": lambda im, d, v, style="wood": arm(im, d, v, "l", style),
    "arm_r": lambda im, d, v, style="wood": arm(im, d, v, "r", style),
    "fore_l": lambda im, d, v, style="wood": forearm(im, d, v, "l", style),
    "fore_r": lambda im, d, v, style="wood": forearm(im, d, v, "r", style),
    "leg_l": lambda im, d, v: thigh(im, d, v, "l"),
    "leg_r": lambda im, d, v: thigh(im, d, v, "r"),
    "shin_l": lambda im, d, v, style="wood": shin(im, d, v, "l", style),
    "shin_r": lambda im, d, v, style="wood": shin(im, d, v, "r", style),
    "weapon": weapon,
}

# 多变体槽位：值 = 变体名列表。
# 有变体时文件名 {slot}_{variant}_puppet_{view}.png，无变体时保持
# {slot}_puppet_{view}.png —— 旧的加载代码（CharacterVisual.from_assets）
# 和已有的 14 套素材完全不用动。
#
# "" = **默认变体**（还是不带后缀的老文件名）。服装是"在原有基础上多出几套"，
# 不是"原来的那套也改名叫 wood"：运行时的 from_assets 直接拼
# {slot}_puppet_{view}.png，改名会让所有默认装配一次性失灵。
VARIANTS = {
    "face": list(FACE_EXPR.keys()),
    "body": ["", "robe", "leather"],
    "arm_l": ["", "robe", "leather"],
    "arm_r": ["", "robe", "leather"],
    "fore_l": ["", "robe", "leather"],
    "fore_r": ["", "robe", "leather"],
    "shin_l": ["", "boot"],
    "shin_r": ["", "boot"],
    # hat 没有默认：默认角色不戴帽子，只有变体名
    "hat": ["hood", "wizard"],
}

ORDER = ["cape", "hair_back", "leg_r", "shin_r", "arm_r", "fore_r",
         "leg_l", "shin_l", "body", "arm_l", "fore_l", "head", "face",
         "hair_front", "weapon"]


def main():
    root = Path("assets/parts")
    total = 0
    for slot in DRAW:
        (root / slot).mkdir(parents=True, exist_ok=True)
        names = VARIANTS.get(slot)
        for view, v in VIEWS.items():
            for name in (names or [""]):
                im, d = canvas()
                if name:
                    DRAW[slot](im, d, v, name)
                    stem = f"{slot}_{name}"
                else:
                    DRAW[slot](im, d, v)
                    stem = slot
                im.save(root / slot / f"{stem}_puppet_{view}.png")
                # 染色 mask 与贴图一一对应（同 stem 同 view）。
                # face 层全是眼白/瞳孔/线条 → mask 全黑，等于不染，但也生成，
                # 让运行时"有没有 mask"不用特判
                make_mask(im).save(root / slot / f"{stem}_mask_{view}.png")
                total += 1
    print(f"生成 {len(DRAW)} 部件，共 {total} 张（贴图 + mask 各一份）")

    sheet = Image.new("RGBA", (CELL * len(VIEWS), CELL), (238, 240, 248, 255))
    for i, view in enumerate(VIEWS):
        comp = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
        for slot in ORDER:
            names = VARIANTS.get(slot)
            # 自检图只拼默认变体（没变体的走老命名）
            fname = (f"{slot}_{names[0]}_puppet_{view}.png" if names and names[0]
                     else f"{slot}_puppet_{view}.png")
            comp.alpha_composite(Image.open(root / slot / fname))
        sheet.alpha_composite(comp.crop((60, 40, 200, 230)), (i * CELL, 30))
    out = Path(os.environ.get("TEMP", "/tmp")) / "puppet_views.png"
    sheet.save(out)
    print("自检图:", out)


if __name__ == "__main__":
    main()
