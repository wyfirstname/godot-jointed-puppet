"""生成 docs/sn_feet_compare.png 与 docs/nw_shoulder_compare.png。

本轮两个修法的改前 / 改后对照：

1. S / N 的脚
   改前：不分朝向，一律 22x9 的横躺胶囊（比小腿宽 8px，两脚在中线连成一条 40px 长板）
   改后：foot() 按「朝向在屏幕横轴上的投影」出形状 —— 正/背面只剩脚宽、居中在踝上

2. NW / NE 的肩膀
   改前：NEAR_SIDE 写成 "r"（近侧在贴图右边），而美术把 "r" 画成远侧（压暗、缩小、内收）
         —— 暗的胳膊压在身体上、亮的沉到背后；披风(22)还切掉近臂的半个肩球
   改后：NEAR_SIDE 取 "l"，且背面近臂抬到 24（压过披风）

改前不是靠改图，是把当时代码里的那几个值临时塞回去重画一遍，两边同一套合成逻辑。
"""

import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import check_joint_gap as C  # noqa: E402
import gen_joint_art as G   # noqa: E402

TMP = Path(tempfile.gettempdir()) / "paperdoll_prev_art"

# 中文标题必须用系统里的 CJK 字体，PIL 默认位图字体只有 ASCII（会打成一串方框）
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\msyhl.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    "/System/Library/Fonts/PingFang.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
]


def _font(size: int):
    for p in FONT_CANDIDATES:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


F_TITLE, F_TAG = _font(17), _font(15)

OLD_FOOT_W, OLD_FOOT_TOP = 11, 204   # 旧脚：22 宽（±11）、上沿 204


def _old_foot(d, v, kn, far):
    w = OLD_FOOT_W
    d.rounded_rectangle([kn[0] - w, OLD_FOOT_TOP, kn[0] + w, 213], radius=4,
                        fill=G.WOOD_FAR if far else G.WOOD_D,
                        outline=G.OUTLINE, width=2)


def build(dst: Path, old: bool) -> None:
    """把整套部件重画到 dst。old=True 时把脚换回旧画法。"""
    saved = G.foot
    if old:
        G.foot = _old_foot
    try:
        for slot in G.DRAW:
            (dst / slot).mkdir(parents=True, exist_ok=True)
            for view, v in G.VIEWS.items():
                im, d = G.canvas()
                G.DRAW[slot](im, d, v)
                im.save(dst / slot / f"{slot}_puppet_{view}.png")
    finally:
        G.foot = saved


def arm_z_back(slot: str, near: bool) -> int:
    """背面手臂 z。NEAR_ARM_ON_BACK 改名 ARM_Z_ON_BACK 后每条手臂有两档（近, 远）。"""
    rule = getattr(C, "ARM_Z_ON_BACK", {}).get(slot)
    if rule is None:
        return 0
    if isinstance(rule, dict):
        return rule["near" if near else "far"]
    return rule[0] if near else rule[-1]


def z_of(slot: str, view: str, is_back: bool, near: str, back_near_arm: bool) -> int:
    z = C.SLOT_Z.get(slot, 10)
    if slot in C.LIMB_Z:
        side = "l" if slot.endswith("_l") else "r"
        is_near = near == "" or side == near
        z = C.LIMB_Z[slot][0] if is_near else C.LIMB_Z[slot][1]
        if back_near_arm and is_back and slot in getattr(C, "ARM_Z_ON_BACK", {}):
            z = arm_z_back(slot, is_near)
    if is_back and slot in C.Z_ON_BACK:
        z = C.Z_ON_BACK[slot]
    return z


def compose(root: Path, view: str, is_back: bool, near: str, back_near_arm: bool):
    slots = [s for s in C.SLOT_Z if (root / s / f"{s}_puppet_{view}.png").exists()]
    order = sorted(slots, key=lambda s: z_of(s, view, is_back, near, back_near_arm))
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    for s in order:
        canvas.alpha_composite(Image.open(root / s / f"{s}_puppet_{view}.png").convert("RGBA"))
    return canvas


# (标题, 视图, 是否背面, 裁切框, 目标文件)
ROWS = [
    ("S 脚 —— 正对镜头，不再左右摊成一条板", "s", False, (100, 176, 156, 217), "sn_feet_compare.png"),
    ("N 脚 —— 同上，正背对镜头", "n", True, (100, 176, 156, 217), "sn_feet_compare.png"),
    ("NW 肩 —— 近臂移到披风前面", "nw", True, (84, 78, 178, 164), "nw_shoulder_compare.png"),
]
CELL = (330, 300)


def tile(im: Image.Image, box, label: str) -> Image.Image:
    bg = Image.new("RGBA", (256, 256), (255, 0, 255, 255))
    bg.alpha_composite(im)
    t = bg.crop(box).resize(CELL, Image.LANCZOS).convert("RGB")
    d = ImageDraw.Draw(t)
    d.rectangle([0, 0, 62, 21], fill=(30, 30, 34))
    d.text((7, 2), label, font=F_TAG, fill=(232, 232, 240))
    return t


def main() -> int:
    build(TMP, old=True)
    new_root = ROOT / "assets" / "parts"
    made = {}
    for title, view, is_back, box, fname in ROWS:
        near_old = "r" if view == "nw" else C.NEAR_SIDE[view]
        before = tile(compose(TMP, view, is_back, near_old, False), box, "before")
        after = tile(compose(new_root, view, is_back, C.NEAR_SIDE[view], True), box, "after")
        made.setdefault(fname, []).append((title, before, after))

    for fname, rows in made.items():
        sheet = Image.new("RGB", (CELL[0] * 2 + 12, CELL[1] * len(rows) + 30 * len(rows)),
                          (30, 30, 34))
        y = 0
        for title, before, after in rows:
            ImageDraw.Draw(sheet).text((6, y + 3), title, font=F_TITLE, fill=(228, 228, 236))
            y += 26
            sheet.paste(before, (0, y))
            sheet.paste(after, (CELL[0] + 12, y))
            y += CELL[1]
        out = ROOT / "docs" / fname
        sheet.save(out)
        print("对照图:", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
