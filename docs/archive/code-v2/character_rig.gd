# 角色骨架装配器：程序化建 Skeleton2D，把部件挂成骨骼子节点（Cutout）
# 设计前提（见 docs/技术方案.md §4.1）：刚性部件不蒙皮，直接做 Bone2D 的子节点
# Godot 4.7

class_name CharacterRig
extends Node2D

signal view_changed(view: int)

## 视图集：画 5 套 + 镜像 = 8 方向
enum View { S, SW, W, NW, N }
const VIEW_NAMES := ["s", "sw", "w", "nw", "n"]

## 方向 -> (视图, 是否镜像)。屏幕坐标系：0=S 1=SW 2=W 3=NW 4=N 5=NE 6=E 7=SE
const DIR_TO_VIEW := [
	Vector2i(View.S, 0), Vector2i(View.SW, 0), Vector2i(View.W, 0),
	Vector2i(View.NW, 0), Vector2i(View.N, 0),
	Vector2i(View.NW, 1), Vector2i(View.W, 1), Vector2i(View.SW, 1),
]

const CANVAS_ANCHOR := Vector2(128, 216)   # 画布锚点 = 脚底中心

## 骨架定义：name -> [parent, 局部坐标(画布坐标系)]
## 顺序即前序遍历顺序，骨骼索引就是数组下标 —— 这正是不用手算索引的原因
const BONE_TABLE := [
	["hip",     "",        Vector2(128, 150)],
	["spine",   "hip",     Vector2(128, 130)],
	["chest",   "spine",   Vector2(128, 112)],
	["head",    "chest",   Vector2(128, 78)],
	["arm_l",   "chest",   Vector2(110, 108)],
	["fore_l",  "arm_l",   Vector2(98, 128)],
	["hand_l",  "fore_l",  Vector2(92, 148)],
	["arm_r",   "chest",   Vector2(146, 108)],
	["fore_r",  "arm_r",   Vector2(158, 128)],
	["hand_r",  "fore_r",  Vector2(164, 148)],
	["thigh_l", "hip",     Vector2(116, 158)],
	["shin_l",  "thigh_l", Vector2(114, 186)],
	["foot_l",  "shin_l",  Vector2(114, 208)],
	["thigh_r", "hip",     Vector2(140, 158)],
	["shin_r",  "thigh_r", Vector2(142, 186)],
	["foot_r",  "shin_r",  Vector2(142, 208)],
	["cape_1",  "chest",   Vector2(128, 105)],
	["cape_2",  "cape_1",  Vector2(128, 140)],
]

## 槽位 -> z 值
const SLOT_Z := {
	&"mount": -10, &"hair_back": 0, &"cape": 2, &"wing": 4, &"tail": 5,
	&"leg_r": 7, &"shin_r": 7, &"arm_r": 8, &"fore_r": 8,
	&"leg_l": 9, &"shin_l": 9,
	&"body": 10, &"clothes": 20, &"shoes": 25,
	&"arm_l": 13, &"fore_l": 13,
	&"head": 30, &"ear": 31,
	&"face": 32, &"hair_front": 34, &"hat": 36, &"shoulder": 40,
	&"glove": 42, &"offhand": 48, &"weapon": 50, &"summon": 60,
}

## 背面朝向时要沉到身体之下的槽位
const BEHIND_ON_BACK := [&"weapon", &"offhand"]

@export var visual: CharacterVisual:
	set(v):
		visual = v
		if is_inside_tree():
			_rebuild_parts()

var view: int = View.S
var direction: int = 0
var action: StringName = &"idle"

var skeleton: Skeleton2D
var anim_player: AnimationPlayer
var _bones: Dictionary = {}          # name -> Bone2D
var _rest_global: Dictionary = {}    # name -> Vector2（rest 全局坐标，算偏移用）
var _parts: Array[Sprite2D] = []


func _ready() -> void:
	_build_skeleton()
	_build_parts_container()
	_rebuild_parts()
	anim_player = _ensure_anim_player()


# ---------------------------------------------------------------- 骨架

