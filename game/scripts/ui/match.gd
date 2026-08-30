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
@export var ui_path: NodePath = ^"UI"
@export var pause_path: NodePath = ^"UI/Pause"
@export var hand_path: NodePath = ^"UI/Hand"
@export var toast_path: NodePath = ^"UI/Toast"
@export var settle_path: NodePath = ^"UI/Settle"

@export var player_count := 4
## 哪几个位置由人来打；留空 = 一局可观战的 AI 互搏
@export var human_players: Array[int] = []
## AI 强度：false = 启发式（普通），true = 蒙特卡洛推演（较强）。
## 由对局配置面板拨；观战局也吃这一位。
@export var ai_smart := false
## AI 每步之间的停顿改由设置页管（CWSettings.ai_delay_ms），纯观感不影响结算
## 0 = 每局取当前时间做种子；填非 0 可复现同一局
@export var match_seed := 0
## 单独跑本场景时自己开局；挂在 Main 下面时由 main.gd 在过场结束后调 start()
@export var autostart := false

## 此刻能不能存档：引擎只在 pending 边界有完整快照（CWSave 的写入条件）。
## 暂停菜单拿它决定「保存并退出」亮不亮。
func can_save_now() -> bool:
	return game != null and not game._pending.is_empty() and not game.is_over()

## 固化癌组织的色标。硬化外壳的美术还没有，但**固化格必须能一眼认出来**——
## 【裂解】和癌方【复活】都只对它生效，看不出来就没法玩。压暗一档是临时手段。
const MARK_SOLID := Color("0000004d")

## 开场绽开时每格翻面的那一下白闪
const FLASH_TIME := 0.22
const FLASH_ALPHA := 0.7

## 细胞出现/复活时的淡入。团队试玩反馈「显示得太突然」——
## 淡入 + 稍微放大到位，读起来像「就位」而不是「凭空冒出来」。
const CELL_POP := 0.32
const CELL_POP_SCALE := 0.7

## 细胞贴脚落在格子「顶面中心」再往下 6px，和主菜单的装饰细胞同一套。
const CELL_FOOT_DY := 6.0
## 同一格站了多个细胞时左右错开的间距
const STACK_DX := 9.0

## 棋盘上的细胞用**横排 6 帧的静息呼吸表**（美术 2026-08-29 交付，帧内容上下浮动 0~2px）。
## 静态单帧图仍在 cells/ 根目录，主菜单装饰、右侧面板等静态场合继续用它们。
const IMMUNE_ART := {
	CWData.ImmuneType.BASIC: preload("res://assets/art/cells/anim/immune_breath.png"),
	CWData.ImmuneType.B_CELL: preload("res://assets/art/cells/anim/bcell_breath.png"),
	CWData.ImmuneType.T_CELL: preload("res://assets/art/cells/anim/tcell_breath.png"),
	CWData.ImmuneType.MACRO: preload("res://assets/art/cells/anim/macrophage_breath.png"),
	CWData.ImmuneType.DENDRITIC: preload("res://assets/art/cells/anim/dendritic_breath.png"),
}

## 癌细胞四种。小细胞肺癌的帧只有 16x18（其余 32x34）—— 是美术故意画小的，
## 别拿缩放去凑齐：贴图过滤是最近邻，非整数倍缩放会磨出锯齿（约定 #13 同理）。
const CANCER_ART := {
	CWData.CancerType.MELANOMA: preload("res://assets/art/cells/anim/melanoma_breath.png"),
	CWData.CancerType.SIGNET: preload("res://assets/art/cells/anim/signet_breath.png"),
	CWData.CancerType.OSTEO: preload("res://assets/art/cells/anim/osteo_breath.png"),
	CWData.CancerType.SCLC: preload("res://assets/art/cells/anim/sclc_breath.png"),
}

## 呼吸动画：6 帧/秒 × 6 帧 = 一秒一次完整呼吸；相位按细胞编号错开，免得全场同频起伏
const BREATH_FPS := 6.0
const BREATH_FRAMES := 6

var game: CWGame
var bridge: CWUIBridge

