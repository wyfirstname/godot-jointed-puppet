# 步态自检：正面(0) / 背面(4) 走路时，腿只能**上下**动，不许左右偏、不许转
#
# 用法：godot --headless --path . --script res://tools/gait_probe.gd
#
# 为什么要它：S/N 这两格的脚曾经是用「膝盖转 -30°」做抬脚的。屏幕平面里转小腿，
# 结果就是脚甩到腿的左边或右边、还带一个斜面 —— 朝镜头走路时最刺眼的那种错。
# 前后方向的位移投影到屏幕上只能是**缩短**。这条断言把它钉死：
#   · mode 1（正/背面）整个步态周期里，膝盖节点的 x 位移 = 0、rotation = 0；
#   · 但 y 必须有位移（不然就是没动，抬脚丢了）；
#   · mode 0（侧面）反过来要有角度，否则摆动被误删了也没人发现。

extends SceneTree

const EPS := 0.01

var fails: Array[String] = []


func _initialize() -> void:
	_check(int(JointDoll.View.S), "S", true)
	_check(int(JointDoll.View.N), "N", true)
	_check(int(JointDoll.View.W), "W", false)
	_check(int(JointDoll.View.SW), "SW", false)
	print("")
	if fails.is_empty():
		print("==== 全部通过 ====")
		quit(0)
	else:
		print("==== 失败 %d 项 ====" % fails.size())
		for f in fails:
			print("  ✗ ", f)
		quit(1)


func _make_doll() -> JointDoll:
	var vis := CharacterVisual.new()
	for slot in JointDoll.SLOT_JOINT.keys():
		var p := PartDef.new()
		p.slot = slot
		p.id = slot
		vis.equip(slot, p)
	var d := JointDoll.new()
	d._build_tree()
	d.visual = vis
	d._rebuild_parts()
	return d


func _check(view: int, label: String, want_fixed: bool) -> void:
	var d := _make_doll()
	d.set_direction(view)
	d.play(&"walk")

	var xs := {"knee_l": [], "knee_r": []}
	var ys := {"knee_l": [], "knee_r": []}
	var rots: Array[float] = []
	var N := 24
	for i in N:
		d.phase = float(i) / float(N)
		d._process(0.000001)
		for k in ["knee_l", "knee_r"]:
			var n: Node2D = d._joint_nodes[k]
			xs[k].append(n.get_global_transform().origin.x)
			ys[k].append(n.get_global_transform().origin.y)
			rots.append(absf(n.rotation))

	var spread_x := 0.0
	var spread_y := 0.0
	for k in ["knee_l", "knee_r"]:
		spread_x = maxf(spread_x, _range(xs[k]))
		spread_y = maxf(spread_y, _range(ys[k]))
	var max_rot := 0.0
	for r in rots:
		max_rot = maxf(max_rot, r)

	print("%-3s 膝盖 x 位移 %6.3f px   y 位移 %6.3f px   最大转角 %6.2f°" % [
		label, spread_x, spread_y, rad_to_deg(max_rot)])

	if want_fixed:
		# 正/背面：x 和转角必须为 0（脚正对镜头、居中不偏），y 必须有位移（抬脚还在）
		if spread_x > EPS:
			fails.append("%s：脚左右偏移 %.2fpx（正/背面走路脚只能上下动）" % [label, spread_x])
		if max_rot > EPS:
			fails.append("%s：腿有 %.2f° 转角（屏幕平面内旋转 = 脚被甩歪）" % [
				label, rad_to_deg(max_rot)])
		if spread_y < 3.0:
			fails.append("%s：抬脚高度只有 %.2fpx，等于没抬" % [label, spread_y])
	else:
		# 侧面/斜角：必须有前后摆动，否则是把摆动误删了
		if spread_y < 3.0:
			fails.append("%s：没有抬脚/摆动（%.2fpx）" % [label, spread_y])
		if max_rot < 1.0 and spread_x < 1.0:
			fails.append("%s：腿既没有角度也没有位移，摆动丢失" % label)
	d.free()


func _range(v: Array) -> float:
	var lo: float = v[0]
	var hi: float = v[0]
	for x in v:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return hi - lo
