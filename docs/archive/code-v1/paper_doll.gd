# 纸娃娃合成器：一个时钟 + N 个 Sprite2D 图层
# 设计约束：所有部件共享同一张 AnimTable（帧数/fps/循环），第 n 帧逐层叠图
# 方向策略：MIRROR3 / MIRROR5 用少量列 + flip_h 出 8 方向，FULL8 逐列绘制
# Godot 4.3+

class_name PaperDoll
extends Node2D

signal frame_changed(action: StringName, direction: int, frame: int)

const DIR_COUNT := 8
const CANVAS_W := 256
const CANVAS_H := 256
const ANCHOR := Vector2(128, 216)   # 脚底中心，所有帧对齐此点

## 方向 -> (列号, 是否水平镜像)
## 屏幕坐标系（y 向下）：0=S 1=SW 2=W 3=NW 4=N 5=NE 6=E 7=SE
const DIR_MAP_M3 := [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 0), Vector2i(1, 0),
	Vector2i(2, 0), Vector2i(1, 1), Vector2i(1, 1), Vector2i(1, 1),
]
const DIR_MAP_M5 := [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
	Vector2i(4, 0), Vector2i(3, 1), Vector2i(2, 1), Vector2i(1, 1),
]

## 槽位 -> 基础 z 值。留 10 的间隔方便插层
const SLOT_Z := {
	&"mount": -10, &"hair_back": 0, &"cape": 2, &"wing": 4, &"tail": 5,
	&"body": 10, &"clothes": 20, &"shoes": 25, &"head": 30, &"ear": 31,
	&"face": 32, &"hair_front": 34, &"hat": 36, &"shoulder": 40,
	&"glove": 42, &"offhand": 48, &"weapon": 50, &"summon": 60,
}

## 背面朝向（N / NW / NE）时，武器副手要沉到身体之后
const BACK_DIRS := [3, 4, 5]

@export var anim_table: AnimTable
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
var _last := Vector3i(-1, -1, -1)   # 去重：只在真正变化时写属性


func _ready() -> void:
	if anim_table == null:
		anim_table = load("res://core/data/default_anim_table.tres")
	_rebuild()


func _process(delta: float) -> void:
	var cfg: Dictionary = anim_table.actions.get(action, {})
	if cfg.is_empty():
		return

	var total: int = cfg.get("frames", 1)
	_acc += delta * float(cfg.get("fps", 8.0))

	while _acc >= 1.0:
		_acc -= 1.0
		if _frame + 1 >= total:
			if cfg.get("loop", true):
				_frame = 0
			else:
				_frame = total - 1
				_flush()
				play(&"idle")       # 非循环动作播完回 idle
				return
		else:
			_frame += 1

	_flush()


## 切换动作（帧表里不存在的动作会被忽略）
func play(a: StringName) -> void:
	if a == action or not anim_table.actions.has(a):
		return
	action = a
	_frame = 0
	_acc = 0.0
	_flush()


func set_direction(d: int) -> void:
	d = wrapi(d, 0, DIR_COUNT)
	if d == direction:
		return
	direction = d
	_apply_z_order()    # 背面朝向会改 z 序，必须重算
	_flush()


## 按移动向量自动选方向（屏幕坐标系，y 向下为正）
func face_vector(v: Vector2) -> void:
	if v.length_squared() < 0.0001:
		return
	var oct := int(round(v.angle() / (PI / 4.0)))   # -4..4
	# 0=E 1=SE 2=S 3=SW 4/-4=W -1=NE -2=N -3=NW
	var table := {0: 6, 1: 7, 2: 0, 3: 1, 4: 2, -1: 5, -2: 4, -3: 3, -4: 2}
	set_direction(table.get(oct, 0))


# ---------------------------------------------------------------- 内部

