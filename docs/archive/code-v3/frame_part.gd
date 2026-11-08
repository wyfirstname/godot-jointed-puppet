# 烘焙后的部件（帧表版）：每个动作一张 8 列图集
# 列 = 8 个方向（已烘焙，运行时不需要镜像），行 = 帧
# 帧数由图集高度推导：frames = height / 256

class_name FramePart
extends Resource

@export var id: StringName
@export var slot: StringName
@export var layer_offset: int = 0

## action(StringName) -> Texture2D（8 列图集）
@export var sheets: Dictionary = {}

## 换色遮罩（与图集同尺寸）；为空则整块可染
@export var tint_mask: Texture2D


func has_action(a: StringName) -> bool:
	return sheets.get(a) != null


func frames_of(a: StringName) -> int:
	var tex: Texture2D = sheets.get(a)
	if tex == null:
		return 0
	return int(tex.get_height()) / 256
