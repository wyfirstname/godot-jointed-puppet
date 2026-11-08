#!/usr/bin/env python3
"""把素材和当前 z 表内联进 HTML，生成单文件设计器。

    python tools/gen_layer_designer.py

产物 tools/layer_designer.html 是**一次性快照**：双击就能开，不依赖本地服务器、
不依赖同目录、不发网络请求（file:// 下 canvas 会被 CORS 拦，所以不用 canvas，
只用绝对定位的 <img> + CSS transform）。

什么时候要重跑：
  · 改了美术（assets/parts/**）
  · 改了骨架 / 步态参数（JOINTS、PROFILE、NEAR_SIDE）→ 先跑 dump_layers.gd 刷新 _rig
  · 想换一个起始 z 表
"""

from __future__ import annotations

import base64
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
RULES = ROOT / "data" / "layer_rules.json"
TPL = ROOT / "tools" / "layer_designer.tpl.html"
OUT = ROOT / "tools" / "layer_designer.html"


def data_uri(p: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode("ascii")


def overlap_table(slots, views) -> dict:
    """每个视图里，两两部件「不透明像素真正叠在一起」的像素数。

    这是设计器最需要的一个数：z 序只在两部件重叠的地方才看得出来。
    正侧面（W）躯干和披风投影上根本不碰（实测 0），改那一格的 z 不会有
    任何视觉变化 —— 不是没生效，是几何上无从体现。把这个数摆在格角上，
    用户一眼就能分清「我改错了」和「这一格本来就看不出」。

    打包时算好内联进去，浏览器端零成本（也避开 file:// 下 canvas 的 CORS 风险）。
    """
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        print("跳过重叠矩阵（没装 numpy/Pillow）")
        return {}

    out: dict[str, list] = {}
    for v in views:
        masks = {}
        for s in slots:
            p = PARTS / s / f"{s}_puppet_{v}.png"
            if not p.exists():
                continue
            a = np.array(Image.open(p).convert("RGBA"))[:, :, 3]
            masks[s] = a > 8          # 和 check_parts.py 用同一个阈值
        pairs = []
        for a, b in itertools.combinations(sorted(masks), 2):
            n = int((masks[a] & masks[b]).sum())
            if n:
                pairs.append([a, b, n])
        out[v] = pairs
    return out


def main() -> int:
    if not RULES.exists():
        print("缺 %s —— 先跑 godot --headless --path . --script tools/dump_layers.gd" % RULES)
        return 1
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    rig = rules.get("_rig")
    if not rig:
        print("layer_rules.json 里没有 _rig，设计器无法复现姿态。重跑 dump_layers.gd")
        return 1

    views = rig["views"]
    assets: dict[str, dict[str, str]] = {}
    for slot_dir in sorted(PARTS.iterdir()):
        if not slot_dir.is_dir():
            continue
        per_view = {}
        for v in views:
            p = slot_dir / f"{slot_dir.name}_puppet_{v}.png"
            if p.exists():
                per_view[v] = data_uri(p)
        if per_view:
            assets[slot_dir.name] = per_view

    # 只投喂设计器需要的字段，别把 note 之类的东西塞进去
    slim = {"z": rules["z"], "swing": rules.get("swing", []), "_rig": rig}

    ov = overlap_table(list(assets.keys()), views)

    html = TPL.read_text(encoding="utf-8")
    for key, obj in (("/*__ASSETS__*/{}", assets), ("/*__RULES__*/{}", slim),
                     ("/*__OVERLAP__*/{}", ov)):
        if key not in html:
            print("模板里找不到占位符 %s" % key)
            return 1
        html = html.replace(key, json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
    html = html.replace("/*__RIG__*/{}", json.dumps(rig, ensure_ascii=False, separators=(",", ":")))

    OUT.write_text(html, encoding="utf-8")
    n_img = sum(len(v) for v in assets.values())
    print("写出 %s：%d 个槽位 / %d 张图 / %.0f KB" % (
        OUT.relative_to(ROOT), len(assets), n_img, OUT.stat().st_size / 1024))
    for v in views:
        print("   %s 视图重叠对 %d 组，合计 %d px" % (
            v.upper(), len(ov.get(v, [])), sum(p[2] for p in ov.get(v, []))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
