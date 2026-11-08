#!/usr/bin/env python3
"""生成《素材清单》—— 外采/自绘部件都按这份交。

    python tools/asset_spec.py

只做两件事：把**现有素材的真实数据**量出来（包围盒、覆盖率、变体、挂点、z），
再把硬约束写成人话。数据部分自动生成，所以文档不会和美术实际状态脱节：
以后美术改了尺寸，重跑一次，表格跟着变。

产物：docs/素材清单.md
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PARTS = ROOT / "assets" / "parts"
RULES = ROOT / "data" / "layer_rules.json"
OUT = ROOT / "docs" / "素材清单.md"

VIEWS = ["s", "sw", "w", "nw", "n"]
VIEW_CN = {"s": "正", "sw": "西南3/4", "w": "侧", "nw": "西北3/4", "n": "背"}
LABEL = {
    "body": "躯干", "head": "头", "face": "表情", "hair_front": "刘海",
    "hair_back": "后发", "cape": "披风", "arm_l": "左上臂", "arm_r": "右上臂",
    "fore_l": "左小臂", "fore_r": "右小臂", "leg_l": "左大腿", "leg_r": "右大腿",
    "shin_l": "左小腿", "shin_r": "右小腿", "weapon": "武器", "hat": "帽子",
    "clothes": "外衣", "ear": "耳饰", "tail": "尾巴", "wing": "翅膀",
    "shoulder": "肩甲", "glove_l": "左手套", "glove_r": "右手套",
    "shoes_l": "左鞋", "shoes_r": "右鞋", "offhand": "副手", "summon": "召唤物",
}
# 挂点合理性：这些槽位的可见像素必须够到自己的关节，否则一转就飞出身体
MUST_REACH_JOINT = {"arm_l", "arm_r", "fore_l", "fore_r", "leg_l", "leg_r",
                    "shin_l", "shin_r", "body", "head", "face", "hair_front",
                    "hair_back", "hat", "cape", "clothes"}


def scan() -> dict:
    """-> {slot: {variant: {view: path}}}"""
    art: dict[str, dict[str, dict[str, Path]]] = {}
    for d in sorted(p for p in PARTS.iterdir() if p.is_dir()):
        slot = d.name
        for f in sorted(d.glob("*.png")):
            if "_puppet_" not in f.name:
                continue
            stem = f.name.split("_puppet_")[0]
            view = f.name.rsplit("_", 1)[1].removesuffix(".png")
            if view not in VIEWS:
                continue
            var = stem[len(slot) + 1:] if stem != slot else "default"
            art.setdefault(slot, {}).setdefault(var, {})[view] = f
    return art


def bbox_cov(p: Path):
    a = np.asarray(Image.open(p).convert("RGBA"))
    m = a[:, :, 3] > 8
    if not m.any():
        return None, 0.0
    ys, xs = np.nonzero(m)
    return (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())), float(m.mean())


def main() -> int:
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    rig = rules["_rig"]
    z = rules["z"]
    joints = {j["name"]: j["pos"] for j in rig["joints"]}
    slot_joint = rig["slot_joint"]
    art = scan()

    rows = []
    for slot in sorted(art, key=lambda s: (slot_joint.get(s, ""), s)):
        variants = art[slot]
        ref = variants.get("default") or variants[sorted(variants)[0]]
        bb, cov = bbox_cov(ref["s"]) if "s" in ref else (None, 0.0)
        jn = slot_joint.get(slot, "?")
        jp = joints.get(jn)
        rows.append({
            "slot": slot, "cn": LABEL.get(slot, slot), "joint": jn,
            "jp": jp, "z_s": z.get("s", {}).get(slot),
            "z_n": z.get("n", {}).get(slot),
            "vars": list(variants), "bb": bb, "cov": cov,
        })

    lines: list[str] = []
    A = lines.append

    A("# 素材清单 · 部件交付规范")
    A("")
    A("> 这份文档由 `python tools/asset_spec.py` 生成，尺寸/覆盖率/变体都是从")
    A("> `assets/parts/` 实测出来的。美术改完图重跑一次，表格自动跟着变。")
    A("")
    A("## 0 · 一句话版本")
    A("")
    A("**256×256 透明 PNG，地板线在 y=216，五个视图各一张，命名")
    A("`{槽位}_{变体}_puppet_{视图}.png`，染色遮罩同命名把 `puppet` 换成 `mask`。**")
    A("丢进 `assets/parts/{槽位}/`，跑 `tools/import_part.py`（可省）→")
    A("`tools/check_part.py` 验收 → `python tools/gen_character_designer.py` 上货架。")
    A("")
    A("## 1 · 坐标系统（所有部件共用一张画布）")
    A("")
    A("| 项 | 值 | 说明 |")
    A("|---|---|---|")
    A("| 画布 | 256 × 256 RGBA | 不是 512，不是任意尺寸 |")
    A("| 地面线 | y = 216 | 脚底踩在这条线上；上下留 40px 给帽子/披风 |")
    A("| 竖直中轴 | x = 128 | 角色始终居中，不做左右偏移补偿 |")
    A("| 左右 | 屏幕左 = `l`，屏幕右 = `r` | 命名里的 l/r 说的是**屏幕**方向 |")
    A("| 缩放 | 1 单位 = 1 像素 | 不要给整张图做整体缩放，直接按像素画 |")
    A("")
    A("### 关节坐标（枢轴，画的时候要对得上）")
    A("")
    A("| 关节 | x, y | 谁挂在这 |")
    A("|---|---|---|")
    holders: dict[str, list[str]] = {}
    for s, j in slot_joint.items():
        if s in art:
            holders.setdefault(j, []).append(LABEL.get(s, s))
    for jn, jp in joints.items():
        if jn in holders:
            A("| `%s` | %.0f, %.0f | %s |" % (jn, jp[0], jp[1], "、".join(holders[jn])))
    A("")
    A("## 2 · 五个视图，八个朝向")
    A("")
    A("游戏里只存 5 张图，八个朝向靠**镜像**补出来：")
    A("")
    A("| 朝向 | 0 S | 1 SW | 2 W | 3 NW | 4 N | 5 NE | 6 E | 7 SE |")
    A("|---|---|---|---|---|---|---|---|---|")
    A("| 用哪张 | s | sw | w | nw | n | nw 镜像 | w 镜像 | sw 镜像 |")
    A("")
    A("两个后果，画之前就要想好：")
    A("")
    A("1. **左右不对称的装饰会翻**。单边耳环、歪戴的帽子、左肩的肩甲，")
    A("   在 NE/E/SE 会跑到另一边 —— 要么接受，要么画成对称的。")
    A("2. **暗面朝向必须和 z 表的远近侧同侧**。sw/w 的暗面在屏幕右、nw 的在屏幕左，")
    A("   背面视图转过去了。`tools/check_parts.py` 会用像素把这条钉死，")
    A("   反了会出现「压暗的、变窄的那条胳膊压在身体前面」这种读不通的画面。")
    A("")
    A("## 3 · 槽位表（实测）")
    A("")
    A("参考包围盒 = 现有默认变体在正视图下的可见范围，用来判断你画的大小/位置对不对。")
    A("新部件不必完全一致，但**同一槽位跨变体要尽量接近**，否则换装会明显跳位。")
    A("")
    A("| 槽位 | 中文 | 挂点 | z 正/背 | 现有变体 | 参考包围盒 (x0,y0)-(x1,y1) | 覆盖率 |")
    A("|---|---|---|---|---|---|---|")
    for r in rows:
        bb = r["bb"]
        bbs = "(%d,%d)-(%d,%d)" % bb if bb else "—"
        zp = "%s / %s" % (r["z_s"], r["z_n"])
        A("| `%s` | %s | `%s` | %s | %s | %s | %.1f%% |" % (
            r["slot"], r["cn"], r["joint"], zp,
            "、".join(r["vars"]), bbs, r["cov"] * 100))
    A("")
    A("z 值含义：数字大的画在上面。躯干 10，近侧上臂 13，披风 2（在后面），")
    A("表情/刘海 32~34（压住脸），帽子 36，武器正常 50 —— 但**背面朝向**")
    A("（NW/N/NE）武器要降到 21 藏进披风后面，这条在 `joint_doll.gd` 的 `Z_ON_BACK` 里。")
    A("")
    A("## 4 · 画法约束")
    A("")
    A("| 要求 | 原因 |")
    A("|---|---|")
    A("| alpha 只有 0 或 255，边缘不羽化 | 遮罩和描边都靠硬边判定，半透明会串色 |")
    A("| 不要画投影 / 背景 / 环境光 | 影子由引擎按地面线自己画 |")
    A("| 每种材质至少 3 档明度（主色 / 暗部 / 高光） | 单色填充染色后是一块死色板 |")
    A("| 描边用统一深色（现为 `#382212`） | 描边不参与染色，靠它保持轮廓 |")
    A("| 关节处多画 2~3px 重叠 | 转起来才不会露缝（`tools/check_joint_gap.py` 查这个） |")
    A("| 部件不要贴到画布边缘 | 贴边说明尺寸超了，转视角会被裁 |")
    A("| 同一槽位的所有变体，挂点位置一致 | 换装时部件不能跳位 |")
    A("")
    A("## 5 · 染色遮罩（决定这件东西能不能改色）")
    A("")
    A("遮罩是同样尺寸的 PNG，用纯色标出「这块像素吃什么颜色」：")
    A("")
    A("| 像素值 | 含义 |")
    A("|---|---|")
    A("| `(255, 0, 0)` 纯红 | 主色区：跟着木头/布料/头发色板走 |")
    A("| `(255, 255, 0)` 黄 | 皮肤区：跟着肤色走 |")
    A("| `(255, 0, 255)` 品红 | 金属区：跟着金属色走 |")
    A("| 全透明 | 不染色，保持美术原色（描边就该在这里） |")
    A("")
    A("**R 通道是总开关**：shader 最后一步是 `mix(base, c, mask.r)`，")
    A("R=0 的像素不管 G/B 写什么都没用 —— 金属区曾经写成 `(0,0,255)`，")
    A("结果金属调色被整个丢掉，验证图三行长得一模一样。所以遮罩内可见像素 R 必须 255。")
    A("")
    A("两条做法，选一条：")
    A("")
    A("- **A. 交给工具**：`import_part.py --metal-colors ...` 按色距自动分类。")
    A("  金属/皮肤之外全部算主色；想让描边免染就手绘遮罩（自动判描边容易误伤深色布料）。")
    A("- **B. 手绘遮罩**：另存一张同尺寸图，用上面三种纯色刷出区域。最准，")
    A("  适合金属件、皮肤露出的部件。")
    A("")
    A("## 6 · 进场流程")
    A("")
    A("```bash")
    A("# 1) 收图：自动裁到画布、对齐挂点、生成遮罩（--pivot 是图上要对到关节的那个点）")
    A("python tools/import_part.py --art 我的长袍.png --slot body --variant robe \\")
    A("       --view s --pivot 300,180 --scale 1.0")
    A("")
    A("# 2) 验收：五个视图齐不齐、尺寸/挂点/遮罩/基色对不对")
    A("python tools/check_part.py --slot body --variant robe")
    A("")
    A("# 3) 上货架：重打包角色设计器，页面里立刻多一套")
    A("python tools/gen_character_designer.py")
    A("```")
    A("")
    A("五张视图都要跑一次第 1 步（`--view s/sw/w/nw/n`）。")
    A("")
    A("## 7 · 交付前逐项打勾")
    A("")
    A("```")
    A("[ ] 5 个视图齐全：s / sw / w / nw / n")
    A("[ ] 每张 256×256，RGBA，背景全透明")
    A("[ ] 脚底落在 y=216，中轴 x=128，没有任何一边被裁")
    A("[ ] 挂点和骨架对得上（表 3 的挂点列）")
    A("[ ] 同一槽位所有变体的挂点、整体大小一致")
    A("[ ] 每种材质有 3 档明度，不是单色平涂")
    A("[ ] 暗面方向和现有素材同侧（跑 check_parts.py 不报错）")
    A("[ ] 遮罩齐全、R=255、描边没被标成可染")
    A("[ ] 关节处有 2~3px 重叠，不露缝")
    A("[ ] check_part.py 通过")
    A("```")
    A("")
    A("## 8 · 常见退回原因")
    A("")
    A("1. **尺寸不是 256，或四个视图尺寸不一致** —— 统一画布是整套对齐的前提。")
    A("2. **挂点漂移** —— 头饰按包围盒居中贴，结果每个变体帽子位移不一样，换装就跳。")
    A("3. **贴边** —— 边长 256 或 bbox 到 0/255，转视角直接被裁。")
    A("4. **半透明边缘** —— 遮罩判定失准，染色后一圈脏边。")
    A("5. **单色平涂** —— 染色能上色，但看起来像贴纸。")
    A("6. **遮罩把描边也标了** —— 整圈轮廓跟着变色，暗棕被拉成亮色，边缘糊掉。")
    A("7. **遮罩 R=0** —— 看着写了颜色，实际一点没染（最隐蔽的一条）。")
    A("8. **暗面朝反** —— 3/4 视图里远近侧和 z 表打架。")
    A("9. **只交正视图** —— 一转身发现侧面是空的。")
    A("10. **不对称装饰** —— 镜像视图里跑到另一边，除非你本来就要这个效果。")
    A("")
    A("## 9 · 想加一个全新槽位（不是新变体）")
    A("")
    A("新变体只要放图；**新槽位**要改四处，漏一处就会出现「图在但游戏里不显示」：")
    A("")
    A("| 步骤 | 文件 | 改什么 |")
    A("|---|---|---|")
    A("| 1 | `data/layer_rules.json` → `z` | 五个视图各给一个 z 值 |")
    A("| 2 | `data/layer_rules.json` → `_rig.slot_joint` | 槽位挂哪个关节 |")
    A("| 3 | `core/character/joint_doll.gd` | 若背面要换层，进 `Z_ON_BACK` |")
    A("| 4 | `core/data/character_visual.gd` | 要默认穿戴就进 `DEFAULT_SLOTS`；")
    A("   |  | 进 `tools/gen_character_designer.py` 的 `GROUPS` 才能被色板染 |")
    A("")
    A("改完跑：`godot --headless --path . --script tools/dump_layers.gd` 刷新 `_rig`，")
    A("再 `python tools/gen_character_designer.py`。")
    A("")
    A("---")
    A("")
    A("## 附 · 对齐参考图")
    A("")
    A("`docs/templates/guide_{槽位}.png` —— 每个槽位一张，五个视图并排，")
    A("标了地面线、中轴、挂点、现有包围盒。可以当参考图层垫在下面画，")
    A("也可以直接喂给图生图当构图约束。")
    A("")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("写出 %s（%d 个槽位）" % (OUT.relative_to(ROOT), len(rows)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
