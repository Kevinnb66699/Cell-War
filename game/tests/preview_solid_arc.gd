extends SceneTree
## 固化进度外圈：**现状（硬切半圈）** vs **提案（环形扫描）** 的对照图。
##
## 给人看的工具，不是测试。Kevin 2026-09-09 要的对比图 ——
## 现在的 solid_progress.gdshader 只有「上半圈 / 整圈」两档硬切，
## 而固化计数实际能落在 0.5 / 1.0 / 1.5 / 2.0 上（停留 +1.0、衰减 -0.5、
## 【基质硬化】+1.0~+2.0，阈值 2.0），前三档画出来一模一样。
##
## 三行分别是：
##   ① 现状：`step(UV.y, 0.5)` 硬切上半圈
##   ② 提案 A：从正上方顺时针扫，未点亮那段完全不画
##   ③ 提案 B：同 A，但未点亮那段留一道暗槽（照 store_progress 的 dim_alpha）
##
## **提案 shader 只活在这个文件里**（`Shader.new()` + code），
## 不往 assets/ 里塞文件 —— 方案没定之前不动仓库资产。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_solid_arc.gd -- <输出.png>

## 提案 shader：把现状那句 `step(UV.y, 0.5)` 换成按极角扫。
## 边缘检测那几行与现状**逐字相同**，对照图里唯一的变量就是 arc 的算法。
const ARC_CODE := """
shader_type canvas_item;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 solid_color : source_color = vec4(0.84, 0.69, 0.47, 1.0);
uniform float hframes = 6.0;
uniform float dim_alpha : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float alive = step(0.01, base.a) * step(0.001, progress);

	float edge = 0.0;
	for (int i = 1; i <= 2; i++) {
		vec2 step_px = TEXTURE_PIXEL_SIZE * float(i);
		edge = max(edge, step(texture(TEXTURE, UV + vec2(step_px.x, 0.0)).a, 0.01));
		edge = max(edge, step(texture(TEXTURE, UV - vec2(step_px.x, 0.0)).a, 0.01));
		edge = max(edge, step(texture(TEXTURE, UV + vec2(0.0, step_px.y)).a, 0.01));
		edge = max(edge, step(texture(TEXTURE, UV - vec2(0.0, step_px.y)).a, 0.01));
	}

	// UV 在**整张表**的坐标系里（只是被限制在本帧那一段），
	// 所以 TEXTURE_PIXEL_SIZE 的倒数就是整张表的像素尺寸，不必再乘 hframes。
	vec2 sheet_px = vec2(1.0) / TEXTURE_PIXEL_SIZE;
	vec2 center = vec2((floor(UV.x * hframes) + 0.5) / hframes, 0.5);
	vec2 d = (UV - center) * sheet_px;

	// 屏幕 y 向下：正上方 = -PI/2。+PI/2 之后 0 = 正上方，顺时针一圈到 1。
	float ang = atan(d.y, d.x);
	float along = fract((ang + 1.5707963) / 6.2831853);
	float lit = step(along, progress + 0.001);

	float a = edge * alive * mix(dim_alpha, 1.0, lit);
	COLOR = vec4(mix(base.rgb, solid_color.rgb, 0.92), base.a * a);
}
"""

const NOW_SHADER := preload("res://assets/shaders/solid_progress.gdshader")
const TISSUE_CANCER := preload("res://assets/art/tissue_cancer.png")
const FONT := preload("res://assets/fonts/fusion_pixel_10px.ttf")
const SOLID_CELL_COLOR := Color("d6b078")   ## 现读 CWMatch 的同名常量，别在这儿另开一份

## 固化阈值 2.0，所以真正能出现的四档计数就是这些
const STEPS := [0.5, 1.0, 1.5, 2.0]
const THRESHOLD := 2.0

const SCALE := 4.0
const SIZE := Vector2i(1120, 760)
const COL_X := [250.0, 470.0, 690.0, 910.0]
const ROW_Y := [250.0, 460.0, 670.0]
const ROW_LABEL := ["现状", "提案 A", "提案 B"]

var _out := "user://solid_arc.png"
var _art := "res://assets/art/cells/anim/signet_breath.png"
var _title := "印戒细胞瘤"
var _vp: SubViewport
var _frames := 0


## 画进一个 SubViewport 而不是 root：project.godot 把视口钉在 960x540，
## 三行四列在那个尺寸上小到看不清外圈 —— 而对照图的全部意义就在于看清那一圈。
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_art = args[1]
	if args.size() > 2:
		_title = args[2]
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	root.add_child(_vp)
	var bg := ColorRect.new()
	bg.color = Color("141b1f")
	bg.size = Vector2(SIZE)
	_vp.add_child(bg)


func _setup() -> void:
	var tex: Texture2D = load(_art)
	var arc := Shader.new()
	arc.code = ARC_CODE

	var grid := Node2D.new()
	_vp.add_child(grid)

	for row in 3:
		for col in 4:
			var p := Vector2(COL_X[col], ROW_Y[row])
			## 脚下的癌组织：外圈要在真背景上判读，不能悬空看
			var floor_tile := Sprite2D.new()
			floor_tile.texture = TISSUE_CANCER
			floor_tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			floor_tile.position = p
			floor_tile.scale = Vector2(SCALE, SCALE)
			grid.add_child(floor_tile)

			var cell := Sprite2D.new()
			cell.texture = tex
			cell.hframes = 6
			cell.frame = 2                     ## 呼吸表里挑一帧钉死，三行同帧才好比
			cell.offset = Vector2(0, -tex.get_height() / 2.0)
			cell.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			cell.position = p - Vector2(0, 4.0 * SCALE)   ## Board.TOP_FACE_DY
			cell.scale = Vector2(SCALE, SCALE)
			grid.add_child(cell)

			var overlay := Sprite2D.new()
			overlay.texture = tex
			overlay.hframes = 6
			overlay.frame = cell.frame
			overlay.offset = cell.offset
			overlay.z_index = 1
			overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			var mat := ShaderMaterial.new()
			mat.shader = NOW_SHADER if row == 0 else arc
			mat.set_shader_parameter("solid_color", SOLID_CELL_COLOR)
			mat.set_shader_parameter("progress", STEPS[col] / THRESHOLD)
			if row > 0:
				mat.set_shader_parameter("dim_alpha", 0.0 if row == 1 else 0.35)
			overlay.material = mat
			cell.add_child(overlay)

	_label("固化进度外圈：现状 vs 环形扫描（%s · 阈值 2.0）" % _title,
		Vector2(24, 16), 20, Color("eaf8fc"))
	for col in 4:
		_label("计数 %.1f" % STEPS[col], Vector2(COL_X[col] - 40.0, 62.0), 20, Color("ffb03a"))
	for row in 3:
		_label(ROW_LABEL[row], Vector2(20, ROW_Y[row] - 150.0), 20, Color("9fb4bd"))
	_label("现状 = 上半圈硬切，0.5 / 1.0 / 1.5 画出来完全一样",
		Vector2(24, 700), 20, Color("7f9199"))
	_label("提案 = 从正上方顺时针扫；B 比 A 多一道暗槽（未点亮那段）",
		Vector2(24, 728), 20, Color("7f9199"))


func _label(text: String, pos: Vector2, size: int, col: Color) -> void:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	_vp.add_child(l)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_setup()          ## 第 2 帧再搭：第 1 帧视口尺寸还没定下来
	if _frames < 14:
		return false
	var img := _vp.get_texture().get_image()
	img.save_png(_out)
	print("已保存 ", _out)
	return true
