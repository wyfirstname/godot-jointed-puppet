## 骨架编辑器：让 JointDoll 在 Godot 编辑器里"能编辑"
#
# 为什么需要它：JointDoll 的 11 个关节节点是在 _ready() 里用代码 add_child 出来的，
# **没有 owner**。Godot 的场景面板只列有 owner 的节点，所以：
#   · 场景面板里看不到 hip / chest / shoulder_l …，选不中；
#   · 视口里点它也不会被选中（没有可拾取的节点）；
#   · 于是除了根节点上那 5 个 preview_* 属性，什么都改不了。
# 这正是"打开 Godot 却无法编辑"的全部原因 —— 不是脚本坏了，是缺一层编辑器外壳。
#
# 这个插件补的就是那层外壳，两条路都通：
#   1. 视口手柄：选中 JointDoll 后，每个枢轴上画一个圆点，按住拖动 = 旋转该关节
#      （Shift 吸附 5°，Alt+点击 单个归零）。旋转是父子级联的，拖肩会带着整条胳膊走。
#   2. 右侧停靠面板：下拉选关节 + 滑杆精调、归零、把当前姿势导出成 JSON。
# 手柄画在 _forward_canvas_draw_over_viewport 里，不依赖任何节点，所以不会污染 .tscn。

@tool
extends EditorPlugin

const SNAP_STEP_DEG := 5.0
const HANDLE_PX := 5.0        ## 手柄半径（屏幕像素，不随缩放变化）
const HIT_PX := 11.0          ## 命中半径（屏幕像素）

const C_HANDLE := Color(0.30, 0.85, 1.0, 0.95)
const C_ACTIVE := Color(1.0, 0.62, 0.20)
const C_BONE := Color(0.30, 0.85, 1.0, 0.40)

var _doll: JointDoll = null
var _overlay: Control = null
var _visible := true

var _hover := ""
var _drag := ""
var _drag_axis := 0.0         ## 按下瞬间「枢轴 → 鼠标」的角度
var _drag_angle := 0.0        ## 按下瞬间该关节的旋转

# ---- 停靠面板 ----
var _dock: VBoxContainer = null
var _pick: OptionButton = null
var _slider: HSlider = null
var _val: Label = null
var _btn_zero: Button = null
var _syncing := false


func _enter_tree() -> void:
	_build_dock()


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


# ---------------------------------------------------------------- 接管选中

func _handles(object: Object) -> bool:
	return object is JointDoll


func _edit(object: Object) -> void:
	_doll = object as JointDoll
	_hover = ""
	_drag = ""
	if _doll != null and not _doll.editor_pose_changed.is_connected(_on_pose_changed):
		_doll.editor_pose_changed.connect(_on_pose_changed)
	_sync_dock()
	_request_redraw()


func _make_visible(visible: bool) -> void:
	_visible = visible
	if not visible:
		_drag = ""
		_hover = ""
	_request_redraw()


func _on_pose_changed() -> void:
	_sync_slider()


# ---------------------------------------------------------------- 视口手柄

func _forward_canvas_draw_over_viewport(overlay: Control) -> void:
	_overlay = overlay
	if not _visible or not _ready_for_draw():
		return

	var zoom := _zoom(overlay)
	var r: float = HANDLE_PX / zoom
	var lw: float = 1.0 / zoom
	var font := ThemeDB.fallback_font
	var fsize: int = maxi(8, int(round(12.0 / zoom)))

	for entry in JointDoll.JOINTS:
		var jname: String = entry[0]
		var parent_name: String = entry[1]
		var p: Vector2 = _doll.editor_joint_global_pos(jname)
		if parent_name != "":
			var pp: Vector2 = _doll.editor_joint_global_pos(parent_name)
			overlay.draw_line(pp, p, C_BONE, lw, true)
		var active: bool = jname == _drag or jname == _hover
		var col: Color = C_ACTIVE if active else C_HANDLE
		overlay.draw_circle(p, r, col)
		overlay.draw_circle(p, r * 0.42, Color(0.05, 0.07, 0.10, 0.85))
		overlay.draw_arc(p, r * 1.9, 0.0, TAU, 24, Color(col, 0.35 if not active else 0.85), lw, true)
		if active:
			var txt := "%s  %.1f°" % [jname, rad_to_deg(_doll.editor_joint_angle(jname))]
			overlay.draw_string(font, p + Vector2(r * 2.6, -r * 1.4), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fsize,
				Color(1.0, 0.80, 0.35) if jname == _drag else Color(0.75, 0.95, 1.0))


