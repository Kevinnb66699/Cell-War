extends SceneTree
## 新手教程 v2 · S9a **真机四帧**：间章分镜 2 的「世界重心平移到玩家」长什么样。
## 出处：PRD:395-397「地图以免疫细胞为中心向四周延伸，补齐缺失格子使其处于一个
## **完整棋盘的中央格**」（Kevin 2026-09-19 拍板走重心平移，不是纯镜头、也不是重心不动）。
##
## 四帧：
##   ① 第四关照旧（半径 6 / 127 格、镜头是「地图调中」的对局机位）—— 这一片没动它，截来对照；
##   ② 重心平移**前**（同一份盘面，镜头换成「玩家调中」：玩家挪到屏幕正中，倍率不变）；
##   ③ 重心平移**后**的浮现中（玩家已经是 `(0,0)`、四周新格按环错峰淡入）；
##   ④ 浮现完（397 格的完整棋盘，玩家在正中）。
##
## ②③ 对着看就是验收点：**玩家在屏幕上一动不动、老格的相对位置一格没挪**，
## 画面上只多了四周长出来的新格。整张图跳一下 = 这一片做坏了。
##
## 跑（**不能加 --headless**，要真渲染；新脚本先 `--import`）：
##   godot --path game --script res://tests/preview/preview_tutor_recenter.gd -- <输出目录>

const TUT_STAGE := preload("res://scripts/kernel/cw_tutorial_stage.gd")
const TUTOR_SCRIPT := preload("res://scripts/kernel/cw_tutor_script.gd")

## 重心平移之后那个「完整棋盘」的半径（397 格）：§7.4 的绝对坐标表减去 (6,-2) 之后，
## 第六关最远的 T 细胞落在 (−11,1)，离盘心正好 11
const RADIUS := 11
const CELL_FOOT_DY := 6.0      ## 同 CWMatch：脚底落在格顶面中心再往下 6px
const BREATH_FRAMES := 6
const CELL_ART := {
	"ImmuneBasic": preload("res://assets/art/cells/anim/immune_breath.png"),
	"TCell": preload("res://assets/art/cells/anim/tcell_breath.png"),
	"BCell": preload("res://assets/art/cells/anim/bcell_breath.png"),
	"Macrophage": preload("res://assets/art/cells/anim/macrophage_breath.png"),
	"Dendritic": preload("res://assets/art/cells/anim/dendritic_breath.png"),
	"Osteosarcoma": preload("res://assets/art/cells/anim/osteo_breath.png"),
	"SmallCellLung": preload("res://assets/art/cells/anim/sclc_breath.png"),
	"SignetRing": preload("res://assets/art/cells/anim/signet_breath.png"),
	"Melanoma": preload("res://assets/art/cells/anim/melanoma_breath.png"),
}

var _dir := "user://"
var _board            ## Board.tscn 的实例。不标类型：board.gd 没有 class_name
var _cells: Node2D
var _cam: Camera2D
var _stage
var _frames := 0
var _t := 0.0
var _queue: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]
	if not _dir.ends_with("/"):
		_dir += "/"
	DirAccess.make_dir_recursive_absolute(_dir)

	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = CWView.screen_size()
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cells = Node2D.new()
	_board.add_child(_cells)
	_cam = Camera2D.new()
	root.add_child(_cam)

	var d = TUTOR_SCRIPT.new()
	_stage = TUT_STAGE.new()
	_stage.cfg = { "autorun": false }   ## 同 CWMatch：不关的话内核会自己把整局跑完
	if _stage.open_level(d.load_level("c2_l4")) == null:
		push_error("第四关开不起来：%s" % str(_stage.errors))
		quit()
		return

	_at(0.05, func() -> void:
		_sync()
		_board.set_active_tiles(CWData.all_coords(), 0.0)
		_camera("map"))
	_at(0.60, func() -> void: _shot("01_第四关_半径6_照旧"))
	## 分镜 2 前半段：镜头先平移到玩家（数据里就是 `ui.camera = {anchor: player, align: center}`）
	_at(0.70, func() -> void: _camera("player"))
	_at(1.20, func() -> void: _shot("02_重心平移_前_玩家居中"))
	_at(1.30, func() -> void: _recenter())
	_at(1.55, func() -> void: _shot("03_重心平移_后_新环浮现中"))
	_at(2.20, func() -> void: _shot("04_重心平移_后_浮现完_397格"))
	_at(2.40, func() -> void:
		if _stage.kernel != null:
			_stage.kernel.close()
		_stage.dispose()
		quit())


