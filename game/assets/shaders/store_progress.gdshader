shader_type canvas_item;

// 代谢核心 / 骨髓的「积累进度」显示（Kevin 2026-09-08：A′ 外缘环 + B 进度条**两个都要**）。
//
// 两种形状共用这一份：贴图给的是掩膜（store_ring.png / store_bar.png），
// 这里只负责「按 progress 点亮一部分、其余留一道暗槽」。差别只有**填充方向**：
//   · 环：从**底顶点往上**长。顶面六边形分左右两条边往上走时 y 都是单调的，
//     所以「沿环走了多远」= 「离底部多高」，不必算角度。
//     为什么不从顶部顺时针：细胞脚底锚在顶面中心、贴图向上长，站人时盖住的是**上半部**，
//     从顶部起填会让低进度整段落进被盖住的地方，玩家看到的和空仓一模一样
//     （2026-09-08 的方案对比图里当场看见）。
//   · 条：从**左往右**长，常规读法。
//
// ⚠ **fragment 里不许 return**（Godot 4 直接拒绝编译，报
// "Using 'return' in the 'fragment' processor function is incorrect"）。
// 而编译失败是**静默的** —— load() 照样给你一个 Shader 对象，只是渲染时什么都不画。
// 同仓的 solid_progress.gdshader 就这么坏了一版没人发现（2026-09-08 一并修）。
// 所以这里一律用 mix/step 走完整条路径，不提前退出。
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 lit_color : source_color = vec4(1.0);
uniform bool horizontal = false;   // false = 环（自下而上）；true = 条（自左而右）
// 掩膜在贴图里的跨度（像素 / 贴图边长）。**必须按形状自己的跨度归一化**，
// 不能直接用 UV —— 条只占 x 7..24，拿整张 32px 宽算的话 progress=0.2 就已经把左端点亮了。
// 环：顶面 y 0..25 于 34 高的图里。条：x 7..25 于 32 宽的图里。
uniform float ring_top : hint_range(0.0, 1.0) = 0.0;
uniform float ring_bottom : hint_range(0.0, 1.0) = 0.735;
uniform float bar_left : hint_range(0.0, 1.0) = 0.219;
uniform float bar_right : hint_range(0.0, 1.0) = 0.781;
// 没点亮那段的不透明度：留一道暗槽，玩家看得出「这里有一圈/一条，只是还没涨上来」
uniform float dim_alpha : hint_range(0.0, 1.0) = 0.30;

void fragment() {
	vec4 mask = texture(TEXTURE, UV);
	// 这一像素在填充方向上走了多远（0 = 起点，1 = 终点）
	float along = horizontal
		? clamp((UV.x - bar_left) / max(bar_right - bar_left, 0.0001), 0.0, 1.0)
		: clamp((ring_bottom - UV.y) / max(ring_bottom - ring_top, 0.0001), 0.0, 1.0);
	// <= 而不是 <：progress 恰好等于某像素位置时也该亮，否则满仓时末端差一格
	float lit = step(along, progress + 0.001);
	COLOR = vec4(lit_color.rgb, mask.a * mix(dim_alpha, lit_color.a, lit));
}
