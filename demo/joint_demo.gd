# 演示：关节人偶（对应参考视频开发日记 2 的实际做法）
#
# 环形 8 只 = 8 个方向，按视频的椭圆布局摆放，验证「5 张图 + 镜像」与「逐方向 z 序」
# 下排 1 只 = 来回巡逻 + 走走停停，用来看头发/披风的弹簧惯性
#
# 操作：空格 开关弹簧    1-8 指定巡逻角色方向    J 攻击    K 受击
#      --shot 参数启动则截图后退出
#
# @tool：打开 joint_demo.tscn 时编辑器里也能看到这 8 个方向。
# 编辑器里只建一次环、摆固定相位，不跑巡逻/输入/HUD。

@tool
extends Node2D

const DIR_NAMES := ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]

## ── 八方向环（复刻参考视频开发日记 2 的展示布局）───────────────────────
## 视频里 8 个方向不是排成一行，而是摆在一个「被压扁的圆」上：
## 上下两个（N/S）贴在竖直中轴，左右两个（W/E）拉到最外，四个斜向落在椭圆上。
## 这正是俯视等角投影 —— 地上一个半径 R 的圆，屏幕 y 方向被压扁 k 倍。
## 实测视频帧（1280×720）：中轴 ±0，左右 ±456，上下 −130/+140，即 k ≈ 0.30。
const RING_CENTER := Vector2(640.0, 358.0)
const RING_RX := 452.0
const RING_RY := 132.0
const RING_SCALE := 0.76
## 角色显示高度（贴图内容 181px × RING_SCALE）—— 用来让虚线和标签避开身体
const PAWN_H := 138.0
## 方向编号 -> 椭圆参数角（度）。E=0°，N=90°，按 DIR_NAMES 顺序每格 45°
const RING_T := [270.0, 225.0, 180.0, 135.0, 90.0, 45.0, 0.0, 315.0]


## 方向 -> 环上坐标。用椭圆参数化，而不是均匀角度：
## 直接按 45° 摆成圆环会让斜向四个贴在上下两个旁边，看起来像「一堆」而不是「一圈」。
func _ring_pos(dir: int) -> Vector2:
	var t := deg_to_rad(RING_T[dir])
	return RING_CENTER + Vector2(cos(t) * RING_RX, -sin(t) * RING_RY)
## 槽位列表已挪到 CharacterVisual.DEFAULT_SLOTS（装配默认外观的静态方法要用它）。

var dolls: Array[JointDoll] = []
var _tags: Array[Label] = []
var hero: JointDoll
var hud: Label
var shot_mode := false

var px := 640.0
var moving := true
var timer := 0.0
var dirsign := 1
var spring_on := true
var tags_on := true
var strip_mode := false   # --strip：拍一组"急停瞬间头发甩动"的连续帧
var pose_mode := false    # --phase=：8 方向姿势表（不出环、不出巡逻角色）
var freeze := false       # --attack：定住巡逻，只看攻击姿势

## O 键轮换的三套服装。键名和 tools/character_designer.html 的部件库一致：
## 变体名是「槽位_变体_puppet_视图.png」里的那一段，空串 = 摘掉
const OUTFIT_CYCLE := [
	{"n": "骑士", "key": "knight", "outfit": {}},
	{"n": "法师长袍", "key": "robe", "outfit": {"body": "robe", "arm_l": "robe",
		"arm_r": "robe", "fore_l": "robe", "fore_r": "robe",
		"hat": "wizard", "cape": ""}},
	{"n": "游侠皮甲", "key": "ranger", "outfit": {"body": "leather",
		"arm_l": "leather", "arm_r": "leather", "fore_l": "leather",
		"fore_r": "leather", "shin_l": "boot", "shin_r": "boot",
		"hat": "hood", "cape": ""}},
]
var outfit_idx := 0
var expr_override := &""  # --expr=：启动时指定表情；空 = neutral

