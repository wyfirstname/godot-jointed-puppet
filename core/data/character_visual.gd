# 角色外观数据：槽位 -> 部件 + 换色参数
# 这是"一个角色"的全部可配置信息，存档只需存这个（或它的 id）

class_name CharacterVisual
extends Resource

## slot(StringName) -> Resource（PartDef = 骨架生产用；FramePart = 运行时帧表用）
## 两条管线共用同一份外观数据结构，换装/存档逻辑不用写两遍
@export var equipped: Dictionary = {}

## 当前表情（face 槽位的变体名）。想换就调 set_expression()，
## 它会重读对应变体的贴图并刷新画面；直接改这个字段不会触发换图
@export var expression: StringName = &"neutral"

## slot(StringName) -> Color
## 打包约定：r = hue_shift + 0.5, g = sat_mul, b = val_mul
## 作用于 mask 的 R 区（木头/布料/头发）
@export var tints: Dictionary = {}

## slot(StringName) -> Color，金属区（球关节/护手/柄头）的换色。
## 打包约定同 tints。留空 = 金属保持原色
@export var tints_metal: Dictionary = {}

## 皮肤统一色（脸和手共用，解决"蓝皮肤却戴肉色手套"）
@export var skin_tint: Color = Color(0.5, 1.0, 1.0)

@export var scale_mul: float = 1.0


func get_part(slot: StringName) -> Resource:
	return equipped.get(slot)


func equip(slot: StringName, part: Resource) -> void:
	if part == null:
		equipped.erase(slot)
	else:
		equipped[slot] = part


func to_dict() -> Dictionary:
	var slots := {}
	for slot in equipped.keys():
		var p = equipped[slot]
		if p != null:
			slots[String(slot)] = String(p.get("id"))
	var tint_dict := {}
	for slot in tints.keys():
		var c: Color = tints[slot]
		tint_dict[String(slot)] = [c.r, c.g, c.b]
	return {
		"slots": slots,
		"tints": tint_dict,
		"skin_tint": [skin_tint.r, skin_tint.g, skin_tint.b],
		"expression": String(expression),
	}


## 当前 assets/parts 下真实存在的 14 个槽位。
## 和 demo 里那份列表是同一套；放在这里是为了让"装配一份默认外观"变成可复用的一行。
const DEFAULT_SLOTS: Array[StringName] = [
	&"cape", &"hair_back", &"leg_r", &"shin_r", &"leg_l", &"shin_l",
	&"arm_r", &"fore_r", &"body", &"arm_l", &"fore_l", &"head", &"face",
	&"hair_front", &"weapon",
]


## 从 res://assets/parts 装配一份完整外观（每个槽位 5 张视图）。
##
## 编辑器和运行时都能用：编辑器里 load() 拿的是导入后的纹理，和运行时同一份。
## 缺图不报错 —— 该视图的精灵直接不显示，正好用来做"半套美术"的中间状态。
##
## expr：表情（face 槽位的变体名）。face 是多变体槽位，文件名带变体：
##   face/face_{expr}_puppet_{view}.png；其它槽位仍是无变体的老命名。
##
## outfit：slot(StringName) -> 变体名(String)。服装和表情是同一套机制——
##   变体槽的文件名带变体段。传 {"body": "robe", "hat": "wizard"} 就是一套法师；
##   传 {"cape": ""} 表示把 cape 摘掉（空串 = 该槽位整体不装）。
##   没提到的槽位保持默认；设计师页面（tools/character_designer.html）
##   导出的 JSON 里 parts 字段可以直接喂给这个参数。
static func from_assets(tint: Color = Color(1.0, 1.0, 1.0),
		expr: StringName = &"neutral",
		outfit: Dictionary = {}) -> CharacterVisual:
	var vis := CharacterVisual.new()
	vis.skin_tint = Color(0.5, 1.0, 1.0)
	vis.expression = expr
	var slots := DEFAULT_SLOTS.duplicate()
	for slot in outfit.keys():
		var s: StringName = slot if slot is StringName else StringName(slot)
		var variant: String = outfit[slot]
		if variant == "":
			slots.erase(s)          # 空串 = 摘掉
		elif not slots.has(s):
			slots.append(s)         # 默认装配之外的槽位（hat 等）按需加进来
	for slot in slots:
		var part := _load_slot_part(slot, _variant_of(slot, outfit), expr)
		vis.equip(slot, part)
	# 只染披风：木头身保持原色，视觉上才像"不同角色共用同一个木头人"
	vis.tints[&"cape"] = tint
	return vis


## 该槽位这次该装哪个文件 stem：face 用表情，其余槽位查 outfit，都没有就是默认命名
static func _variant_of(slot: StringName, outfit: Dictionary) -> String:
	if slot == &"face":
		return ""                    # face 由 expr 参数决定，调用方拼前缀
	if outfit.has(slot):
		return String(outfit[slot])
	return ""


## 装一个槽位的 5 张视图 + 对应 mask。表情/服装/默认三条装配路径共用这一个函数，
## 谁也不许自己另拼文件名 —— 命名规则改一次就要三处同步，必然漏
static func _load_slot_part(slot: StringName, variant: String, expr: StringName) -> PartDef:
	var part := PartDef.new()
	part.slot = slot
	part.id = slot
	var stem := String(slot)
	if slot == &"face":
		stem = "face_%s" % expr
	elif variant != "":
		stem = "%s_%s" % [slot, variant]
	for v in ["s", "sw", "w", "nw", "n"]:
		var path := "res://assets/parts/%s/%s_puppet_%s.png" % [slot, stem, v]
		if ResourceLoader.exists(path):
			part.sheets[v] = load(path)
		# 染色 mask 与贴图同 stem 同视图；缺 mask 的视图走整图主色调
		var mask_path := "res://assets/parts/%s/%s_mask_%s.png" % [slot, stem, v]
		if ResourceLoader.exists(mask_path):
			part.tint_masks[v] = load(mask_path)
	return part


## 换装：outfit = slot -> 变体名（"" = 摘掉）。
## 变体是"另一张图"不是"换个参数"，所以必须整槽位重装；tints / 表情原地保留
func apply_outfit(outfit: Dictionary) -> void:
	for slot in outfit.keys():
		var s: StringName = slot if slot is StringName else StringName(slot)
		var variant := String(outfit[slot])
		if variant == "":
			equip(s, null)
			continue
		equip(s, _load_slot_part(s, variant, expression))


## 换表情：重读 face 槽位某一变体的 5 张视图。
## 表情本质就是「face 槽位换了张贴图」——头骨/头发/鼻尖都不动，
## 所以切换是零成本的（改一个指针，_apply_view 重新绑纹理）。
func set_expression(expr: StringName) -> void:
	expression = expr
	var part: PartDef = equipped.get(&"face")
	if part == null:
		return
	for v in ["s", "sw", "w", "nw", "n"]:
		var path := "res://assets/parts/face/face_%s_puppet_%s.png" % [expr, v]
		part.sheets[v] = load(path) if ResourceLoader.exists(path) else null
	# 镜像视图也吃同一份 sheets（_apply_view 只按视图名查），不用额外处理
