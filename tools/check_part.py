#!/usr/bin/env python3
"""部件验收门禁 —— 交进来的素材过不过得了这一关，跑一下就知道。

    python tools/check_part.py                       # 检查 assets/parts 下所有变体
    python tools/check_part.py --slot hat --variant wizard
    python tools/check_part.py --slot face           # 整个槽位

检查分三档：
    [E] error   必须修，修了才能进设计器/游戏
    [W] warning 不拦路，但大概率是坑（历史上真实翻过车的记了原因）
    [i] info    提示

每条检查背后都有一次真实事故：R=0 的金属遮罩、贴边被裁、挂点漂移、
半透明边缘串色……不是形式主义，是踩坑记录变成了断言。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
RULES = ROOT / "data" / "layer_rules.json"

VIEWS = ["s", "sw", "w", "nw", "n"]
CELL = 256
GROUND = 216

# 挂点必须落在部件包围盒附近的槽位（部件从关节长出来）。
# face / hair_front / hat 是「向上叠」的贴片，锚在头但画在头上方，不在名单里。
MUST_REACH_JOINT = {"body", "head", "arm_l", "arm_r", "fore_l", "fore_r",
                    "leg_l", "leg_r", "shin_l", "shin_r", "cape"}
REACH_SLACK = 16         # 关节允许在包围盒外多少 px
#                         （侧视图肢体收拢到中线，关节落在包络外一点是正常形态）
# 这些「向上叠」的贴片在背面视图留空是设计行为：背面看不见脸和刘海
BLANK_OK_ON_BACK = {"face", "hair_front"}
BACK_VIEWS = {"n", "nw"}


def scan_slot(slot: str) -> dict[str, dict[str, Path]]:
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


def mask_path(p: Path) -> Path:
    return p.with_name(p.name.replace("_puppet_", "_mask_"))


class Report:
    def __init__(self):
        self.errors = 0
        self.warns = 0

    def E(self, msg):
        self.errors += 1
        print("  [E] " + msg)

    def W(self, msg):
        self.warns += 1
        print("  [W] " + msg)

    def I(self, msg):
        print("  [i] " + msg)


def check_view(slot: str, var: str, view: str, p: Path, rig: dict, rep: Report):
    tag = "%s/%s %s" % (slot, var, view)

    im = Image.open(p)
    if im.size != (CELL, CELL):
        rep.E("%s: 尺寸 %s，应为 256x256" % (tag, im.size))
        return None
    if im.mode != "RGBA":
        rep.E("%s: 模式 %s，应为 RGBA" % (tag, im.mode))
        return None
    a = np.asarray(im.convert("RGBA"))
    alpha = a[:, :, 3]

    if not (alpha > 8).any():
        if slot in BLANK_OK_ON_BACK and view in BACK_VIEWS:
            rep.I("%s: 背面视图留空（贴片背面不可见，设计行为）" % tag)
            return None
        rep.E("%s: 全透明" % tag)
        return None

    # 半透明边：染色遮罩和描边都按硬边判定
    soft = ((alpha > 8) & (alpha < 250)).sum()
    if soft > (alpha > 8).sum() * 0.02:
        rep.W("%s: %d 个半透明像素（>2%%）—— 抗锯齿边缘会让遮罩串色" % (tag, soft))

    ys, xs = np.nonzero(alpha > 8)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    if x0 <= 1 or y0 <= 1 or x1 >= CELL - 2 or y1 >= CELL - 2:
        rep.E("%s: 包围盒 (%d,%d)-(%d,%d) 贴边/出界，转视角会被裁" % (tag, x0, y0, x1, y1))

    # 挂点够不够得到
    jn = rig["slot_joint"].get(slot)
    if slot in MUST_REACH_JOINT and jn:
        jx, jy = next(j["pos"] for j in rig["joints"] if j["name"] == jn)
        if not (x0 - REACH_SLACK <= jx <= x1 + REACH_SLACK
                and y0 - REACH_SLACK <= jy <= y1 + REACH_SLACK):
            rep.E("%s: 挂点 %s(%.0f,%.0f) 在包围盒外 %dpx —— 转起来部件会飞离身体"
                  % (tag, jn, jx, jy, REACH_SLACK))

    # 明度档位：单色平涂染色后是一块死色（只查正视图，其他视图是同一份美术的变体）
    if view == "s":
        vis = a[alpha > 8][:, :3].astype(int)
        lum = (vis * [3, 6, 1]).sum(axis=1) // 10
        levels = len(np.unique(lum // 24))
        if levels < 3:
            rep.W("%s: 明度只有 %d 档，建议主色/暗部/高光至少 3 档" % (tag, levels))

    # ---- 遮罩 ----
    mp = mask_path(p)
    if not mp.exists():
        rep.E("%s: 缺遮罩 %s" % (tag, mp.name))
        return None
    mk = np.asarray(Image.open(mp).convert("RGBA"))
    if mk.shape[:2] != (CELL, CELL):
        rep.E("%s: 遮罩尺寸不对 %s" % (tag, mk.shape[:2]))
        return None

    vis_m = alpha > 8
    m = mk[:, :, :3]
    painted = m.sum(axis=2) > 12
    outside = painted & ~vis_m
    if outside.any():
        rep.E("%s: 遮罩画到部件轮廓外 %d px" % (tag, int(outside.sum())))

    R, G, B = m[:, :, 0], m[:, :, 1], m[:, :, 2]
    dyed = vis_m & (R > 127)
    ratio = dyed.sum() / max(1, vis_m.sum())
    if view == "s" and ratio < 0.3:
        rep.W("%s: 只有 %.0f%% 像素可染（R=255）—— 几乎整件都染不了色（武器这类"
              "「刀身原色、握把可染」的设计可以无视）" % (tag, ratio * 100))

    # R=0 陷阱：G/B 有值但 R 没有 -> 看着配了色，实际一点不染
    trap = vis_m & (R <= 127) & ((G > 127) | (B > 127))
    if trap.any():
        rep.E("%s: %d px 的 G/B 有值但 R=0 —— shader 按 R 门控，这些区域永远不会被染色"
              % (tag, int(trap.sum())))

    # 非法组合
    valid = ((R > 127) & (G <= 127) & (B <= 127)) | \
            ((R > 127) & (G > 127) & (B <= 127)) | \
            ((R > 127) & (G <= 127) & (B > 127)) | (~painted)
    if not valid.all():
        rep.W("%s: 有 %d px 的遮罩不属于 红/黄/品红 任何一档" % (tag, int((~valid).sum())))

    return {"bbox": (int(x0), int(y0), int(x1), int(y1)),
            "cov": float(vis_m.mean())}


def check_variant(slot: str, var: str, views: dict[str, Path], rig: dict,
                  ref_bb, rep: Report):
    print("%s / %s" % (slot, var))
    missing = [v for v in VIEWS if v not in views]
    if missing:
        rep.E("%s/%s: 缺视图 %s —— 一转就穿帮" % (slot, var, ",".join(missing)))

    bbs = {}
    for v, p in sorted(views.items()):
        r = check_view(slot, var, v, p, rig, rep)
        if r:
            bbs[v] = r["bbox"]

    # 与同槽位默认变体的对齐性：换装不能跳位
    if ref_bb and var != "default" and "s" in bbs:
        (rx0, ry0, rx1, ry1), (x0, y0, x1, y1) = ref_bb, bbs["s"]
        dcx = abs((x0 + x1) / 2 - (rx0 + rx1) / 2)
        dh = abs((y1 - y0) - (ry1 - ry0)) / max(1, ry1 - ry0)
        if dcx > 12:
            rep.W("%s/%s: 正视图中轴偏了 %.0f px（和 default 比）—— 换装会横向跳位"
                  % (slot, var, dcx))
        if dh > 0.18:
            rep.W("%s/%s: 高度差 %.0f%%（和 default 比）—— 换装会纵向跳位"
                  % (slot, var, dh * 100))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slot")
    ap.add_argument("--variant")
    args = ap.parse_args()

    rig = json.loads(RULES.read_text(encoding="utf-8"))["_rig"]
    slots = [args.slot] if args.slot else sorted(p.name for p in PARTS.iterdir() if p.is_dir())

    rep = Report()
    n_var = 0
    for slot in slots:
        variants = scan_slot(slot)
        if args.variant:
            variants = {k: v for k, v in variants.items() if k == args.variant}
        if not variants:
            continue
        ref = variants.get("default")
        ref_bb = None
        if ref and "s" in ref:
            a = np.asarray(Image.open(ref["s"]).convert("RGBA"))
            m = a[:, :, 3] > 8
            if m.any():
                ys, xs = np.nonzero(m)
                ref_bb = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))
        for var, views in variants.items():
            check_variant(slot, var, views, rig, ref_bb, rep)
            n_var += 1

    print()
    if rep.errors:
        print("不通过：%d 个 error，%d 个 warning（%d 个变体）"
              % (rep.errors, rep.warns, n_var))
        return 1
    print("通过：%d 个变体，0 error，%d warning" % (n_var, rep.warns))
    return 0


if __name__ == "__main__":
    sys.exit(main())