## 表情循环顺序（E 键切换）。与 tools/gen_joint_art.py::FACE_EXPR 一致
const EXPR_CYCLE: Array[StringName] = [
	&"neutral", &"smile", &"angry", &"sad", &"surprise", &"blink",
]
var hero_off: JointDoll    # 对照组：弹簧关


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_editor_preview()
		return
	RenderingServer.set_default_clear_color(Color(0.90, 0.91, 0.94))
	shot_mode = "--shot" in OS.get_cmdline_user_args()
	strip_mode = "--strip" in OS.get_cmdline_user_args()

	# 置顶预览：从命令行/别的进程拉起来时，窗口容易被日志窗口或编辑器挡住。
	# 只在显式 --ontop 时生效，正常游玩不受影响。
	if "--ontop" in OS.get_cmdline_user_args():
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)

	# 姿势表：8 个方向 × 一个固定相位，只用来量「胳膊到底在身前还是身后」。
	# 相位由 --phase= 给定，一次一张，外部再拼成网格（tools/pose_sheet.py）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--phase="):
			pose_mode = true
			_pose_sheet(float(a.substr(8)))
			return
		if a.begins_with("--expr="):
			expr_override = StringName(a.substr(7))
		# --outfit=robe / --outfit=ranger：启动时直接穿好一套，供截图验证
		if a.begins_with("--outfit="):
			var on := a.substr(9)
			for i in OUTFIT_CYCLE.size():
				if OUTFIT_CYCLE[i]["n"] == on or OUTFIT_CYCLE[i].get("key", "") == on:
					outfit_idx = i

	if not strip_mode:
		_build_ring()

	# 下排：巡逻角色
	hero = _new_hero(Vector2(px, 676.0), true, 200)
	# 服装必须在 hero 建好之后穿（set_outfit 依赖 visual 已装配）
	if outfit_idx != 0:
		hero.set_outfit(OUTFIT_CYCLE[outfit_idx]["outfit"])

	hud = Label.new()
	hud.position = Vector2(24, 14)
	hud.add_theme_font_size_override("font_size", 20)
	hud.add_theme_color_override("font_color", Color(0.15, 0.15, 0.2))
	add_child(hud)

	if strip_mode:
		# 对照组：同一位置、同一套动作，只把弹簧关掉
		hero_off = _new_hero(Vector2(px, 400.0), false, 300)
		_strip()
	elif "--selftest" in OS.get_cmdline_user_args():
		_selftest()
	elif shot_mode:
		_shot_later(1.05)


## 八方向环：8 只各占一个方向，位置按视频的椭圆布局摆。
## 配色统一 —— 视频里这 8 只是同一个角色转出来的，同色才能一眼看出「差的是朝向，不是人」
## tints 是打包参数：r = hue_shift + 0.5，g = sat_mul，b = val_mul。
## 红披风转青（互补色）= hue_shift +0.5 -> r 填 1.0
func _build_ring(tint: Color = Color(1.0, 1.0, 1.0)) -> void:
	for c in dolls:
		if is_instance_valid(c):
			c.queue_free()
	dolls.clear()
	for i in 8:
		var d := JointDoll.new()
		d.name = "Dir%d" % i
		d.position = _ring_pos(i)
		d.scale = Vector2(RING_SCALE, RING_SCALE)
		# 环上靠下的先画：两只若碰上，下面那只盖住上面那只，和真实透视一致
		d.z_base = 300 + int(d.position.y)
		d.spring_enabled = false
		add_child(d)
		d.visual = _make_visual(tint)
		d.set_direction(i)
		d.play(&"walk")
		d.stride_time = 0.78
		dolls.append(d)
	_add_ring_tags()


## 编辑器里的样子：不跑巡逻、不读命令行、不建 HUD，只把 8 个方向摆出来。
## 相位固定 0.25（两条腿张开最大的瞬间），方便对着枢轴看层级。
func _build_editor_preview() -> void:
	_build_ring()
	queue_redraw()


