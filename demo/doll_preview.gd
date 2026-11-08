## 单只人偶的骨架预览场景（@tool）
#
# 用法：在 Godot 里双击 demo/doll_preview.tscn。
#   · 视口里直接看到人偶 + 枢轴球 + 骨骼连线（由 JointDoll 的 RigOverlay 画）
#   · 选中 DollPreview，检视面板「编辑器预览」里改：
#       preview_direction 0-7  —— 换朝向（S/SW/W/NW/N/NE/E/SE）
#       preview_phase    0-1   —— 步幅相位（0.25 / 0.75 腿张得最开）
#       preview_pose           —— idle / walk / attack / hurt
#       show_rig               —— 关掉骨骼线，只看成品
#       show_rig_names         —— 再叠一层关节名（11 个关节挤在 50px 里，默认关）
#   · 场景面板里**只**会显示 DollPreview —— 关节是运行时建的，没有 owner，
#     所以不会出现在场景面板（Godot 的场景面板只列有 owner 的节点）。
#     想看关节名就打开 show_rig_names。
#   · 这套 export 在运行时被 is_editor_hint() 挡掉，不影响游戏
#
# 为什么需要它：JointDoll 的节点树是代码建的，直接把 JointDoll 拖进场景是空的
# （没 visual 就什么也画不出来）。这里在编辑器里补一份默认外观。

@tool
extends JointDoll


## 在 _init 里就填好 visual，而不是等 _ready：
## 编辑器装载场景时会先问一次「有没有配置警告」，晚一步填就会留下「缺 visual」的提示。
func _init() -> void:
	if visual == null:
		visual = CharacterVisual.from_assets()


func _ready() -> void:
	super._ready()


## 本脚本自己装配 visual，所以父类那条「visual 是空的」警告在这里不适用
func _get_configuration_warnings() -> PackedStringArray:
	return PackedStringArray()
