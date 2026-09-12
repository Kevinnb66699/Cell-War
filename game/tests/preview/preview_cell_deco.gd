extends SceneTree
## 印戒【囊性护甲】两枚小盾的轨道放大看（Kevin 2026-09-12：「护甲穿模」）—— 给人看的工具，不是测试。
##
## 六只印戒摆成一排，每只的装饰钉在轨道的不同相位（0° / 60° / … / 300°），一张图看完一整圈；
## 棋盘放大 4 倍。细胞摆法照抄 CWMatch（脚底 = 格顶面中心 + CELL_FOOT_DY，贴图 offset 抬半高，hframes 6），
## 装饰前后两个节点、z 夹着细胞 —— 和 _sync_cells 一样，穿不穿模就看这张图。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_cell_deco.gd -- <输出.png>
const WARMUP := 12
const SETTLE := 3
const ZOOM := 4.0
const SPOTS := [Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]
var _out := "user://cell_deco.png"
var _board: Node2D
var _game: CWGame
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.scale = Vector2(ZOOM, ZOOM)
	root.add_child(_board)
	## 一局真的 CWGame 给装饰读状态：六只印戒，护甲都没用过
	_game = CWGame.new()
	_game.init(CWData.FACTION_ORDER[6], 7)
	_game.setup.build_board()
	for i in SPOTS.size():
		var made := CWSetup.make_cell(i, 1, CWData.Faction.CANCER, SPOTS[i], -1, int(CWData.CancerType.SIGNET))
		made["energy"] = 50
		made["armor_used"] = false
		_game.cells.append(made)
		_game.tiles[SPOTS[i]]["tissue"] = CWData.Tissue.CANCER


## 棋盘的 map 要等它自己 _ready 之后才有：格子贴图 / 细胞 / 装饰都在 WARMUP 那一帧再摆
func _setup_scene() -> void:
	## 六格一排居中：格距 36，中点在第 3、4 只之间
	_board.position = Vector2(480.0 - 18.0 * ZOOM, 300.0) - _board.tile_center(Vector2i(0, 1)) * ZOOM
	var tex: Texture2D = load("res://assets/art/cells/anim/signet_breath.png")
	for i in SPOTS.size():
		var at: Vector2i = SPOTS[i]
		_board.set_tissue(at, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.hframes = CWMatch.BREATH_FRAMES
		sp.offset = Vector2(0, -tex.get_height() / 2.0)
		sp.position = _board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY)
		sp.z_index = _board.tile_z(at, _board.Z_CELL)
		_board.add_child(sp)
		## 相位钉死：第 i 只 = 一圈的第 i 个六分之一（shield_at 的角速度 0.85）
		var t_fixed := float(i) * (PI / 3.0) / 0.85
		for is_front in [false, true]:
			var deco := CWCellDeco.new()
			deco.front = bool(is_front)
			deco.game = _game
			deco.index = i
			deco.set("half_h", tex.get_height() / 2.0)   ## 同 _sync_cells；旧版装饰没这个属性时 set 静默略过
			deco.position = _board.tile_center(at)
			deco.z_index = sp.z_index + (1 if bool(is_front) else -1)
			deco.set_process(false)     ## 不走时间，画一次定格
			deco._t = t_fixed
			_board.add_child(deco)
			deco.queue_redraw()


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_setup_scene()
		return false
	if _frames < WARMUP + SETTLE:
		return false
	root.get_texture().get_image().save_png(_out)
	return true
