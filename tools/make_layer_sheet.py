#!/usr/bin/env python3
"""出 docs/layers_8dir.png：8 个方向 × 2 个摆动相位，用**引擎真实渲染**拼图。

    python tools/make_layer_sheet.py

为什么要引擎渲染而不是离线合成：这张图要说明的正是"同一块部件在不同相位该在身体哪一侧"，
而摆臂是 JointDoll 按正弦实时算出来的 —— 离线合成器没有关节旋转，
拼出来的图会静悄悄地和游戏不一致。
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
GODOT = Path(r"F:/Godot/Godot_v4.7.2-stable_win64_console.exe")
DIRS = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
PHASES = [(0.25, "相位 0.25　近臂前摆"), (0.75, "相位 0.75　近臂后摆")]


def _font(size: int):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf",
              "/System/Library/Fonts/PingFang.ttc",
              "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"):
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


F_T, F_S = _font(18), _font(15)


def shoot(ph: float) -> Image.Image:
    """跑一次引擎的姿势表模式，返回那一帧"""
    if not GODOT.exists():
        sys.exit("找不到 Godot：%s（改脚本里的 GODOT 路径）" % GODOT)
    subprocess.run([str(GODOT), "--path", str(ROOT), "--", "--phase=%s" % ph],
                   cwd=ROOT, check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    out = ROOT / "demo" / ("pose_%03d.png" % round(ph * 100))
    if not out.exists():
        sys.exit("引擎没产出 %s" % out)
    return Image.open(out).convert("RGB")


def main() -> None:
    shots = [(shoot(ph), tag) for ph, tag in PHASES]
    W, H = 118, 214          # 单格裁切尺寸（画布像素）
    S = 1.7                  # 放大倍数
    cw, ch = int(W * S), int(H * S)
    pad, top = 10, 30
    sheet = Image.new("RGB", (cw * 8 + pad * 2, (ch + top) * len(shots) + pad),
                      (247, 248, 251))
    d = ImageDraw.Draw(sheet)
    for r, (img, tag) in enumerate(shots):
        y0 = pad + r * (ch + top)
        d.text((pad, y0), tag, font=F_T, fill=(40, 44, 54))
        for i in range(8):
            px = 150 + (i % 4) * 300
            py = 290 + (i // 4) * 350
            c = img.crop((px - 56, py - 196, px + 56, py + 18)).resize((cw, ch), Image.LANCZOS)
            sheet.paste(c, (pad + i * cw, y0 + top))
            d.text((pad + i * cw + 4, y0 + top + 2), DIRS[i], font=F_S, fill=(180, 40, 40))
    out = ROOT / "docs" / "layers_8dir.png"
    sheet.save(out)
    print("写出", out.relative_to(ROOT), sheet.size)


if __name__ == "__main__":
    main()
