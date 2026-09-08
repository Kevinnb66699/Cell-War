shader_type canvas_item;

// 固化进度显示：只给细胞最外圈加一段石化色，主体仍保留原癌细胞颜色。
// progress = 0.5 表示 1.0 / 2.0，显示半圈；progress = 1.0 表示 2.0 / 2.0，显示整圈。
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 solid_color : source_color = vec4(0.84, 0.69, 0.47, 1.0);

// ⚠ **fragment 里不许 return**（Godot 4 直接拒绝编译：
// "Using 'return' in the 'fragment' processor function is incorrect"），而且**失败是静默的**——
// load() 照样给你一个 Shader 对象，只是渲染时整个 shader 不生效、什么都不画。
// 这个文件原来就是那么写的，于是固化进度外圈上线后一直没画出来，直到 2026-09-08
// 新写 store_progress 时撞上同一条报错才发现。改成算完再统一出 COLOR，不提前退出。
void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float alive = step(0.01, base.a) * step(0.001, progress);

	// 只取贴图轮廓外侧约 1px。四个采样点都以整数像素步长移动，保持像素边界。
	float edge = 0.0;
	for (int i = 1; i <= 2; i++) {
		// Sprite2D 的 hframes=6 让 UV 横向落在当前帧区域；采样相邻像素时要跨过整张表的 6 倍像素宽。
		vec2 step_px = vec2(TEXTURE_PIXEL_SIZE.x * 6.0, TEXTURE_PIXEL_SIZE.y) * float(i);
		edge = max(edge, 1.0 - step(texture(TEXTURE, UV + vec2(step_px.x, 0.0)).a, 0.01));
		edge = max(edge, 1.0 - step(texture(TEXTURE, UV - vec2(step_px.x, 0.0)).a, 0.01));
		edge = max(edge, 1.0 - step(texture(TEXTURE, UV + vec2(0.0, step_px.y)).a, 0.01));
		edge = max(edge, 1.0 - step(texture(TEXTURE, UV - vec2(0.0, step_px.y)).a, 0.01));
	}
	// 1.0 / 2.0 显示上半圈，达到 2.0 / 2.0 后显示整圈。
	float arc = progress >= 0.99 ? 1.0 : step(UV.y, 0.5);
	float mask = edge * arc * alive;
	COLOR = vec4(mix(base.rgb, solid_color.rgb, 0.92), base.a * mask);
}
