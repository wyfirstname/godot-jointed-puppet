# 弹簧关节：挂在头发/披风上的"看不见的弹簧"
#
# 参考视频原话：
#   "身体停了，头发不该马上跟着停"
#   "拉开就往回弹，阻尼让它慢慢停下"
#   "阻尼太小，停下来还一直晃；阻尼是负数，越晃越大，直接甩飞"
#
# 模型：把头发当成挂在移动支点上的单摆，支点就是父关节。
#   支点加速度 a  -> 惯性伪力      -> 角速度增量 +inertia·a·dt
#   支点速度 v    -> 空气阻力      -> 角速度增量 +drag·v·dt
#   角度偏离 0    -> 回弹弹簧      -> 角加速度 -stiffness·θ
#   角速度        -> 阻尼耗能      -> 角加速度 -damping·ω
#
# 关键：冲量必须积分成"角速度"，而不是直接当"目标角"。
# 早期版本把加速度映射成目标角，结果急停只有一帧脉冲、头发甩不起来。
#
# 符号约定：正角度让下垂部件（局部尖端在 (0,+L)）往 -x 摆。

class_name SpringJoint
extends Node2D

## 弹簧刚度：越大回弹越快、越硬
@export var stiffness: float = 90.0
## 阻尼：越小晃得越久，<0 会自激发散（对应视频里"甩飞"那个玩笑）
@export var damping: float = 5.5
## 惯性增益：支点加速度 -> 角速度增量
@export var inertia: float = 0.035
## 空气阻力：支点速度 -> 持续的后拖角
@export var drag: float = 0.10
## 最大摆角，防止极端参数甩出画布
@export var max_angle: float = 0.85

## 驱动增益。这个弹簧只是屏幕 x 方向的一维单摆：
## 角色朝镜头走时，真实运动在景深方向，屏幕上不该左右甩。
## 所以由持有者按"视图"把它压到 0.25~1.0（见 JointDoll.SPRING_GAIN）。
@export var gain: float = 1.0

var angle: float = 0.0
var vel: float = 0.0
var enabled: bool = true

var _prev_pos := Vector2.ZERO
var _prev_vx: float = 0.0
var _started := false


func step(dt: float, driver_pos: Vector2) -> void:
	if dt <= 0.0:
		return

	if not enabled:
		# 关掉时平滑归零，避免开关瞬间跳变
		angle = move_toward(angle, 0.0, 6.0 * dt)
		vel = 0.0
		rotation = angle
		_started = false
		return

	if not _started:
		_prev_pos = driver_pos
		_prev_vx = 0.0
		_started = true
		return

	dt = minf(dt, 1.0 / 30.0)   # 掉帧保护，别让积分炸掉
	var vx := (driver_pos.x - _prev_pos.x) / dt
	var ax := (vx - _prev_vx) / dt
	_prev_pos = driver_pos
	_prev_vx = vx
	ax = clampf(ax, -9000.0, 9000.0)

	# 外力：惯性（加速度）+ 空气阻力（速度）
	# 两项同号：向右走时空气把头发往左推（= 正角度），
	# 向右急停时惯性让头发继续往右（= 负角度），正好是"甩一下再回弹"
	vel += (inertia * ax + drag * vx) * gain * dt

	# 弹簧回正 + 阻尼耗能
	var acc := -stiffness * angle - damping * vel
	vel += acc * dt

	angle = clampf(angle + vel * dt, -max_angle, max_angle)
	rotation = angle


func reset() -> void:
	angle = 0.0
	vel = 0.0
	_started = false
	rotation = 0.0
