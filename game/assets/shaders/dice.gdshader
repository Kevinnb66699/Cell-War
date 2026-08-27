shader_type canvas_item;

// 掷骰用的骰子：在片段着色器里直接对立方体解析求交，不需要网格、不需要 SubViewport。
//
// 为什么不是 ray marching：立方体有闭式解（slab 法求光线与轴对齐盒的交点），
// 十来行、O(1)，比步进更快，而且平面上不会留下步进条纹。
// 只有要做**圆角骰**时才真的需要改成 marching sdRoundBox。
//
// **旋转由 GDScript 算好、当 uniform 传进来，着色器无权决定点数。**
// 点数是 CWGame.rng 先掷出来的，动画只负责演到那个数上（架构约定 #2）。
// 这也是将来做确定性锁步联机的前提 —— 表现层永远不参与规则。

uniform mat3 rot;                       // 复合旋转：骰子姿态 → 世界竖轴偏航 → 视角俯仰
uniform float pixelate = 0.0;           // >0.5 时降到棋盘的像素密度，风格贴回像素棋盘
uniform float pixel_res = 36.0;         // 棋盘贴图 32px、放大 2 倍，骰子取相近密度

// 色区分档：一眼读出档位，不用记「1-2 是失败」这个映射
uniform vec3 col_fail : source_color = vec3(0.690, 0.290, 0.353);  // 1-2 失败
uniform vec3 col_ok   : source_color = vec3(0.247, 0.647, 0.714);  // 3-5 成功
uniform vec3 col_crit : source_color = vec3(1.000, 0.843, 0.369);  // 6 大成功
uniform vec3 col_pip  : source_color = vec3(0.047, 0.078, 0.090);

// 注意不能叫 LIGHT —— 那是 canvas_item 着色器的内建量，重名会编译失败
// （和仓库里「不能给 CWGame 加 log() 方法」是同一类坑）
const vec3 LIGHT_DIR = vec3(-0.339, 0.798, 0.499);

vec3 face_color(float v) {
	if (v < 2.5) return col_fail;
	if (v < 5.5) return col_ok;
	return col_crit;
}

// 本地空间法线 → 点数。+Z=1 -Z=6 +X=2 -X=5 +Y=3 -Y=4，对面点数和为 7。
float face_val(vec3 n) {
	if (n.z >  0.5) return 1.0;
	if (n.z < -0.5) return 6.0;
	if (n.x >  0.5) return 2.0;
	if (n.x < -0.5) return 5.0;
	if (n.y >  0.5) return 3.0;
	return 4.0;
}

// 命中点 → 该面内的 2D 坐标
vec2 face_uv(vec3 p, vec3 n) {
	if (abs(n.z) > 0.5) return vec2(p.x * sign(n.z), p.y);
	if (abs(n.x) > 0.5) return vec2(-p.z * sign(n.x), p.y);
	return vec2(p.x, -p.z * sign(n.y));
}

// 点数程序化生成，不用任何贴图
float pips(float v, vec2 uv, float aa) {
	float s = 0.52;
	float d = 1e9;
	if (v < 1.5) {
		d = length(uv);
	} else {
		d = min(length(uv - vec2(-s, -s)), length(uv - vec2(s, s)));
		if (v > 2.5 && mod(v, 2.0) > 0.5) d = min(d, length(uv));         // 3、5 有中心点
		if (v > 3.5) {                                                    // 4、5、6 补另两角
			d = min(d, length(uv - vec2( s, -s)));
			d = min(d, length(uv - vec2(-s,  s)));
		}
		if (v > 5.5) {                                                    // 6 再补两个腰点
			d = min(d, length(uv - vec2(-s, 0.0)));
			d = min(d, length(uv - vec2( s, 0.0)));
		}
	}
	return 1.0 - smoothstep(0.15 - aa, 0.15 + aa, d);
}

// 程序化环境，给 Fresnel 反射当查找源 —— 省掉一张 matcap 贴图
vec3 env(vec3 r) {
	float up = r.y * 0.5 + 0.5;
	vec3 sky = mix(vec3(0.05, 0.10, 0.14), vec3(0.50, 0.78, 0.86), up);
	float hi = pow(max(0.0, dot(r, normalize(vec3(-0.40, 0.86, 0.32)))), 26.0);
	return sky + vec3(1.0, 0.97, 0.88) * hi * 1.6;
}

void fragment() {
	// Godot 的 UV 原点在左上、y 轴向下，翻过来才和「上为 +Y」的世界一致
	vec2 uv = vec2(UV.x, 1.0 - UV.y) * 2.0 - 1.0;
	if (pixelate > 0.5) {
		// 直接在着色器里降密度：不需要额外的渲染目标
		uv = (floor((uv * 0.5 + 0.5) * pixel_res) + 0.5) / pixel_res * 2.0 - 1.0;
	}

	// 相机推得比较远，把透视强度压到和棋盘那套压扁投影相近（前后缩放比约 1.29）
	vec3 ro = vec3(0.0, 0.0, 8.0);
	vec3 rd = normalize(vec3(uv * 0.25, -1.0));

	// 旋转矩阵是正交阵，转置即逆；GLSL 里 v * M 就等于 transpose(M) * v
	vec3 ro_l = ro * rot;
	vec3 rd_l = rd * rot;

	// ── slab 法：光线与轴对齐单位立方体求交 ──
	vec3 inv  = 1.0 / rd_l;
	vec3 ta   = (-vec3(1.0) - ro_l) * inv;
	vec3 tb   = ( vec3(1.0) - ro_l) * inv;
	vec3 tmin = min(ta, tb);
	vec3 tmax = max(ta, tb);
	float t_near = max(max(tmin.x, tmin.y), tmin.z);
	float t_far  = min(min(tmax.x, tmax.y), tmax.z);
	if (t_near > t_far || t_far < 0.0) discard;

	vec3 p_l = ro_l + rd_l * t_near;
	vec3 n_l = -sign(rd_l) * step(tmin.yzx, tmin.xyz) * step(tmin.zxy, tmin.xyz);
	vec3 n_w = rot * n_l;

	float v   = face_val(n_l);
	float aa  = pixelate > 0.5 ? 0.006 : 0.030;
	float pip = pips(v, face_uv(p_l, n_l), aa);

	vec3 col = face_color(v) * (0.40 + 0.66 * max(0.0, dot(n_w, LIGHT_DIR)));
	float fres = pow(1.0 - max(0.0, dot(n_w, -rd)), 3.5);          // Fresnel 边缘光
	// 像素化时压低反射：这个密度承载不了边缘高光，硬留着只会变成噪点
	col += env(reflect(rd, n_w)) * fres * (pixelate > 0.5 ? 0.30 : 0.85);
	col = mix(col, col_pip, pip);

	COLOR = vec4(col, 1.0);
}