## 每个方向脚下标名字。镜像出来的三个用蓝色 —— 视频那句「左边三个，是右边翻过来的」
## 在画面上没有标记，只能靠看；这里直接标出来，便于逐格核对。
func _add_ring_tags() -> void:
	for t in _tags:
		if is_instance_valid(t):
			t.queue_free()
	_tags.clear()
	for i in 8:
		var mirrored: bool = JointDoll.DIR_TO_VIEW[i].y == 1
		var l := Label.new()
		l.text = DIR_NAMES[i]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.custom_minimum_size = Vector2(120.0, 20.0)
		l.size = Vector2(120.0, 20.0)
		l.position = _ring_pos(i) + Vector2(-60.0, 14.0)
		l.z_index = 2000
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color",
			Color(0.28, 0.44, 0.80) if mirrored else Color(0.14, 0.15, 0.22))
		add_child(l)
		_tags.append(l)


## 地面：中央镜像轴 + 每个方向脚下的光环。
## 角色 z_base >= 300，所以这些线统统压在角色下面 —— 和视频里虚线被身体挡住一样。
func _draw() -> void:
	if pose_mode:
		return   # 姿势表不需要地面和虚线，免得压在角色下面误导判断
	# 竖虚线只走在 N 的脚底和 S 的头顶之间 —— 视频里它正是这两只之间那一段
	var x := RING_CENTER.x
	var y0 := RING_CENTER.y - RING_RY + 8.0
	var y1 := RING_CENTER.y + RING_RY - PAWN_H + 6.0
	var col := Color(0.38, 0.58, 0.95, 0.60)
	var y := y0
	while y < y1:
		draw_line(Vector2(x, y), Vector2(x, minf(y + 10.0, y1)), col, 2.0)
		y += 18.0
	for i in 8:
		var p := _ring_pos(i) + Vector2(0.0, 4.0)
		draw_set_transform(p, 0.0, Vector2(1.0, 0.30))
		draw_circle(Vector2.ZERO, 36.0, Color(0.52, 0.70, 1.0, 0.20))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _new_hero(pos: Vector2, spring: bool, zb: int) -> JointDoll:
	var d := JointDoll.new()
	d.position = pos
	d.scale = Vector2(0.50, 0.50)
	d.z_base = zb
	d.spring_enabled = spring
	add_child(d)
	d.visual = _make_visual(Color(0.60, 1.05, 1.0))
	d.set_direction(6)
	d.play(&"walk")
	return d


func _make_visual(tint: Color, tint_hair: bool = false) -> CharacterVisual:
	# 一份完整外观 = 15 个槽位 × 5 视图，装配逻辑在 CharacterVisual.from_assets()
	# （编辑器预览和运行时共用同一份，不会一边有一套）
	var vis := CharacterVisual.from_assets(tint,
			expr_override if expr_override != &"" else &"neutral")
	if tint_hair:
		vis.tints[&"hair_front"] = Color(tint.r, tint.g * 0.9, tint.b * 0.95)
		vis.tints[&"hair_back"] = Color(tint.r, tint.g * 0.9, tint.b * 0.95)
	return vis


func _process(delta: float) -> void:
	# 编辑器里由 JointDoll 自己按 preview_phase 摆姿势，这里不驱动
	if Engine.is_editor_hint():
		return
	if hero == null:
		return   # --phase 姿势表模式：没有巡逻角色
	_handle_input()
	_patrol(delta)

	hud.text = "方向 %d (%s)   动作 %s   弹簧 %s   头发弹簧 %s   阻尼 %.1f   表情 %s   服装 %s\n空格 开关弹簧    H 头发弹簧    1-8 方向    J 攻击    K 受击    E 表情    O 服装    环形 = 8 个方向    L 标签" % [
		hero.direction, DIR_NAMES[hero.direction], hero.action,
		"开" if spring_on else "关", "开" if hero.spring_on_hair else "关",
		hero.spring_damping, hero.visual.expression,
		OUTFIT_CYCLE[outfit_idx]["n"],
	]


