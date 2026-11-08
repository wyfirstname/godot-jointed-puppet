# 摆动层级探针：验证 layer_rules.json 里的 swing 规则真的按时序生效
#
# 用法：godot --headless --path . --script res://tools/swing_probe.gd
#
# 这条规则是整张 z 表里唯一**随时间变化**的部分，静帧看不出来，只能按相位扫。
# 断言：joint 角 >= deg 的那半个周期里，槽位的 z 必须等于规则给的 front/back；
#       <= deg-hysteresis 时必须回落到静态值。

extends SceneTree

var fails: Array[String] = []


func _initialize() -> void:
	var d := _make_doll()
	if d.swing_rules.is_empty():
		print("没有 swing 规则（data/layer_rules.json 的 swing 是空的）—— 跳过")
		d.free()
		quit(0)
		return
	for di in [0, 1, 2, 3, 4]:
		d.set_direction(di)
		d.play(&"walk")
		var view: int = JointDoll.DIR_TO_VIEW[di].x
		var is_back: bool = di in JointDoll.BACK_VIEW_DIRS
		var line := ""
		for i in 17:
			d._process(0.000001)
			d.phase = float(i) / 16.0
			d._process(0.000001)
			var row := ""
			for r in d.swing_rules:
				var slot := StringName(r["slot"])
				var ang: float = rad_to_deg(d._get_rot(String(r["joint"])))
				var z: int = d.z_map().get(slot, -1)
				var hot: float = float(r.get("deg", 8.0))
				var want_hi: int = int(r.get("back" if is_back else "front", z))
				var want_lo: int = d._z_static.get(slot, z)
				if ang >= hot + 0.5 and z != want_hi:
					_fail("%s %s 角%.1f° 应为 %d，实为 %d" % [
						JointDoll.VIEW_NAMES[view], slot, ang, want_hi, z])
				if ang <= hot - float(r.get("hysteresis", 4.0)) - 0.5 and z != want_lo:
					_fail("%s %s 角%.1f° 应回落到 %d，实为 %d" % [
						JointDoll.VIEW_NAMES[view], slot, ang, want_lo, z])
				row += " %s=%d(%+.0f°)" % [slot, z, ang]
			line += "\n  ph=%.2f%s" % [float(i) / 16.0, row]
		print("%s view=%d back=%s%s" % [
			["S","SW","W","NW","N"][di], view, str(is_back), line])
	d.free()
	print("")
	if fails.is_empty():
		print("==== 摆动层级全部符合规则 ====")
		quit(0)
	else:
		print("==== 失败 %d 项 ====" % fails.size())
		for f in fails:
			print("  ✗ ", f)
		quit(1)


func _fail(m: String) -> void:
	fails.append(m)


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
