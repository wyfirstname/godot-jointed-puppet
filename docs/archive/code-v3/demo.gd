# 演示场景：4 台角色共用同一套骨架 + 同一套贴图，仅换色/朝向不同
# 操作：方向键/WASD = 8 方向朝向；数字键 1-8 = 直接指定方向
#      （加 --shot 参数启动则截一张图后自动退出，用于无头验证）

extends Node2D

const DIR_NAMES := ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]

var rigs: Array[CharacterRig] = []
var hud: Label
var t := 0.0
var shot_mode := false


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.90, 0.91, 0.94))
	shot_mode = "--shot" in OS.get_cmdline_user_args()

	var palette := [
		{"hue": 0.0, "sat": 1.0, "val": 1.0},
		{"hue": 0.42, "sat": 1.0, "val": 1.05},
		{"hue": -0.12, "sat": 1.1, "val": 0.95},
		{"hue": 0.0, "sat": 0.12, "val": 1.0},
	]
	var dirs := [0, 2, 6, 4]           # S / W / E / N —— 一开屏就能看到 4 种视图
	var xs := [190, 480, 770, 1060]

	for i in 4:
		var rig := CharacterRig.new()
		rig.name = "Char%d" % i
		rig.position = Vector2(xs[i], 520)
		add_child(rig)
		rig.visual = _make_visual(palette[i])
		rig.set_direction(dirs[i])
		rigs.append(rig)

	_make_hud()


func _make_visual(p: Dictionary) -> CharacterVisual:
	var vis := CharacterVisual.new()
	vis.skin_tint = Color(0.5, 1.0, 1.0)
	var tinted := [&"body", &"hat", &"leg_l", &"leg_r", &"shin_l", &"shin_r"]
	for slot in [&"body", &"head", &"hat", &"arm_l", &"arm_r",
			&"fore_l", &"fore_r", &"leg_l", &"leg_r", &"shin_l", &"shin_r"]:
		var part := PartDef.new()
		part.slot = slot
		part.id = StringName("demo_%s" % slot)
		for v in ["s", "sw", "w", "nw", "n"]:
			var tex: Texture2D = load("res://assets/parts/%s/%s%s_%s.png"
					% [slot, _part_stem(slot), _suffix(slot), v])
			if tex != null:
				part.sheets[v] = tex
		vis.equip(slot, part)
		if slot in tinted:
			vis.tints[slot] = Color(p.hue + 0.5, p.sat, p.val)
	return vis


func _part_stem(slot: StringName) -> String:
	match slot:
		&"body": return "body_human_01"
		&"head": return "head_human_01"
		&"hat": return "hat_wiz_01"
		_: return "%s_human_01" % String(slot).trim_suffix("_l").trim_suffix("_r")


func _suffix(slot: StringName) -> String:
	match slot:
		&"arm_l", &"fore_l", &"leg_l", &"shin_l": return "_l"
		&"arm_r", &"fore_r", &"leg_r", &"shin_r": return "_r"
		_: return ""


# ---------------------------------------------------------------- 每帧

func _process(delta: float) -> void:
	t += delta
	_handle_input()
	for i in rigs.size():
		_animate(rigs[i], t, rigs[i].view)
	if shot_mode and t > 0.8:
		_take_shot()


func _handle_input() -> void:
	var v := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if v.length_squared() > 0.01:
		for r in rigs:
			r.face_vector(v)
	for k in 8:
		if Input.is_key_pressed(KEY_1 + k):
			for r in rigs:
				r.set_direction(k)
	hud.text = "方向 %d (%s)   视图 %s%s\n方向键/WASD 换朝向   数字键 1-8 直接指定" % [
		rigs[0].direction, DIR_NAMES[rigs[0].direction],
		CharacterRig.VIEW_NAMES[rigs[0].view],
		" (镜像)" if rigs[0].scale.x < 0 else ""]


## 程序化走路循环：正式版应换成 AnimationPlayer 给骨骼打关键帧，
## 这里用代码驱动是为了让演示零资产可跑。
func _animate(rig: CharacterRig, time: float, view: int) -> void:
	var amp: float
	match view:
		CharacterRig.View.W: amp = 0.5
		CharacterRig.View.SW, CharacterRig.View.NW: amp = 0.38
		_: amp = 0.12                       # 正/背面：摆动幅度收小，避免别扭
	var s := sin(time * 6.0)
	var c := cos(time * 6.0)
	var hip: Bone2D = rig.get_bone("hip")
	var head: Bone2D = rig.get_bone("head")
	var cape: Bone2D = rig.get_bone("cape_1")
	hip.position.y = CharacterRig.BONE_TABLE[0][2].y + absf(c) * 2.0   # 重心起伏
	hip.rotation = s * 0.02

	_swing(rig.get_bone("thigh_l"), rig.get_bone("shin_l"), s, amp)
	_swing(rig.get_bone("thigh_r"), rig.get_bone("shin_r"), -s, amp)
	_swing(rig.get_bone("arm_l"), rig.get_bone("fore_l"), -s, amp * 0.8)
	_swing(rig.get_bone("arm_r"), rig.get_bone("fore_r"), s, amp * 0.8)

	head.rotation = sin(time * 3.0) * 0.04
	cape.rotation = -s * 0.06


func _swing(upper: Bone2D, lower: Bone2D, phase: float, amp: float) -> void:
	upper.rotation = phase * amp
	# 膝/肘只往一个方向弯，弯折量跟随摆动相位
	lower.rotation = maxf(0.0, -phase) * amp * 1.3


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://demo/shot.png")
	print("screenshot saved")
	get_tree().quit()


# ---------------------------------------------------------------- HUD

func _make_hud() -> void:
	hud = Label.new()
	hud.position = Vector2(24, 16)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_color", Color(0.15, 0.15, 0.2))
	add_child(hud)