func _patrol(delta: float) -> void:
	if freeze:
		return
	if strip_mode:
		# 先匀速走 1 秒，然后瞬间停住 —— 和视频里"身体停了，头发不该马上跟着停"同一个测试
		timer += delta
		if timer < 1.0:
			px += 105.0 * delta
			hero.position.x = px
			hero.play(&"walk")
			if hero_off != null:
				hero_off.position.x = px
				hero_off.play(&"walk")
		return

	timer += delta
	if not moving:
		hero.play(&"idle")
		if timer > 0.85:
			moving = true
			timer = 0.0
			dirsign = -dirsign
			hero.set_direction(6 if dirsign > 0 else 2)
			hero.play(&"walk")
		return

	px += dirsign * 105.0 * delta
	if px < 180.0:
		px = 180.0
		moving = false
		timer = 0.0
	elif px > 1100.0:
		px = 1100.0
		moving = false
		timer = 0.0
	elif timer > 1.5:
		moving = false
		timer = 0.0
	hero.position.x = px


func _handle_input() -> void:
	if _space_edge():
		spring_on = not spring_on
		hero.spring_enabled = spring_on
	if _edge(KEY_H):
		hero.spring_on_hair = not hero.spring_on_hair
	if _edge(KEY_L):
		tags_on = not tags_on
		for t in _tags:
			t.visible = tags_on
	if _edge(KEY_E):
		# 循环表情：换的只是 face 槽位那张图，头骨头发都不动
		var i := EXPR_CYCLE.find(hero.visual.expression)
		hero.set_expression(EXPR_CYCLE[(i + 1) % EXPR_CYCLE.size()])
	if _edge(KEY_O):
		# 循环服装：骑士（默认）→ 法师长袍 → 游侠皮甲。
		# 和表情同一个机制（变体槽换贴图），整槽位重装，tints/表情保留
		outfit_idx = (outfit_idx + 1) % OUTFIT_CYCLE.size()
		hero.set_outfit(OUTFIT_CYCLE[outfit_idx]["outfit"])
	for k in 8:
		if Input.is_key_pressed(KEY_1 + k):
			hero.set_direction(k)
	if Input.is_key_pressed(KEY_J):
		hero.play(&"attack")
	if Input.is_key_pressed(KEY_K):
		hero.play(&"hurt")


var _space_was := false
var _edge_state := {}


func _space_edge() -> bool:
	var now := Input.is_key_pressed(KEY_SPACE)
	var edge := now and not _space_was
	_space_was = now
	return edge


func _edge(key: int) -> bool:
	var now := Input.is_key_pressed(key)
	var was: bool = _edge_state.get(key, false)
	_edge_state[key] = now
	return now and not was


func _strip() -> void:
	await get_tree().create_timer(1.0).timeout
	for i in 12:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://demo/strip_%02d.png" % i)
		print("t=%02d  头发:%s  披风:%.1f°" % [
			i,
			"刚性 0.0°" if not hero.spring_on_hair else "%.1f°" % hero.spring_angle_deg(&"hair_back"),
			hero.spring_angle_deg(&"cape")])
		await get_tree().create_timer(0.04).timeout
	print("strip saved")
	get_tree().quit()


func _shot_later(wait: float) -> void:
	if "--attack" in OS.get_cmdline_user_args():
		freeze = true
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--dir="):
				hero.set_direction(int(a.substr(6)))
		hero.play(&"attack")
		for i in 7:
			await get_tree().create_timer(0.025).timeout
			await RenderingServer.frame_post_draw
			var f := get_viewport().get_texture().get_image()
			f.save_png("res://demo/atk_%02d.png" % i)
			var sh := hero.find_child("shoulder_r", true, false) as Node2D
			var wp := hero.find_child("weapon", true, false) as Sprite2D
			if sh != null and wp != null:
				# 剑尖：sprite 局部坐标 = 画布点 - 枢轴，再乘上 sprite 自己的变换
				print("i=%d dir=%d scale.x=%+.0f rot=%+.1f°  肩=%s  剑sp=%s" % [
					i, hero.direction, hero.scale.x, rad_to_deg(sh.rotation),
					str(sh.global_position.round()), str(wp.global_position.round())])
		print("attack 7 frames saved")
		get_tree().quit()
		return
	await get_tree().create_timer(wait).timeout
	await RenderingServer.frame_post_draw
	if "--dump" in OS.get_cmdline_user_args():
		_dump(dolls[4] if dolls.size() > 4 else hero)
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://demo/shot_joint.png")
	print("screenshot saved")
	get_tree().quit()