func _build_skeleton() -> void:
	skeleton = Skeleton2D.new()
	skeleton.name = "Skeleton2D"
	# 画布坐标 (0..256) 与骨架局部坐标 1:1，把脚底锚点 (128,216) 移到节点原点
	skeleton.position = -CANVAS_ANCHOR
	add_child(skeleton)

	for entry in BONE_TABLE:
		var bone_name: String = entry[0]
		var parent_name: String = entry[1]
		var world_pos: Vector2 = entry[2]

		var b := Bone2D.new()
		b.name = bone_name
		# 入树前就关掉长度/角度自动计算：入树瞬间还没有子骨，自动计算必刷警告
		# （4.7 里这两个是方法而不是属性）
		b.set_autocalculate_length_and_angle(false)

		# 局部坐标 = 本骨画布坐标 - 父骨画布坐标
		var parent_pos := Vector2.ZERO
		if parent_name != "":
			parent_pos = _rest_global[parent_name]

		b.position = world_pos - parent_pos
		b.rotation = 0.0
		b.scale = Vector2.ONE

		var parent: Node = skeleton
		if parent_name != "":
			parent = _bones[parent_name]
		parent.add_child(b)

		# rest 必须在入树当帧就给出非退化值：默认 rest 会让 Skeleton2D
		# 首次更新时对零矩阵做 affine_inverse，报一串 det == 0
		b.rest = b.transform
		_bones[bone_name] = b
		_rest_global[bone_name] = world_pos

	# 骨骼长度：指向第一个子骨；无子骨给固定 8，避免长度 0 导致变换矩阵退化。
	# 注意 Godot 4.7 移除了 Skeleton2D.set_bone_rest，rest 只需写在 Bone2D 上（上面已写）。
	for entry in BONE_TABLE:
		var bone_name: String = entry[0]
		var b: Bone2D = _bones[bone_name]
		var child_pos := _first_child_pos(bone_name)
		if child_pos != Vector2.INF:
			b.set_length(maxf(4.0, (child_pos - _rest_global[bone_name]).length()))
		else:
			b.set_length(8.0)


func _first_child_pos(bone_name: String) -> Vector2:
	for entry in BONE_TABLE:
		if entry[1] == bone_name:
			return entry[2]
	return Vector2.INF


func get_bone(bone_name: StringName) -> Bone2D:
	return _bones.get(String(bone_name))


# ---------------------------------------------------------------- 部件

func _build_parts_container() -> void:
	# 部件直接挂在骨骼下，所以不需要额外容器；这里只做占位说明
	pass


func _rebuild_parts() -> void:
	for p in _parts:
		if is_instance_valid(p):
			p.queue_free()
	_parts.clear()

	if visual == null or skeleton == null:
		return

	for slot in visual.equipped.keys():
		var part: PartDef = visual.equipped[slot]
		if part == null:
			continue
		var bone_name: String = String(part.bone) if part.bone != &"" else _default_bone(slot)
		var bone: Bone2D = get_bone(bone_name)
		if bone == null:
			push_warning("CharacterRig: 槽位 %s 找不到骨骼 %s，跳过" % [slot, bone_name])
			continue

		var s := Sprite2D.new()
		s.name = String(slot)
		s.centered = false
		# 贴图按「画布坐标」绘制，而骨骼绕自己的原点旋转。
		# 要让画布点 c 在骨骼旋转后落在 G + R·(c - G)，节点位置必须是 -G：
		#   T(G)·R·T(-G)·c = G + R·(c - G)
		# 于是贴图原点 (0,0) -> 骨架局部 (0,0)，画布坐标与骨架局部坐标 1:1。
		# 整体再靠 skeleton.position 把脚底挪到节点原点。
		s.position = -_rest_global[bone_name]
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		s.set_meta(&"part", part)
		s.set_meta(&"slot", slot)
		s.material = _make_material(part, slot)
		bone.add_child(s)

		_parts.append(s)

	_apply_view()
	_apply_z_order()