@onready var board: Node2D = get_node(board_path)
@onready var camera: Camera2D = get_node(camera_path)
@onready var action_bar: CWActionBar = get_node_or_null(action_bar_path)
@onready var panel: CWMatchPanel = get_node_or_null(panel_path)
## 整层 HUD。开局前必须关掉 —— 棋盘和相机是和主菜单共用的同一份，
## 不关的话主菜单右边会凭空多出一条空竖条（2026-08-27 接上 Main 后出现的）。
@onready var ui: CanvasLayer = get_node_or_null(ui_path)
@onready var pause_menu: CWPauseMenu = get_node_or_null(pause_path)
@onready var hand: CWHand = get_node_or_null(hand_path)
@onready var toast: CWToast = get_node_or_null(toast_path)
## 结算屏。谁来开它、开完选了什么由 main.gd 管（那是场景流转，不是对局呈现），
## 这里只负责在拆局时把它擦掉。
@onready var settle: CWSettleScreen = get_node_or_null(settle_path)

var _dice: CWDice
var _cells_root: Node2D
var _cell_nodes: Array[Node2D] = []   ## 下标 = cell["id"]，和 game.cells 一一对应
var _was_alive: Array[bool] = []      ## 上一帧的存活状态，用来认出「复活」这一下
var _bloom := {}      ## 开场还没揭开的格子：一律先按健康组织画
var _hand_seen := {}  ## pid -> 上一帧的手牌数，用来认出「刚抽了一张」
var _hand_pid := -1   ## 抽屉正在显示谁的手牌
var _opening := false ## 正在演开场；start() 会把它带给桥（桥是 start() 里才建的）
var _breath_acc := 0.0   ## 呼吸计时的小数积累
var _breath_step := 0    ## 全局呼吸步进（各细胞再按编号错相位）
var _fading := false  ## 正在演返场淡出：这期间**必须停掉每帧刷新**，
                      ## 否则 _sync_tiles 会把刚淡成健康的格子又刷回癌性
var _flash := {}      ## 刚翻面的格子 → 白闪剩余时间
var _tile_info: CWTileInfo   ## 悬停格子详情（_ready 里程序化补进 UI 层）
var _log_panel: CWLogPanel   ## 对局日志面板（L 键开关），同样程序化补进