func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if not _ready_for_draw():
		return false
	if OS.get_environment("RIGED_DEBUG") != "":
		print("[RigEd] ev=%s pos=%s" % [event.get_class(),
			str(event.position) if event is InputEventMouse else "-"])

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var w := _to_world(event.position)
		if event.pressed:
			var hit := _pick_joint(w)
			if OS.get_environment("RIGED_DEBUG") != "":
				print("[RigEd] press world=%s hit='%s'" % [w, hit])
			if hit == "":
				return false
			if event.alt_pressed:
				_doll.editor_set_joint_angle(hit, 0.0)
				_select_in_dock(hit)
				return true
			_drag = hit
			_drag_angle = _doll.editor_joint_angle(hit)
			_drag_axis = (w - _doll.editor_joint_global_pos(hit)).angle()
			_select_in_dock(hit)
			_request_redraw()
			return true
		if _drag != "":
			_drag = ""
			_request_redraw()
			return true
		return false

	if event is InputEventMouseMotion:
		var w2 := _to_world(event.position)
		if _drag != "":
			if OS.get_environment("RIGED_DEBUG") != "":
				print("[RigEd] drag world=%s" % w2)
			var pivot := _doll.editor_joint_global_pos(_drag)
			var cur := (w2 - pivot).angle()
			var next: float = _drag_angle + angle_difference(_drag_axis, cur)
			if event.shift_pressed:
				next = deg_to_rad(snappedf(rad_to_deg(next), SNAP_STEP_DEG))
			_doll.editor_set_joint_angle(_drag, next)
			_request_redraw()
			return true
		var h := _pick_joint(w2)
		if h != _hover:
			_hover = h
			_request_redraw()
	return false


# ---------------------------------------------------------------- 坐标 / 命中

func _ready_for_draw() -> bool:
	if _doll == null or not is_instance_valid(_doll) or not _doll.is_inside_tree():
		return false
	return not _doll._joint_nodes.is_empty()


## 视口像素 → 画布坐标。event.position 是视口局部坐标，canvas_transform 是画布→视口的变换
func _to_world(p: Vector2) -> Vector2:
	var vp := _doll.get_viewport()
	if vp == null:
		return p
	return vp.get_canvas_transform().affine_inverse() * p


func _zoom(overlay: Control) -> float:
	return maxf(overlay.get_global_transform_with_canvas().get_scale().x, 0.001)


func _pick_joint(world: Vector2) -> String:
	var vp := _doll.get_viewport()
	var z := 1.0
	if vp != null:
		z = maxf(vp.get_canvas_transform().get_scale().x, 0.001)
	var r: float = HIT_PX / z
	var best := ""
	var best_d := r
	for entry in JointDoll.JOINTS:
		var jname: String = entry[0]
		var d: float = world.distance_to(_doll.editor_joint_global_pos(jname))
		if d <= best_d:
			best_d = d
			best = jname
	return best


func _request_redraw() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_redraw()


# ---------------------------------------------------------------- 停靠面板

