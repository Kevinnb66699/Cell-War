## match.gd —— 一局对局的装配与呈现
##
## 职责只有两件：**把引擎组装起来跑**，以及**把引擎的状态画到棋盘上**。
## 规则一行都不在这里（规则全在 scripts/core/），界面交互在 CWUIBridge。
##
## 呈现走的是「每帧全量刷新」而不是事件驱动：引擎直接改 game.tiles / game.cells
## 的字典，没有变更信号，与其到处补信号，不如每帧把 127 格和几个细胞重刷一遍——
## board.set_tissue() 在贴图没变时会直接返回，所以这么做的代价接近零，
## 而好处是**画面永远不可能和状态对不上**（漏发一个信号那种 bug 从根上没有了）。
class_name CWMatch
extends Node2D

## 对局结束（winner = CWData.Faction）
signal finished(winner: int)

## 棋盘和相机都是**同级节点**：开场过场是同一个镜头往前推、不切场景，
## 所以菜单和对局共用同一张棋盘、同一台相机（见 Main.tscn 与 main.gd）。
@export var board_path: NodePath = ^"../Board"
@export var camera_path: NodePath = ^"../Camera2D"
@export var action_bar_path: NodePath = ^"UI/ActionBar"
@export var panel_path: NodePath = ^"UI/Panel"

@export var player_count := 4
## 哪几个位置由人来打；留空 = 一局可观战的 AI 互搏
@export var human_players: Array[int] = []
## AI 每步之间的停顿（毫秒），纯观感，不影响结算
@export var ai_delay_ms := 220
## 0 = 每局取当前时间做种子；填非 0 可复现同一局
@export var match_seed := 0
## 单独跑本场景时自己开局；挂在 Main 下面时由 main.gd 在过场结束后调 start()
@export var autostart := false

## 固化癌组织的色标。硬化外壳的美术还没有，但**固化格必须能一眼认出来**——
## 【裂解】和癌方【复活】都只对它生效，看不出来就没法玩。压暗一档是临时手段。
const MARK_SOLID := Color("0000004d")

## 开场绽开时每格翻面的那一下白闪
const FLASH_TIME := 0.22
const FLASH_ALPHA := 0.7

## 细胞贴脚落在格子「顶面中心」再往下 6px，和主菜单的装饰细胞同一套。
const CELL_FOOT_DY := 6.0
## 同一格站了多个细胞时左右错开的间距
const STACK_DX := 9.0

const IMMUNE_ART := {
	CWData.ImmuneType.BASIC: preload("res://assets/art/cells/immune.png"),
	CWData.ImmuneType.B_CELL: preload("res://assets/art/cells/bcell.png"),
	CWData.ImmuneType.T_CELL: preload("res://assets/art/cells/tcell.png"),
	CWData.ImmuneType.MACRO: preload("res://assets/art/cells/macrophage.png"),
	CWData.ImmuneType.DENDRITIC: preload("res://assets/art/cells/dendritic.png"),
}

var game: CWGame
var bridge: CWUIBridge

@onready var board: Node2D = get_node(board_path)
@onready var camera: Camera2D = get_node(camera_path)
@onready var action_bar: CWActionBar = get_node_or_null(action_bar_path)
@onready var panel: CWMatchPanel = get_node_or_null(panel_path)

var _dice: CWDice
var _cells_root: Node2D
var _cell_nodes: Array[Node2D] = []   ## 下标 = cell["id"]，和 game.cells 一一对应
var _bloom := {}      ## 开场还没揭开的格子：一律先按健康组织画
var _opening := false ## 正在演开场；start() 会把它带给桥（桥是 start() 里才建的）
var _flash := {}      ## 刚翻面的格子 → 白闪剩余时间


