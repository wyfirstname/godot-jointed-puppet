extends SceneTree

## 验证：父节点 scale.x = -1 时，子节点 rotation 的世界朝向怎么变
## 纯矩阵推导（不依赖节点变换缓存），这决定「挥剑」类方向性动作要不要乘朝向符号

func _initialize() -> void:
	print("手臂局部朝下 (0,22)，看它转到世界里指向哪：")
	for deg in [0.0, 45.0, 95.0, -95.0]:
		for sx in [1.0, -1.0]:
			var parent := Transform2D.IDENTITY.scaled(Vector2(sx, 1.0))
			var arm := Transform2D(deg_to_rad(deg), Vector2(152, 108))
			var world: Transform2D = parent * arm
			var tip: Vector2 = world * Vector2(0, 22)
			var d: Vector2 = tip - world.origin
			print("  rot=%+6.0f°  scale.x=%+2.0f  ->  dir=%s  angle=%+7.1f°" % [
				deg, sx, str(d.round()), rad_to_deg(d.angle())])
	quit()