## 关内换盘：把活局面整体挪到「玩家 = 新盘心」，盘子同时长到半径 11。
## 次序与 `CWMatch._tutor_recenter` 一字不差 —— 这一帧要是好看而真机难看，那就是这儿抄漏了
func _recenter() -> void:
	var me: Vector2i = _stage._game.cell_of(0)["pos"]
	if _stage.reload_recentered(-me, RADIUS) == null:
		push_error("重心平移失败：%s" % str(_stage.errors))
		return
	_board.ensure_radius(RADIUS)          ## 真机走 `_adopt_mirror`，这儿手动补上同一句
	_sync()
	_board.set_active_tiles(CWData.all_coords(RADIUS))   ## 新格按环错峰淡入
	_camera("player")


## 引擎状态 → 棋盘贴图（真机那一套在 `CWMatch._sync_tiles` / `_sync_cells`，这儿只要组织与细胞）
func _sync() -> void:
	var g = _stage._game
	for c in CWData.all_coords(int(g.board_radius)):
		var t: Dictionary = g.tile(c)
		_board.set_tissue(c, int(t["tissue"]), int(t["special"]))
	var necro: Array = []
	for c in CWData.all_coords(int(g.board_radius)):
		if int((g.tile(c) as Dictionary)["necrosis"]) > 0:
			necro.append(c)
	_board.set_necrosis(necro)
	for n in _cells.get_children():
		_cells.remove_child(n)
		n.queue_free()
	for cell in g.cells:
		if not bool((cell as Dictionary)["alive"]):
			continue
		_draw_cell(cell as Dictionary)


func _draw_cell(cell: Dictionary) -> void:
	var kind := TUTOR_SCRIPT.kind_name(cell)
	if not CELL_ART.has(kind):
		return
	var at: Vector2i = cell["pos"]
	var tex: Texture2D = CELL_ART[kind]
	var s := Sprite2D.new()
	s.texture = tex
	s.hframes = BREATH_FRAMES
	s.frame = 2
	s.offset = Vector2(0, -tex.get_height() / 2.0)   ## 锚点从贴图中心挪到脚底中心
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.position = _board.tile_center(at) + Vector2(0, CELL_FOOT_DY)
	s.z_index = _board.tile_z(at, _board.Z_CELL)
	_cells.add_child(s)


## `anchor` 两档照 `ui.camera`：`map` = 地图调中（第四关今天就是它），`player` = 玩家调中。
## 取景一律走 `CWView.tutor_framing` —— 真机与这张图算的是同一套数
func _camera(anchor: String) -> void:
	var focus: Variant = null
	if anchor == "player":
		focus = _stage._game.cell_of(0)["pos"]
	var f := CWView.tutor_framing(_board, _board.active_tiles(), "center", focus, true)
	CWView.apply(_cam, _board, float(f["zoom"]), f["look_at"], f["anchor"])


func _at(t: float, fn: Callable) -> void:
	_queue.append({ "at": t, "fn": fn })
	_queue.sort_custom(func(a, b) -> bool: return a["at"] < b["at"])


func _process(delta: float) -> bool:
	## 头两帧棋盘的 map 还没铺完（Board._ready 里才建 127 格），
	## 这时候 set_tissue / tile_center 全部落空（preview_solidify 踩过）
	_frames += 1
	if _frames < 3:
		return false
	_t += delta
	while not _queue.is_empty() and _t >= _queue[0]["at"]:
		var step: Dictionary = _queue.pop_front()
		step["fn"].call()
	return false


func _shot(shot_name: String) -> void:
	var path: String = _dir + shot_name + ".png"
	var err := root.get_texture().get_image().save_png(path)
	print("已保存 %s (err=%d)" % [path, err])
