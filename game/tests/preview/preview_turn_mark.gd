extends SceneTree
## 回合脚标放大看（Kevin 2026-09-12）—— 给人看的工具，不是测试。
##
## 两只细胞（左免疫、右黑色素瘤）各站一格；脚标一次只有一只（真机也是），所以两张图：先给免疫那格、再给癌那格，
## 拍子各取不同值，能看出虚线走了位；棋盘放大 3 倍。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_turn_mark.gd -- <输出前缀>
const WARMUP := 12
const ZOOM := 3.0
const IMMUNE_AT := Vector2i(-1, 0)
const CANCER_AT := Vector2i(1, 0)
var _out := "user://turn_mark"
var _board: Node2D
var _frames := 0
var _shot := 0
var _set_at := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.scale = Vector2(ZOOM, ZOOM)
	root.add_child(_board)


func _cell(tex_path: String, at: Vector2i) -> void:
	var sp := Sprite2D.new()
	var tex: Texture2D = load(tex_path)
	sp.texture = tex
	sp.hframes = CWMatch.BREATH_FRAMES
	sp.offset = Vector2(0, -tex.get_height() / 2.0)
	sp.position = _board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY)
	sp.z_index = _board.tile_z(at, _board.Z_CELL)
	_board.add_child(sp)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	var now := Time.get_ticks_msec()
	if _frames == WARMUP:
		_board.position = Vector2(480, 300) - _board.tile_center(Vector2i(0, 0)) * ZOOM
		_board.set_tissue(CANCER_AT, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
		_cell("res://assets/art/cells/anim/immune_breath.png", IMMUNE_AT)
		_cell("res://assets/art/cells/anim/melanoma_breath.png", CANCER_AT)
		_board.set_turn_ring(IMMUNE_AT, CWStyle.IMMUNE, 0.0)
		_set_at = now
		return false
	if now - _set_at < 200:
		return false
	if _shot == 0:
		root.get_texture().get_image().save_png(_out + "_immune.png")
		_board.set_turn_ring(CANCER_AT, CWStyle.CANCER, 0.3)   ## 第 3 拍：虚线挪了三格
		_set_at = now
		_shot = 1
		return false
	root.get_texture().get_image().save_png(_out + "_cancer.png")
	return true
