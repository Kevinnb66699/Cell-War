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
## 网页单机走服务器（换内核 P6，Kevin 10-01「网页单机连服务器」）：网页版的「开始对局」（一位真人 + AI）请服务器开私人房，
## 对局按联机局那套走；没开成（服务器开关关着 / 连不上 / 满了）就照旧本地开。热座与观战（AI 互搏）仍在本地。
## 桌面版恒为 false（行为不变）；测试把它拨成 true 在桌面上走这条路
var solo_via_server := OS.has_feature("web")
var _solo_cfg := {}    ## 上一局网页单机的配置（「再来一局」照它再开一间，种子换新）


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
	match_node.tutorial_done.connect(_back_to_menu)   ## 教程全部通关 → 返场回主菜单（Q-14 默认，09-25 接上）
	match_node.kernel_lost.connect(_on_kernel_lost)
	settle.chose.connect(_on_settle_chose)
	## 首次进入才询问一次。旧版进度文件视为已访问；选新手后即使只过了半关，
	## 下次启动也回主菜单。Main 作为测试夹具挂树时不是开机，不弹这层。
	if CWGuideProgress.needs_entry_choice() and get_tree().current_scene == self:
		await get_tree().process_frame
		menu.show_entry_choice(_on_entry_choice)


func _on_entry_choice(index: int) -> void:
	CWGuideProgress.choose_entry(
		CWGuideProgress.ENTRY_NEW if index == 0 else CWGuideProgress.ENTRY_EXPERIENCED)
	if index == 0:
		_begin_tutorial(0)


## cfg 来自配置面板（CWConfigPanel.config()）。座位规则：人类坐所选阵营
## 在行动顺序里的第一个位置；观战（faction -1）就一个人也不坐。
func _begin(cfg: Dictionary) -> void:
	if _entering:
		return
	match_node.tutorial = false   ## 正式局入口统一复位（教程标志只在 _begin_tutorial 置位）
	## 网页单机：先把私人房开起来（连服务器与下面的镜头推进同时进行），推完再看开没开成
	var solo := solo_wanted(cfg, solo_via_server)
	if solo:
		_solo_cfg = cfg.duplicate()
		menu.start_solo(cfg)
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
	if solo and await _enter_solo():
		_entering = false
		return
	await match_node.start_with_bloom(T_BLOOM)
	_entering = false    ## 三拍走完才算「不在过场中」——忘了置回，返回主菜单会永远进不去


## 这一份配置要不要走服务器：开关打开（网页版）、而且是「一位真人 + AI」那种 —— 热座（多位真人共用一台机器）
## 与观战（一个真人都没有）留在本地。**纯函数**，好直接测
static func solo_wanted(cfg: Dictionary, via_server: bool) -> bool:
	if not via_server or int(cfg["faction"]) == CWConfigPanel.HOTSEAT:
		return false
	return CWConfigPanel.human_seat(int(cfg["players"]), int(cfg["faction"])) >= 0