func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "骨架姿势"

	var tip := Label.new()
	tip.text = "选中 JointDoll / DollPreview → 视口里拖圆点旋转关节\nShift 吸附 5° · Alt+点击 单个归零"
	tip.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	_dock.add_child(tip)

	var row1 := HBoxContainer.new()
	var l1 := Label.new()
	l1.text = "关节"
	row1.add_child(l1)
	_pick = OptionButton.new()
	_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick.item_selected.connect(_on_pick)
	row1.add_child(_pick)
	_dock.add_child(row1)

	var row2 := HBoxContainer.new()
	_slider = HSlider.new()
	_slider.min_value = -180.0
	_slider.max_value = 180.0
	_slider.step = 0.5
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.value_changed.connect(_on_slider)
	row2.add_child(_slider)
	_val = Label.new()
	_val.text = "—"
	_val.custom_minimum_size = Vector2(56, 0)
	_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row2.add_child(_val)
	_dock.add_child(row2)

	var row3 := HBoxContainer.new()
	_btn_zero = Button.new()
	_btn_zero.text = "本关节归零"
	_btn_zero.pressed.connect(_on_zero_one)
	row3.add_child(_btn_zero)
	var b2 := Button.new()
	b2.text = "全部归零"
	b2.pressed.connect(_on_zero_all)
	row3.add_child(b2)
	_dock.add_child(row3)

	var row4 := HBoxContainer.new()
	var b3 := Button.new()
	b3.text = "导出姿势 JSON"
	b3.pressed.connect(_on_export)
	row4.add_child(b3)
	_dock.add_child(row4)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_sync_dock()


func _joint_names() -> Array:
	var out := []
	for entry in JointDoll.JOINTS:
		out.append(String(entry[0]))
	return out


func _sync_dock() -> void:
	if _pick == null:
		return
	var names := _joint_names()
	var same: bool = _pick.item_count == names.size()
	if same:
		for i in names.size():
			if _pick.get_item_text(i) != names[i]:
				same = false
				break
	if not same:
		_pick.clear()
		for n in names:
			_pick.add_item(n)
	if _pick.item_count > 0 and _pick.selected < 0:
		_pick.selected = 0
	_sync_slider()


func _sync_slider() -> void:
	if _slider == null or _val == null:
		return
	var jname := _selected_joint()
	var has: bool = _doll != null and jname != ""
	_slider.editable = has
	if _btn_zero != null:
		_btn_zero.disabled = not has
	if not has:
		_val.text = "—"
		return
	var deg: float = rad_to_deg(_doll.editor_joint_angle(jname))
	_syncing = true
	_slider.value = clampf(deg, -180.0, 180.0)
	_syncing = false
	_val.text = "%.1f°" % deg


func _selected_joint() -> String:
	if _pick == null or _pick.item_count == 0 or _pick.selected < 0:
		return ""
	return _pick.get_item_text(_pick.selected)


func _select_in_dock(jname: String) -> void:
	if _pick == null:
		return
	for i in _pick.item_count:
		if _pick.get_item_text(i) == jname:
			_pick.selected = i
			break
	_sync_slider()


func _on_pick(_idx: int) -> void:
	_sync_slider()
	_request_redraw()


func _on_slider(v: float) -> void:
	if _syncing or _doll == null:
		return
	var jname := _selected_joint()
	if jname == "":
		return
	_doll.editor_set_joint_angle(jname, deg_to_rad(v))
	_val.text = "%.1f°" % v
	_request_redraw()


func _on_zero_one() -> void:
	if _doll == null:
		return
	var jname := _selected_joint()
	if jname != "":
		_doll.editor_set_joint_angle(jname, 0.0)
		_request_redraw()


func _on_zero_all() -> void:
	if _doll == null:
		return
	_doll.editor_clear_pose()
	_sync_slider()
	_request_redraw()


func _on_export() -> void:
	if _doll == null:
		print("[Rig Editor] 没选中 JointDoll，无从导出")
		return
	var payload := {
		"_note": "在 Godot 里手动摆的姿势（角度制）。关节名对应 JointDoll.JOINTS",
		"_scene": _doll.scene_file_path if _doll.scene_file_path != "" else "",
		"joints": _doll.editor_pose_degrees(),
	}
	var f := FileAccess.open("res://data/pose.json", FileAccess.WRITE)
	if f == null:
		push_warning("[Rig Editor] 写 data/pose.json 失败：%s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	print("[Rig Editor] 已写出 res://data/pose.json（%d 个关节）" % (payload["joints"] as Dictionary).size())
