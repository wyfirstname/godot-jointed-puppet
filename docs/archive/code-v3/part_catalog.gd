# 演示用部件清单：slot -> 源图 stem
# 源图（5 视图单张）在 assets/parts/{slot}/{stem}_{s|sw|w|nw|n}.png
# 烘焙产物（8 方向 x N 帧图集）在 assets/frames/{slot}/{stem}_{action}.png

class_name PartCatalog
extends RefCounted

const DEMO := [
	{"slot": &"leg_r", "stem": "leg_human_01_r"},
	{"slot": &"shin_r", "stem": "shin_human_01_r"},
	{"slot": &"leg_l", "stem": "leg_human_01_l"},
	{"slot": &"shin_l", "stem": "shin_human_01_l"},
	{"slot": &"arm_r", "stem": "arm_human_01_r"},
	{"slot": &"fore_r", "stem": "fore_human_01_r"},
	{"slot": &"body", "stem": "body_human_01"},
	{"slot": &"arm_l", "stem": "arm_human_01_l"},
	{"slot": &"fore_l", "stem": "fore_human_01_l"},
	{"slot": &"head", "stem": "head_human_01"},
	{"slot": &"hat", "stem": "hat_wiz_01"},
]

const SOURCE_VIEWS := ["s", "sw", "w", "nw", "n"]


static func src_path(slot: StringName, stem: String, view: String) -> String:
	return "res://assets/parts/%s/%s_%s.png" % [slot, stem, view]


static func baked_path(slot: StringName, stem: String, action: String) -> String:
	return "res://assets/frames/%s/%s_%s.png" % [slot, stem, action]


static func find(slot: StringName) -> Dictionary:
	for e in DEMO:
		if e.slot == slot:
			return e
	return {}