## 等服务器把私人房开好（start_solo 之后），开好了就按联机局进棋盘（绽开那一拍照演）。
## 返回 false = 没开成，调用方照旧本地开 —— 网页包里还有 GD 内核（P8 之前），玩家照样能玩，只在控制台留一行
func _enter_solo() -> bool:
	while menu.solo_pending():
		await get_tree().process_frame
	var client: CWNetClient = menu.solo_client()
	if client == null:
		push_warning("网页单机没走成服务器（%s），这一局在本地开" % menu.solo_error())
		return false
	match_node.solo = true   ## 要在 start_online 之前：结算屏 / 暂停菜单的文案按它挑
	await match_node.start_online_with_bloom(client, T_BLOOM)
	return true


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
			## 网页单机虽然是联机局，结算屏给的是「再来一局」（没有等待室可回）
			if match_node.online and not match_node.solo:
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
	## 继续过的老存档还是「较强」「树搜索」（换内核 P8 撤出选单）：再来一局落到搜索档（同网页单机 SOLO_TIER_OF_LEVEL 的口径）。
	## 不然这条链一直跑在 GD 内核上，每次「保存并退出」又把老档位写回存档（P8 复核）
	if not (match_node.ai_level in CWMatch.AI_MENU):
		match_node.ai_level = CWMatch.AI_ABS
	## **种子必须清掉**（issue #13，HXR-I 2026-09-10 报「再来一局新种子，实际不会用新种子」）。
	## 配置面板每次开局都 `_roll_seed()` 给一个**非零**种子，而 `CWMatch.start()` 是
	## 「非零就用它、为零才取时钟」—— 于是这颗种子一直钉在那儿，
	## 「再来一局」年年重放同一局，而按钮上明写着「同样人数 · **新种子**」。
	## 清成 0 = 让 start() 去取时钟。想复现某一局仍走主菜单，在配置面板里填那个种子。
	match_node.match_seed = 0
	var solo := match_node.solo   ## teardown 会把它清掉，先记下
	_entering = true
	_started_ms = Time.get_ticks_msec()
	match_node.fade_out(T_RESTART)
	await get_tree().create_timer(T_RESTART).timeout
	match_node.teardown()          ## 顺带把结算屏和暂停菜单擦回原样
	## 网页单机：同一条连接上离开这一间、再开一间（新种子）；没开成就照旧本地再来一局。
	## **排在 teardown 之后**：新房间的对局流一开打就往 client.stream 里排，上一局的句柄还挂着的话会把第一份状态吃掉
	if solo:
		_solo_cfg["seed"] = 0
		menu.start_solo(_solo_cfg)
	if solo and await _enter_solo():
		_entering = false
		return
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
	## C# 存档只有新内核读得回来。这会儿连新内核都找不到 —— 没得试，注定读不回来：
	## 不推镜头（以前推进棋盘再退出来，白等 3 秒才看见通知），就在主菜单上直接说（2026-10-01 复核）。
	## 找得到就照旧推镜头、真去开：起不来 / 不认这份档 / 开完当场就没了，只有真开过才知道
	var cs_save := String((data["snap"] as Dictionary).get("kernel", "")) == CWKernelSidecar.SAVE_KERNEL
	if cs_save:
		var loc := CWKernelSidecar.locate()
		if loc.has("error"):
			push_warning("读档：C# 存档读不回来（%s）" % String(loc["error"]))   ## 原话落 godot.log，通知上只说人话
			menu.show_notice(SAVE_LOST_TITLE, save_lost_text(CWKernel.Fault.SPAWN_FAILED, true))
			return
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
	## 玩家亲手点的「继续对局」不看「这一次运行里起不来过」的记忆（`CWKernelSidecar.start_failure`），真去试一次（2026-10-01 三轮复核，
	## Kevin 按推荐定）：记下的那一次可能只是偶发（.NET 冷启动卡满握手、杀毒软件攥着刚解出来的目录），甚至是玩家没看见的一次
	## 新开局悄悄退回 GD —— 当场拦的话只能叫人重开游戏。先清掉再开：开成了就空着（之后的新开局也重新指望 sidecar）；
	## 起不来由这一次重新记下；起来了却不认这份档，内核是好的，也空着。自动的路（新开局 / 教程换盘）照旧看记忆
	if cs_save:
		CWKernelSidecar.start_failure = {}
	if not match_node.start(data["snap"]):
		## C# 存档读不回来（新内核起不来 / 不认这份检查点）：GD 内核装不进它，退无可退 —— 回主菜单说清楚。
		## 当帧就拆：界面层刚被 start() 亮起来、还没画过一帧，返场时就不会闪一下空的右栏。存档一个字不动。
		## 原话 match.gd 已经写进日志，这里只要故障种类挑那句人话
		var fault := match_node.lost_fault()
		match_node.teardown()
		_entering = false
		await _back_to_menu()
		menu.show_notice(SAVE_LOST_TITLE, save_lost_text(fault))
		return
	_entering = false


## ── 新内核没了的时候说什么（换内核观察期，Kevin 2026-10-01）────────────────
## 新开局 sidecar 起不来会悄悄退回 GD 内核（CWMatch.start），玩家看不出来；只有这两种退不回去，要明说：
const SAVE_LOST_TITLE := "读不了这份存档"
const KERNEL_LOST_TITLE := "对局中断了"
## 两段通知的最后一行：原话不上屏（见 `kernel_reason`），告诉人去哪儿找。说「日志文件」不说「日志」——
## 对局里 L 键那块也叫「日志」，那里头没有这一条
const LOG_NOTE := "详细原因已写进日志文件。"