func _dump(d: JointDoll) -> void:
	for n in d.find_children("*", "Sprite2D", true, false):
		var sp := n as Sprite2D
		var m := sp.material as ShaderMaterial
		if m == null:
			continue
		print("%-12s hue=%+.3f sat=%.2f val=%.2f" % [sp.name,
			m.get_shader_parameter("hue_shift"),
			m.get_shader_parameter("sat_mul"),
			m.get_shader_parameter("val_mul")])


## 自检：头发默认刚性（不挂弹簧），披风挂；开关切换不崩
func _selftest() -> void:
	await get_tree().create_timer(0.4).timeout
	print("== 弹簧槽位自检 ==")
	print("默认         : %s   (spring_on_hair=%s)" % [hero.spring_slots(), hero.spring_on_hair])
	hero.spring_on_hair = true
	await get_tree().process_frame
	print("打开头发弹簧 : %s" % [hero.spring_slots()])
	await get_tree().create_timer(0.8).timeout
	print("  走 0.8s 后 hair_back = %.2f°" % hero.spring_angle_deg(&"hair_back"))
	hero.spring_on_hair = false
	await get_tree().process_frame
	print("关回来       : %s" % [hero.spring_slots()])
	await get_tree().create_timer(0.3).timeout
	print("  0.3s 后     : %s" % [hero.spring_slots()])
	get_tree().quit()


## 姿势表：8 个方向横排，全部冻在同一个相位上。
##
## 存这张表是为了"胳膊在身前还是身后"能被量出来、而不是靠看：
## 相位固定后，每只的肩角是确定的，于是「谁该压过躯干」也就确定了。
func _pose_sheet(ph: float) -> void:
	# 披风不染色（tints 的 r 是 hue_shift+0.5，0.5 就是不偏色）——
	# 姿势表是用来核对"谁盖住谁"的，颜色一变红披风就认不出来了
	var vis := _make_visual(Color(0.5, 1.0, 1.0))
	var dx := 300.0
	var dy := 350.0
	for i in 8:
		var d := JointDoll.new()
		d.position = Vector2(150.0 + (i % 4) * dx, 290.0 + (i / 4) * dy)
		d.scale = Vector2(1.0, 1.0)
		d.z_base = 10
		d.spring_enabled = false
		add_child(d)
		d.visual = vis
		d.set_direction(i)
		d.play(&"walk")
		d.phase = ph
		d._process(0.000001)
		d.set_process(false)   # 冻住，别再自己推进相位
		var l := Label.new()
		l.text = DIR_NAMES[i]
		l.position = Vector2(150.0 + (i % 4) * dx - 30.0, 290.0 + (i / 4) * dy - 200.0)
		l.add_theme_font_size_override("font_size", 18)
		l.add_theme_color_override("font_color", Color(0.1, 0.1, 0.15))
		add_child(l)
		# 顺便把肩角打出来：这是判断"手朝前还是朝后"的唯一依据
		var sl: Node2D = d._joint_nodes["shoulder_l"]
		var sr: Node2D = d._joint_nodes["shoulder_r"]
		print("%-2s near=%-1s  肩L=%+6.1f°  肩R=%+6.1f°  arm_l z=%d arm_r z=%d body z=%d" % [
			DIR_NAMES[i], str(JointDoll.NEAR_SIDE[JointDoll.DIR_TO_VIEW[i].x]),
			rad_to_deg(sl.rotation), rad_to_deg(sr.rotation),
			d.z_map().get(&"arm_l", -1), d.z_map().get(&"arm_r", -1),
			d.z_map().get(&"body", -1)])
	await get_tree().create_timer(0.25).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://demo/pose_%03d.png" % int(round(ph * 100.0)))
	print("pose sheet saved: phase=%.2f" % ph)
	get_tree().quit()
