# 八向 z 序自检：把「每个槽位、每个方向」实际生效的 z 打出来并断言
#
# 用法：godot --headless --path . --script res://tools/zdump.gd
#
# 为什么需要这个工具：z 序是这套方案唯一无法靠"看"保证正确的东西。
# 8 个方向 × 24 个槽位 = 192 个值，靠目视一帧帧核对不现实，
# 而且错法很隐蔽 —— 近侧胳膊沉到躯干后面，只在转身那一刻闪一下。
#
# 断言的规则（全部来自"人站在那，镜头绕着转"这个物理事实）：
#   1. 近侧手臂 > 躯干 > 远侧手臂；正/背面两侧等距，两条手臂必须同 z
#   2. 近侧腿 > 远侧腿（否则近腿被远腿盖住，走路像两条腿在打架）
#   3. 同侧小腿 >= 大腿
#   4. 背面朝向：披风 > 躯干、后发 > 头、刘海与五官 < 头
#      以及 双臂+肩球+武器 < 披风（披风裹住后背，手臂连拿剑的手一起被布挡住
#      —— 用户拍板的外观 v3；但仍要 > 躯干，只是被布盖住，不是被躯干吞掉）
#   5. 正面朝向：披风 < 躯干；SW 的远臂要收进披风后面（同样是指定外观）
#   6. 方向 5/6/7 必须走镜像

extends SceneTree

var fails: Array[String] = []


func _initialize() -> void:
	_check_tables()
	_dump_and_check()
	print("")
	if fails.is_empty():
		print("==== 全部通过 ====")
		quit(0)
	else:
		print("==== 失败 %d 项 ====" % fails.size())
		for f in fails:
			print("  ✗ ", f)
		quit(1)


func _fail(msg: String) -> void:
	fails.append(msg)


# ---------------------------------------------------------------- 表本身的一致性

func _check_tables() -> void:
	print("--- 表一致性 ---")
	# 每个 SLOT_Z 的槽位都要能挂到关节，否则会被跳过
	for slot in JointDoll.SLOT_Z.keys():
		if slot == &"summon":
			continue
		if not JointDoll.SLOT_JOINT.has(slot):
			_fail("SLOT_Z 有 %s，SLOT_JOINT 没有 → 该槽位会被跳过" % slot)
	# 每个 LIMB_Z 的槽位都必须是已知槽位
	for slot in JointDoll.LIMB_Z.keys():
		if not JointDoll.SLOT_Z.has(slot):
			_fail("LIMB_Z 有 %s，SLOT_Z 没有 → 默认值缺失" % slot)
		if not JointDoll.SLOT_JOINT.has(slot):
			_fail("LIMB_Z 有 %s，SLOT_JOINT 没有 → 该槽位会被跳过" % slot)
	# 四肢必须成对（l/r 都有），否则近远判定单向失效
	for slot in JointDoll.LIMB_Z.keys():
		var s := String(slot)
		if not (s.ends_with("_l") or s.ends_with("_r")):
			_fail("LIMB_Z 的 %s 不以下划线 l/r 结尾，近远判定会失效" % s)
	# 每个视图都要有近侧定义、步态参数、弹簧增益
	for v in [JointDoll.View.S, JointDoll.View.SW, JointDoll.View.W,
			JointDoll.View.NW, JointDoll.View.N]:
		if not JointDoll.NEAR_SIDE.has(v):
			_fail("视图 %d 缺 NEAR_SIDE" % v)
		if not JointDoll.PROFILE.has(v):
			_fail("视图 %d 缺 PROFILE" % v)
		if not JointDoll.SPRING_GAIN.has(v):
			_fail("视图 %d 缺 SPRING_GAIN" % v)
	print("  槽位 %d 个 / 视图 %d 档" % [JointDoll.SLOT_JOINT.size(), JointDoll.NEAR_SIDE.size()])


# ---------------------------------------------------------------- 实战：建一只人偶逐方向查

