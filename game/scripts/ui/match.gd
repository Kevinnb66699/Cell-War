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
## 自定义对局钉死的癌种：按癌席顺序的 CWData.CancerType（-1 = 随机），空表 = 普通对局全随机。
## 只在 start() 开新局时喂给 tune；重开（_restart）沿用，读档 / 联机不经过这里。
@export var cancer_types: Array = []
## 单独跑本场景时自己开局；挂在 Main 下面时由 main.gd 在过场结束后调 start()
@export var autostart := false

## 此刻能不能存档：引擎只在 pending 边界有完整快照（CWSave 的写入条件）。
## 暂停菜单拿它决定「保存并退出」亮不亮。联机局不写本地存档（状态在服务器，掉线凭令牌重连）。
func can_save_now() -> bool:
	return game != null and not online and not game._pending.is_empty() and not game.is_over()

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
## 联机模式（docs/联机设计 §七）：game 是客户端的影子对局（只读、由服务器的视角快照 restore），
## 桥仍是 CWUIBridge，但询问与演出由 _net_loop 从 client.stream 里按顺序取出来驱动，
## 引擎不在本机跑。start_online() 进入，teardown() 退出。
var online := false
var net_hud: CWNetHud
var _client: CWNetClient
var _loop_id := 0        ## 每次 start_online / teardown 递增：旧的 _net_loop 看到号变了就退出
var _ask_serial := 0     ## 每收到一次询问递增：作答时核对，服务器代打后重问的旧答案不发

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
## fade_out() 建的那几条补间的句柄。**必须留着**：它们绑在 `_cells_root` 和 HUD 上，
## 而这两个节点 teardown() 都不销毁 —— 补间会活过拆局、跑进下一局继续把 alpha 拉向 0。
## 返场过场被玩家点击跳过时最容易撞上：跳过只快进了相机补间（main.gd 的 `_tween`），
## 这几条没人管。表现是「新局开局细胞全不可见、HUD 却正常」
## （HUD 那几条只有 0.6 倍时长，通常已经先跑完）。start() 里统一杀掉。
var _fade_tws: Array[Tween] = []
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
var _card_info: CWCardInfo   ## 悬停手牌详情，同样程序化补进；与格子详情同一套打法
var _chemo_fx: CWChemoFx     ## 树突【I-趋化源】的漩涡核心演出（挂在棋盘层，跟着格子走）
## 【E-侵蚀】的两帧过场。不是节点：它只决定「这一格这一帧画哪张图」，由 _sync_tiles 落实
var _erosion_fx := CWErosionFx.new()
## 细胞传送的溶解演出（规格 docs/动画规格_传送.md）。同样不是节点：残影挂在 _cells_root 下，句柄它自己收。
## 「这是传送」由下面 _last_pos 的差分判定（上一帧与这一帧都活着、两格不相邻），不走引擎信号。
var _teleport_fx := CWTeleportFx.new()
var _last_pos: Array[Vector2i] = []   ## 上一帧位置，下标 = cell id；两格不相邻 = 传送
var _log_panel: CWLogPanel   ## 对局日志面板（L 键开关），同样程序化补进
var _log_hint: CWLogHint     ## 左上角「对局日志 L」入口提示（定案A），显隐跟着面板走
var _handoff: CWHandoff      ## 热座换手遮罩（UI 层，压在暂停菜单下面）；桥在换人时 await 它


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
		## 趋化源的漩涡：挂在**棋盘**上而不是 UI 层 —— 它是场上的东西，
		## 得跟着相机缩放/平移，也得按格子的 z 序压在细胞下面
		_chemo_fx = CWChemoFx.new()
		_chemo_fx.visible = false
		board.add_child(_chemo_fx)
		_tile_info = CWTileInfo.new()
		ui.add_child(_tile_info)
		if pause_menu != null:
			ui.move_child(_tile_info, pause_menu.get_index())
		## 手牌详情与格子详情同层。两者不会同时出现——鼠标只能停在一处
		_card_info = CWCardInfo.new()
		ui.add_child(_card_info)
		ui.move_child(_card_info, _tile_info.get_index())
		## 日志面板压在信息卡下面：两者都开着时，悬停详情仍然读得到
		_log_panel = CWLogPanel.new()
		ui.add_child(_log_panel)
		ui.move_child(_log_panel, _tile_info.get_index())
		## 左上角入口提示（定案A·2026-08-30）：钉在面板展开的位置，点击 = 按 L。
		## 显隐归本类管：开局亮、面板开着让位（_process 每帧对齐）、拆局收起。
		_log_hint = CWLogHint.new()
		_log_hint.visible = false
		ui.add_child(_log_hint)
		ui.move_child(_log_hint, _tile_info.get_index())
		_log_hint.pressed.connect(func() -> void: _log_panel.toggle())
		## 联机的倒计时与断线遮罩，同层
		net_hud = CWNetHud.new()
		ui.add_child(net_hud)
		ui.move_child(net_hud, _tile_info.get_index())
		## 热座换手遮罩：盖住手牌 / 行动栏 / 详情框，只让暂停菜单压在它上面
		_handoff = CWHandoff.new()
		ui.add_child(_handoff)
		if pause_menu != null:
			ui.move_child(_handoff, pause_menu.get_index())
		ui.visible = false
	if autostart:
		CWView.apply(camera, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
		start()


## snap 非空 = 从存档继续：装配完把快照原样放回去，run_game 会把存档那一刻
## 待决的询问重新问出来（恢复点必然是 pending 边界，CWSave 只在那儿写得出档）。
func start(snap: Dictionary = {}) -> void:
	_prepare_ui()
	game = CWGame.new()
	game.tune.cancer_types = cancer_types.duplicate()   ## 必须在 init 之前：抽种类在开局第一步
	game.init(CWData.FACTION_ORDER[player_count],
		match_seed if match_seed != 0 else int(Time.get_unix_time_from_system()))
	if not snap.is_empty():
		game.restore(snap)   ## rng 状态也在快照里，init 用的种子随之作废
	_wire_bridge(ai_smart)
	## 同一个桥对象注册给所有玩家：人类那几位走界面，其余走 AI，
	## 掷骰演出按对象去重所以只演一遍（理由见 ui_bridge.gd 文件头）。
	for pid in game.order:
		game.bridges[pid] = bridge
	_run()


## 联机：影子对局来自客户端，桥只服务我这一席；询问与演出由 _net_loop 驱动。
## 调用前 client 已进入顺序播放模式且第一份状态已排在 stream 里（CWOnlinePanel 保证）。
func start_online(p_client: CWNetClient) -> void:
	_prepare_ui()
	online = true
	_client = p_client
	_loop_id += 1
	_ask_serial += 1
	while not _client.stream.is_empty() and _client.stream[0]["t"] == "state":
		_client.apply_now(_client.stream.pop_front())   ## 先让第一份状态生效，影子对局才存在
	if _client.shadow == null:
		_client.shadow = CWGame.new()
		_client.shadow.init(CWData.FACTION_ORDER[player_count], 0)
	game = _client.shadow
	player_count = game.players.size()
	var seats: Array[int] = []
	if _client.my_seat >= 0:
		seats.append(_client.my_seat)
	human_players = seats
	_wire_bridge(false)
	if pause_menu != null:
		pause_menu.online = true
	if settle != null:
		settle.online = true
	if net_hud != null:
		net_hud.set_link("")
		net_hud.stop_countdown()
	_net_loop(_loop_id)


func start_online_with_bloom(p_client: CWNetClient, seconds: float) -> void:
	_opening = true
	start_online(p_client)
	await _play_bloom(seconds)


## 开局前把上一局留下的东西还原、HUD 亮起来（start / start_online 共用）
func _prepare_ui() -> void:
	_fading = false
	## 先杀上一局的淡出补间，再还原 alpha —— 顺序反了等于没改：
	## 补间还活着的话，下一帧它会把刚设回 1.0 的 alpha 继续拉向 0。
	for tw in _fade_tws:
		if tw != null and tw.is_valid():
			tw.kill()
	_fade_tws.clear()
	## 棋盘那边同一回事：fade_to_healthy() 的过渡叠层不归 set_marks 管，
	## 残留回调会在这一局里把格子刷成健康贴图
	if board != null:
		board.cancel_fade()
	if _cells_root != null:
		_cells_root.modulate.a = 1.0     ## 上一局淡出留下的，开新局要还原
	if hand != null:
		hand.visible = true              ## 热座换手期间会收起，开新局要还原
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
	if _card_info != null and hand != null 			and not hand.card_hovered.is_connected(_card_info.on_hover):
		hand.card_hovered.connect(_card_info.on_hover)
	## 右栏固定详情里停在某条技能上 → 同一只详情框浮 PRD 原文（2026-09-04 Kevin 要的）
	if _card_info != null and panel != null 			and not panel.skill_hovered.is_connected(_card_info.on_hover_info):
		panel.skill_hovered.connect(_card_info.on_hover_info)
	if _log_panel != null:
		_log_panel.active = true
	if _log_hint != null:
		_log_hint.visible = true


func _wire_bridge(smart: bool) -> void:
	bridge = CWUIBridge.new()
	bridge.game = game
	bridge.board = board
	bridge.dice = _dice
	bridge.bar = action_bar
	bridge.info = _card_info   ## 分化提问里悬停种类按钮 → 细胞种类详情（同一只详情框）
	bridge.panel = panel
	bridge.toast = toast
	bridge.camera = camera
	bridge.erosion = _erosion_fx
	bridge.hand = hand   ## 方案甲：打出/弃置手势从手牌抽屉来
	bridge.handoff = _handoff
	bridge.hotseat = human_players.size() >= 2   ## 热座 = 一台电脑坐了两位以上真人
	bridge.human_pids = human_players
	bridge.enabled = smart       ## 「较强」= 蒙特卡洛推演（桥的基类），默认启发式
	## 真人档要有可预测的响应上限；预算按模拟 step 计，不受本机快慢影响。
	bridge.max_sim_steps = 192 if smart else 0
	bridge.opening = _opening    ## 绽开演完前先不弹询问界面
	bridge.delay_ms = CWSettings.ai_delay_ms
	bridge.delay_node = self


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
	await _play_bloom(seconds)


func _play_bloom(seconds: float) -> void:
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


## 联机：按服务器发来的顺序消费对局流。演出（掷骰）要等播完再让下一条生效，
## 所以 state 不在收到时 restore、而是在这里轮到它时才 apply_now。
func _net_loop(id: int) -> void:
	while online and _loop_id == id and _client != null and is_inside_tree():
		if _client.stream.is_empty():
			_sync_link()
			await get_tree().process_frame
			continue
		var m: Dictionary = _client.stream.pop_front()
		match m["t"]:
			"state":
				_client.apply_now(m)
			"roll":
				if bridge != null:
					await bridge.show_roll(m["reason"], m["value"], m["sides"], m["pid"], m["at"])
			"result":
				if bridge != null:
					bridge.show_result(m["text"], m["at"])
			"notice":
				if bridge != null:
					bridge.show_notice(m["text"])
			"erosion":
				if bridge != null:
					bridge.show_erosion(m["at"], int(m["dir"]))
			"ask":
				_serve_ask(m)
			"game_over":
				_client.apply_now(m)
				if online and _loop_id == id:
					finished.emit(int(m["winner"]))
				return


## 一次询问：交给现有的界面桥，答完把下标发回服务器。不 await 它 —— 玩家在想的时候，
## 对局流里的其它条目照常处理。服务器代打后重问的旧一问：先 abort 收掉界面，
## 旧协程醒来发现序号变了就丢弃答案。
func _serve_ask(m: Dictionary) -> void:
	if bridge == null:
		return
	_ask_serial += 1
	var my := _ask_serial
	bridge.abort()
	if net_hud != null:
		net_hud.start_countdown(int(m.get("left_ms", -1)))
	var idx: int = await bridge.ask(m["req"])
	if _ask_serial != my or not online or _client == null or game == null:
		return
	if net_hud != null:
		net_hud.stop_countdown()
	_client.answer(int(m["ask_id"]), idx)


## 断线遮罩与席位状态跟着客户端走
func _sync_link() -> void:
	if _client == null:
		return
	if net_hud != null:
		net_hud.set_link("" if _client.status == "open" else "连接断开，正在重连…")
	if panel != null:
		panel.net_seats = _client.room.get("seats", [])


## 返场淡出：让棋盘上的东西**淡着消失**，而不是啪地不见（团队 2026-08-27 反馈）。
## 真正的拆解由 teardown() 在淡完之后做 —— 这里只管演。
##
## 第一件事是把对局叫停：不然淡出途中 AI 还在走棋、组织还在变色，
## 一边淡一边动，看起来像出了故障。
func fade_out(seconds: float) -> void:
	if game == null or _fading:
		return
	if not online:
		game.aborted = true     ## 联机的影子对局没有引擎在跑，也不归本节点收摊
	if bridge != null:
		bridge.abort()
	_fading = true
	board.set_marks({})                      ## 高亮自己会淡掉
	board.fade_to_healthy(seconds)
	if _cells_root != null:
		var tw := _cells_root.create_tween()
		tw.tween_property(_cells_root, "modulate:a", 0.0, seconds)
		_fade_tws.append(tw)
	## HUD 稍微早一点淡完 —— 它不在棋盘上，跟着棋盘一起慢慢消反而拖沓
	if ui != null:
		for c in ui.get_children():
			if c is Control and (c as Control).visible:
				var ui_tw := (c as Control).create_tween()
				ui_tw.tween_property(c, "modulate:a", 0.0, seconds * 0.6)
				_fade_tws.append(ui_tw)


## 拆掉当前这一局，把棋盘擦回开局前的样子。
##
## 返回主菜单必须走这里：棋盘和相机是**和菜单共用的同一份**，
## 不擦干净的话上一局的癌组织和细胞会留在菜单背景里。
func teardown() -> void:
	_fading = false
	_loop_id += 1            ## 联机：让 _net_loop 退出
	if online:
		## 影子对局属于客户端（回到等待室还要用），这里只放手不销毁
		if bridge != null:
			bridge.abort()
		game = null
		online = false
		_client = null
		if net_hud != null:
			net_hud.stop_countdown()
			net_hud.set_link("")
		if pause_menu != null:
			pause_menu.online = false
		if settle != null:
			settle.online = false
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
	if _handoff != null:
		_handoff.hide_now()
	_teleport_fx.clear_all()   ## 先杀补间再删节点：残影/真身的补间不能活过拆局
	for node in _cell_nodes:
		node.queue_free()
	_cell_nodes.clear()
	_was_alive.clear()
	_last_pos.clear()
	_bloom.clear()
	_flash.clear()
	_erosion_fx.clear_all()
	_hand_seen.clear()
	_hand_pid = -1
	if hand != null:
		hand.clear()
	if toast != null:
		toast.hide_now()
	if _tile_info != null:
		_tile_info.hide_now()
	if _card_info != null:
		_card_info.hide_now()
	## 手牌不属于棋盘，不能等下面那段 is_instance_valid(board) 里再断
	if _card_info != null and hand != null and hand.card_hovered.is_connected(_card_info.on_hover):
		hand.card_hovered.disconnect(_card_info.on_hover)
	if _card_info != null and panel != null 			and panel.skill_hovered.is_connected(_card_info.on_hover_info):
		panel.skill_hovered.disconnect(_card_info.on_hover_info)
	if _log_panel != null:
		_log_panel.active = false
		_log_panel.hide_now()
	if _log_hint != null:
		_log_hint.visible = false
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
	_erosion_fx.advance(delta)
	_sync_tiles()
	_sync_cells()
	_animate_breath(delta)
	_sync_chemo(delta)
	_sync_hand()
	if panel != null:
		if online and _client != null:
			panel.net_seats = _client.room.get("seats", [])
		panel.refresh(game)
	if _tile_info != null:
		## 迁移态的每格耗能由询问桥转手过来（它那边是从引擎算好的选项里抄的）。
		## 桥可能是纯 AI 桥（无界面跑测试时），所以要判一下有没有这两个字段
		var costs: Dictionary = bridge.move_costs if bridge is CWUIBridge else {}
		var verb: String = bridge.move_verb if bridge is CWUIBridge else ""
		_tile_info.sync(delta, game, board, camera, _opening or _fading, costs, verb)
	if _card_info != null:
		## 阵营取「抽屉正在显示谁的手牌」，不是 current_pid —— 观战/热座时它们会不一样，
		## 而详情框说的是**手上这张卡**，得跟着卡的主人走（只影响【代谢耦联】的措辞）
		var info_faction: int = game.player(_hand_pid)["faction"] if _hand_pid >= 0 			else CWData.Faction.IMMUNE
		_card_info.sync(delta, info_faction, _opening or _fading)
	if _log_panel != null:
		## 热座：日志按「当前露牌的真人」视角过滤，换手期间（-1）所有秘密行都是公开替身；单人局不过滤
		var hs := bridge is CWUIBridge and (bridge as CWUIBridge).hotseat
		_log_panel.filter = hs
		_log_panel.viewer = (bridge as CWUIBridge).current_human if hs else -1
		_log_panel.refresh(game)
	if _log_hint != null and _log_panel != null:
		_log_hint.visible = not _log_panel.visible   ## 面板开着就让位（同一个角）


func _sync_tiles() -> void:
	var marks := {}
	for c: Vector2i in game.tiles:
		var t: Dictionary = game.tiles[c]
		## 【E-侵蚀】过场：引擎早就把这一格翻成癌了，但玩家还没看见「癌是从哪边漫过来的」。
		## 过场这 0.32 秒里改画过场图 —— 不加覆盖层，所以不会和高亮剪影抢 Z_MARK。
		## 演完 frame_of() 返回 null，下面那行自然把它换成癌组织，不需要收尾代码。
		var ero: Texture2D = _erosion_fx.frame_of(c)
		if ero != null:
			board.set_tile_tex(c, ero)
			continue
		## 开场绽开期间，还没轮到的那几格先按健康组织画
		var tissue: int = CWData.Tissue.HEALTHY if _bloom.has(c) else int(t["tissue"])
		board.set_tissue(c, tissue, t["special"])
		if tissue == CWData.Tissue.SOLID:
			marks[c] = MARK_SOLID
	for c: Vector2i in _flash:
		marks[c] = Color(1, 1, 1, _flash[c] / FLASH_TIME * FLASH_ALPHA)
	## 热座换手中：该玩家细胞脚下一圈阵营色光环呼吸，告诉 TA 自己在哪（开局还没落子时没有）
	if _handoff != null and _handoff.active and _handoff.cell_pos != CWHandoff.INVALID:
		marks[_handoff.cell_pos] = Color(_handoff.faction_color, 0.18 + 0.32 * _handoff.pulse())
	## 交互高亮压过状态色标：正在选目标时，「这格能不能选」比「它是不是固化」重要。
	if bridge != null:
		marks.merge(bridge.marks, true)
	board.set_marks(marks)


## 趋化源：场上有就把漩涡摆到那一格，没有就收起。
## 「只剩 1 回合」喂给演出层换色加速 —— 玩家不必去翻日志就知道它快没了。
func _sync_chemo(delta: float) -> void:
	if _chemo_fx == null:
		return
	if game.chemo.is_empty():
		_chemo_fx.visible = false
		return
	var at: Vector2i = game.chemo["at"]
	_chemo_fx.visible = true
	## 压在细胞下面（Z_MARK 那一层）：漩涡是地面上的东西，不该盖住站在上面的细胞
	_chemo_fx.sync(delta, board.tile_center(at), board.tile_z(at, board.Z_MARK),
		int(game.chemo["left"]) <= 1)


func _sync_cells() -> void:
	while _cell_nodes.size() < game.cells.size():
		_cell_nodes.append(_make_cell_node(game.cells[_cell_nodes.size()]))
	## 同格可能站着多个细胞，得先数清楚每格几个才能左右错开
	var per_tile := {}
	for c in game.cells:
		if c["alive"]:
			per_tile[c["pos"]] = per_tile.get(c["pos"], 0) + 1
	var placed := {}
	var jumps: Array = []   ## 本帧检出的传送：{ i, from, to, ghost_pos, ghost_z }
	for i in game.cells.size():
		var c: Dictionary = game.cells[i]
		var node: Node2D = _cell_nodes[i]
		node.visible = c["alive"]
		## 死而复活的也要淡入一次 —— 它和刚落子一样是「凭空出现」
		if c["alive"] and not _was_alive[i]:
			_pop_in(node)
		## 传送 = 上一帧与这一帧都活着、两格**不相邻**（六邻域按轴坐标算，别用像素距离）。
		## 判定顺序先复活再传送：复活走 _pop_in，不和传送混淆（规格 §三.1）。
		## 残影要站在它上一帧**实际画的位置**：趁下面覆写 position 之前抄走，同格错位也就自动对上
		elif c["alive"] and CWData.hex_dist(_last_pos[i], c["pos"]) > 1:
			jumps.append({ "i": i, "from": _last_pos[i], "to": c["pos"],
				"ghost_pos": node.position, "ghost_z": node.z_index })
		_was_alive[i] = c["alive"]
		if not c["alive"]:
			continue
		_last_pos[i] = c["pos"]
		var pos: Vector2i = c["pos"]
		var n: int = per_tile[pos]
		var k: int = placed.get(pos, 0)
		placed[pos] = k + 1
		var top: Vector2 = board.tile_center(pos)
		node.position = top + Vector2((k - (n - 1) / 2.0) * STACK_DX, CELL_FOOT_DY)
		node.z_index = board.tile_z(pos, board.Z_CELL)
		if c["faction"] == CWData.Faction.IMMUNE:
			_apply_immune_art(node as Sprite2D, c["itype"])
	if not jumps.is_empty():
		_play_teleports(jumps)


## 本帧检出的传送开演（规格 §三.2~3）。同一帧多个（紊乱全场齐传）按离重心的环数错峰；
## 两端都是血管格 = 血管互换：两端同一延迟、完全同时演，血管格先白闪一下交代「是血管干的」。
## 开关关着时检测照做、演出全跳（细胞照旧瞬移）—— AI 互搏观战局紊乱频繁，要这个降噪开关。
func _play_teleports(jumps: Array) -> void:
	if not CWSettings.teleport_anim:
		return
	var dests: Array = []
	for j in jumps:
		dests.append(j["to"])
	var delays: Dictionary = board.ring_delays(dests, CWTeleportFx.RING_STEP) if jumps.size() > 1 else {}
	for j in jumps:
		var i: int = j["i"]
		var from: Vector2i = j["from"]
		var to: Vector2i = j["to"]
		var delay: float = float(delays.get(to, 0.0))
		if game.tiles[from]["special"] == CWData.Special.VESSEL \
				and game.tiles[to]["special"] == CWData.Special.VESSEL:
			_flash[from] = FLASH_TIME
			_flash[to] = FLASH_TIME
			delay = CWTeleportFx.VESSEL_LEAD
		_teleport_fx.play(_cells_root, _cell_nodes[i] as Sprite2D, i, j["ghost_pos"], int(j["ghost_z"]),
			CWTeleportFx.edge_for(int(game.cells[i]["faction"])), delay,
			func() -> void: _flash[to] = FLASH_TIME)


## 手牌抽屉。抽到的卡从**发起抽卡的那个细胞**身上飞出来 ——
## 让「是谁抽的」这件事自己说清楚，而不是凭空出现在角落里。
##
## 显示谁的手牌：轮到哪个人类玩家就显示谁的；不是人类回合时保持上一次。
## （热座还没定案，定了之后这里就是现成的。）
func _sync_hand() -> void:
	if hand == null or human_players.is_empty():
		return
	if bridge is CWUIBridge and (bridge as CWUIBridge).hotseat:
		## 热座：抽屉跟「当前露牌的真人」（遮罩确认过的那一席），不跟「当前回合席位」——
		## A 结束回合到 B 点「开始回合」之间谁也不该看见 B 的牌。换手期间整个收起，
		## 确认后 B 的牌从 B 的细胞飞进抽屉（复用抽卡动画），行动栏随即出现。
		var who: int = (bridge as CWUIBridge).current_human
		if who < 0:
			if _hand_pid >= 0:
				hand.clear()
				hand.visible = false
				_hand_pid = -1
				_hand_seen.clear()
			return
		if who >= game.cells.size():
			return                   ## 开局布置阶段，这个人还没落子
		if _hand_pid != who:
			_hand_pid = who
			hand.visible = true
			var c0: Dictionary = game.cell_of(who)
			var cards0: PackedStringArray = PackedStringArray(c0["hand"])
			_hand_seen[who] = cards0.size()
			hand.deal_from(cards0.size(), CWView.board_to_screen(camera, board.tile_center(c0["pos"])), cards0)
			return
	elif game.current_pid in human_players:
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
	_last_pos.append(cell["pos"])
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
	_teleport_fx.sync_breath(_breath_step, BREATH_FRAMES)   ## 残影也要跟着呼吸，否则帧率不一致穿帮


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
