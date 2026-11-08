# 骨架烘焙器：把「骨架 + 5 视图单张」烘焙成「8 方向 x N 帧图集」
#
# 这是 v3 的核心工序 —— 骨架只在离线存在，运行时回到帧表算法（和参考视频一致）。
#
# 运行：godot --path <工程> res://tools/bake_frames.tscn
# 产出：assets/frames/{slot}/{stem}_{action}.png  (宽 2048 = 8 方向 x 256, 高 = 帧数 x 256)

extends Node

const CELL := 256
const DIR_COUNT := 8
const OUT_ROOT := "res://assets/frames"

## 动作表：帧数与 FrameDoll.ACTIONS 必须一致
const ACTIONS := {
	&"idle": {"frames": 6, "fps": 6.0, "loop": true},
	&"walk": {"frames": 8, "fps": 10.0, "loop": true},
	&"attack": {"frames": 6, "fps": 14.0, "loop": false},
	&"hurt": {"frames": 4, "fps": 8.0, "loop": false},
}

## 攻击：手挥出去再收回（每个动作单独一张关键帧表，比公式更好调）
const ATTACK_POSE := {
	"arm_r": [-0.15, -0.75, -1.15, 0.55, 1.25, 0.35],
	"fore_r": [0.15, 0.55, 0.85, 0.25, 0.05, 0.15],
	"chest": [-0.03, -0.10, -0.14, 0.08, 0.16, 0.04],
	"head": [0.0, -0.04, -0.06, 0.03, 0.07, 0.02],
}

## 受击：向后仰再回位
const HURT_POSE := {
	"chest": [0.0, -0.10, -0.17, -0.09],
	"head": [0.0, -0.12, -0.20, -0.10],
	"arm_l": [0.0, 0.25, 0.45, 0.20],
	"arm_r": [0.0, -0.20, -0.35, -0.15],
	"hip_dy": [0.0, 2.0, 3.5, 1.5],
}

var viewport: SubViewport
var stage: Node2D
var rig: CharacterRig


func _ready() -> void:
	print("=== bake start ===")
	_build_stage()
	await get_tree().process_frame
	await _bake_all()
	print("=== bake done ===")
	get_tree().quit()


func _build_stage() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(CELL, CELL)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.disable_3d = true
	add_child(viewport)

	stage = Node2D.new()
	viewport.add_child(stage)

	rig = CharacterRig.new()
	# 骨架内容 = 画布坐标 - CANVAS_ANCHOR，所以这里挪回 +CANVAS_ANCHOR 让画布铺满视口
	rig.position = CharacterRig.CANVAS_ANCHOR
	stage.add_child(rig)
	rig.visual = _build_visual()
	rig.refresh()
	rig.show_all()


func _build_visual() -> CharacterVisual:
	var vis := CharacterVisual.new()
	for entry in PartCatalog.DEMO:
		var slot: StringName = entry.slot
		var stem: String = entry.stem
		var part := PartDef.new()
		part.slot = slot
		part.id = StringName(stem)
		for v in PartCatalog.SOURCE_VIEWS:
			var tex: Texture2D = load(PartCatalog.src_path(slot, stem, v))
			if tex != null:
				part.sheets[v] = tex
		vis.equip(slot, part)
	return vis


# ---------------------------------------------------------------- 烘焙主循环

func _bake_all() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_ROOT)

	for entry in PartCatalog.DEMO:
		var slot: StringName = entry.slot
		var stem: String = entry.stem
		DirAccess.make_dir_recursive_absolute("%s/%s" % [OUT_ROOT, slot])

		for a in ACTIONS.keys():
			var frames: int = ACTIONS[a].frames
			var sheet := Image.create(DIR_COUNT * CELL, frames * CELL, false, Image.FORMAT_RGBA8)
			for f in frames:
				for d in DIR_COUNT:
					rig.set_direction(d)
					rig.solo_slot(slot)
					_pose(a, f, frames, d)
					await RenderingServer.frame_post_draw
					var img := viewport.get_texture().get_image()
					if img.get_format() != Image.FORMAT_RGBA8:
						img.convert(Image.FORMAT_RGBA8)
					sheet.blit_rect(img, Rect2i(0, 0, CELL, CELL),
							Vector2i(d * CELL, f * CELL))
			var out := PartCatalog.baked_path(slot, stem, String(a))
			var err := sheet.save_png(out)
			print("%s  %s  err=%d" % [slot, a, err])


# ---------------------------------------------------------------- 摆姿势

func _bone(n: String) -> Bone2D:
	return rig.get_bone(n)


func _reset_pose() -> void:
	for entry in CharacterRig.BONE_TABLE:
		var b := _bone(entry[0])
		if b != null:
			b.rotation = 0.0
	var hip := _bone("hip")
	hip.position = CharacterRig.BONE_TABLE[0][2]


## 侧向摆动幅度按视图收敛：正/背面把前后摆动压小，否则看起来像横着走
func _amp_for(d: int) -> float:
	match CharacterRig.DIR_TO_VIEW[d].x:
		2:
			return 1.0
		1, 3:
			return 0.8
		_:
			return 0.35


func _pose(a: StringName, f: int, frames: int, d: int) -> void:
	_reset_pose()
	var amp := _amp_for(d)
	var phase := TAU * float(f) / float(frames)
	var s := sin(phase)
	var hip := _bone("hip")
	var rest_y: float = CharacterRig.BONE_TABLE[0][2].y

	match a:
		&"idle":
			hip.position = Vector2(hip.position.x, rest_y + s * 1.5)
			_bone("chest").rotation = s * 0.02
			_bone("head").rotation = sin(phase + 0.7) * 0.03
			_bone("arm_l").rotation = s * 0.04
			_bone("arm_r").rotation = -s * 0.04
			_bone("cape_1").rotation = s * 0.05
		&"walk":
			hip.position = Vector2(hip.position.x, rest_y + absf(cos(phase)) * 3.0)
			_bone("thigh_l").rotation = s * 0.45 * amp
			_bone("shin_l").rotation = maxf(0.0, -s) * 0.65 * amp
			_bone("thigh_r").rotation = -s * 0.45 * amp
			_bone("shin_r").rotation = maxf(0.0, s) * 0.65 * amp
			_bone("arm_l").rotation = -s * 0.35 * amp
			_bone("fore_l").rotation = maxf(0.0, -s) * 0.45 * amp
			_bone("arm_r").rotation = s * 0.35 * amp
			_bone("fore_r").rotation = maxf(0.0, s) * 0.45 * amp
			_bone("chest").rotation = s * 0.03
			_bone("head").rotation = -s * 0.04
			_bone("cape_1").rotation = -s * 0.10
		&"attack":
			_apply_table(ATTACK_POSE, f, amp)
		&"hurt":
			_apply_table(HURT_POSE, f, amp)


func _apply_table(table: Dictionary, f: int, amp: float) -> void:
	var k := 0.6 + 0.4 * amp
	for key in table.keys():
		var values: Array = table[key]
		var v: float = values[clampi(f, 0, values.size() - 1)] * k
		if key == "hip_dy":
			var hip := _bone("hip")
			hip.position = Vector2(hip.position.x, hip.position.y + v)
		else:
			var b := _bone(key)
			if b != null:
				b.rotation = v
