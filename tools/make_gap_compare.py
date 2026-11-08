"""生成 docs/shoulder_compare.png：「肩绑定点」改前 / 改后对照。

改前 = 肩枢轴 104/152（躯干轮廓外）、肩球半径 7
改后 = 肩枢轴 108/148（轮廓内 4px）、肩球半径 8.5

两侧都用同一套 z 表合成整身，品红底 —— 缝一旦存在就是一条刺眼的线。
"""

import sys
import tempfile
import types
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import check_joint_gap as C  # noqa: E402

TMP = Path(tempfile.gettempdir()) / "paperdoll_old_art"   # 别放进项目里，否则会被 Godot 当资源导入
VIEWS = ["s", "sw", "w", "nw", "n"]


def build_old():
    src = (ROOT / "tools" / "gen_joint_art.py").read_text(encoding="utf-8")
    src = src.replace("r=8.5 if not far else 7", "r=7")
    for a, b in [("(108, 108)", "(104, 108)"), ("(102, 130)", "(98, 130)"),
                 ("(148, 108)", "(152, 108)"), ("(154, 130)", "(158, 130)")]:
        src = src.replace(a, b)
    mod = types.ModuleType("old_art")
    exec(compile(src, "old_art", "exec"), mod.__dict__)
    for slot in mod.DRAW:
        (TMP / slot).mkdir(parents=True, exist_ok=True)
        for view, v in mod.VIEWS.items():
            im, d = mod.canvas()
            mod.DRAW[slot](im, d, v)
            im.save(TMP / slot / f"{slot}_puppet_{view}.png")


def compose(root: Path, view: str, is_back: bool):
    slots = [s for s in C.SLOT_Z if (root / s / f"{s}_puppet_{view}.png").exists()]
    order = sorted(slots, key=lambda s: C.slot_z(s, view, is_back))
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    for s in order:
        canvas.alpha_composite(Image.open(root / s / f"{s}_puppet_{view}.png").convert("RGBA"))
    return canvas


def tile(im: Image.Image, label: str):
    bg = Image.new("RGBA", (256, 256), (255, 0, 255, 255))
    bg.alpha_composite(im)
    t = bg.crop((72, 76, 184, 172)).resize((312, 268), Image.LANCZOS).convert("RGB")
    ImageDraw.Draw(t).text((4, 2), label, fill=(40, 20, 40))
    return t


def main() -> int:
    build_old()
    rows = [("s", False), ("sw", False), ("nw", True)]
    W, H = 312 * 2, 268 * len(rows)
    sheet = Image.new("RGB", (W, H), (30, 30, 34))
    for i, (view, is_back) in enumerate(rows):
        before = tile(compose(TMP, view, is_back), f"{view.upper()}  before")
        after = tile(compose(ROOT / "assets" / "parts", view, is_back), f"{view.upper()}  after")
        sheet.paste(before, (0, i * 268))
        sheet.paste(after, (312, i * 268))
    out = ROOT / "docs" / "shoulder_compare.png"
    sheet.save(out)
    print("对照图:", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
