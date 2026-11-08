# 部件定义（v2 骨骼版）
# 一个 PartDef = 一个部件在某一个槽位上的一个变体，持有 5 套视图的贴图

class_name PartDef
extends Resource

@export var id: StringName                   # "hat_wizard_01"
@export var slot: StringName                 # "hat"
@export var display_name: String
@export var layer_offset: int = 0            # 衣服 5 层用，叠加到槽位 z 上

## 绑到哪根骨。留空则用 CharacterRig._default_bone(slot) 的默认值
## 分片部件（如 body 切成 6 片）每片一个 PartDef，各自指定骨骼
@export var bone: StringName = &""

## 视图名 -> 贴图："s" "sw" "w" "nw" "n"
## 部件在某视图缺失时留空，运行时自动隐藏该层
@export var sheets: Dictionary = {}

## 换色遮罩：R = 主色区，G = 皮肤区，B = 金属区。为空则整图按主色调
## （单张兜底版；变体贴图请用 tint_masks 按视图给）
@export var tint_mask: Texture2D

## 视图名 -> 染色 mask（"s" "sw" "w" "nw" "n"）。
## mask 必须和贴图逐视图对应 —— 五个视图的形状不同，一张 mask 盖不住。
## _apply_view 切视图时会同步切 mask
@export var tint_masks: Dictionary = {}

## 非对称部件（单手持剑、斜挎包）：镜像方向不翻转，退到最近原始视图
@export var no_mirror: bool = false

@export_group("兼容性")
@export var tags: Array[StringName] = []
@export var weight: float = 1.0
@export var incompatible_with: Array[StringName] = []


func has_view(view_name: String) -> bool:
	return sheets.get(view_name) != null
