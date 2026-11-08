"""生成文档用的八向对照图（从 assets 直接合成，不含 HUD）。

    docs/turn_8dir.png    8 个方向整身（4 列 × 2 行）
    docs/faces_8dir.png   8 个方向头部（1 行 8 列）

为什么不用 `--shot` 截图裁：引擎截图上有 HUD 文字和环形标签，按环坐标裁出来的
格子里会带上邻近的标签（"NW"、"8 个方向"…）。静态图要的是干净的对照，
所以这里走 `check_joint_gap.composite()` —— 它和运行时用同一套 z 表，只是不摆姿势。

用法：python tools/make_doc_sheets.py
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import check_joint_gap as C  # noqa: E402

NAMES = C.DIR_NAMES
BG = (236, 239, 246)
FONT_CANDIDATES = [r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf",
                   "/System/Library/Fonts/PingFang.ttc"]


def _font(size):
    for p in FONT_CANDIDATES:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


def render(d: int, skip=()) -> Image.Image:
    vi, mir = C.DIR_TO_VIEW[d]
    canvas, _ = C.composite(C.VIEW_NAMES[vi], d in C.BACK_DIRS, mir, skip)
    bg = Image.new("RGBA", (256, 256), BG + (255,))
    bg.alpha_composite(canvas)
    return bg.convert("RGB")


def main() -> int:
    font = _font(22)

    CW, CH = 300, 540
    body = Image.new("RGB", (CW * 4, (CH + 30) * 2), BG)
    for d in range(8):
        cell = render(d).crop((88, 46, 168, 218)).resize((CW, CH), Image.LANCZOS)
        ox, oy = (d % 4) * CW, (d // 4) * (CH + 30) + 30
        body.paste(cell, (ox, oy))
        ImageDraw.Draw(body).text((ox + 8, oy - 27), NAMES[d], font=font, fill=(30, 34, 44))
    body.save(ROOT / "docs" / "turn_8dir.png")

    HW, HH = 240, 230
    heads = Image.new("RGB", (HW * 8, HH + 30), BG)
    for d in range(8):
        # 脸部特写排掉武器：剑 z=50，剑身正好压在脸骨右缘上
        cell = render(d, skip=("weapon",)).crop((103, 46, 153, 100)).resize((HW, HH), Image.LANCZOS)
        heads.paste(cell, (d * HW, 30))
        ImageDraw.Draw(heads).text((d * HW + 8, 2), NAMES[d], font=font, fill=(30, 34, 44))
    heads.save(ROOT / "docs" / "faces_8dir.png")

    print("docs/turn_8dir.png", body.size)
    print("docs/faces_8dir.png", heads.size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
