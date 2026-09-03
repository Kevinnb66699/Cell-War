## main.gd —— 入口：主菜单与对局共用同一台相机、同一张棋盘
##
## 「开始对局」的过场是同一个镜头从菜单机位往前推、**不切场景**，
## 所以菜单和对局必须活在同一棵树里，相机也只有一台。
##
## 开场三拍（团队 2026-08-27 定，来龙去脉见开发日志）：
##   ① 相机拉远铺满棋盘 1.55s，装饰细胞同时沿离心方向漂散淡出
##   ② 初始癌组织从正中绽开 0.75s，中央先翻、外圈绕一圈扫过去
##   ③ 停下来等玩家落子 —— **这一拍必须把控制权交还玩家**，落子是决策不是演出
##
## 时长常量集中放这里，别散进各个 Tween：手感是要反复微调的，
## 散开了改一次要翻好几个文件（参照 CWTuning 的做法）。
extends Node2D

const T_ENTER := 1.55       ## ① 相机推进。最初给 0.62s，团队试过原型后改成 1.55s
const T_BLOOM := 0.75       ## ② 癌组织绽开
const T_DECOR := 1.10       ## 装饰细胞漂散淡出，在推进途中就走完
const DECOR_DRIFT := 26.0   ## 漂散距离（棋盘像素）
const T_BACK := 1.55        ## 棋盘 → 主菜单。团队定了**和进场对称**
                            ##（本来按 0.75s 做的：进场是揭幕值得给分量，返回该干脆）
const T_MENU_IN := 0.32     ## 相机回位之后菜单再淡进来。两段刻意**不重叠**
## 再来一局的淡出。比返回主菜单（T_BACK）短 —— **镜头不动**：
## 我们已经在对局机位上了，退回菜单再推进来纯属多此一举，
## 开场三拍只在「从菜单进入对局」时才演。
const T_RESTART := 0.85
## 过场刚起步的这一小段里不接受「点一下跳过」。
## 防的是**启动过场的那一下点击自己把它跳掉** —— Control 的 gui_input 不会自动
## 吃掉事件，那一下会一路漏到这里来。菜单那边已经标记了已处理，这里再加一道闸，
## 是因为「事件被谁消费」这种事在加新界面时最容易被破坏，
## 而破坏的表现是**过场整个消失**（画面瞬间就位），极难察觉。
const SKIP_GRACE_MS := 250

@onready var camera: Camera2D = $Camera2D
@onready var board: Node2D = $Board
@onready var menu: Node2D = $MainMenu
@onready var match_node: CWMatch = $Match
@onready var pause: CWPauseMenu = $Match/UI/Pause
@onready var settle: CWSettleScreen = $Match/UI/Settle

var _tween: Tween
var _entering := false
var _started_ms := 0   ## 本次过场起步的时刻


func _ready() -> void:
	CWSettings.load_prefs()   ## 偏好尽早读：AI 节奏/掷骰动画在开局装配时就要用
	menu.start_requested.connect(_begin)
	menu.continue_requested.connect(_continue)
	menu.online_match_requested.connect(_begin_online)
	menu.online_lost.connect(_on_online_lost)
	pause.chose.connect(_on_pause_chose)
	pause.action_bar = match_node.action_bar
	match_node.finished.connect(_on_match_finished)
	settle.chose.connect(_on_settle_chose)


## cfg 来自配置面板（CWConfigPanel.config()）。座位规则：人类坐所选阵营
## 在行动顺序里的第一个位置；观战（faction -1）就一个人也不坐。
func _begin(cfg: Dictionary) -> void:
	if _entering:
		return
	match_node.player_count = cfg["players"]
	var seats: Array[int] = []
	var seat := CWConfigPanel.human_seat(cfg["players"], cfg["faction"])
	if seat >= 0:
		seats.append(seat)
	match_node.human_players = seats
	match_node.ai_smart = cfg["smart"]
	## 配置面板给的随机种子（拨一下换一个）：填进去这局就可复现
	match_node.match_seed = int(cfg.get("seed", 0))
	## 自定义对局钉死的癌种（按癌席顺序，-1 = 随机；普通对局是空表）
	match_node.cancer_types = Array(cfg.get("cancer_types", []))
	_entering = true
	_started_ms = Time.get_ticks_msec()
	menu.dismiss(T_DECOR, DECOR_DRIFT)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 0.0, 1.0, T_ENTER)
	await _tween.finished
	## 两段计时动画必须**前后相接**，不能挂在同一条时间轴上：原型里第一版共用
	## 一个进度值，相机走完那一帧的进度 1 被当成「绽开也走完了」，
	## 7 格癌组织一次全出、绽开整个被跳过（开发日志 2026-08-27）。
	await match_node.start_with_bloom(T_BLOOM)
	_entering = false    ## 三拍走完才算「不在过场中」——忘了置回，返回主菜单会永远进不去


## 联机开局：房间进入对局且第一份状态到了。过场和本地开局一样（推镜头 + 绽开），
## 只是对局由服务器驱动（CWMatch.start_online）。
func _begin_online(client: CWNetClient) -> void:
	if _entering:
		return
	match_node.player_count = int(client.room.get("players", 4))
	_entering = true
	_started_ms = Time.get_ticks_msec()
	menu.dismiss(T_DECOR, DECOR_DRIFT)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 0.0, 1.0, T_ENTER)
	await _tween.finished
	await match_node.start_online_with_bloom(client, T_BLOOM)
	_entering = false


