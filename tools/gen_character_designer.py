#!/usr/bin/env python3
"""把整套美术 + 骨架 + z 表打进一个单文件角色设计器。

    python tools/gen_character_designer.py

产物 tools/character_designer.html：双击就开，不需要服务器、不发请求。
（所有图都以 data URI 内联 —— file:// 下 canvas 读跨目录图片会被判污染，
 getImageData 直接抛错，而分区染色全靠读像素，所以必须内联。）

变体是自动发现的：目录里出现 `{槽位}_{变体名}_puppet_{视图}.png` 就多一个可选部件，
重新跑一次脚本，页面里立刻多一张缩略图。加服装不用改这个脚本。

什么时候重跑：
  · 改了/新增了素材（assets/parts/**）
  · 改了骨架、步态、z 表 → 先跑 dump_layers.gd 刷新 _rig，再跑本脚本
"""

from __future__ import annotations

import base64
import json
import re
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
RULES = ROOT / "data" / "layer_rules.json"
DOLL = ROOT / "core" / "character" / "joint_doll.gd"
TPL = ROOT / "tools" / "character_designer.tpl.html"
OUT = ROOT / "tools" / "character_designer.html"

VIEWS = ["s", "sw", "w", "nw", "n"]

# 分区染色的 5 个「色板」：同一块色板下面可以挂多个槽位。
# 皮肤/金属是全局通道（所有槽位都吃 mask 的 G/B），这里留空表示「按通道全局处理」。
#
# 服装变体用「槽位:变体」的细键：body 槽位同时装着木头身（wood）和袍子/皮甲（cloth），
# 按槽位分组的话袍子会被木头色滑杆染。页面里先查细键、查不到再退回槽位键。
GROUPS = {
    "wood":  ["body", "head", "arm_l", "arm_r", "fore_l", "fore_r",
              "leg_l", "leg_r", "shin_l", "shin_r"],
    "cloth": ["cape",
              "body:robe", "body:leather",
              "arm_l:robe", "arm_r:robe", "fore_l:robe", "fore_r:robe",
              "arm_l:leather", "arm_r:leather",
              "fore_l:leather", "fore_r:leather",
              "shin_l:boot", "shin_r:boot",
              "hat:hood", "hat:wizard"],
    "hair":  ["hair_front", "hair_back"],
}


