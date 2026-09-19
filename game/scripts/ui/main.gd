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

## 新手引导的开场动画（PRD:59-87 / 方案 §S7）。独立场景、自带相机、压根不建内核，
## 盖在整棵树之上（CanvasLayer layer 100）演完再让位。**只有第一次进引导时播**，
## 看过没有记在 `user://guide_progress.cfg` 里（键 `opening_seen`，见那个脚本的静态方法）。
const OPENING_SCENE := preload("res://scenes/tutorial_opening.tscn")
const OPENING := preload("res://scripts/ui/tutorial_opening.gd")
## 开场演完、第一关的章节提示已经立起来之后，盖着的那一层淡掉要多久。
## 之所以**不在演完的当下就掀掉**：掀早了玩家会先看见一帧光秃秃的对局界面（行动栏 / 右栏），
## 而 PRD:87 要的是「直接进第一章全屏章节提示」
const T_OPENING_OUT := 0.45

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
	## 批 1 步 9 / E-3：旧版存档与回放启动时静默清掉（版本 / 规则指纹不符的一律读不出，留着只会让「继续对局」永远灰着）
	CWSave.purge_stale()
	CWReplay.purge_stale()
	CWSettings.load_prefs()   ## 偏好尽早读：AI 节奏/掷骰动画在开局装配时就要用
	menu.start_requested.connect(_begin)
	menu.continue_requested.connect(_continue)
	menu.replay_requested.connect(_watch_replay)
	menu.tutorial_requested.connect(_begin_tutorial)
	menu.online_match_requested.connect(_begin_online)
	menu.online_lost.connect(_on_online_lost)
	pause.chose.connect(_on_pause_chose)
	pause.action_bar = match_node.action_bar
	match_node.finished.connect(_on_match_finished)
	match_node.replay_opening.connect(_replay_opening)
	settle.chose.connect(_on_settle_chose)


## cfg 来自配置面板（CWConfigPanel.config()）。座位规则：人类坐所选阵营
## 在行动顺序里的第一个位置；观战（faction -1）就一个人也不坐。
func _begin(cfg: Dictionary) -> void:
	if _entering:
		return
	match_node.tutorial = false   ## 正式局入口统一复位（教程标志只在 _begin_tutorial 置位）
	match_node.player_count = cfg["players"]
	var seats: Array[int] = []
	if cfg["faction"] == CWConfigPanel.HOTSEAT:
		seats = CWConfigPanel.hotseat_seats(cfg)   ## 本地多人：席位表里为真人的下标（热座，2026-09-05）
	else:
		var seat := CWConfigPanel.human_seat(cfg["players"], cfg["faction"])
		if seat >= 0:
			seats.append(seat)
	match_node.human_players = seats
	match_node.ai_level = int(cfg.get("ai", 0))
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


## 「新手引导」：开一局教程局。过场和正式局一样三拍：新手也该先看到干净棋盘、再看到癌组织怎么铺开。
##
## **2026-09-19 老教程整套推倒**（新手教程 v2 · S1 commit A）：席位数 / 人类席 / 癌种 / 活跃格
## 都是**关卡数据里的设计量**（方案 §2.2），不再在这儿现算 —— 装配整段搬去 commit B 的导演。
## 入口母菜单那一项重做期间一直灰着，**2026-09-19 · S12 收口已恢复**（`main_menu.gd` 的 `enabled: true`，
## 那是唯一一处开关）；`cancer_type` 形参留着不动：主菜单那套「过完教程可自选对手」是 Kevin 09-05 拍板过的，保留。
func _begin_tutorial(_cancer_type: int) -> void:
	if _entering:
		return
	match_node.tutorial = true
	_entering = true
	_started_ms = Time.get_ticks_msec()
	## **菜单退场必须排在开场动画之前**：它要淡 T_DECOR = 1.1 秒，排在后面的话这 1.1 秒正好落在
	## 「幕布淡掉、章节提示露出来」那一段，玩家会看见主菜单的 CELL WAR 标题和菜单项幽灵般叠在提示上
	##（09-19 真机截图抓到的）。放在前面，它就在幕布底下淡完了
	menu.dismiss(T_DECOR, DECOR_DRIFT)
	## 开场动画（PRD:59-87）：**只有第一次**进引导时播，演完（或被跳过）就记上一笔。
	## 它自带全屏幕布，所以底下的菜单退场、镜头推进、癌组织绽开全被盖着 —— 玩家看不到，也不必等
	var cut = null   ## 不标 Node：开场脚本没有 class_name（附 C 第 1 条），标了就够不着它的成员
	if not OPENING.seen():
		cut = OPENING_SCENE.instantiate()
		add_child(cut)
		await cut.finished
		OPENING.mark_seen()
	if cut == null:
		_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tween.tween_method(_look, 0.0, 1.0, T_ENTER)
		await _tween.finished
	else:
		_look(1.0)   ## 开场已经把镜头交代完了，不在幕布底下再空推一次 1.55 秒
	await match_node.start_with_bloom(T_BLOOM)
	if cut != null:
		## 这会儿第一章的章节提示已经立起来了（关首那一拍在 `CWMatch.start()` 里装），
		## 幕布淡掉露出来的就是它 —— 一帧对局界面都不闪（PRD:87）
		await cut.fade_out(T_OPENING_OUT)
		cut.queue_free()
	_entering = false


