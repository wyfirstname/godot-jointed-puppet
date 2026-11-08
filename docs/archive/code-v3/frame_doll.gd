# 运行时角色：帧表驱动的纸娃娃（与参考视频同一套算法）
#
# 核心只有一句：**一个时钟，N 个 Sprite2D**。
# 每帧算出 (动作, 方向, 帧号) 后广播给所有图层，`frame = 帧号 * 8 + 方向`。
# 绝不给每个部件挂独立 AnimatedSprite2D —— 那样各层动画会各自漂移。
#
# 骨架（CharacterRig）只用于离线烘焙，运行时完全不参与。

class_name FrameDoll
extends Node2D

signal frame_pushed(action: StringName, direction: int, frame: int)

const DIR_COUNT := 8
const CELL := 256
const CANVAS_ANCHOR := Vector2(128, 216)

## 动作表：帧数和 fps 必须与烘焙时一致（见 tools/bake_frames.gd）
const ACTIONS := {
	&"idle": {"fps": 6.0, "loop": true},
	&"walk": {"fps": 10.0, "loop": true},
	&"attack": {"fps": 14.0, "loop": false},
	&"hurt": {"fps": 8.0, "loop": false},
}

## 屏幕坐标系：0=S 1=SW 2=W 3=NW 4=N 5=NE 6=E 7=SE
const DIR_NAMES := ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]

@export var visual: CharacterVisual:
	set(v):
		visual = v
		if is_inside_tree():
			_rebuild()

var direction: int = 0
var action: StringName = &"idle"

var _frame: int = 0
var _acc: float = 0.0
var _layers: Array[Sprite2D] = []


func _ready() -> void:
	_rebuild()


# ---------------------------------------------------------------- 装备

func _rebuild() -> void:
	for c in get_children():
		if c is Sprite2D:
			c.queue_free()
	_layers.clear()
	if visual == null:
		return

	var slots: Array = visual.equipped.keys()
	slots.sort_custom(func(a, b): return _z_of(a) < _z_of(b))

	for slot in slots:
		var part = visual.equipped[slot]
		if part == null:
			continue
		var s := Sprite2D.new()
		s.name = String(slot)
		s.centered = false
		# 贴图按画布坐标绘制：(0,0) 对齐到 -CANVAS_ANCHOR，脚底落在节点原点
		s.position = -CANVAS_ANCHOR
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		s.z_as_relative = true
		s.z_index = _z_of(slot) + int(part.layer_offset)
		s.set_meta(&"part", part)
		s.set_meta(&"slot", slot)
		s.material = _make_material(part, slot)
		add_child(s)
		_layers.append(s)

	_push()


func _z_of(slot: StringName) -> int:
	return int(CharacterRig.SLOT_Z.get(slot, 10))


func _make_material(part, slot: StringName) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/part_tint.gdshader")
	var has_mask: bool = part.tint_mask != null
	m.set_shader_parameter("use_mask", has_mask)
	if has_mask:
		m.set_shader_parameter("tint_mask", part.tint_mask)
	var packed: Color = visual.tints.get(slot, Color(0.5, 1.0, 1.0))
	m.set_shader_parameter("hue_shift", packed.r - 0.5)
	m.set_shader_parameter("sat_mul", packed.g)
	m.set_shader_parameter("val_mul", packed.b)
	var sk: Color = visual.skin_tint
	m.set_shader_parameter("skin_hue_shift", sk.r - 0.5)
	m.set_shader_parameter("skin_sat_mul", sk.g)
	m.set_shader_parameter("skin_val_mul", sk.b)
	return m


func equip(slot: StringName, part) -> void:
	visual.equip(slot, part)
	_rebuild()


# ---------------------------------------------------------------- 方向

func set_direction(d: int) -> void:
	d = wrapi(d, 0, DIR_COUNT)
	if d == direction:
		return
	direction = d
	_push()


## 按移动向量选方向（屏幕坐标系，y 向下）
func face_vector(v: Vector2) -> void:
	if v.length_squared() < 0.0001:
		return
	var oct := int(round(v.angle() / (PI / 4.0)))
	var table := {0: 6, 1: 7, 2: 0, 3: 1, 4: 2, -1: 5, -2: 4, -3: 3, -4: 2}
	set_direction(table.get(oct, 0))


# ---------------------------------------------------------------- 时间轴

func play(a: StringName) -> void:
	if not ACTIONS.has(a) or a == action:
		return
	action = a
	_frame = 0
	_acc = 0.0
	_push()


func _process(delta: float) -> void:
	var cfg: Dictionary = ACTIONS.get(action, {})
	if cfg.is_empty():
		return
	var total := _current_frames()
	if total <= 1:
		return
	_acc += delta * float(cfg.fps)
	while _acc >= 1.0:
		_acc -= 1.0
		if _frame + 1 >= total:
			if bool(cfg.loop):
				_frame = 0
			else:
				_frame = total - 1
				play(&"idle")
				return
		else:
			_frame += 1
	_push()


func _current_frames() -> int:
	for s in _layers:
		var p = s.get_meta(&"part")
		if p.has_action(action):
			return p.frames_of(action)
	return 0


func _push() -> void:
	for s in _layers:
		var p = s.get_meta(&"part")
		var tex: Texture2D = p.sheets.get(action)
		var used: StringName = action
		if tex == null:
			used = &"idle"
			tex = p.sheets.get(used)
		if tex == null:
			s.visible = false
			continue
		s.visible = true
		var frames := int(tex.get_height()) / CELL
		var f := clampi(_frame, 0, frames - 1)
		s.hframes = DIR_COUNT
		s.vframes = frames
		s.texture = tex
		# 图集布局：列 = 方向，行 = 帧 -> 索引 = 行 * 8 + 列
		s.frame = f * DIR_COUNT + direction
	frame_pushed.emit(action, direction, _frame)


func current_frame() -> int:
	return _frame
