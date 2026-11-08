# 弹簧参数探针：不依赖渲染，直接喂运动曲线看角度响应
# 用法：godot --headless --script res://tools/spring_probe.gd
#
# 验证三件事（对应参考视频里讲的三句）：
#   1. 加速时滞后、匀速时几乎归零          -> 惯性来自加速度，不是速度
#   2. 急停后往前甩一下再荡回来            -> "身体停了，头发不该马上跟着停"
#   3. 阻尼太小晃不停 / 阻尼为负发散       -> "参数调错就好玩了"

extends SceneTree

const FPS := 60.0
const DT := 1.0 / FPS


func _make(stiffness: float, damping: float) -> SpringJoint:
	var s := SpringJoint.new()
	s.stiffness = stiffness
	s.damping = damping
	s.inertia = 0.035
	s.drag = 0.10
	return s


## 速度曲线：0~0.2s 加速到 100px/s，保持到 0.8s，然后瞬间停住
func _speed(t: float) -> float:
	if t < 0.2:
		return 500.0 * t
	if t < 0.8:
		return 100.0
	return 0.0


func _run(label: String, stiffness: float, damping: float) -> void:
	var s := _make(stiffness, damping)
	var x := 0.0
	var peak_back := 0.0
	var peak_fwd := 0.0
	var settle_time := -1.0
	var series: Array[float] = []
	var t := 0.0
	while t < 2.2:
		x += _speed(t) * DT
		s.step(DT, Vector2(x, 0))
		var deg := rad_to_deg(s.angle)
		series.append(deg)
		# 0.8s 之后才是"急停"阶段
		if t > 0.8:
			peak_fwd = minf(peak_fwd, deg)
			peak_back = maxf(peak_back, deg)
			if settle_time < 0.0 and t > 1.2 and absf(deg) < 0.5:
				settle_time = t - 0.8
		else:
			peak_back = maxf(peak_back, deg)
		t += DT

	# 抽样打印：每 4 帧一个点
	var picks: Array[String] = []
	for i in range(0, series.size(), 6):
		picks.append("%.1f" % series[i])
	print("=== %s (k=%.0f c=%.1f) ===" % [label, stiffness, damping])
	print("  角度序列(°): ", ", ".join(picks))
	print("  加速期最大后仰 %.1f°   急停后最大前甩 %.1f°   平息用时 %s" % [
		peak_back, peak_fwd,
		("%.2f s" % settle_time) if settle_time >= 0.0 else "未平息",
	])
	s.free()


func _init() -> void:
	_run("正常", 90.0, 5.5)
	_run("阻尼太小", 90.0, 0.6)
	_run("阻尼为负", 90.0, -3.0)
	_run("过硬", 400.0, 7.0)
	quit()
