# 演示：帧表驱动的纸娃娃（运行时与参考视频同一套算法）
# 4 台角色共用同一批图集，只换色参数不同 —— 对应视频里"16 个角色全用同一个木头人拼出来"
#
# 操作：方向键/WASD 换朝向，数字键 1-8 直接指定方向，J 攻击，K 受击
#      --shot 参数启动则截图后退出

extends Node2D

const DIR_NAMES := ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]

var dolls: Array[FrameDoll] = []
var hud: Label
var t := 0.0
var shot_mode := false


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.90, 0.91, 0.94))
	shot_mode = "--shot" in OS.get_cmdline_user_args()

	var palette := [
		{"hue": 0.0, "sat": 1.0, "val": 1.0},
		{"hue": 0.42, "sat": 1.0, "val": 1.05},
		{"hue": -0.12, "sat": 1.15, "val": 0.95},
		{"hue": 0.0, "sat": 0.1, "val": 1.0},
	]
	var dirs := [0, 2, 6, 4]
	var xs := [190, 480, 770, 1060]

	for i in 4:
		var d := FrameDoll.new()
		d.name = "Doll%d" % i
		d.position = Vector2(xs[i], 520)
		add_child(d)
		d.visual = _make_visual(palette[i])
		d.set_direction(dirs[i])
		d.play(&"walk")
		dolls.append(d)

	hud = Label.new()
	hud.position = Vector2(24, 16)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_color", Color(0.15, 0.15, 0.2))
	add_child(hud)

	if shot_mode:
		_shot_later()


func _make_visual(p: Dictionary) -> CharacterVisual:
	var vis := CharacterVisual.new()
	vis.skin_tint = Color(0.5, 1.0, 1.0)
	var tinted := [&"body", &"hat", &"leg_l", &"leg_r", &"shin_l", &"shin_r"]
	for entry in PartCatalog.DEMO:
		var slot: StringName = entry.slot
		var stem: String = entry.stem
		var part := FramePart.new()
		part.slot = slot
		part.id = StringName(stem)
		for a in ["idle", "walk", "attack", "hurt"]:
			var path := PartCatalog.baked_path(slot, stem, a)
			if ResourceLoader.exists(path):
				part.sheets[StringName(a)] = load(path)
		vis.equip(slot, part)
		if slot in tinted:
			vis.tints[slot] = Color(p.hue + 0.5, p.sat, p.val)
	return vis


func _process(delta: float) -> void:
	t += delta
	_handle_input()
	var d0 := dolls[0]
	hud.text = "方向 %d (%s)   动作 %s   帧 %d\n方向键/WASD 换朝向   1-8 指定方向   J 攻击   K 受击" % [
		d0.direction, DIR_NAMES[d0.direction], d0.action, d0.current_frame()]


func _handle_input() -> void:
	var v := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if v.length_squared() > 0.01:
		for d in dolls:
			d.face_vector(v)
	for k in 8:
		if Input.is_key_pressed(KEY_1 + k):
			for d in dolls:
				d.set_direction(k)
	if Input.is_key_pressed(KEY_J):
		for d in dolls:
			d.play(&"attack")
	if Input.is_key_pressed(KEY_K):
		for d in dolls:
			d.play(&"hurt")


func _shot_later() -> void:
	await get_tree().create_timer(0.9).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://demo/shot_frames.png")
	print("screenshot saved")
	get_tree().quit()
