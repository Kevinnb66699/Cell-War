shader_type canvas_item;

// 把贴图整个染成纯色，只保留它的 alpha 轮廓。
//
// 用途：格子高亮。设计稿的高亮是「原色和 #30D1FA 按 0.43 混合」——
// 那正好等于在原格上叠一层 alpha=0.43 的纯青色轮廓（a·新 +(1-a)·旧 就是 lerp），
// 所以叠一张同贴图的纯色剪影就能逐像素还原设计稿，不必给 127 个格子各配一份材质。
//
// 颜色和透明度都由节点的 modulate 给，一份材质够所有高亮共用。
//
// **modulate 必须自己从顶点阶段传下来。** canvas_item 着色器里 modulate 是在顶点阶段
// 乘进 COLOR 的，到了 fragment，COLOR 已经是「modulate × 贴图」；
// 而这里要整个覆写 COLOR，写成 vec4(1,1,1,a) 会把 modulate 一并丢掉——
// 所有高亮都会渲染成纯白不透明（2026-08-27 就是这么错的：肉眼一看便知，
// 但无头测试查不出来，它只数节点、不看像素）。
// 顺带一提 MODULATE 这个内建量在 4.5 的 canvas_item 里不存在，别去写它。
varying vec4 tint;

void vertex() {
	tint = COLOR;   // 此处的 COLOR 尚未乘贴图，就是节点的 modulate
}

void fragment() {
	COLOR = vec4(tint.rgb, texture(TEXTURE, UV).a * tint.a);
}
