# 肘部符号校准图：同一姿势下把肘拧到 -40 / -20 / 0 / +20 / +40，肉眼看哪边才是「朝身前」
#
# 用法（必须开窗口，headless 不出图）：
#   godot --path . --script res://tools/elbow_calib.gd
# 产物：demo/elbow_grid.png
#
# 为什么要把符号画出来：肘的旋转符号、视图朝向、镜像三者叠在一起，
# 靠读矩阵推容易推反（本项目已经推错过两次）。摆一排 ±40° 的对照，
# 「手在哪一侧」一秒钟就能看出来，比公式可靠。
#
# 时序坑：_initialize 阶段 SceneTree 的 root 还没进树，add_child 不会触发
# _ready，_joint_nodes 是空的 —— 这时改姿势会被静默丢掉（键塞进去也没人读）。
# 所以必须先 add_child、等一帧让 _ready 建完树，再拧关节。

extends SceneTree

const ANGLES := [-40.0, -20.0, 0.0, 20.0, 40.0]
const VIEWS := [[2, "W"], [1, "SW"], [0, "S"]]

var dolls: Array = []


func _initialize() -> void:
	_run()


func _run() -> void:
	RenderingServer.set_default_clear_color(Color(0.92, 0.93, 0.96))
	var layer := Node2D.new()
	root.add_child(layer)

	for row in VIEWS.size():
		var view: int = VIEWS[row][0]
		for col in ANGLES.size():
			var d := JointDoll.new()
			d.position = Vector2(80.0 + col * 260.0, 150.0 + row * 280.0)
			d.scale = Vector2(0.95, 0.95)
			layer.add_child(d)
			dolls.append([d, row, col])
			d.set_process(false)      # 别让 _process 把姿势覆盖回去

	var vis := CharacterVisual.from_assets()
	for entry in dolls:
		(entry[0] as JointDoll).visual = vis

	# 等一帧：让所有 _ready 跑完（_build_tree / _rebuild_parts）
	await process_frame

	for entry in dolls:
		var d: JointDoll = entry[0]
		var row: int = entry[1]
		var col: int = entry[2]
		d.set_direction(VIEWS[row][0])
		# 只拧肘，肩保持 0：干净地看「前臂相对上臂往哪折」
		d._rot.clear()
		for k in d._joint_nodes.keys():
			d._rot[k] = 0.0
		d._rot["elbow_l"] = deg_to_rad(ANGLES[col])
		d._rot["elbow_r"] = deg_to_rad(ANGLES[col])
		d._apply_rot()

		var l := Label.new()
		l.text = "%s  肘 %+.0f°" % [VIEWS[row][1], ANGLES[col]]
		l.position = d.position + Vector2(-110.0, -135.0)
		l.add_theme_color_override("font_color", Color(0.1, 0.1, 0.15))
		layer.add_child(l)

	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://demo/elbow_grid.png")
	print("saved demo/elbow_grid.png")
	quit(0)