## 教程目录底部那行「Cell War」（Kevin 2026-09-19 Q-21）：重看开场。
## `opening_seen` 已经由 `CWMatch` 清掉了（开场三件只调它现成的 `clear_seen()`），
## 这儿只负责**收摊这一局再重进引导** —— 返场那三拍照抄 `_back_to_menu`，
## 差别只有最后一步不是把菜单放出来，而是径直重进（`_begin_tutorial` 见 `seen()` 为假会重播开场）。
## `_entering` 在重进之前先放掉：`_begin_tutorial` 自己头一句就判它
func _replay_opening() -> void:
	if _entering:
		return
	_entering = true
	_started_ms = Time.get_ticks_msec()
	match_node.fade_out(T_BACK * 0.8)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 1.0, 0.0, T_BACK)
	await _tween.finished
	match_node.teardown()
	_entering = false
	_begin_tutorial(0)


## 联机开局：房间进入对局且第一份状态到了。过场和本地开局一样（推镜头 + 绽开），
## 只是对局由服务器驱动（CWMatch.start_online）。
func _begin_online(client: CWNetClient) -> void:
	if _entering:
		return
	match_node.tutorial = false
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
	## 房间没了要说清楚为什么。2026-09-07 顶带那条通报删掉之后，这句改用棋盘中央偏上的气泡
	## （这会儿正要收摊回主菜单，不进左侧事件列表 —— 那一列跟着对局一起清掉了）
	if match_node.toast != null:
		var screen := CWView.screen_size()
		var at := Rect2(Vector2((screen.x - CWView.PANEL_WIDTH) * 0.5, CWToast.MARGIN), Vector2.ZERO)
		match_node.toast.show_at(reason, at, CWUIBridge.TEXT_HOLD)
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
	## 还飘在棋盘上的临时 HUD（提示气泡、左侧出牌列）一起收掉，否则结算屏一出来就显得脏
	match_node.clear_transient_hud()
	## 本地局的回放自己存（联机局是服务器随终局发下来、客户端那边存的）。
	## 存不下就算了 —— 一局回放丢了不该挡住结算屏
	if not match_node.online:
		CWReplay.save(match_node.replay_tape())   ## 批 1 步 7：存的是 tape，不再收 CWGame
	settle.show_result(match_node.mirror)   ## 批 1 步 8：结算屏吃终局那一份镜像


## 结算屏的「看这局回放」：刚打完那一局就是**最新的一份**（本地局在
## `_on_match_finished` 里刚存过，联机局由服务器随终局推下来、客户端存过）
func _watch_latest_replay() -> void:
	var files := CWReplay.list_files()
	if files.is_empty():
		return
	var d := CWReplay.read(files[0])
	if d.is_empty():
		return
	settle.reset()
	_watch_replay(d)


func _on_settle_chose(action: String) -> void:
	match action:
		"replay":
			_watch_latest_replay()
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
	match_node.tutorial = false   ## 再来一局是正式局，不带引导
	## **种子必须清掉**（issue #13，HXR-I 2026-09-10 报「再来一局新种子，实际不会用新种子」）。
	## 配置面板每次开局都 `_roll_seed()` 给一个**非零**种子，而 `CWMatch.start()` 是
	## 「非零就用它、为零才取时钟」—— 于是这颗种子一直钉在那儿，
	## 「再来一局」年年重放同一局，而按钮上明写着「同样人数 · **新种子**」。
	## 清成 0 = 让 start() 去取时钟。想复现某一局仍走主菜单，在配置面板里填那个种子。
	match_node.match_seed = 0
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
			if CWSave.write(match_node.save_blob(), match_node.player_count, match_node.human_players, match_node.ai_level):
				_back_to_menu()
			else:
				push_warning("存档写入失败，留在对局中")
		"surrender":
			## 菜单先收起来：投降立刻定胜负，结算屏跟着就上来，
			## 留着暂停菜单会压在它上面（pause.active 要等 finished 才关）
			pause.close()
			match_node.surrender_now()
		"quit":
			get_tree().quit()


## 「继续对局」：读档 → 按档里的人数/座位/AI 强度装配 → 镜头推进（不演绽开，
## 那是新局的仪式）→ 恢复快照开跑，存档那一刻待决的询问会原样回来。
## 从回放面板选了一份：镜头照常推进棋盘，只是跑的是播放器而不是新对局
func _watch_replay(d: Dictionary) -> void:
	if _entering:
		return
	var p := CWReplay.Player.open(d, true)   ## consumer=true：界面那条路要等演出（批 1 步 7；步 8 接播放队列）
	if p == null:
		return          ## 读得出但建不起来（版本/参数不认）：留在菜单，面板那边已经报过
	match_node.tutorial = false
	match_node.online = false
	match_node.player_count = int(d.get("players", 4))
	_entering = true
	_started_ms = Time.get_ticks_msec()
	menu.dismiss(T_DECOR, DECOR_DRIFT)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_look, 0.0, 1.0, T_ENTER)
	await _tween.finished
	match_node.start_replay(p)
	_entering = false


func _continue() -> void:
	if _entering:
		return
	match_node.tutorial = false   ## 读档入口统一复位（存档里不记教程标志，读回来就是正式局）
	var data := CWSave.read()
	if data.is_empty():
		return   ## 档坏了或没了：亮灭是按 exists() 算的，这里兜底
	match_node.player_count = data["players"]
	var seats: Array[int] = []
	for s in data["human"]:
		seats.append(int(s))
	match_node.human_players = seats
	match_node.ai_level = CWSave.ai_level_of(data)
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
