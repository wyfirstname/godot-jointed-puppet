# 把「每个视图 × 每个槽位」的 z 写到 data/layer_rules.json
#
# 用法：godot --headless --path . --script res://tools/dump_layers.gd
#
# 为什么要有这一步：SLOT_Z / LIMB_Z / NEAR_SIDE / Z_ON_BACK / ARM_Z_ON_BACK 是**规则**，
# 它们推导出来的是一张 5×26 的结果矩阵。改前后关系时去动那五张表（还是互相耦合的），
# 很容易改出一对矛盾的格子；直接编辑结果矩阵就只是"把这块挪到那块前面"。
#
# 所以：规则留在代码里当默认值，结果矩阵外置成 JSON 供设计器编辑。
# 改了规则（加槽位、改近远）之后重跑一次这个脚本刷新基线。
#
# ⚠ 重跑会**覆盖** JSON 里所有手工调整 —— 特别是这几个没有对应规则项、
# 只存在于结果矩阵里的格子：sw/se 的远臂(1/1/1)、nw/n 的双臂+肩球(21/20/21)。
# ARM_Z_ON_BACK 已同步成同样的值，所以重跑后这些格子不会变，但改过
# 设计器里的其它格子就会被抹掉。改完记得用 git diff 核对。

extends SceneTree


func _initialize() -> void:
	# 先临时挪开外部表，才能拿到"纯推导"的结果 —— 否则会把外部表原样吐回去
	var path := JointDoll.LAYER_RULES_PATH
	var backup := ""
	if FileAccess.file_exists(path):
		backup = FileAccess.get_file_as_string(path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var out := {}
	for vi in 5:
		var d := _make_doll()
		d.set_direction(vi)      # 0..4 恰好对应 5 个视图
		var row := {}
		for slot in JointDoll.SLOT_Z.keys():
			row[String(slot)] = int(d.z_map().get(slot, 0))
		out[JointDoll.VIEW_NAMES[vi]] = row
		d.free()

	# 恢复外部表：它是用户的编辑结果，不能被工具顺手删掉
	if backup != "":
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(backup)
			f.close()

	# 摆动规则原样保留（dump 只管静态矩阵）
	var swing: Array = []
	if backup != "":
		var old: Variant = JSON.parse_string(backup)
		if typeof(old) == TYPE_DICTIONARY and old.get("swing") is Array:
			swing = old["swing"]

	var doc := {
		"version": 1,
		"generated_by": "tools/dump_layers.gd",
		"note": "前后关系（z 序）的唯一可编辑副本。用 tools/layer_designer.html 编辑，改完跑 tools/zdump.gd 校验。数字越大越靠近镜头。",
		"views": JointDoll.VIEW_NAMES.duplicate(),
		"z": out,
		"swing": swing,
		"_rig": _rig_snapshot(),
	}
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	if f2 == null:
		print("写不了 %s" % path)
		quit(1)
		return
	f2.store_string(JSON.stringify(doc, "  "))
	f2.close()
	print("写出 %s：%d 视图 × %d 槽位，swing 规则 %d 条" % [
		path, out.size(), (out["s"] as Dictionary).size(), swing.size()])
	quit(0)


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


## 骨架快照：设计器要在浏览器里复现同一套姿态，需要关节表 / 槽位挂点 / 步态参数。
## 带下划线前缀表示「生成物，别手改」；设计器导出时会原样带回去。
func _rig_snapshot() -> Dictionary:
	var joints: Array = []
	for e in JointDoll.JOINTS:
		joints.append({
			"name": String(e[0]),
			"parent": String(e[1]),
			"pos": [float(e[2].x), float(e[2].y)],
		})
	var slot_joint := {}
	for slot in JointDoll.SLOT_JOINT.keys():
		slot_joint[String(slot)] = String(JointDoll.SLOT_JOINT[slot])
	var near := {}
	var prof := {}
	for vi in 5:
		var v: int = JointDoll.View.values()[vi]
		near[JointDoll.VIEW_NAMES[vi]] = String(JointDoll.NEAR_SIDE.get(v, ""))
		var p: Dictionary = JointDoll.PROFILE[v]
		prof[JointDoll.VIEW_NAMES[vi]] = {
			"leg": float(p.leg), "arm": float(p.arm), "bob": float(p.bob),
			"knee": float(p.knee), "lift": float(p.get("lift", 0.0)), "mode": int(p.mode),
		}
	var dirs: Array = []
	for di in 8:
		var m: Vector2i = JointDoll.DIR_TO_VIEW[di]
		dirs.append([m.x, m.y])
	# 默认 z 从大到小：表格初始就是这个顺序（前面的在上）
	var slots: Array = JointDoll.SLOT_Z.keys().map(func(x): return String(x))
	slots.sort()
	return {
		"views": JointDoll.VIEW_NAMES.duplicate(),
		"dir_to_view": dirs,
		"back_dirs": JointDoll.BACK_VIEW_DIRS.duplicate(),
		"near_side": near,
		"anchor": [JointDoll.ANCHOR.x, JointDoll.ANCHOR.y],
		"joints": joints,
		"slot_joint": slot_joint,
		"profile": prof,
		"slots": slots,
	}
