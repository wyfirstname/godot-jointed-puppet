// 部件换色着色器：HSV 偏移 + 三通道遮罩
// 遮罩通道约定：R = 主色区（木头/布料/头发），G = 皮肤区，B = 金属区（球关节/护手）
// 用法：挂在每个部件 Sprite2D 的 ShaderMaterial 上，参数由 JointDoll 写入

shader_type canvas_item;

uniform sampler2D tint_mask : filter_nearest, repeat_disable, hint_default_black;
uniform bool use_mask = false;

uniform float hue_shift : hint_range(-0.5, 0.5) = 0.0;
uniform float sat_mul : hint_range(0.0, 2.0) = 1.0;
uniform float val_mul : hint_range(0.0, 2.0) = 1.0;

uniform float skin_hue_shift : hint_range(-0.5, 0.5) = 0.0;
uniform float skin_sat_mul : hint_range(0.0, 2.0) = 1.0;
uniform float skin_val_mul : hint_range(0.0, 2.0) = 1.0;

uniform float metal_hue_shift : hint_range(-0.5, 0.5) = 0.0;
uniform float metal_sat_mul : hint_range(0.0, 2.0) = 1.0;
uniform float metal_val_mul : hint_range(0.0, 2.0) = 1.0;

varying vec4 v_modulate;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

vec3 apply_hsv(vec3 c, float h, float s, float v) {
	vec3 hsv = rgb2hsv(c);
	hsv.x = fract(hsv.x + h);
	hsv.y = clamp(hsv.y * s, 0.0, 1.0);
	hsv.z = clamp(hsv.z * v, 0.0, 1.0);
	return hsv2rgb(hsv);
}

void vertex() {
	// 提前捕获 modulate（含父节点调制），避免 fragment 覆盖 COLOR 时丢失
	v_modulate = COLOR;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec4 mk = use_mask ? texture(tint_mask, UV) : vec4(1.0, 0.0, 0.0, 1.0);

	// 部件本体调色（主色区 R）
	vec3 c = apply_hsv(base.rgb, hue_shift, sat_mul, val_mul);

	// 金属区 B：球关节、护手、柄头。独立参数，染金不伤木头。
	// 无 mask 时 mk.b = 0，金属调色等于关闭 —— 老行为不变
	vec3 metal = apply_hsv(base.rgb, metal_hue_shift, metal_sat_mul, metal_val_mul);
	c = mix(c, metal, mk.b);

	// 皮肤区 G 优先级最高：脸和手永远是同一肤色，金属/主色都盖不过它
	vec3 skin = apply_hsv(base.rgb, skin_hue_shift, skin_sat_mul, skin_val_mul);
	c = mix(c, skin, mk.g);

	// 遮罩外的像素保持原样
	c = mix(base.rgb, c, mk.r);

	COLOR = vec4(c, base.a) * v_modulate;
}
