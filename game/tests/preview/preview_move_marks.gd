extends SceneTree
## 迁移模式下癌性组织的候选色（issue #47）—— 给人看的工具，不是测试。
##
## **为什么非得出图**：色标是**叠在地块贴图上的半透明剪影**（silhouette.gdshader，
## 混合比例 0x6E ≈ 0.43），叠完到底是什么色只有真渲染算得出来。改之前癌组织那块红
## （#B04A5A）叠一层免疫青被洗成 #79849F 的灰蓝，而健康组织叠出来是 #2F8491 ——
## 两种组织在迁移模式里几乎是一个色，正是 Kevin 附图里那一格。
##
## 一次跑出**同一块棋盘**的改前 / 改后两帧（种子写死、两帧逐格可比）：
##   godot --path game --script res://tests/preview/preview_move_marks.gd -- <输出.png>
## 落地两个文件：`<输出>_改前.png` / `<输出>_改后.png`
##
## **不能加 --headless**：要的就是真渲染的那一层混合。
const SEED := 20260919
const WARMUP := 12
## 高亮淡入 MARK_FADE 0.22 + 逐环 MARK_RING_DELAY 两环，留够再截
const SETTLE := 0.8

var _out := "user://move_marks.png"
var _board: Node2D
var _game: CWGame
var _mirror: CWMirror
var _tiles: Array[Vector2i] = []
var _cap: Label
var _sub: Label
var _stage := 0
var _t := 0.0
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_game = CWGame.new()
	_game.init(CWData.FACTION_ORDER[4], SEED)
	## `begin()` 而不是 `build_board()`：铺初始癌组织那一步在它里头，
	## 只建棋盘的话全盘都是健康组织，这张图什么也证明不了（第一版就是这么空跑的）
	_game.setup.begin()
	## 再把靠里的两格**固化**掉：固化癌组织也走 is_cancerous 那一档，一起看
	var solid_left := 2
	for c: Vector2i in _game.tiles:
		if solid_left > 0 and int(_game.tiles[c]["tissue"]) == CWData.Tissue.CANCER \
				and CWData.special_of(c) == CWData.Special.NONE:
			_game.tiles[c]["tissue"] = CWData.Tissue.SOLID
			solid_left -= 1
	_mirror = CWMirror.new()
	var err := _mirror.sync_from(_game)
	if err != "":
		push_error("preview_move_marks：镜像装载失败 —— %s" % err)
	## 候选格取「贴着癌区那一格」的两环：一半健康一半癌性 ——
	## 正是选迁移落点时真要读的那种画面（只画健康格的话这张图什么也证明不了）
	var center := _boundary_tile()
	for c: Vector2i in _mirror.tiles:
		if c != center and CWData.hex_dist(c, center) <= 2:
			_tiles.append(c)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cap = _label("", Vector2(16, 14), CWStyle.TEXT_HI, CWStyle.SIZE_BODY)
	_sub = _label("", Vector2(16, 44), CWStyle.TEXT_DIM, CWStyle.SIZE_LABEL)


## 癌邻居最多的那一格健康组织 = 战线上那一格
func _boundary_tile() -> Vector2i:
	var best := Vector2i.ZERO
	var best_n := -1
	for c: Vector2i in _mirror.tiles:
		if _mirror.is_cancerous(c):
			continue
		var n := 0
		for d in CWData.neighbors(c):
			if _mirror.is_cancerous(d):
				n += 1
		if n > best_n:
			best_n = n
			best = c
	return best


func _label(text: String, at: Vector2, color: Color, size: int) -> Label:
	var l := CWStyle.label(text, size, color)
	l.position = at
	root.add_child(l)
	return l


## 照 CWMatch._sync_tiles 那一套把 127 格真刷一遍（固化进度也给，石化贴图才出得来）
func _paint_tiles() -> void:
	for c: Vector2i in _mirror.tiles:
		var t: Dictionary = _mirror.tiles[c]
		var tissue: int = int(t["tissue"])
		var solid: float = 0.0 if tissue == CWData.Tissue.HEALTHY \
			else float(t["d"]["solid_fraction"]) / 1000.0
		_board.set_tissue(c, tissue, t["special"], int(t["cards"]) > 0, solid)


## after = false 照改之前（癌性格也用免疫青），true 照现在（癌性格换红）
func _marks(after: bool) -> Dictionary:
	var m := {}
	for c in _tiles:
		m[c] = _board.MARK_MOVE_SICK if after and _mirror.is_cancerous(c) else _board.MARK_MOVE
	return m


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	## 贴图要等 Board._ready() 建完 map 才刷得上（同 preview_erosion 那个坑）
	if _frames == WARMUP:
		## 照对局机位摆：zoom 1.27、中央格对到锚点（CWView.GAME_ZOOM / GAME_ANCHOR）。
		## **只能在这儿摆** —— tile_center 要等 Board._ready() 建完 map 才有值
		_board.scale = Vector2(CWView.GAME_ZOOM, CWView.GAME_ZOOM)
		_board.position = Vector2(CWView.GAME_ANCHOR.x, 300.0) \
			- _board.tile_center(Vector2i.ZERO) * CWView.GAME_ZOOM
		_paint_tiles()
		_repaint(false)
		return false
	_t += delta
	if _t < SETTLE:
		return false
	var path := "%s_%s.png" % [_out.trim_suffix(".png"), "改前" if _stage == 0 else "改后"]
	var err := root.get_texture().get_image().save_png(path)
	print("已保存 %s (err=%d)" % [path, err])
	if _stage == 1:
		return true
	_stage = 1
	_repaint(true)
	return false


func _repaint(after: bool) -> void:
	_cap.text = "issue #47 · 迁移模式的候选格：%s" % ("改后（癌性组织换红）" if after else "改前（一律免疫青）")
	_sub.text = "同一块棋盘、同一批候选格（种子 %d）。改前癌性格叠完是灰蓝 #79849F，和健康格的 #2F8491 几乎同色；改后是 #C55163" % SEED
	_board.set_marks(_marks(after))
	_t = 0.0