func _flush() -> void:
	var key := Vector3i(direction, int(hash(action)), _frame)
	if key == _last:
		return
	_last = key

	for s in _layers:
		var part: PartDef = s.get_meta(&"part")
		var sheets: Array = part.sheets.get(action, [])
		var m: Vector2i = _map_or_identity(part, direction)

		# 列数越界 / 纹理缺失 -> 隐藏该层（不崩）
		if sheets.is_empty() or m.x >= sheets.size() or sheets[m.x] == null:
			s.visible = false
			continue
		s.visible = true

		var tex: Texture2D = sheets[m.x]
		if s.texture != tex:
			s.texture = tex
			_apply_frame_grid(s, part, tex)
		s.flip_h = m.y == 1
		if _frame < s.vframes:
			s.frame = _frame

	frame_changed.emit(action, direction, _frame)


func _dir_map(part: PartDef) -> Array:
	match part.mirror_mode:
		PartDef.Mirror.MIRROR3:
			return DIR_MAP_M3
		PartDef.Mirror.MIRROR5:
			return DIR_MAP_M5
		_:
			return []   # FULL8：调用方用 identity（列号 = 方向，不镜像）


func _map_or_identity(part: PartDef, dir: int) -> Vector2i:
	var mapped := _dir_map(part)
	if mapped.is_empty():
		return Vector2i(dir, 0)   # FULL8
	return mapped[dir]


func _apply_frame_grid(s: Sprite2D, part: PartDef, tex: Texture2D) -> void:
	var cols: int = part.col_count()
	if tex.get_width() != cols * CANVAS_W or tex.get_height() % CANVAS_H != 0:
		push_warning("PaperDoll: 部件 %s 的 %s 图尺寸 %s 与列数 %d 不符"
			% [part.id, action, tex.get_size(), cols])
	s.hframes = cols
	s.vframes = maxi(1, int(tex.get_height() / CANVAS_H))
	if _frame >= s.vframes:
		_frame = 0


func _apply_z_order() -> void:
	for s in _layers:
		var part: PartDef = s.get_meta(&"part")
		s.z_index = _base_z(part) + part.layer_offset


func _base_z(p: PartDef) -> int:
	var z: int = SLOT_Z.get(p.slot, 10)
	if p.behind_on_back and direction in BACK_DIRS:
		return mini(z, 8)
	return z


func _rebuild() -> void:
	for c in get_children():
		if c is Sprite2D:
			c.queue_free()
	_layers.clear()
	_last = Vector3i(-1, -1, -1)

	if visual == null:
		return

	var parts: Array[PartDef] = []
	for slot in visual.equipped.keys():
		var p: PartDef = visual.equipped[slot]
		if p != null:
			parts.append(p)
	parts.sort_custom(func(a: PartDef, b: PartDef) -> bool:
		return _base_z(a) + a.layer_offset < _base_z(b) + b.layer_offset)

	for p in parts:
		var s := Sprite2D.new()
		s.name = String(p.slot)
		s.hframes = p.col_count()
		s.vframes = 1
		s.centered = false
		s.offset = Vector2.ZERO
		s.position = -ANCHOR                    # 画布锚点对齐到节点原点
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		s.set_meta(&"part", p)
		s.material = _make_material(p, p.slot)
		add_child(s)
		_layers.append(s)

	_apply_z_order()
	_flush()


func _make_material(part: PartDef, slot: StringName) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/part_tint.gdshader")
	m.set_shader_parameter("use_mask", part.tint_mask != null)
	if part.tint_mask != null:
		m.set_shader_parameter("tint_mask", part.tint_mask)
	apply_tint(m, visual.tints.get(slot, Color(0.5, 1.0, 1.0)))
	apply_skin(m)
	return m


## Color 打包约定：r = hue_shift + 0.5, g = sat_mul, b = val_mul
func apply_tint(m: ShaderMaterial, packed: Color) -> void:
	m.set_shader_parameter("hue_shift", packed.r - 0.5)
	m.set_shader_parameter("sat_mul", packed.g)
	m.set_shader_parameter("val_mul", packed.b)


## 皮肤统一色：脸和手共用，解决"蓝皮肤却戴肉色手套"
func apply_skin(m: ShaderMaterial) -> void:
	var s: Color = visual.skin_tint
	m.set_shader_parameter("skin_hue_shift", s.r - 0.5)
	m.set_shader_parameter("skin_sat_mul", s.g)
	m.set_shader_parameter("skin_val_mul", s.b)
