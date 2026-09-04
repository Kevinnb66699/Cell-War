extends Node2D

## 【临时演示场景】传送溶解 shader 的效果预览，不参与对局。
##
## 跑法：Godot 编辑器里直接运行 res://scenes/TeleportPreview.tscn，
## 或命令行 godot --path game res://scenes/TeleportPreview.tscn
##
## 演什么：一排不同体型的细胞循环「沉入 → 延迟 → 凝出」，
## 验证三件事——向下偏置的溶解方向、边缘亮色、以及 shader 与呼吸表
## 帧切换共存不穿帮。接入方案（残影节点、状态差分）另案，见动画规格讨论。
## 看完效果后本场景随时可删。

const SHADER := preload("res://assets/shaders/teleport.gdshader")
const BREATH_FRAMES := 6
const BREATH_FPS := 6.0

const TEXTURES := [
	preload("res://assets/art/cells/anim/immune_breath.png"),
	preload("res://assets/art/cells/anim/macrophage_breath.png"),
	preload("res://assets/art/cells/anim/melanoma_breath.png"),
	preload("res://assets/art/cells/anim/sclc_breath.png"),
	preload("res://assets/art/cells/anim/osteo_breath.png"),
]

## 演两套边缘色：免疫青（离场）和癌方橙，看哪个更读得清
const EDGE_IMMUNE := Color(0.188, 0.82, 0.98)
const EDGE_CANCER := Color(1.0, 0.69, 0.23)

var _mats: Array[ShaderMaterial] = []
var _sprites: Array[Sprite2D] = []
var _breath_acc := 0.0

func _ready() -> void:
	for i in TEXTURES.size():
		var tex: Texture2D = TEXTURES[i]
		var s := Sprite2D.new()
		s.texture = tex
		s.hframes = BREATH_FRAMES
		## 贴脚站在同一水平线上（和 match.gd 的锚点算法同款）
		s.offset = Vector2(0, -tex.get_height() / 2.0)
		s.position = Vector2(200 + i * 140, 270)
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		## 离场边缘色：免疫细胞青、癌细胞橙
		mat.set_shader_parameter("edge_color",
			EDGE_IMMUNE if i < 2 else EDGE_CANCER)
		s.material = mat
		add_child(s)
		_sprites.append(s)
		_mats.append(mat)
		_loop(i)
	_maybe_capture()


## 一轮完整演出：沉入 0.25s → 停 0.35s → 凝出 0.3s → 完好停 1.4s。
## 各细胞错开 0.4s 启动，顺便看两个细胞一沉一冒同框时的观感。
func _loop(i: int) -> void:
	var mat := _mats[i]
	var s := _sprites[i]
	var tw := s.create_tween().set_loops()
	tw.tween_interval(i * 0.4)
	tw.tween_callback(func() -> void: mat.set_shader_parameter("emerge", 0.0))
	tw.tween_method(func(v: float) -> void:
		mat.set_shader_parameter("progress", v), 0.0, 1.0, 0.25)
	tw.tween_interval(0.35)
	## 凝出阶段：翻偏置锚点（脚底先长回来），边缘换白——离场阵营色、
	## 落场白色，颜色本身在讲「走 / 到」
	tw.tween_callback(func() -> void:
		mat.set_shader_parameter("emerge", 1.0)
		mat.set_shader_parameter("edge_color", Color.WHITE))
	tw.tween_method(func(v: float) -> void:
		mat.set_shader_parameter("progress", v), 1.0, 0.0, 0.3)
	tw.tween_callback(func() -> void:
		mat.set_shader_parameter("edge_color",
			EDGE_IMMUNE if i < 2 else EDGE_CANCER))
	tw.tween_interval(1.4)


## 呼吸帧照常推着走：确认溶解和帧切换互不打架。
func _process(delta: float) -> void:
	_breath_acc += delta * BREATH_FPS
	if _breath_acc < 1.0:
		return
	var steps := int(_breath_acc)
	_breath_acc -= steps
	for i in _sprites.size():
		var s := _sprites[i] as Sprite2D
		s.frame = (s.frame + steps) % BREATH_FRAMES


## 自动截图模式（命令行带 `-- capture` 时启用）：在沉入中段和凝出中段
## 各存一张 PNG 到仓库根目录，供不开编辑器快速看效果。平时不起作用。
func _maybe_capture() -> void:
	if not "capture" in OS.get_cmdline_user_args():
		return
	var shots := [[0.525, "_teleport_mid_dissolve.png"],   ## cell1 沉入中段 progress≈0.5
		[0.225, "_teleport_mid_emerge.png"]]   ## 接在上张后合计 0.75s：cell0 凝出中段
	for shot in shots:
		await get_tree().create_timer(shot[0]).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path: String = "C:/Users/AS/Desktop/cellwar/" + shot[1]
		var err := img.save_png(path)
		print("shot ", shot[1], " err=", err, " empty=", img.is_empty())
	get_tree().quit()