## 句柄的故障种类（`CWKernel.Fault`）→ 给玩家看的那半句（2026-10-01 复核）。**原话不上屏**：
## 「找不到 sidecar（dotnet=…，dll=…）」「退出码 -1」「decider 的答案被 sidecar 拒了」是写给开发看的 ——
## 玩家看不懂，路径还会把面板撑开、「-1」会在减号后面折行；原话由 match.gd / `_continue` 写进日志（godot.log）。
## 被拒（PROTOCOL）在这里只剩对局中途那一种（答案对不上，内核自己出了错）：读档时被拒 = 不认这份检查点，
## `save_lost_text` 整段另说（三轮复核第 5 条）。握手时 token 对不上也记 PROTOCOL —— 那得有别的本机进程抢先连进一次性端口，不单列
static func kernel_reason(fault: int) -> String:
	match fault:
		CWKernel.Fault.CRASHED:
			return "新内核意外退出了"
		CWKernel.Fault.REPLY_TIMEOUT:
			return "新内核没有响应"
		CWKernel.Fault.PROTOCOL, CWKernel.Fault.NONE:
			return "新内核出错了"
	## SPAWN_FAILED / HANDSHAKE_TIMEOUT / ABI_MISMATCH / SELFTEST_FAILED：进程没起来、或者起来了没握上手
	return "新内核没能启动"


## ① C# 存档读不回来（`_continue`）。存档都还在；「稍后可以再试」是实话：玩家每次亲手点「继续对局」都真去试一次
##（不看「这一次运行里起不来过」的记忆，见 `_continue`；原来记下了就当场拦，这句话只好分成「稍后」/「重新打开游戏后」两种）。
## 例外照实说（四轮复核）：不认这份检查点（读档时 PROTOCOL）—— 同一份档、同一个内核再点多半还是被拒，原因不猜（存档是这台机器上
## 这个版本写的，被拒多半是个 bug，原话进日志）；版本对不上（ABI_MISMATCH / SELFTEST_FAILED）—— 更新游戏前怎么点都一样；
## 游戏包里压根没有新内核（`missing`：`locate()` 都找不到，见 `_continue`）—— 重新下载完整的游戏才有。每句都压在一行之内
## 句与句之间硬换行：一句一行，折行就不会落在词中间（「存档还 / 在」，三轮复核第 9 条；面板内宽一行放得下二十来个字）
static func save_lost_text(fault: int, missing := false) -> String:
	if missing:
		return "这份存档需要新内核，但游戏包里缺它。\n存档还在，重新下载游戏后可以再试。\n" + LOG_NOTE
	if fault == CWKernel.Fault.PROTOCOL:
		return "这份存档新内核打不开。\n存档还在。\n" + LOG_NOTE
	if fault == CWKernel.Fault.ABI_MISMATCH or fault == CWKernel.Fault.SELFTEST_FAILED:
		return "这份存档需要新内核，但版本对不上。\n存档还在，更新游戏后可以再试。\n" + LOG_NOTE
	return "这份存档需要新内核，但%s。\n存档还在，稍后可以再试。\n%s" % [kernel_reason(fault), LOG_NOTE]


## ② 对局中途新内核没了（`_on_kernel_lost`）。存档位只有一份、读档也不删（cw_save.gd 头注），
## 那份存档不一定是这一局的 —— 所以只说「上次的存档」。教程里不提存档（三轮复核第 3 条）：存档位里那份从来不是教程
##（存档不记教程标志，读回来就是正式局），说「可以从『继续对局』接着打」就是把人往别的局里领；
## 教程要接着学是主菜单的「新手引导」，按进度回到这一关的开头（`CWGuideProgress` 续读只认关、不认步）。一句一行，理由同 ①
static func kernel_lost_text(why: String, save_kept: bool, tutorial: bool) -> String:
	var text := "%s，这一局只能到这里。" % why
	if tutorial:
		text += "\n可以从主菜单的「新手引导」重新开始这一关。"
	elif save_kept:
		text += "\n上次的存档还在，可以从「继续对局」接着打。"
	return text + "\n" + LOG_NOTE


## 盖暂停菜单的通知页，只给「返回主菜单」：那一项发的是暂停菜单原有的 "menu"，走 `_on_pause_chose` 同一条返场。不自动恢复。
## 开局过场还没走完（绽开 0.75 s / 教程开场幕布淡出）就先等它：过场期间 `_back_to_menu` 头一句就返回，
## 这时点「返回主菜单」只会关掉通知页、把人留在一盘不会动的棋上
func _on_kernel_lost(fault: int) -> void:
	## 教程是写死的剧本：C# 那边要是确定性的故障，重开这一关会在同一拍再撞一次。记成「这一次运行里起不来过」，
	## 通知里说的「从新手引导重新开始」就落到 GD 内核上（舞台换关 / 重装都看这份记忆）。正式局不记：下一局照旧先试新内核
	if match_node.tutorial:
		CWKernelSidecar._remember_start_failure(fault, "教程中途新内核没了：%s" % match_node.lost_reason())
	while _entering:
		await get_tree().process_frame
	pause.show_notice(KERNEL_LOST_TITLE, kernel_lost_text(kernel_reason(fault), CWSave.can_continue(), match_node.tutorial))


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
