shader_type canvas_item;

// 细胞传送演出：像素风「溶解」。
//
// 形态（docs 有对应规格讨论，2026-09-04）：
//   progress 0 → 1 是「沉入」：细胞从**脚底开始**向上化开，像被组织吸下去；
//   progress 1 → 0 是「冒出」：同一 shader 倒放，从脚底往上重新凝出来。
//   溶解边界带一圈阵营色亮边（1~2px），像细胞膜化开时发光。
//
// 为什么用 shader 而不是动 position：CWMatch 每帧用引擎状态覆写细胞节点的
// position / z_index，位移不敢碰；而 shader 全部发生在精灵自己的 UV 空间里，
// 节点站着不动、效果照跑。驱动方式与 silhouette 高亮同款——补间只推
// progress 一个参数（material 必须逐实例 duplicate，不能共用）。
//
// 像素风约定：噪声按 2px 网格量化（TEXTURE_PIXEL_SIZE 是最近邻像素画的
// 天然网格），溶解边界保持硬台阶，不出灰雾。呼吸表帧由节点侧管
// （hframes 的区域 UV 会正常传进来），shader 不关心第几帧。

// 0 = 完好，1 = 完全溶解。离场 0→1，落场 1→0。
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// 溶解边缘的亮色：离场喂阵营色（免疫青 / 癌方橙），落场喂白。
uniform vec4 edge_color : source_color = vec4(0.188, 0.82, 0.98, 1.0);
// 边缘带的宽度（噪声值单位）。窄了边缘看不见，宽了整团发糊。
uniform float edge_width = 0.10;
// 「向下偏置」强度：决定侵蚀前沿扫过整个身高的落差。**必须明显大于
// 噪声带**，否则排序被噪声吃掉，看着就是同时碎掉（2026-09-04 预览反馈：
// 原先 bias=0.45、噪声跨 1.0，上下几乎同时消失）。
uniform float sink_bias = 1.0;
// 噪声值占的带宽：只提供锯齿状边缘，不主导「哪儿先化」的顺序。
// 越小越接近平直的水平扫描线，越大越碎。
uniform float noise_spread = 0.35;
// 演出方向：0 = 沉入（脚底先化开），1 = 凝出（脚底先长回来）。
// 同一条偏置在两个阶段必须翻锚点：沉入要「可见区从顶部收缩」、
// 凝出要「可见区从脚底扩张」，直接倒放 progress 会变成从头顶冒出来，
// 不符合「破土而出」的规格（2026-09-04 截图验证后修正）。
uniform float emerge : hint_range(0.0, 1.0) = 0.0;

// 2px 网格上的伪随机值噪声。够用即可——溶解不需要平滑噪声，
// 量化后的硬颗粒正是要的像素质感。
float cell_noise(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);

	// UV 量化到 2px 格子：一张 32×34 的帧大约 16×17 个颗粒。
	vec2 cell = floor(UV / (TEXTURE_PIXEL_SIZE * 2.0));
	float n = 0.5 + (cell_noise(cell) - 0.5) * noise_spread;

	// 阈值加偏置：锚点 = 沉入时取脚底（UV.y=1 先越线），凝出时取头顶——
	// 两种情况下都是「脚底先变化」，方向由 emerge 翻转（见上注）。
	float anchor = mix(1.0 - UV.y, UV.y, emerge);
	float local = progress * (1.0 + sink_bias) - anchor * sink_bias;

	float d = n - local;
	// d <= 0：已溶解，直接丢透明。
	// 0 < d < edge_width：边缘亮带，贴图色向 edge_color 混合。
	if (d <= 0.0) {
		discard;
	}
	float edge = 1.0 - smoothstep(0.0, edge_width, d);
	vec3 rgb = mix(tex.rgb, edge_color.rgb, edge * 0.85);
	COLOR = vec4(rgb, tex.a);
}