func _make_doll() -> JointDoll:
	var vis := CharacterVisual.new()
	for slot in JointDoll.SLOT_JOINT.keys():
		var p := PartDef.new()
		p.slot = slot
		p.id = slot
		vis.equip(slot, p)
	var d := JointDoll.new()
	# --script 模式下 _initialize() 里 root 还没进树，add_child 不会触发 _ready，
	# 所以直接手动调建树和装配（这也是"无节点也能跑"的原因）。
	d._build_tree()
	d.visual = vis
	d._rebuild_parts()
	return d


func _dump_and_check() -> void:
	var d := _make_doll()
	var dirs := ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
	for di in 8:
		d.set_direction(di)
		var z := d.z_map()
		var m: Vector2i = JointDoll.DIR_TO_VIEW[di]
		var view := m.x
		var near: String = JointDoll.NEAR_SIDE.get(view, "l")
		var far := "r" if near == "l" else "l"

		# 关键槽位排成一行，便于肉眼速览
		var chain := "body=%d  近臂 arm_%s=%d  远臂 arm_%s=%d  近腿 leg_%s=%d  远腿 leg_%s=%d  披风=%d  后发=%d" % [
			z.get(&"body", -1), near, z.get(StringName("arm_" + near), -1),
			far, z.get(StringName("arm_" + far), -1),
			near, z.get(StringName("leg_" + near), -1),
			far, z.get(StringName("leg_" + far), -1),
			z.get(&"cape", -1), z.get(&"hair_back", -1),
		]
		if near == "":
			chain = "body=%d  对称视图：两臂 arm_l=%d arm_r=%d  两腿 leg_l=%d leg_r=%d  披风=%d  后发=%d" % [
				z.get(&"body", -1), z.get(&"arm_l", -1), z.get(&"arm_r", -1),
				z.get(&"leg_l", -1), z.get(&"leg_r", -1),
				z.get(&"cape", -1), z.get(&"hair_back", -1),
			]
		print("dir=%d %-2s view=%d mirror=%d  %s" % [di, dirs[di], view, m.y, chain])

		# 1. 近臂 > 躯干 > 远臂；正/背面（near == ""）两侧必须同 z
		var zbody: int = z.get(&"body", 0)
		var is_back_v: bool = di in JointDoll.BACK_VIEW_DIRS
		var zcape_v: int = z.get(&"cape", 0)
		if near == "":
			var zl: int = z.get(&"arm_l", 0)
			var zr: int = z.get(&"arm_r", 0)
			if zl != zr:
				_fail("dir=%d 对称视图两臂层级不同：l=%d r=%d" % [di, zl, zr])
			if not zl > zbody:
				_fail("dir=%d 手臂被躯干盖住：%d <= %d" % [di, zl, zbody])
			var gl: int = z.get(&"leg_l", 0)
			var gr: int = z.get(&"leg_r", 0)
			if gl != gr:
				_fail("dir=%d 对称视图两腿层级不同：l=%d r=%d" % [di, gl, gr])
		else:
			var znear: int = z.get(StringName("arm_" + near), 0)
			var zfar: int = z.get(StringName("arm_" + far), 0)
			if is_back_v:
				# 背面：披风裹住后背，两条胳膊连肩球都收进布**后面**（用户指定的外观）。
				# 但仍必须压过躯干 —— 是被布盖住，不是被躯干吞掉
				if not znear > zbody:
					_fail("dir=%d 背面近臂被躯干盖住：%d <= %d" % [di, znear, zbody])
				if not znear >= zfar:
					_fail("dir=%d 背面远臂比近臂高：近 %d < 远 %d" % [di, znear, zfar])
				if not zfar < zcape_v:
					_fail("dir=%d 背面远臂(%d) 没有收进披风(%d) 后面" % [di, zfar, zcape_v])
				if not znear < zcape_v:
					_fail("dir=%d 背面近臂(%d) 应在披风(%d) 后面" % [di, znear, zcape_v])
			elif not (znear > zbody and zbody > zfar):
				_fail("dir=%d 手臂层级不对：近 %d / 躯干 %d / 远 %d" % [di, znear, zbody, zfar])
			if di == 1 and not zfar < zcape_v:
				# SW（正面斜角）：远臂同样收进披风后面。这是指定外观，不是物理事实，
				# 想改回去时把 layer_rules.json 里 sw 的 arm_l/fore_l/glove_l 调回 8/9/9 即可
				_fail("dir=1 SW 远臂(%d) 应收进披风(%d) 后面" % [zfar, zcape_v])
			# 2. 近腿 > 远腿
			var lnear: int = z.get(StringName("leg_" + near), 0)
			var lfar: int = z.get(StringName("leg_" + far), 0)
			if not lnear > lfar:
				_fail("dir=%d 腿没分层：近 %d <= 远 %d（近腿会被远腿盖住）" % [di, lnear, lfar])
		# 3. 同侧小腿 >= 大腿
		for side in ["l", "r"]:
			if int(z.get(StringName("shin_" + side), 0)) < int(z.get(StringName("leg_" + side), 0)):
				_fail("dir=%d 小腿压在大腿下：%s" % [di, side])

		# 4/5. 披风与后背朝向
		var is_back: bool = di in JointDoll.BACK_VIEW_DIRS
		var zcape: int = z.get(&"cape", 0)
		if is_back:
			if not zcape > zbody:
				_fail("dir=%d 背面披风没盖住身体：%d <= %d" % [di, zcape, zbody])
			# 双臂+肩球都收进披风后面（用户拍板的外观）：布裹住后背，
			# 手臂垂在身侧被布挡住。想改回「胳膊在布外」时同步改 ARM_Z_ON_BACK
			for side in ["l", "r"]:
				var za: int = z.get(StringName("arm_" + side), 0)
				if not za < zcape:
					_fail("dir=%d 背面 arm_%s(%d) 没有收进披风(%d) 后面" % [di, side, za, zcape])
			var zs: int = z.get(&"shoulder", 0)
			if not zs < zcape:
				_fail("dir=%d 背面肩球(%d) 浮在披风(%d) 上，应跟着手臂一起收进布后" % [di, zs, zcape])
			# v3：拿剑的手连剑一起收进披风后面（用户拍板）。剑挂在 elbow_r 上，
			# 不跟手一起沉的话，布上会浮着一把凭空出现的剑
			var zw: int = z.get(&"weapon", 0)
			if not zw < zcape:
				_fail("dir=%d 背面武器(%d) 浮在披风(%d) 上，应跟着手一起收进布后" % [di, zw, zcape])
			if not int(z.get(&"hair_back", 0)) > int(z.get(&"head", 0)):
				_fail("dir=%d 背面后发没盖住头" % di)
			if not int(z.get(&"hair_front", 0)) < int(z.get(&"head", 0)):
				_fail("dir=%d 背面刘海糊在后脑上" % di)
			if not int(z.get(&"face", 0)) < int(z.get(&"head", 0)):
				_fail("dir=%d 背面还画着五官" % di)
		else:
			if not zcape < zbody:
				_fail("dir=%d 正面披风跑到身体前面：%d >= %d" % [di, zcape, zbody])

		# 6. 镜像
		var want_mirror := 1 if di >= 5 else 0
		if m.y != want_mirror:
			_fail("dir=%d 镜像标志错：%d" % [di, m.y])
		# 注意：不能用 d.scale.x 判断。负 x 缩放是非可分解的，
		# Godot 读回来会变成 scale.y=-1 + rotation=180°（见 Node2D 文档的 Note）。
		# 直接看变换矩阵的 x 轴朝向才可靠。
		var flipped: bool = d.get_transform().x.x < 0.0
		if flipped != (want_mirror == 1):
			_fail("dir=%d 变换矩阵 x 轴朝向与镜像标志不符" % di)

	d.free()
