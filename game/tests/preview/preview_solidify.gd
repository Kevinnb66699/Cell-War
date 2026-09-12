extends SceneTree
## 固化进度地块贴图的**真机渲染**对照图。给人看的工具，不是测试。
##
## 贴图长什么样由 `tools/gen_solid_tissue.py` 决定，那边出的是离线预览图；
## 这里要验的是**接线之后在真棋盘上的样子**：
##   ① 四档在真实尺寸下分不分得开、变体够不够（相邻格会不会看出是克隆的）
##   ② 站了细胞的格子还读不读得出来 —— 细胞盖住的正是顶面中间那块
##
## **这张图定过一件事**：固化格原先叠着一层压暗（`CWMatch.MARK_SOLID`），
## 两版并排一看，压暗把 1.5 和 2.0 的明度拉近了，反而更难认 —— 于是 2026-09-09 删掉。
## 代码里看不出这种事，只能渲出来比。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_solidify.gd -- <输出.png>

const CELL_ART := preload("res://assets/art/cells/anim/signet_breath.png")
const ROWS := [-4, -2, 0, 2, 4]
## 每行的固化进度。0 = 干净癌组织，1.0 = 已固化。四档 = 计数 0.5/1.0/1.5/2.0。
const FRACS := [0.0, 0.25, 0.5, 0.75, 1.0]

var _out := "user://solidify.png"
var _board: Node2D
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	_board.scale = Vector2(1.27, 1.27)   ## 对局里的机位缩放，别在别的倍率上判断可读性
	root.add_child(_board)


## 一行一档，横向铺开看变体；中间那一列站一只癌细胞，看会不会被盖住。
func _paint() -> void:
	for i in ROWS.size():
		var r: int = ROWS[i]
		var frac: float = FRACS[i]
		for q in range(-4, 5):
			var c := Vector2i(q, r)
			if CWData.hex_dist(c, Vector2i.ZERO) > CWData.BOARD_RADIUS:
				continue
			var tissue: int = CWData.Tissue.SOLID if frac >= 1.0 else CWData.Tissue.CANCER
			## 用真 special：核心 / 骨髓也会固化，它们的石化贴图另有一族，
			## 传 NONE 的话预览里会把图标弄丢，看不出「图标没被石头盖掉」这件事
			_board.set_tissue(c, tissue, CWData.special_of(c), true, frac)


func _put_cells() -> void:
	for i in ROWS.size():
		var c := Vector2i(0, ROWS[i])
		var s := Sprite2D.new()
		s.texture = CELL_ART
		s.hframes = 6
		s.frame = 2
		s.offset = Vector2(0, -CELL_ART.get_height() / 2.0)
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.position = _board.tile_center(c)
		s.z_index = _board.tile_z(c, _board.Z_CELL)
		_board.add_child(s)


func _process(_d: float) -> bool:
	_frames += 1
	## 第 1 帧棋盘的 map 还没建完（Board._ready 里才铺 127 格），set_tissue 会全部落空
	if _frames == 2:
		_paint()
		_put_cells()
	if _frames < 40:
		return false
	root.get_texture().get_image().save_png(_out)
	print("已保存 ", _out)
	return true