func _ready() -> void:
	_cells_root = Node2D.new()
	_cells_root.name = "Cells"
	board.add_child(_cells_root)
	## 骰子挂在棋盘下面，这样 place_at() 收到的就是棋盘坐标，
	## z_index 也能和组织块用同一套画家算法（见 dice.gd 的 place_at）。
	_dice = CWDice.new()
	board.add_child(_dice)
	if ui != null:
		## 悬停格子详情：程序化补进 UI 层，但要压在暂停菜单**下面** ——
		## 暂停时 _process 停了，信息卡收不掉，不能让它浮在暂停层上。
		## 悬停信号在 start()/teardown() 里成对开合（拆局约定：信号必须断干净）。
		_tile_info = CWTileInfo.new()
		ui.add_child(_tile_info)
		if pause_menu != null:
			ui.move_child(_tile_info, pause_menu.get_index())
		## 日志面板压在信息卡下面：两者都开着时，悬停详情仍然读得到
		_log_panel = CWLogPanel.new()
		ui.add_child(_log_panel)
		ui.move_child(_log_panel, _tile_info.get_index())
		ui.visible = false
	if autostart:
		CWView.apply(camera, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
		start()


## snap 非空 = 从存档继续：装配完把快照原样放回去，run_game 会把存档那一刻
## 待决的询问重新问出来（恢复点必然是 pending 边界，CWSave 只在那儿写得出档）。
func start(snap: Dictionary = {}) -> void:
	_fading = false
	if _cells_root != null:
		_cells_root.modulate.a = 1.0     ## 上一局淡出留下的，开新局要还原
	if ui != null:
		ui.visible = true
		for c in ui.get_children():
			if c is Control:
				(c as Control).modulate.a = 1.0
	if pause_menu != null:
		pause_menu.active = true
		pause_menu.can_save = can_save_now
	if _tile_info != null and not board.tile_hovered.is_connected(_tile_info.on_hover):
		board.tile_hovered.connect(_tile_info.on_hover)
	if _log_panel != null:
		_log_panel.active = true
	game = CWGame.new()
	game.init(CWData.FACTION_ORDER[player_count],
		match_seed if match_seed != 0 else int(Time.get_unix_time_from_system()))
	if not snap.is_empty():
		game.restore(snap)   ## rng 状态也在快照里，init 用的种子随之作废
	bridge = CWUIBridge.new()
	bridge.game = game
	bridge.board = board
	bridge.dice = _dice
	bridge.bar = action_bar
	bridge.panel = panel
	bridge.toast = toast
	bridge.camera = camera
	bridge.hand = hand   ## 方案甲：打出/弃置手势从手牌抽屉来
	bridge.human_pids = human_players
	bridge.enabled = ai_smart    ## 「较强」= 蒙特卡洛推演（桥的基类），默认启发式
	bridge.opening = _opening    ## 绽开演完前先不弹询问界面
	bridge.delay_ms = CWSettings.ai_delay_ms
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


## 返场淡出：让棋盘上的东西**淡着消失**，而不是啪地不见（团队 2026-08-27 反馈）。
## 真正的拆解由 teardown() 在淡完之后做 —— 这里只管演。
##
## 第一件事是把对局叫停：不然淡出途中 AI 还在走棋、组织还在变色，
## 一边淡一边动，看起来像出了故障。
func fade_out(seconds: float) -> void:
	if game == null or _fading:
		return
	game.aborted = true
	if bridge != null:
		bridge.abort()
	_fading = true
	board.set_marks({})                      ## 高亮自己会淡掉
	board.fade_to_healthy(seconds)
	if _cells_root != null:
		var tw := _cells_root.create_tween()
		tw.tween_property(_cells_root, "modulate:a", 0.0, seconds)
	## HUD 稍微早一点淡完 —— 它不在棋盘上，跟着棋盘一起慢慢消反而拖沓
	if ui != null:
		for c in ui.get_children():
			if c is Control and (c as Control).visible:
				var ui_tw := (c as Control).create_tween()
				ui_tw.tween_property(c, "modulate:a", 0.0, seconds * 0.6)


## 拆掉当前这一局，把棋盘擦回开局前的样子。
##
## 返回主菜单必须走这里：棋盘和相机是**和菜单共用的同一份**，
## 不擦干净的话上一局的癌组织和细胞会留在菜单背景里。
func teardown() -> void:
	_fading = false
	if game != null:
		## 顺序要紧：先让引擎收摊、再唤醒卡住的询问（它会同步一路展开回来），
		## **最后**才 dispose。反过来的话展开途中会碰到已经置空的模块。
		game.aborted = true
		if bridge != null:
			bridge.abort()
		game.dispose()
		game = null
	bridge = null
	_opening = false
	for node in _cell_nodes:
		node.queue_free()
	_cell_nodes.clear()
	_was_alive.clear()
	_bloom.clear()
	_flash.clear()
	_hand_seen.clear()
	_hand_pid = -1
	if hand != null:
		hand.clear()
	if toast != null:
		toast.hide_now()
	if _tile_info != null:
		_tile_info.hide_now()
	if _log_panel != null:
		_log_panel.active = false
		_log_panel.hide_now()
	if settle != null:
		settle.reset()
	## 退出游戏时 _exit_tree 也会走到这里，那时棋盘可能已经被释放了
	if is_instance_valid(board):
		if _tile_info != null and board.tile_hovered.is_connected(_tile_info.on_hover):
			board.tile_hovered.disconnect(_tile_info.on_hover)
		for c in CWData.all_coords():
			board.set_tissue(c, CWData.Tissue.HEALTHY, CWData.special_of(c))
		board.set_marks({})
	if action_bar != null:
		action_bar.clear()
	if panel != null:
		panel.reset()
	if ui != null:
		ui.visible = false
	if pause_menu != null:
		pause_menu.active = false
		pause_menu.close()


## 对局用完必须显式拆，否则 game 与各模块之间的强引用环不会被回收。
func _exit_tree() -> void:
	teardown()


func _process(delta: float) -> void:
	if game == null or game.tiles.is_empty() or _fading:
		return
	for c: Vector2i in _flash.keys():
		_flash[c] -= delta
		if _flash[c] <= 0.0:
			_flash.erase(c)
	_sync_tiles()
	_sync_cells()
	_animate_breath(delta)
	_sync_hand()
	if panel != null:
		panel.refresh(game)
	if _tile_info != null:
		_tile_info.sync(delta, game, board, camera, _opening or _fading)
	if _log_panel != null:
		_log_panel.refresh(game)


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
		## 死而复活的也要淡入一次 —— 它和刚落子一样是「凭空出现」
		if c["alive"] and not _was_alive[i]:
			_pop_in(node)
		_was_alive[i] = c["alive"]
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


## 手牌抽屉。抽到的卡从**发起抽卡的那个细胞**身上飞出来 ——
## 让「是谁抽的」这件事自己说清楚，而不是凭空出现在角落里。
##
## 显示谁的手牌：轮到哪个人类玩家就显示谁的；不是人类回合时保持上一次。
## （热座还没定案，定了之后这里就是现成的。）
func _sync_hand() -> void:
	if hand == null or human_players.is_empty():
		return
	if game.current_pid in human_players:
		_hand_pid = game.current_pid
	elif _hand_pid < 0:
		_hand_pid = human_players[0]
	if _hand_pid >= game.cells.size():
		return                       ## 开局布置阶段，这个人还没落子
	var cell: Dictionary = game.cell_of(_hand_pid)
	var cards: PackedStringArray = PackedStringArray(cell["hand"])
	var n: int = cards.size()
	var was: int = _hand_seen.get(_hand_pid, -1)
	if was == n:
		return
	_hand_seen[_hand_pid] = n
	if was >= 0 and n > was:
		hand.deal_from(n, CWView.board_to_screen(camera, board.tile_center(cell["pos"])), cards)
	else:
		hand.sync(n, Vector2.INF, cards)   ## 首次显示 / 换人 / 打出去了：直接就位，不演


func _make_cell_node(cell: Dictionary) -> Node2D:
	var node := Sprite2D.new()
	## 癌细胞的种类一局之内不会变（会变形态的只有免疫方的分化），贴图建节点时定一次就够。
	## 免疫的 itype 会变，所以它的贴图交给 _sync_cells 每帧对一次。
	if cell["faction"] == CWData.Faction.CANCER:
		_set_cell_art(node, CANCER_ART[cell["ctype"]])
	_cells_root.add_child(node)
	_was_alive.append(false)   ## 下一次 _sync_cells 就会认出「刚出现」并淡入
	return node


## 淡入 + 放大到位。只动 modulate 和 scale ——
## position 每帧都被 _sync_cells 重写，拿它做补间会被当场覆盖掉。
func _pop_in(node: Node2D) -> void:
	node.modulate.a = 0.0
	node.scale = Vector2.ONE * CELL_POP_SCALE
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "modulate:a", 1.0, CELL_POP)
	tw.parallel().tween_property(node, "scale", Vector2.ONE, CELL_POP)


