shader_type canvas_item;

// 代谢核心 / 骨髓的「积累进度」外圈。
//
// 2026-09-11 起用 5yntaxEr 的手绘贴图（issue #24）：每种组织 × 健康 / 病变各一对
// 「底」（暗色底圈）与「满」（亮色满圈），两张是**同一像素集、只差颜色**。
// Sprite 贴的是「满」（TEXTURE），「底」从 track_tex 读；本 shader 只负责
// 「按 progress 从底顶点顺时针绕一圈，绕到哪儿就露「满」的哪些像素，其余露「底」」。
// 颜色全在贴图里，代码不再给色 —— 美术要改配色直接换文件。
//
// **按图片像素截取，不按屏幕像素**（5yntaxEr 在 #24 里特别叮嘱的）：
// 角度从这一片元所在**纹素的中心**算，整颗纹素同一判定。棋盘 1.27 倍缩放下一颗纹素对应
// 一个多屏幕像素，若按片元算，进度边界处那颗纹素会被劈成两色。
//
// 下面两条是 2026-09-08 第一版（2px 轮廓掩膜 + 代码给色）留下来的，理由不变：
// · **绕着环走，不是一层一层往上涨**（Kevin 2026-09-08 第二版）：按 UV.y 判高度的话
//   左右两条边会同时亮同一高度，看起来像水位在上升而不是一圈在长。按**极角**判：
//   六边形是凸的且包住中心，绕行位置与极角一一对应；先把纵向压扁还原回去，角度≈弧长。
// · **起点在底顶点**：细胞脚底锚在顶面中心、贴图向上长，站人时盖住的是**上半部**，
//   从顶部起填会让低进度整段落进被盖住的地方，玩家看到的和空仓一模一样。
//
// ⚠ **fragment 里不许 return**（Godot 4 直接拒绝编译，报
// "Using 'return' in the 'fragment' processor function is incorrect"）。
// 而编译失败是**静默的** —— load() 照样给你一个 Shader 对象，只是渲染时什么都不画。
// 同仓的 solid_progress.gdshader 就这么坏了一版没人发现（2026-09-08 一并修）。
// 所以这里一律用 mix/step 走完整条路径，不提前退出。
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// 「底」圈：没点亮那段露它。和「满」同一像素集，所以 alpha 也一致
uniform sampler2D track_tex : source_color, filter_nearest;
// 顶面六边形的中心（UV）与尺寸（像素）。顶面在 32x34 的图里占 x 0..31 / y 0..25，
// 所以中心 (15.5/32, 12.5/34)，六边形 32 宽 26 高。
uniform vec2 hex_center = vec2(0.484375, 0.367647);
uniform vec2 tex_size = vec2(32.0, 34.0);
// 纵向压扁比（高/宽）：先按它还原成近似正六边形，极角才≈绕行比例
uniform float hex_squash : hint_range(0.1, 1.0) = 0.8125;

void fragment() {
	// 这一片元落在哪颗纹素：拿纹素中心算角度，整颗纹素同一判定（「以图片像素为准」）
	vec2 texel = (floor(UV * tex_size) + 0.5) / tex_size;
	vec2 d = (texel - hex_center) * tex_size;
	d.y /= hex_squash;                        // 还原压扁，角度才≈弧长
	float ang = atan(d.y, d.x);               // 屏幕 y 向下：底 = +PI/2，左 = PI，顶 = -PI/2
	float along = fract((ang - 1.5707963) / 6.2831853);
	// <= 而不是 <：progress 恰好等于某纹素位置时也该亮，否则满仓时末端差一格。
	// ⚠ 但那点容差在 **progress 恰好为 0** 时会点亮起点那一颗纹素 ——
	// 空仓的骨髓底下于是挂着一小截「进度条」（Kevin 2026-09-09 报）。
	// 所以再乘一道「进度大于 0 才有亮段」：空仓就该是**整圈底圈**，一个亮点都不留。
	float lit = step(along, progress + 0.001) * step(0.0001, progress);
	vec4 full = texture(TEXTURE, UV);
	vec4 track = texture(track_tex, UV);
	COLOR = mix(track, full, lit);
}
