# 染色预览：同一只木头人套不同的分区配色，验证 R/G/B mask 是否各管各的
#
# 用法（必须开窗口，headless 不出图）：
#   godot --path . --script res://tools/tint_preview.gd
# 产物：demo/tint_grid.png
#
# mask 通道约定（tools/gen_joint_art.py::make_mask）：
#   R = 主色（木头/布料/头发）  G = 皮肤  B = 金属（球关节/护手）
# 三行角色的主色相同、皮肤相同，只有金属色不同 —— 肉眼确认金属区独立。

extends SceneTree

## 打包约定：r = hue_shift + 0.5, g = sat_mul, b = val_mul
## 主色统一染成蓝绿色（hue +0.45），三行只差金属
const TINT := Color(0.95, 1.0, 0.9)
const SKIN := Color(0.5, 1.0, 1.0)          # 不偏移 = 原肤色
const METALS := [
	["原色", Color(0.5, 1.0, 1.0)],
	["紫铜", Color(0.62, 0.9, 1.1)],        # hue +0.12，更饱和
	["白银", Color(0.5, 0.0, 1.6)],         # 去饱和 + 提亮
]


func _initialize() -> void:
	_run()


func _run() -> void:
	RenderingServer.set_default_clear_color(Color(0.92, 0.93, 0.96))
	var layer := Node2D.new()
	root.add_child(layer)

	var dolls: Array = []
	for row in METALS.size():
		for col in 2:
			var d := JointDoll.new()
			d.position = Vector2(140.0 + col * 300.0, 170.0 + row * 230.0)
			layer.add_child(d)
			dolls.append([d, row, col])
			d.set_process(false)

	# 等一帧让 _ready 建完树（时序坑见 elbow_calib.gd 顶部注释）
	await process_frame

	for entry in dolls:
		var d: JointDoll = entry[0]
		var row: int = entry[1]
		var col: int = entry[2]
		var vis := CharacterVisual.from_assets()
		vis.tints[&"cape"] = TINT
		# 主色（木头/头发）也染：验证 mask 的 R 区覆盖
		for slot in [&"body", &"arm_l", &"fore_l", &"arm_r", &"fore_r",
				&"leg_l", &"leg_r", &"shin_l", &"shin_r", &"hair_front", &"hair_back"]:
			vis.tints[slot] = TINT
		vis.tints_metal[&"body"] = METALS[row][1]
		vis.tints_metal[&"weapon"] = METALS[row][1]
		vis.tints_metal[&"head"] = METALS[row][1]
		vis.tints_metal[&"arm_l"] = METALS[row][1]
		vis.tints_metal[&"arm_r"] = METALS[row][1]
		vis.tints_metal[&"fore_l"] = METALS[row][1]
		vis.tints_metal[&"fore_r"] = METALS[row][1]
		vis.tints_metal[&"leg_l"] = METALS[row][1]
		vis.tints_metal[&"leg_r"] = METALS[row][1]
		vis.tints_metal[&"shin_l"] = METALS[row][1]
		vis.tints_metal[&"shin_r"] = METALS[row][1]
		d.visual = vis
		d._rebuild_parts()
		d.set_direction(0 if col == 0 else 2)
		d._rot.clear()
		for k in d._joint_nodes.keys():
			d._rot[k] = 0.0
		d._pose_idle()
		d._apply_rot()

		var l := Label.new()
		l.text = "%s  %s" % [METALS[row][0], "正面" if col == 0 else "侧面"]
		l.position = d.position + Vector2(-110.0, -150.0)
		l.add_theme_color_override("font_color", Color(0.1, 0.1, 0.15))
		layer.add_child(l)

	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://demo/tint_grid.png")
	print("saved demo/tint_grid.png")
	quit(0)