def data_uri(p: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode("ascii")


def parse_name(fname: str, slot: str, kind: str):
    """两种命名都要认：

    `body_puppet_s.png`        -> ('default', 's')      无变体
    `face_smile_puppet_s.png`  -> ('smile',   's')      有变体

    不能用一个正则把变体段写成 `(.+)`：无变体时 `_puppet_` 前面没有东西可捕，
    整条就匹配不上 —— 第一版这么写，结果只认出了 face，其余 14 个槽位全丢。
    """
    s = re.escape(slot)
    m = re.match(r"^%s_%s_([a-z]+)\.png$" % (s, kind), fname)
    if m and m.group(1) in VIEWS:
        return "default", m.group(1)
    m = re.match(r"^%s_(.+)_%s_([a-z]+)\.png$" % (s, kind), fname)
    if m and m.group(2) in VIEWS:
        return m.group(1), m.group(2)
    return None


def scan() -> tuple[dict, dict]:
    """-> ({slot: {variant: {view: path}}}, {slot: {variant: {view: maskpath}}})"""
    art: dict[str, dict[str, dict[str, Path]]] = {}
    msk: dict[str, dict[str, dict[str, Path]]] = {}
    for d in sorted(p for p in PARTS.iterdir() if p.is_dir()):
        slot = d.name
        for f in sorted(d.iterdir()):
            if not f.name.endswith(".png"):
                continue
            r = parse_name(f.name, slot, "puppet")
            if r:
                art.setdefault(slot, {}).setdefault(r[0], {})[r[1]] = f
                continue
            r = parse_name(f.name, slot, "mask")
            if r:
                msk.setdefault(slot, {}).setdefault(r[0], {})[r[1]] = f
    return art, msk


def region_hsv(img: Image.Image, mask: Image.Image, channel: int):
    """某个遮罩通道覆盖像素的平均色 -> HSV。

    channel: 0=R 主色区 / 1=G 皮肤区 / 2=B 金属区。

    mask 的编码是**包含式**的（R 是总开关，这是 shader 门控修复的约定）：
        主色 = (255,0,0)   皮肤 = (255,255,0)   金属 = (255,0,255)
    所以三个通道的判据各不相同，不能套一个「其他通道全 <128」的模板 ——
    那样皮肤和金属区会被清空（它们自己就带着 R=255）：
        主色 = R 且 !G 且 !B；皮肤 = G 且 !B；金属 = B 且 !G。
    只按 R>127 统计主色也不行：金属/皮肤像素会混进来，
    尖帽的金箍一混，基色从蓝紫变红紫，染出来永远对不上色板。
    """
    a = np.asarray(img.convert("RGBA")).astype(float)
    mk = np.asarray(mask.convert("RGBA"))
    if channel == 0:
        m = (mk[:, :, 0] > 127) & (mk[:, :, 1] < 128) & (mk[:, :, 2] < 128)
    elif channel == 1:
        m = (mk[:, :, 1] > 127) & (mk[:, :, 2] < 128)
    else:
        m = (mk[:, :, 2] > 127) & (mk[:, :, 1] < 128)
    m &= a[:, :, 3] > 8
    if not m.any():
        return None
    rgb = a[:, :, :3][m].mean(axis=0) / 255.0
    r, g, b = rgb
    mx, mn = max(rgb), min(rgb)
    d = mx - mn
    h = 0.0
    if d > 1e-6:
        if mx == r:
            h = ((g - b) / d) % 6
        elif mx == g:
            h = (b - r) / d + 2
        else:
            h = (r - g) / d + 4
        h /= 6.0
    return [round(h, 4), round(d / mx if mx > 1e-6 else 0.0, 4), round(mx, 4)]


def measure_base(art, msk):
    """每个槽位 × 三个通道的基色（用 s 视图量，正面最完整）"""
    base: dict[str, dict] = {}
    for slot, variants in art.items():
        for var, views in variants.items():
            key = slot if var == "default" else f"{slot}_{var}"
            if "s" not in views:
                continue
            mp = (msk.get(slot, {}).get(var) or {}).get("s")
            if not mp:
                continue
            img, mask = Image.open(views["s"]), Image.open(mp)
            rec = {}
            for ch, name in ((0, "r"), (1, "g"), (2, "b")):
                hv = region_hsv(img, mask, ch)
                if hv:
                    rec[name] = hv
            if rec:
                base[key] = rec
    return base


def read_elbow_rest() -> float:
    """肘部常驻底弯：从 joint_doll.gd 读，避免页面和游戏各写一个数"""
    try:
        txt = DOLL.read_text(encoding="utf-8")
        m = re.search(r"const\s+ELBOW_REST_DEG\s*:=\s*([\d.]+)", txt)
        if m:
            return float(m.group(1))
    except OSError:
        pass
    return 20.0


def main() -> int:
    if not RULES.exists():
        print("缺 %s —— 先跑 godot --headless --path . --script tools/dump_layers.gd" % RULES)
        return 1
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    rig = rules.get("_rig")
    if not rig:
        print("layer_rules.json 里没有 _rig，页面无法复现姿态。重跑 dump_layers.gd")
        return 1

    art, msk = scan()
    if not art:
        print("assets/parts 下没找到贴图，先跑 python tools/gen_joint_art.py")
        return 1

    assets = {slot: {var: {v: data_uri(p) for v, p in views.items()}
                     for var, views in variants.items()}
              for slot, variants in art.items()}
    masks = {slot: {var: {v: data_uri(p) for v, p in views.items()}
                    for var, views in variants.items()}
             for slot, variants in msk.items()}
    base = measure_base(art, msk)

    data = {
        "rig": rig,
        "z": rules["z"],
        "assets": assets,
        "masks": masks,
        "base": base,
        "groups": GROUPS,
        "elbow_rest": read_elbow_rest(),
    }

    html = TPL.read_text(encoding="utf-8")
    ph = "/*__DATA__*/{}"
    if ph not in html:
        print("模板里找不到占位符 %s" % ph)
        return 1
    html = html.replace(ph, json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    OUT.write_text(html, encoding="utf-8")

    n_var = sum(len(v) for v in assets.values())
    n_img = sum(len(views) for v in assets.values() for views in v.values())
    n_msk = sum(len(views) for v in masks.values() for views in v.values())
    print("写出 %s" % OUT.relative_to(ROOT))
    print("  %d 槽位 / %d 套变体 / %d 张贴图 / %d 张遮罩 / %.0f KB"
          % (len(assets), n_var, n_img, n_msk, OUT.stat().st_size / 1024))
    multi = {s: list(v) for s, v in assets.items() if len(v) > 1}
    print("  多变体槽位：%s" % (multi if multi else "无"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