func _default_bone(slot: StringName) -> String:
	match slot:
		&"hat", &"head", &"ear", &"face", &"hair_front": return "head"
		&"hair_back": return "head"
		&"cape": return "cape_1"
		&"weapon": return "hand_r"
		&"offhand": return "hand_l"
		&"glove": return "hand_r"
		&"shoes": return "foot_r"
		&"shoulder": return "arm_r"
		&"arm_l": return "arm_l"
		&"fore_l": return "fore_l"
		&"arm_r": return "arm_r"
		&"fore_r": return "fore_r"
		&"leg_l": return "thigh_l"
		&"shin_l": return "shin_l"
		&"leg_r": return "thigh_r"
		&"shin_r": return "shin_r"
		&"wing", &"body", &"clothes": return "chest"
		_: return "hip"


func _make_material(part: PartDef, slot: StringName) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/part_tint.gdshader")
	m.set_shader_parameter("use_mask", part.tint_mask != null)
	if part.tint_mask != null:
		m.set_shader_parameter("tint_mask", part.tint_mask)
	var packed: Color = visual.tints.get(slot, Color(0.5, 1.0, 1.0))
	m.set_shader_parameter("hue_shift", packed.r - 0.5)
	m.set_shader_parameter("sat_mul", packed.g)
	m.set_shader_parameter("val_mul", packed.b)
	# 皮肤统一色
	var sk: Color = visual.skin_tint
	m.set_shader_parameter("skin_hue_shift", sk.r - 0.5)
	m.set_shader_parameter("skin_sat_mul", sk.g)
	m.set_shader_parameter("skin_val_mul", sk.b)
	return m


# ---------------------------------------------------------------- 视图与方向

func set_direction(d: int) -> void:
	d = wrapi(d, 0, 8)
	if d == direction:
		return
	direction = d
	var m: Vector2i = DIR_TO_VIEW[d]
	if m.x != view:
		view = m.x
		view_changed.emit(view)
	_apply_view()
	_apply_z_order()
	_play_current()


## 按移动向量选方向（屏幕坐标系，y 向下）
func face_vector(v: Vector2) -> void:
	if v.length_squared() < 0.0001:
		return
	var oct := int(round(v.angle() / (PI / 4.0)))
	var table := {0: 6, 1: 7, 2: 0, 3: 1, 4: 2, -1: 5, -2: 4, -3: 3, -4: 2}
	set_direction(table.get(oct, 0))


func _apply_view() -> void:
	var m: Vector2i = DIR_TO_VIEW[direction]
	for s in _parts:
		var part: PartDef = s.get_meta(&"part")
		var tex: Texture2D = part.sheets.get(VIEW_NAMES[m.x])
		s.visible = tex != null
		if tex != null:
			s.texture = tex
	# 镜像在「整只骨架」上做，而不是逐图层 flip_h。
	# 逐图层翻转只会镜像贴图矩形，骨骼仍停在原侧，图与轴心会错位；
	# 整节点 scale.x = -1 则骨骼位置与贴图一起镜像，轴心天然对齐。
	scale.x = -1.0 if m.y == 1 else 1.0


func _apply_z_order() -> void:
	var is_back := direction in [3, 4, 5]
	for s in _parts:
		var part: PartDef = s.get_meta(&"part")
		var slot: StringName = s.get_meta(&"slot")
		var z: int = SLOT_Z.get(slot, 10)
		if is_back and slot in BEHIND_ON_BACK:
			z = 8
		s.z_index = z + part.layer_offset
		s.z_as_relative = true


## 强制重刷当前视图（烘焙时用完 set_direction(0) 的早退分支后需要一次）
func refresh() -> void:
	_apply_view()
	_apply_z_order()


## 只显示指定槽位的部件，其余隐藏 —— 烘焙时逐部件单独出图用
func solo_slot(slot: StringName) -> void:
	for s in _parts:
		s.visible = s.get_meta(&"slot") == slot and s.texture != null


func show_all() -> void:
	for s in _parts:
		s.visible = true


# ---------------------------------------------------------------- 动画

func _ensure_anim_player() -> AnimationPlayer:
	var ap := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if ap == null:
		ap = AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		add_child(ap)
	return ap


func _play_current() -> void:
	if anim_player == null:
		return
	var aname := "%s/%s" % [VIEW_NAMES[view], action]
	if anim_player.has_animation(aname):
		anim_player.play(aname)


func play(a: StringName) -> void:
	action = a
	_play_current()
