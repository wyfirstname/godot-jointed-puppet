"""检查「胳膊和躯干在绑定点上有没有透光的缝」。

起因：看着像胳膊挂在身体外面 —— 肩关节球刚好贴在木桶边线外侧、球心落在轮廓外
8px，两侧各只有 0~1px 的相切面。稍微一动、或者放大一点，肩和腰之间就露一条背景色。

判据（数值，不靠眼睛）：
    gap   = 胳膊的 alpha 区域到躯干 alpha 区域的最小欧氏距离（px）
            > 0  → 透光缝，胳膊确实浮在身体外面
            0    → 贴着（勉强算接上）
    pen   = 胳膊压进躯干里最深的像素数（px）
            < 3  → 太浅，靠抗锯齿的 1px 相切撑不住，动起来就开缝

    python tools/check_joint_gap.py        检查，有缝返回 1
    python tools/check_joint_gap.py -v     逐行打印每个方向的数值
    python tools/check_joint_gap.py --png  额外输出放大诊断图

八向的 z 表在这里独立维护一份（和 core/character/joint_doll.gd 对齐）：
本脚本要离线合成一张完整的角色，必须知道谁盖谁。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt as edt

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"

VIEW_NAMES = ["s", "sw", "w", "nw", "n"]
# 方向 -> (视图, 是否镜像)，与 joint_doll.gd 的 DIR_TO_VIEW 一致
DIR_TO_VIEW = [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (3, 1), (2, 1), (1, 1)]
DIR_NAMES = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]

SLOT_Z = {
    "hair_back": 0, "cape": 2, "wing": 4, "tail": 5,
    "leg_r": 6, "shin_r": 7, "arm_r": 8, "fore_r": 9,
    "leg_l": 6, "shin_l": 7,
    "body": 10, "clothes": 20, "shoes_l": 9, "shoes_r": 9,
    "arm_l": 13, "fore_l": 14,
    "head": 30, "ear": 31, "face": 32, "hair_front": 34, "hat": 36,
    "shoulder": 26, "glove_l": 42, "glove_r": 42,
    "offhand": 48, "weapon": 50, "summon": 60,
}
LIMB_Z = {
    "arm_l": (13, 8), "fore_l": (14, 9), "glove_l": (14, 9),
    "arm_r": (13, 8), "fore_r": (14, 9), "glove_r": (14, 9),
    "leg_l": (8, 6), "shin_l": (9, 7), "shoes_l": (9, 7),
    "leg_r": (8, 6), "shin_r": (9, 7), "shoes_r": (9, 7),
}
# 近侧：""=正/背面（左右等距），两侧同 z。NW 是唯一"近侧在贴图左边"的视图
NEAR_SIDE = {"s": "", "sw": "r", "w": "r", "nw": "l", "n": ""}
BACK_DIRS = (3, 4, 5)
Z_ON_BACK = {"cape": 22, "hair_back": 31, "hair_front": 0, "face": 0,
             "wing": 16, "tail": 16, "offhand": 8}
# 背面：**两只**手臂都要压过披风（胳膊垂在披风外面，不在布里面）。
# 远侧低一档只为保留层次，但仍必须 > 披风 22 —— 否则远臂会周期性被布吃掉。
ARM_Z_ON_BACK = {"arm_l": (24, 23), "arm_r": (24, 23),
                 "fore_l": (25, 24), "fore_r": (25, 24),
                 "glove_l": (25, 24), "glove_r": (25, 24)}

# 肩枢轴，和 joint_doll.gd / gen_joint_art.py 的 JOINTS 一致
JOINTS = {
    "shoulder_l": (108.0, 108.0), "elbow_l": (102.0, 130.0),
    "shoulder_r": (148.0, 108.0), "elbow_r": (154.0, 130.0),
}

# 判定门槛
GAP_MAX = 0        # 允许的最大透光缝
PEN_MIN = 3        # 要求的最小压入深度
# 与 PROFILE 的最大摆臂幅度同量级：W 18°、斜 13°、正/背 4°，再多留一档余量
SWEEP = (-20, -13, 0, 13, 20)


def load(slot: str, view: str) -> np.ndarray | None:
    p = PARTS / slot / f"{slot}_puppet_{view}.png"
    if not p.exists():
        return None
    return np.array(Image.open(p).convert("RGBA"))


def _load_external_z() -> dict:
    """读 data/layer_rules.json 里的结果矩阵（游戏运行时用的同一份）。

    这个脚本原来自己抄了一份 z 表 —— 抄一份就等于留一个会分叉的地方：
    设计器把某块挪到前面，离线合成图还按旧表画，于是"检查通过"而游戏里是错的。
    所以有外部表就用外部表，没有才退回下面的推导。
    """
    p = ROOT / "data" / "layer_rules.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("z", {})
    except Exception as e:                       # noqa: BLE001
        print("layer_rules.json 解析失败，退回内置表：%s" % e)
        return {}


EXT_Z = _load_external_z()


def slot_z(slot: str, view: str, is_back: bool) -> int:
    z = SLOT_Z.get(slot, 10)
    if slot in LIMB_Z:
        side = "l" if slot.endswith("_l") else "r"
        near = NEAR_SIDE[view]
        is_near = near == "" or side == near
        z = LIMB_Z[slot][0] if is_near else LIMB_Z[slot][1]
        if is_back and slot in ARM_Z_ON_BACK:
            z = ARM_Z_ON_BACK[slot][0 if is_near else 1]
    if is_back and slot in Z_ON_BACK:
        z = Z_ON_BACK[slot]
    row = EXT_Z.get(view) or {}
    if slot in row:
        z = int(row[slot])
    return z


def composite(view: str, is_back: bool, mirrored: bool, skip=()):
    """按 z 合成一张整身图，返回 (合成图, {槽位: alpha>,...})

    skip: 要排除的槽位（出脸部特写时排掉 weapon，否则剑身会压在脸上）
    """
    slots = [s for s in SLOT_Z
             if s not in skip and (PARTS / s / f"{s}_puppet_{view}.png").exists()]
    order = sorted(slots, key=lambda s: slot_z(s, view, is_back))
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    masks = {}
    for s in order:
        im = Image.open(PARTS / s / f"{s}_puppet_{view}.png").convert("RGBA")
        masks[s] = np.array(im)[:, :, 3] > 140
        canvas.alpha_composite(im)
    if mirrored:
        canvas = canvas.transpose(Image.FLIP_LEFT_RIGHT)
        masks = {k: np.fliplr(v) for k, v in masks.items()}
    return canvas, masks


def torso_mask(masks) -> np.ndarray:
    t = masks.get("body", np.zeros((256, 256), bool))
    if "clothes" in masks:
        t = t | masks["clothes"]
    return t


def measure(arm: np.ndarray, torso: np.ndarray):
    """返回 (gap, pen)：gap 为缝宽，pen 为压入深度，单位 px

    edt 给的是「到最近零像素的欧氏距离」：
      · edt(~torso) 在躯干外 >0，取胳膊上的最小值 —— 0 表示已经贴上或压进去，
        1 表示中间隔了 1px 透明，即一条真正的缝。
      · edt(torso) 在躯干内 >0，等于离桶边的深度，取胳膊上的最大值即压入多深。
    """
    if not arm.any() or not torso.any():
        return -1.0, 0.0
    gap = float(edt(~torso)[arm].min())
    pen = float(edt(torso)[arm].max())
    return gap, pen


def pivot_of(slot: str, view: str, mirrored: bool) -> tuple[float, float]:
    """槽位枢轴在画布上的位置（镜像后 x 关于 128 对称）"""
    side = slot[-1]
    p = JOINTS[f"shoulder_{side}"]
    if view == "w":  # 侧面：肢体按 _limb_tuck 收向中线
        tar = (128.0, p[1])
        p = (p[0] + (tar[0] - p[0]) * 0.62, p[1])
    elif view in ("sw", "nw"):
        far = side == ("r" if view == "nw" else "l")
        if far:
            p = (p[0] + (128.0 - p[0]) * 0.18, p[1])
    return (256.0 - p[0], p[1]) if mirrored else p


def sweep(canvas: Image.Image, masks, slot: str, torso: np.ndarray,
          view: str, mirrored: bool, angles) -> tuple[float, float]:
    """把胳膊绕肩枢轴转到各个角度，取最差的一档。

    枢轴在躯干轮廓**外面**，所以「静止时刚好相切」不算接上 ——
    肩一抬，胳膊的内缘就绕枢轴甩出去，缝立刻张开。这个扫角是判据的核心。
    """
    px, py = pivot_of(slot, view, mirrored)
    worst = (0.0, 99.0)
    src = Image.open(PARTS / slot / f"{slot}_puppet_{view}.png").convert("RGBA")
    if mirrored:
        src = src.transpose(Image.FLIP_LEFT_RIGHT)
    for a in angles:
        rot = src.rotate(a, center=(px, py), resample=Image.BICUBIC)
        m = np.array(rot)[:, :, 3] > 140
        gap, pen = measure(m, torso)
        if gap > worst[0] or pen < worst[1]:
            worst = (max(gap, worst[0]), min(pen, worst[1]))
    return worst


def main() -> int:
    verbose = "-v" in sys.argv
    want_png = "--png" in sys.argv
    bad = 0
    tiles = []
    print("%-3s %-5s %-4s %6s %6s %6s %6s  %s" % (
        "dir", "view", "arm", "gap", "pen", "摆臂缝", "摆臂压入", "结果"))
    for d, (vi, mir) in enumerate(DIR_TO_VIEW):
        view = VIEW_NAMES[vi]
        is_back = d in BACK_DIRS
        canvas, masks = composite(view, is_back, mir)
        torso = torso_mask(masks)
        near = NEAR_SIDE[view]
        for side in ("l", "r"):
            slot = f"arm_{side}"
            if slot not in masks:
                continue
            gap, pen = measure(masks[slot], torso)
            sgap, spen = sweep(canvas, masks, slot, torso, view, mir, SWEEP)
            ok = (gap <= GAP_MAX and pen >= PEN_MIN
                  and sgap <= GAP_MAX and spen >= PEN_MIN)
            if not ok:
                bad += 1
            tag = "正" if near == "" else ("近" if side == near else "远")
            print("%-3s %-5s %-4s %6.1f %6.1f %6.1f %6.1f  %s" % (
                DIR_NAMES[d], view, tag, gap, pen, sgap, spen, "OK" if ok else "X"))
        if want_png:
            crop = canvas.crop((72, 80, 184, 168)).resize((336, 264), Image.NEAREST)
            # 品红底：缝一旦存在就是一条刺眼的线，肉眼躲不掉
            bg = Image.new("RGBA", crop.size, (255, 0, 255, 255))
            bg.alpha_composite(crop)
            tiles.append(bg)

    print()
    if tiles:
        sheet = Image.new("RGBA", (336 * 4, 264 * 2), (20, 20, 20, 255))
        for i, t in enumerate(tiles):
            sheet.paste(t, ((i % 4) * 336, (i // 4) * 264))
        out = Path(os.environ.get("TEMP", "/tmp")) / "joint_gap.png"
        sheet.convert("RGB").save(out)
        print("诊断图:", out)
    if bad:
        print("失败：%d 处胳膊与躯干的绑定点没接上（gap>%d 或 pen<%d）" % (bad, GAP_MAX, PEN_MIN))
        return 1
    print("全部通过：八向每一条胳膊都与躯干压接 ≥%dpx，无透光缝" % PEN_MIN)
    return 0


if __name__ == "__main__":
    sys.exit(main())
