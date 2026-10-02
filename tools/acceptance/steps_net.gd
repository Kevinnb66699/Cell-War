## tools/acceptance/steps_net.gd —— 联机两项：online（两个客户端在一间 2 人房里对打）/ web_solo（网页单机：主菜单开局走服务器的私人房）
##
## 服务器由命令行 server= 指定（不起本机服务器：要验的是包里的客户端连一台真服务器）。
## 服务器那边这一局跑在哪个内核上客户端看不到（报文与 GD 路同形），由起服务器的人保证（CW_KERNEL / P8 的缺省）。
## 联机逻辑抄自 game/tests/headless_test.gd 的 _net_room / _sc_progress_index（导出包里没有 res://tests）
extends "step_base.gd"

## 2 人房的两席各开一个客户端（同一进程）
const NICKS := ["验收甲", "验收乙"]


## 两个客户端连上 → 甲建一间不进大厅的 2 人房、乙凭房间码进来 → 各坐 0 / 1 号席、准备、甲开局 →
## 两人各自用「往前走」的答法作答，直到两边收到的状态都到了第 3 世界回合。顺带核每一份 sync 都装得进 CWMirror
func step_online(ctx: Dictionary) -> String:
	var url := CWOnlinePanel.url_of(server)
	var a := _client(ctx, NICKS[0])
	var b := _client(ctx, NICKS[1])
	var ta := _tally()
	var tb := _tally()
	a.message.connect(_audit.bind(ta))
	b.message.connect(_audit.bind(tb))
	a.connect_to(url)
	b.connect_to(url)
	if not await _pump(ctx, [a, b], func() -> bool: return a.client_id >= 0 and b.client_id >= 0, 15000):
		return "连不上 %s（甲 %s / 乙 %s）%s" % [url, a.status, b.status, _err(a, b)]
	a.create_room(2, 0, false)
	if not await _pump(ctx, [a, b], func() -> bool: return a.code != "", 10000):
		return "建不了房%s" % _err(a, b)
	b.join(a.code)
	if not await _pump(ctx, [a, b], func() -> bool: return b.code == a.code, 10000):
		return "乙凭房间码 %s 进不去%s" % [a.code, _err(a, b)]
	a.sit(0)
	b.sit(1)
	if not await _pump(ctx, [a, b], func() -> bool: return a.my_seat == 0 and b.my_seat == 1, 10000):
		return "坐不下（甲席 %d / 乙席 %d）%s" % [a.my_seat, b.my_seat, _err(a, b)]
	a.ready()
	b.ready()
	if not await _pump(ctx, [a, b], func() -> bool: return a.room["seats"][0]["ready"] and a.room["seats"][1]["ready"], 10000):
		return "准备不上%s" % _err(a, b)
	a.start()
	var t0 := Time.get_ticks_msec()
	var reached := func() -> bool: return int(ta["round"]) >= 3 and int(tb["round"]) >= 3
	var ok := await _pump(ctx, [a, b], func() -> bool:
		_answer_pending([a, b])
		return reached.call() or not a.game_over.is_empty() or int(ta["bad"]) + int(tb["bad"]) > 0, 150000)
	if int(ta["bad"]) + int(tb["bad"]) > 0:
		return "有 %d 份 sync 装不进 CWMirror：%s" % [int(ta["bad"]) + int(tb["bad"]), String(ta["bad_msg"]) + String(tb["bad_msg"])]
	if not ok or not reached.call():
		return "没打到第 3 世界回合（甲看到第 %d、乙看到第 %d 回合；终局 %s）%s" % [int(ta["round"]), int(tb["round"]),
			str(a.game_over.get("reason", "-")), _err(a, b)]
	ctx["notes"].append("房间 %s：第 %d 世界回合（%.1f s，甲 %d 问、乙 %d 问，sync 各 %d / %d 份）" % [a.code, int(ta["round"]),
		(Time.get_ticks_msec() - t0) / 1000.0, int(ta["asks"]), int(tb["asks"]), int(ta["syncs"]), int(tb["syncs"])])
	a.leave()
	b.leave()
	await _pump(ctx, [a, b], func() -> bool: return false, 500)   ## 让离开那两条报文出得去，房间在服务器上当场关
	return ""


