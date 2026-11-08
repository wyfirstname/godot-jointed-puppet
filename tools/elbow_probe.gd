# 肘部断言：前臂的折叠方向和相位必须和真人一致
#
# 用法：godot --headless --path . --script res://tools/elbow_probe.gd
#
# 判据来自用户实机观感（tools/elbow_calib.gd 的 ±40° 定标图和实机相反，已弃用）：
#   · mode 0（侧向 SW/W/NW）：**正角** = 朝身前折。所以肘角必须恒 ≥ 0（永远不反向），
#     且弯曲量与前摆正相关（前摆弯得深、后摆仍保留 ELBOW_REST_DEG 底弯）。
#   · mode 1（正/背面 S/N）：「朝身前」是朝镜头，屏幕上用小角度内收代替：
#     左手负角（往身体中线收）、右手正角。
#
# 注意：_joint_nodes / _rot 的键必须和 JointDoll 内部写法一致（String 字面量），
# 探针里直接复用 d._get_rot()，不要自己往字典里塞键。

extends SceneTree

const REST := 20.0   # 与 JointDoll.ELBOW_REST_DEG 保持一致

var fails: Array[String] = []


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


func _pose(d: JointDoll, ph: float) -> void:
	d.phase = ph
	d._rot.clear()
	for k in d._joint_nodes.keys():
		d._rot[k] = 0.0
	d._pose_walk()
	d._apply_rot()


func _initialize() -> void:
	var d := _make_doll()
	print("--- 肘部：侧视正角朝身前折（底弯 %.0f°），正/背面小角度内收 ---" % REST)
	for view in [JointDoll.View.S, JointDoll.View.SW, JointDoll.View.W,
			JointDoll.View.NW, JointDoll.View.N]:
		d.set_direction(view)
		var is_side := int(JointDoll.PROFILE[view]["mode"]) == 0
		print("")
		var rec := {"l": [], "r": []}
		for i in 8:
			var ph := float(i) / 8.0
			_pose(d, ph)
			var line := "view=%d phase=%.3f" % [view, ph]
			for side in ["l", "r"]:
				var srot := rad_to_deg(d._get_rot("shoulder_" + side))
				var erot := rad_to_deg(d._get_rot("elbow_" + side))
				rec[side].append([srot, erot])
				line += "   %s: 肩%+6.1f° 肘%+6.1f°" % [side, srot, erot]
			print(line)
		for side in ["l", "r"]:
			var rows: Array = rec[side]
			var cov := 0.0
			var mx := -9e9
			var mn := 9e9
			for pair in rows:
				var s: float = pair[0]
				var e: float = pair[1]
				cov += s * e
				mx = maxf(mx, e)
				mn = minf(mn, e)
			if is_side:
				# 侧视：恒为正（朝身前），底弯不能丢，弯曲随前摆加深
				if mn < -0.05:
					fails.append("view=%d %s 侧出现负肘角（朝身后折）%.1f°" % [view, side, mn])
				if mx < REST - 0.5:
					fails.append("view=%d %s 侧底弯不足：最深只弯到 %.1f°（应常驻 %.0f°）" % [view, side, mx, REST])
				if cov <= 0.0:
					fails.append("view=%d %s 侧弯曲相位反了：应前摆弯得深（协方差 %+.0f）" % [view, side, cov])
			else:
				# 正/背面：左手非正、右手非负（内收方向），幅度小
				if side == "l" and mx > 0.05:
					fails.append("view=%d 左手出现正肘角（正面应往中线收=负）" % view)
				if side == "r" and mn < -0.05:
					fails.append("view=%d 右手出现负肘角（正面应往中线收=正）" % view)
				if absf(mx) > 10.0 or absf(mn) > 10.0:
					fails.append("view=%d %s 侧正面弯曲过大（%.1f°~%.1f°），正面不该有明显屈肘" % [view, side, mn, mx])
			print("   -> %s 侧：肘角 %.1f° ~ %.1f°  与肩角协方差 %+.0f" % [side, mn, mx, cov])
	d.free()

	print("")
	if fails.is_empty():
		print("==== 全部通过 ====")
		quit(0)
	else:
		print("==== 失败 %d 项 ====" % fails.size())
		for f in fails:
			print("  ✗ ", f)
		quit(1)
