shader_type canvas_item;

// 代谢核心 / 骨髓的「积累进度」外圈（Kevin 2026-09-08 拍的 A′ 案）。
//
// 贴图给的是掩膜（store_ring.png，顶面六边形的 2px 轮廓），
// 这里只负责「按 progress 把环从**底顶点往上**点亮，其余留一道暗槽」。
//
// **绕着环走，不是一层一层往上涨**（Kevin 2026-09-08 第二版）。
// 第一版按 UV.y 判「离底部多高」，左右两条边会同时亮同一高度，
// 看起来像水位在上升而不是一圈在长 —— 那不是进度环该有的读法。
// 现在按**极角**判：六边形是凸的且包住中心，所以绕行位置与极角一一对应。
// 角度不完全等于弧长（六边形不是圆），但先把纵向压扁还原回去之后差得很小，
// 32px 一格上看不出来 —— 为这点误差去贴图里烘弧长表不值。
//
// **起点仍在底顶点**：细胞脚底锚在顶面中心、贴图向上长，站人时盖住的是**上半部**，
// 从顶部起填会让低进度整段落进被盖住的地方，玩家看到的和空仓一模一样。
//
// 同日还做过一版 B 案的横向进度条，当天被撤掉了；那条分支已随之删干净。
//
// ⚠ **fragment 里不许 return**（Godot 4 直接拒绝编译，报
// "Using 'return' in the 'fragment' processor function is incorrect"）。
// 而编译失败是**静默的** —— load() 照样给你一个 Shader 对象，只是渲染时什么都不画。
// 同仓的 solid_progress.gdshader 就这么坏了一版没人发现（2026-09-08 一并修）。
// 所以这里一律用 mix/step 走完整条路径，不提前退出。
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 lit_color : source_color = vec4(1.0);
// 顶面六边形的中心（UV）与尺寸（像素）。顶面在 32x34 的图里占 x 0..31 / y 0..25，
// 所以中心 (15.5/32, 12.5/34)，六边形 32 宽 26 高。
uniform vec2 hex_center = vec2(0.484375, 0.367647);
uniform vec2 tex_size = vec2(32.0, 34.0);
// 纵向压扁比（高/宽）：先按它还原成近似正六边形，极角才≈绕行比例
uniform float hex_squash : hint_range(0.1, 1.0) = 0.8125;
// 没点亮那段的不透明度：留一道暗槽，玩家看得出「这里有一圈，只是还没涨上来」
uniform float dim_alpha : hint_range(0.0, 1.0) = 0.30;

void fragment() {
	vec4 mask = texture(TEXTURE, UV);
	// 这一像素从底顶点起绕了多远（0 = 底顶点，顺时针一圈到 1）
	vec2 d = (UV - hex_center) * tex_size;
	d.y /= hex_squash;                        // 还原压扁，角度才≈弧长
	float ang = atan(d.y, d.x);               // 屏幕 y 向下：底 = +PI/2，左 = PI，顶 = -PI/2
	float along = fract((ang - 1.5707963) / 6.2831853);
	// <= 而不是 <：progress 恰好等于某像素位置时也该亮，否则满仓时末端差一格
	// <= 而不是 <：progress 恰好等于某像素位置时也该亮，否则满仓时末端差一格。
	// ⚠ 但那点容差在 **progress 恰好为 0** 时会点亮起点那一个像素 ——
	// 空仓的骨髓底下于是挂着一小截「进度条」（Kevin 2026-09-09 报）。
	// 所以再乘一道「进度大于 0 才有亮段」：空仓就该是**整圈暗槽**，一个亮点都不留。
	float lit = step(along, progress + 0.001) * step(0.0001, progress);
	COLOR = vec4(lit_color.rgb, mask.a * mix(dim_alpha, lit_color.a, lit));
}