## 联机对局中房间没了（被关、令牌失效、重连失败）：收摊回主菜单
func _on_online_lost(reason: String) -> void:
	if not match_node.online:
		return
	if match_node.toast != null:
		match_node.toast.show_at(reason, CWUIBridge.notice_anchor(), CWUIBridge.NOTICE_HOLD)
	_leave_online()


## 结算屏「回到等待室」：镜头退回菜单机位，面板槽里出来的是等待室而不是菜单项
func _back_to_room() -> void:
	if _entering:
		return
	_entering = true
	_started_ms = Time.get_ticks_msec()
	match_node.fade_out(T_BACK * 0.8)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 1.0, 0.0, T_BACK)
	await _tween.finished
	match_node.teardown()
	menu.appear_online(T_MENU_IN)
	_entering = false


## 离开联机（结算屏返回主菜单 / 暂停菜单离开房间 / 房间没了）：先和服务器告别再演返场
func _leave_online() -> void:
	if _entering:
		return
	menu.leave_online()
	_back_to_menu()


## 对局跑完了。**中途放弃也会走到这里**（CWGame.run_game 在 aborted 时同样返回），
## 但那时 winner 仍是 -1 —— 那条路是「返回主菜单」自己在演返场，不该再弹结算屏。
func _on_match_finished(winner: int) -> void:
	if winner < 0:
		return
	## 对局已结束，Esc 归结算屏（「返回主菜单」），不该再唤出暂停菜单
	pause.active = false
	## 上一条提示还飘着的话，结算屏一出来就显得脏（实测截到过「突变：无事发生」）
	if match_node.toast != null:
		match_node.toast.hide_now()
	settle.show_result(match_node.game)


func _on_settle_chose(action: String) -> void:
	match action:
		"restart":
			if match_node.online:
				_back_to_room()
			else:
				_restart()
		"menu":
			if match_node.online:
				_leave_online()
			else:
				_back_to_menu()


## 再来一局：同样人数、新种子。棋盘先淡回健康，再原地开新局 ——
## 和返回主菜单共用 fade_out/teardown 那一套，区别只是**镜头不动、菜单不出来**。
func _restart() -> void:
	if _entering:
		return
	_entering = true
	_started_ms = Time.get_ticks_msec()
	match_node.fade_out(T_RESTART)
	await get_tree().create_timer(T_RESTART).timeout
	match_node.teardown()          ## 顺带把结算屏和暂停菜单擦回原样
	await match_node.start_with_bloom(T_BLOOM)
	_entering = false


func _on_pause_chose(action: String) -> void:
	match action:
		"menu":
			if match_node.online:
				_leave_online()
			else:
				_back_to_menu()
		"save_quit":
			## 先落盘再演返场——fade_out 会把对局 aborted，那之后就没得存了。
			## 写失败（磁盘问题）就留在对局里，别让玩家以为存上了。
			if CWSave.write(match_node.game, match_node.human_players, match_node.ai_smart):
				_back_to_menu()
			else:
				push_warning("存档写入失败，留在对局中")
		"quit":
			get_tree().quit()


## 「继续对局」：读档 → 按档里的人数/座位/AI 强度装配 → 镜头推进（不演绽开，
## 那是新局的仪式）→ 恢复快照开跑，存档那一刻待决的询问会原样回来。
func _continue() -> void:
	if _entering:
		return
	var data := CWSave.read()
	if data.is_empty():
		return   ## 档坏了或没了：亮灭是按 exists() 算的，这里兜底
	match_node.player_count = data["players"]
	var seats: Array[int] = []
	for s in data["human"]:
		seats.append(int(s))
	match_node.human_players = seats
	match_node.ai_smart = data["smart"]
	_entering = true
	_started_ms = Time.get_ticks_msec()
	menu.dismiss(T_DECOR, DECOR_DRIFT)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 0.0, 1.0, T_ENTER)
	await _tween.finished
	match_node.start(data["snap"])
	_entering = false


## 返回主菜单：镜头原路退回，棋盘擦干净，菜单淡回来。
## 顺序不能颠倒 —— 棋盘和菜单共用同一张棋盘，得先擦掉上一局的癌组织，
## 否则镜头退到菜单机位时背景里还留着一片红。
func _back_to_menu() -> void:
	if _entering:
		return
	_entering = true
	_started_ms = Time.get_ticks_msec()
	## 淡出和镜头退回**同时进行**：镜头一边拉远，棋盘上的东西一边消失。
	## 真正的拆解等淡完再做 —— 先 teardown 的话棋盘会瞬间清空，就没得淡了。
	match_node.fade_out(T_BACK * 0.8)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 1.0, 0.0, T_BACK)
	await _tween.finished
	match_node.teardown()
	menu.appear(T_MENU_IN)
	_entering = false


## 过场进行中再点一次 → 立即到位（团队要求：别等做完再补）
func _unhandled_input(event: InputEvent) -> void:
	if not _entering or _tween == null or not _tween.is_running():
		return
	if Time.get_ticks_msec() - _started_ms < SKIP_GRACE_MS:
		return
	if event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()
		menu.skip_dismiss()
		_tween.custom_step(3600.0)   ## 一步推到底，进场返场都适用


## 补间只推一个 0..1 的进度，取景由 CWView.blend() 现算 ——
## 别去插相机的 position（理由见 blend 的注释）。
func _look(k: float) -> void:
	CWView.blend(camera, board, k)