## 静息呼吸：所有活细胞的帧号循环推进。相位 = 全局步进 + 细胞编号——
## 刻意不用随机数（UI 不碰 game.rng，那是对局状态的一部分；别的随机源又破坏可复现）。
func _animate_breath(delta: float) -> void:
	_breath_acc += delta * BREATH_FPS
	if _breath_acc < 1.0:
		return
	var steps := int(_breath_acc)
	_breath_acc -= steps
	_breath_step = (_breath_step + steps) % BREATH_FRAMES
	for i in _cell_nodes.size():
		var s := _cell_nodes[i] as Sprite2D
		if s.visible and s.hframes == BREATH_FRAMES:
			s.frame = (_breath_step + i) % BREATH_FRAMES


## 分化会改 itype，所以贴图每帧对一次。
func _apply_immune_art(s: Sprite2D, itype: int) -> void:
	var tex: Texture2D = IMMUNE_ART[itype]
	if s.texture != tex:
		_set_cell_art(s, tex)


## offset 把锚点从贴图中心挪到脚底中心 —— 细胞是「站」在格子上的，
## 而贴图有 24/32/16 三种高度，只有对齐脚底才不会因为大小不同而上下乱跳。
func _set_cell_art(s: Sprite2D, tex: Texture2D) -> void:
	s.texture = tex
	s.hframes = BREATH_FRAMES   ## 所有对局细胞贴图都是横排 6 帧呼吸表
	s.offset = Vector2(0, -tex.get_height() / 2.0)
