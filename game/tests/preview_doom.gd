extends SceneTree
## 「回合末会被压死」预警圈的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：判定对不对由 `t_pressure_doom` 守着，但那验的是「该不该报」。
## **报出来长什么样**代码验不了 —— 红圈在几种免疫贴图上都看得清吗、脉冲会不会太吵、
## 会不会和癌细胞的固化外圈撞脸，只能把图摆出来看。
##
## ⚠ 节点搭法是照 `CWMatch._add_doom_overlay` 抄的（那是私有的）。
## **颜色、透明度、脉冲一律现读 CWMatch 的常量与 `doom_pulse()`**，
## 所以调参数只改那一处，这里跟着走；只有那 8 行节点搭建是两份，改结构时记得同步。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_doom.gd -- <输出.png>
const WARMUP := 12
const SHOTS := [0.0, 0.25]     ## 连拍两帧：脉冲的亮暗两头
const ART := [
	"res://assets/art/cells/anim/immune_breath.png",
	"res://assets/art/cells/anim/tcell_breath.png",
	"res://assets/art/cells/anim/bcell_breath.png",
	"res://assets/art/cells/anim/macrophage_breath.png",
	"res://assets/art/cells/anim/dendritic_breath.png",
]

var _out := "user://doom.png"
var _board: Node2D
var _rings: Array[Sprite2D] = []
var _frames := 0
var _t := 0.0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	root.add_child(_board)


func _setup() -> void:
	## 五种免疫贴图各摆一只，都挂上预警圈 —— 要看的是「每种都认得出」
	var spots: Array = [Vector2i(-4, 0), Vector2i(-2, 0), Vector2i(0, 0),
		Vector2i(2, 0), Vector2i(4, 0)]
	for i in ART.size():
		var s := Sprite2D.new()
		var tex: Texture2D = load(ART[i])
		s.texture = tex
		s.hframes = 6
		s.offset = Vector2(0, -tex.get_height() / 2.0)
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.position = _board.tile_center(spots[i])
		s.z_index = _board.tile_z(spots[i], _board.Z_CELL)
		_board.add_child(s)

		var ring := Sprite2D.new()
		ring.texture = tex
		ring.hframes = 6
		ring.offset = s.offset
		ring.z_index = 1
		ring.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/shaders/solid_progress.gdshader")
		mat.set_shader_parameter("solid_color", CWMatch.DOOM_COLOR)
		mat.set_shader_parameter("progress", 1.0)
		ring.material = mat
		s.add_child(ring)
		_rings.append(ring)


func _process(d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_setup()
	if _frames < WARMUP:
		return false
	_t += d
	## 两帧分别取脉冲的最亮和最暗，看看两头的可读性
	var a: float = CWMatch.DOOM_ALPHA.y if _shot == 0 else CWMatch.DOOM_ALPHA.x
	for r in _rings:
		r.modulate.a = a
	if _frames < WARMUP + 2 + _shot * 3:
		return false
	var img := root.get_texture().get_image()
	var path := _out if _shot == 0 else _out.get_basename() + "_dim.png"
	img.save_png(path)
	print("已保存 ", path)
	_shot += 1
	return _shot >= SHOTS.size()