## 网页单机：主菜单「开始对局」（一位真人 + AI）走服务器开私人房（main.gd solo_via_server，网页版恒开，这里拨开），
## 镜头推完按联机局进棋盘；界面上照常作答打到第 3 世界回合，再从暂停菜单「返回主菜单」（告别服务器、房间关掉）
func step_web_solo(ctx: Dictionary) -> String:
	var main_scene := await open_main(ctx, func(ms: Node) -> void: ms.solo_via_server = true)
	## 排在 Main 进树之后：它的 _ready 会 load_prefs，那一下会把设置盖回盘上存的（用户目录是新清的，盘上没有）
	CWSettings.server = server
	CWSettings.nick = "验收"
	var m = main_scene.match_node
	begin_match(main_scene, 2, CWData.Faction.IMMUNE, CWMatch.AI_NORMAL, 0)
	if not await until(ctx, func() -> bool: return not main_scene._entering and m.kernel != null and m.mirror != null, 30000):
		return "开局过场没走完 / 对局没开起来（%s）" % main_scene.menu.solo_error()
	if not m.online or not m.solo or not (m.kernel is CWKernelRemote):
		return "没走成服务器的私人房、退回本地开了（%s；句柄 %s）" % [main_scene.menu.solo_error(), _kernel_name(m.kernel)]
	ctx["notes"].append("私人房开好、按联机局进了棋盘（我坐席 %s）" % str(m.human_players))
	var why := await play_to_round(ctx, m, 3)
	if why != "":
		return why
	return "" if await back_to_menu(ctx, main_scene) else "打完回不到主菜单"


func _client(ctx: Dictionary, nick: String) -> CWNetClient:
	var c := CWNetClient.new()
	c.nick = nick
	ctx["clients"].append(c)
	return c


## 客户端每帧 poll（服务器在别的进程里，不归这里转），直到 until 成立；没等到返回 false
func _pump(ctx: Dictionary, clients: Array, cond: Callable, ms: int) -> bool:
	var stop := mini(Time.get_ticks_msec() + ms, int(ctx["deadline"]))
	while true:
		for c in clients:
			await c.poll()
		if cond.call():
			return true
		if Time.get_ticks_msec() > stop or bool(ctx["cancelled"]):
			return false
		await t.process_frame
	return false


## 手上悬着一问就答：结束回合 / 停 / 跳过，都没有就第一项（落子、弃牌这类每项都往前走）。抄 `_sc_progress_index`，语义键一起交
func _answer_pending(clients: Array) -> void:
	for c: CWNetClient in clients:
		if c.pending_ask.is_empty():
			continue
		var req: Dictionary = c.pending_ask["req"]
		var opts: Array = req.get("options", [])
		var idx := 0
		for i in opts.size():
			var d: Dictionary = opts[i].get("data", {})
			if String(d.get("act", "")) == "end" or bool(d.get("stop", false)) or bool(d.get("skip", false)):
				idx = i
				break
		var key := CWSemKey.key(req, opts[idx]["data"]) if not opts.is_empty() else ""
		c.answer(int(c.pending_ask["ask_id"]), idx, key)


static func _tally() -> Dictionary:
	return { "round": -1, "asks": 0, "syncs": 0, "bad": 0, "bad_msg": "" }


## 一个客户端收到的对局流记账：sync 装进 CWMirror 读世界回合（装不进算坏），ask 计数
static func _audit(msg: Dictionary, tally: Dictionary) -> void:
	match String(msg["t"]):
		"ask":
			tally["asks"] += 1
		"sync":
			tally["syncs"] += 1
			var mm := CWMirror.new()
			var err := mm.load_from(msg["envelope"])
			if err != "":
				tally["bad"] += 1
				tally["bad_msg"] = err
			else:
				tally["round"] = maxi(int(tally["round"]), int(mm.round_no))


## 服务器回过的最后一条错误（没有就空串）
static func _err(a: CWNetClient, b: CWNetClient) -> String:
	for c in [a, b]:
		if not (c.last_error as Dictionary).is_empty():
			return "；服务器说：%s" % str(c.last_error)
	return ""