func _ready() -> void:
	_cells_root = Node2D.new()
	_cells_root.name = "Cells"
	board.add_child(_cells_root)
	## 骰子挂在棋盘下面，这样 place_at() 收到的就是棋盘坐标，
	## z_index 也能和组织块用同一套画家算法（见 dice.gd 的 place_at）。
	_dice = CWDice.new()
	board.add_child(_dice)
	if autostart:
		CWView.apply(camera, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
		start()


func start() -> void:
	game = CWGame.new()
	game.init(CWData.FACTION_ORDER[player_count],
		match_seed if match_seed != 0 else int(Time.get_unix_time_from_system()))
	bridge = CWUIBridge.new()
	bridge.game = game
	bridge.board = board
	bridge.dice = _dice
	bridge.bar = action_bar
	bridge.panel = panel
	bridge.human_pids = human_players
	bridge.opening = _opening    ## 绽开演完前先不弹询问界面
	bridge.delay_ms = ai_delay_ms
	bridge.delay_node = self
	## 同一个桥对象注册给所有玩家：人类那几位走界面，其余走 AI，
	## 掷骰演出按对象去重所以只演一遍（理由见 ui_bridge.gd 文件头）。
	for pid in game.order:
		game.bridges[pid] = bridge
	_run()


## 开场第二拍：初始癌组织从正中一格一格翻出来（团队定的三拍开场之二）。
##
## 顺序很讲究：start() 会一路跑到**第一次询问**才挂起，那时初始癌组织已经躺在
## game.tiles 里了，而本帧的 _process 还没跑 —— 所以在这中间把它们记进 _bloom
## 还来得及，玩家看到的第一帧仍是干净的健康组织。
##
## 揭示顺序不写死「中央 + 第一环」，而是按「离中心几格、同环按角度」排 ——
## 地图生成还在讨论中，初始癌区形状随时可能变，排序法对什么形状都成立。
func start_with_bloom(seconds: float) -> void:
	## 必须在 start() **之前**置位：桥是 start() 里才 new 出来的，
	## 在这之后再写 bridge.opening 就晚了（第一版就是这么错的，
	## 守卫静默失效、绽开还没演完落子提示就弹了出来）。
	_opening = true
	start()
	var order := _bloom_order()
	for c in order:
		_bloom[c] = true
	var step := seconds / maxf(order.size(), 1)
	for c in order:
		_bloom.erase(c)
		_flash[c] = FLASH_TIME
		await get_tree().create_timer(step).timeout
	_opening = false
	bridge.opening = false


func _bloom_order() -> Array:
	var out: Array = []
	for c: Vector2i in game.tiles:
		if game.is_cancerous(c):
			out.append(c)
	var origin: Vector2 = board.tile_center(Vector2i.ZERO)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := CWData.hex_dist(a, Vector2i.ZERO)
		var db := CWData.hex_dist(b, Vector2i.ZERO)
		if da != db:
			return da < db
		return (board.tile_center(a) - origin).angle() < (board.tile_center(b) - origin).angle())
	return out


func _run() -> void:
	var winner: int = await game.run_game()
	finished.emit(winner)


## 对局用完必须显式拆，否则 game 与各模块之间的强引用环不会被回收。
func _exit_tree() -> void:
	if game != null:
		game.dispose()
		game = null


func _process(delta: float) -> void:
	if game == null or game.tiles.is_empty():
		return
	for c: Vector2i in _flash.keys():
		_flash[c] -= delta
		if _flash[c] <= 0.0:
			_flash.erase(c)
	_sync_tiles()
	_sync_cells()
	if panel != null:
		panel.refresh(game)


func _sync_tiles() -> void:
	var marks := {}
	for c: Vector2i in game.tiles:
		var t: Dictionary = game.tiles[c]
		## 开场绽开期间，还没轮到的那几格先按健康组织画
		var tissue: int = CWData.Tissue.HEALTHY if _bloom.has(c) else int(t["tissue"])
		board.set_tissue(c, tissue, t["special"])
		if tissue == CWData.Tissue.SOLID:
			marks[c] = MARK_SOLID
	for c: Vector2i in _flash:
		marks[c] = Color(1, 1, 1, _flash[c] / FLASH_TIME * FLASH_ALPHA)
	## 交互高亮压过状态色标：正在选目标时，「这格能不能选」比「它是不是固化」重要。
	if bridge != null:
		marks.merge(bridge.marks, true)
	board.set_marks(marks)


func _sync_cells() -> void:
	while _cell_nodes.size() < game.cells.size():
		_cell_nodes.append(_make_cell_node(game.cells[_cell_nodes.size()]))
	## 同格可能站着多个细胞，得先数清楚每格几个才能左右错开
	var per_tile := {}
	for c in game.cells:
		if c["alive"]:
			per_tile[c["pos"]] = per_tile.get(c["pos"], 0) + 1
	var placed := {}
	for i in game.cells.size():
		var c: Dictionary = game.cells[i]
		var node: Node2D = _cell_nodes[i]
		node.visible = c["alive"]
		if not c["alive"]:
			continue
		var pos: Vector2i = c["pos"]
		var n: int = per_tile[pos]
		var k: int = placed.get(pos, 0)
		placed[pos] = k + 1
		var top: Vector2 = board.tile_center(pos)
		node.position = top + Vector2((k - (n - 1) / 2.0) * STACK_DX, CELL_FOOT_DY)
		node.z_index = board.tile_z(pos, board.Z_CELL)
		if c["faction"] == CWData.Faction.IMMUNE:
			_apply_immune_art(node as Sprite2D, c["itype"])


func _make_cell_node(cell: Dictionary) -> Node2D:
	var node: Node2D
	if cell["faction"] == CWData.Faction.IMMUNE:
		node = Sprite2D.new()
	else:
		node = CWCancerBlob.new()
	_cells_root.add_child(node)
	return node


## 分化会改 itype，所以贴图每帧对一次；offset 把锚点从贴图中心挪到脚底中心。
func _apply_immune_art(s: Sprite2D, itype: int) -> void:
	var tex: Texture2D = IMMUNE_ART[itype]
	if s.texture == tex:
		return
	s.texture = tex
	s.offset = Vector2(0, -tex.get_height() / 2.0)
