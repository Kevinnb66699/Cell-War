## net_live.gd —— 线上验收：连一台**真正在跑的**联机服务器，把协议 / 大厅 / 对局 / AI 补位 / 重连 / 超时 / 并发房间 / 频率限制跑一遍
##
## 无头回归（headless_test 的 t_net_*）验的是「代码对不对」，服务器和客户端在同一个进程里走回环；
## 这个脚本验的是「线上那台机器、经过公网、systemd 里那份进程」对不对 —— 发版后跑一遍，全绿才算上线。
## 客户端全在本进程里（一台笔记本开若干个 CWNetClient），机器人用启发式作答，规则都在服务器上跑。
##
##   godot --headless --path game --script res://tests/net_live.gd -- url=ws://124.221.78.13:8611
## 参数：url=…（默认公网服务器）  quick=1（跳过 4 人 AI 补位局和并发局，只跑 3 分钟内的那几项）
## 退出码 0 = 全绿。每项都有墙钟上限，服务器卡死也不会挂住不退。
## ⚠ 跑它的机器别同时跑平衡网格：客户端全在本进程里，被饿到 20 秒发不出心跳，服务器会把它们判成掉线
##   （2026-09-03 第一轮：笔记本上 15 个 MC 进程把验收进程饿死，超时场景的两个机器人被服务器踢了）。
extends SceneTree

var url := "ws://%s:%d" % [CWNet.DEFAULT_HOST, CWNet.DEFAULT_PORT]
var quick := false
var fails := 0
var checks := 0
var _t_scene := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "url":
			url = kv[1]
		elif kv.size() == 2 and kv[0] == "quick":
			quick = kv[1] != "0"
	_run()


func _run() -> void:
	print("线上验收 %s%s" % [url, "（快速档）" if quick else ""])
	await s_version()
	await s_lobby()
	await s_game_2p()
	await s_reconnect()
	await s_timeout()
	await s_rate_limit()
	if not quick:
		await s_game_4p_ai()
		await s_concurrent_rooms()
	print("")
	if fails == 0:
		print("✔ 线上验收通过（%d 项检查）" % checks)
		quit(0)
	else:
		print("✘ %d 项检查失败（共 %d 项）" % [fails, checks])
		quit(1)


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("  ok  %s" % name)
	else:
		fails += 1
		print("  FAIL %s" % name)


func _scene(name: String) -> void:
	print("[%s]" % name)
	_t_scene = Time.get_ticks_msec()


func _took() -> String:
	return "%.1f s" % ((Time.get_ticks_msec() - _t_scene) / 1000.0)


func _client(nick: String, bot: bool = true) -> CWNetClient:
	var c := CWNetClient.new()
	c.nick = nick
	if bot:
		c.autoplay = CWHeuristicBridge.new()
	return c


## 轮询这些客户端直到条件成立；墙钟上限 max_ms（远端的事没有帧数可数）
func _pump(clients: Array, until: Callable, max_ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		for c in clients:
			await c.poll()
		if until.call():
			return true
		await process_frame
	return false


## 连不上的重试一次并说出来 —— 公网上偶尔一个握手包丢了 / 来源 IP 被限流，是环境不是代码（2026-09-03 两次撞到）
func _connect_all(clients: Array, max_ms := 15000) -> bool:
	for c in clients:
		c.connect_to(url, c.nick, c.code, c.token)
	var all_in := func() -> bool:
		for c in clients:
			if c.client_id < 0:
				return false
		return true
	if await _pump(clients, all_in, max_ms):
		return true
	var retried: Array = []
	for c in clients:
		if c.client_id < 0:
			retried.append(c.nick)
			c.connect_to(url, c.nick, c.code, c.token)
	var ok: bool = await _pump(clients, all_in, max_ms)
	print("      （%s 第一次握手 %d 秒没通，重试一次：%s）" % ["、".join(retried), max_ms / 1000, "通了" if ok else "还是不通"])
	return ok


func _count(c: CWNetClient, t: String) -> int:
	var n := 0
	for m in c.inbox:
		if m["t"] == t:
			n += 1
	return n


func _last(c: CWNetClient, t: String) -> Dictionary:
	for i in range(c.inbox.size() - 1, -1, -1):
		if c.inbox[i]["t"] == t:
			return c.inbox[i]
	return {}


## 建房 → 乙加入 → 各坐 0/1 → 都准备；返回是否就绪
func _room_2p(a: CWNetClient, b: CWNetClient, timer: int, seed_value: int, players := 2) -> bool:
	a.create_room(players, timer, false, seed_value)
	if not await _pump([a, b], func() -> bool: return a.code != "", 10000):
		return false
	b.join(a.code)
	if not await _pump([a, b], func() -> bool: return b.code == a.code, 10000):
		return false
	a.sit(0)
	b.sit(1)
	if not await _pump([a, b], func() -> bool: return a.my_seat == 0 and b.my_seat == 1, 10000):
		return false
	a.ready()
	b.ready()
	return await _pump([a, b], func() -> bool:
		return a.room.get("seats", []).size() > 1 and a.room["seats"][0]["ready"] and a.room["seats"][1]["ready"], 10000)


## 别人的手牌在我的视角里必须全是占位；返回泄露的张数
func _hand_leaks(c: CWNetClient, my_pid: int) -> int:
	var leaks := 0
	for m in c.inbox:
		if m["t"] != "state":
			continue
		for cell in m["view"]["cells"]:
			if cell["pid"] == my_pid:
				continue
			for card in cell["hand"]:
				if card != CWNet.HIDDEN_CARD:
					leaks += 1
	return leaks


## 相邻两份状态之间最长隔了多久（服务器被 AI 决策堵住的体感指标）
func _max_state_gap_ms(c: CWNetClient) -> int:
	var gap := 0
	var last := -1
	for m in c.inbox:
		if m["t"] != "state":
			continue
		var t: int = m.get("_recv_ms", -1)
		if last >= 0 and t >= 0:
			gap = maxi(gap, t - last)
		last = t
	return gap


## 给收到的每条报文盖一个本机时间戳（inbox 里的字典是同一个对象，直接加键）
func _stamp(c: CWNetClient) -> void:
	c.message.connect(func(m: Dictionary) -> void: m["_recv_ms"] = Time.get_ticks_msec())


# ============ 场景 ============

func s_version() -> void:
	_scene("版本校验")
	var old := _client("旧版本", false)
	old.hello_version = 999
	old.connect_to(url, old.nick)
	var ok := await _pump([old], func() -> bool:
		return old.last_error.get("code", "") == "version" and old.status == "closed", 15000)
	check(ok, "协议版本不符 → 收到 version 错误并被断开（%s）" % _took())
	old.dispose()


func s_lobby() -> void:
	_scene("大厅与房间")
	var a := _client("甲", false)
	var b := _client("乙", false)
	check(await _connect_all([a, b]), "两个客户端握手拿到 welcome（%s）" % _took())
	check(not _last(a, "welcome").get("maintenance", true), "服务器不在维护中")
	a.list_rooms()
	var ok := await _pump([a], func() -> bool: return _count(a, "lobby") > 0, 10000)
	check(ok, "大厅列表能拿到（当前 %d 个公开房）" % _last(a, "lobby").get("rooms", []).size())
	## 私密房不进列表
	a.create_room(2, 0, false, 0)
	ok = await _pump([a, b], func() -> bool: return a.code != "", 10000)
	check(ok and a.code.length() == CWNet.CODE_LEN and a.room.get("you_host", false), "建私密房：6 位房间码，建房者是房主")
	b.list_rooms()
	await _pump([a, b], func() -> bool: return _count(b, "lobby") > 0, 10000)
	var listed := false
	for r in _last(b, "lobby").get("rooms", []):
		if r["code"] == a.code:
			listed = true
	check(not listed, "私密房不进大厅列表")
	b.join("ZZZZZZ")
	ok = await _pump([a, b], func() -> bool: return b.last_error.get("code", "") == "no_room", 10000)
	check(ok, "加入不存在的房间：no_room")
	b.join(a.code.to_lower())
	ok = await _pump([a, b], func() -> bool: return b.code == a.code, 10000)
	check(ok and b.room["members"].size() == 2, "房间码不分大小写，加入后成员两人")
	b.sit(1)
	ok = await _pump([a, b], func() -> bool: return b.my_seat == 1, 10000)
	check(ok and b.token != "", "坐下拿到席位与重连令牌")
	a.sit(0)
	ok = await _pump([a, b], func() -> bool: return a.my_seat == 0, 10000)
	check(ok, "房主坐 0 号席")
	a.set_ai(1, "heur")
	ok = await _pump([a, b], func() -> bool: return a.last_error.get("code", "") == "seat_taken", 10000)
	check(ok, "有人坐着的席位不能放 AI：seat_taken")
	a.leave()
	b.leave()
	ok = await _pump([a, b], func() -> bool: return a.code == "" and b.code == "" and _count(a, "left") > 0, 10000)
	check(ok, "离开房间收到回执（%s）" % _took())
	## 公开房进列表
	a.create_room(4, 60, true, 0)
	await _pump([a, b], func() -> bool: return a.code != "", 10000)
	b.list_rooms()
	await _pump([a, b], func() -> bool: return _count(b, "lobby") > 1, 10000)
	listed = false
	for r in _last(b, "lobby").get("rooms", []):
		if r["code"] == a.code and r["host"] == "甲" and r["players"] == 4 and r["timer"] == 60:
			listed = true
	check(listed, "公开房进大厅列表，带房主 / 人数 / 计时")
	a.leave()
	await _pump([a, b], func() -> bool: return a.code == "", 10000)
	a.dispose()
	b.dispose()


func s_game_2p() -> void:
	_scene("2 人整局（两位真人机器人）")
	var a := _client("甲")
	var b := _client("乙")
	_stamp(a)
	_stamp(b)
	check(await _connect_all([a, b]), "连上")
	check(await _room_2p(a, b, 0, 20260910), "建房坐席就绪")
	a.start()
	var ok := await _pump([a, b], func() -> bool: return not a.game_over.is_empty() and not b.game_over.is_empty(), 300000)
	check(ok, "打完整局（%s，%d 份状态，第 %d 回合）" % [_took(), _count(a, "state"), a.game_over.get("round", -1)])
	if not ok:
		a.dispose(); b.dispose(); return
	check(a.game_over["winner"] == b.game_over["winner"] and a.game_over["reason"] == b.game_over["reason"],
		"双方收到同一终局：%s" % a.game_over["reason"])
	check(a.logs.size() == b.logs.size() and a.logs.size() > 50, "双方日志行数一致（%d 行）" % a.logs.size())
	check(a.shadow.winner == a.game_over["winner"] and b.shadow.state_hash() != "", "终局快照与 game_over 一致")
	check(_hand_leaks(a, 0) == 0 and _hand_leaks(b, 1) == 0, "视角快照里别人的手牌全是占位（不泄露）")
	check(_count(a, "ask") > 0 and _count(b, "ask") > 0, "双方都被问过（甲 %d 次、乙 %d 次）" % [_count(a, "ask"), _count(b, "ask")])
	check(_count(a, "roll") == _count(b, "roll") and _count(a, "roll") > 0, "掷骰演出广播给双方各一次（%d 次）" % _count(a, "roll"))
	check(a.status == "open" and b.status == "open", "整局没有掉线")
	print("      相邻状态最长间隔 %d ms" % _max_state_gap_ms(a))
	check(a.room.get("state", "") == "waiting" and not a.room["seats"][0]["ready"], "局末房间回到等待中、准备状态清零")
	a.leave(); b.leave()
	await _pump([a, b], func() -> bool: return a.code == "" and b.code == "", 10000)
	a.dispose()
	b.dispose()


func s_reconnect() -> void:
	_scene("断线重连（有计时：询问悬着等他回来）")
	var a := _client("甲")
	var b := _client("乙", false)
	check(await _connect_all([a, b]), "连上")
	check(await _room_2p(a, b, 60, 20260911), "2 人房、60 秒计时就绪")
	a.start()
	var ok := await _pump([a, b], func() -> bool: return not b.pending_ask.is_empty(), 60000)
	check(ok, "乙收到自己的询问")
	if not ok:
		a.dispose(); b.dispose(); return
	var ask_id: int = b.pending_ask["ask_id"]
	var left: int = b.pending_ask["left_ms"]
	check(left > 40000 and left <= 60000, "询问带剩余时间（%d ms）" % left)
	var token: String = b.token
	var code: String = b.code
	b.dispose()                                          ## 硬断线：socket 直接关
	await _pump([a], func() -> bool: return false, 3000)   ## 让服务器察觉
	var bad := _client("丙", false)
	bad.connect_to(url, "丙", code, "deadbeef")
	ok = await _pump([a, bad], func() -> bool: return bad.last_error.get("code", "") == "bad_token", 15000)
	check(ok, "错误令牌：bad_token")
	bad.dispose()
	var b2 := _client("乙", false)
	b2.connect_to(url, "乙", code, token)
	ok = await _pump([a, b2], func() -> bool: return not b2.pending_ask.is_empty(), 20000)
	check(ok and b2.pending_ask["ask_id"] == ask_id and b2.my_seat == 1, "凭令牌重连：席位接回、同一次询问重发（ask #%d）" % ask_id)
	check(b2.shadow != null and b2.logs.size() > 0, "重连拿到当前状态与日志（%d 行）" % b2.logs.size())
	b2.autoplay = CWHeuristicBridge.new()
	ok = await _pump([a, b2], func() -> bool: return not a.game_over.is_empty() and not b2.game_over.is_empty(), 300000)
	check(ok, "重连后打完整局（%s）" % _took())
	a.leave(); b2.leave()
	await _pump([a, b2], func() -> bool: return a.code == "" and b2.code == "", 10000)
	a.dispose()
	b2.dispose()


func s_timeout() -> void:
	_scene("回合计时超时代打（乙从不作答）")
	var a := _client("甲")
	var b := _client("乙", false)
	check(await _connect_all([a, b]), "连上")
	check(await _room_2p(a, b, 3, 20260912), "2 人房、3 秒计时就绪")
	a.start()
	var ids := {}
	b.message.connect(func(m: Dictionary) -> void:
		if m["t"] == "ask":
			ids[m["ask_id"]] = true)
	var ok := await _pump([a, b], func() -> bool: return not a.game_over.is_empty() and not b.game_over.is_empty(), 720000)
	check(ok, "乙一直不答，服务器到点代打，整局仍打完（%s，乙被问 %d 次）" % [_took(), ids.size()])
	if not ok:
		print("      甲 status=%s err=%s | 乙 status=%s err=%s room=%s" % [a.status, str(a.last_error.get("code", "")), b.status, str(b.last_error.get("code", "")), str(b.room.get("state", ""))])
	check(ids.size() >= 3, "乙收到多次询问（每次到点都换了新的一问）")
	check(b.status == "open", "不作答不算掉线，乙全程在线")
	a.leave(); b.leave()
	await _pump([a, b], func() -> bool: return a.code == "" and b.code == "", 10000)
	a.dispose()
	b.dispose()


func s_rate_limit() -> void:
	_scene("频率限制")
	var a := _client("刷屏", false)
	check(await _connect_all([a]), "连上（%s）" % ("status=" + a.status))
	for i in 60:
		a.list_rooms()
	var ok := await _pump([a], func() -> bool: return a.status == "closed", 10000)
	check(ok, "一秒 60 条非作答报文 → 被断开（%s）" % (a.last_error.get("code", "（未收到错误码，直接断）")))
	a.dispose()


func s_game_4p_ai() -> void:
	_scene("4 人整局：两位真人 + 新手 AI + 专家 AI（专家档在服务器上跑 rollouts=2·horizon=40）")
	var a := _client("甲")
	var b := _client("乙")
	_stamp(a)
	check(await _connect_all([a, b]), "连上")
	check(await _room_2p(a, b, 0, 20260913, 4), "4 人房两位真人坐好")
	a.set_ai(2, "heur")
	a.set_ai(3, "mc")
	var ok := await _pump([a, b], func() -> bool:
		return a.room["seats"][2]["kind"] == "ai" and a.room["seats"][3]["tier"] == "mc", 10000)
	check(ok, "房主放好新手 AI 与专家 AI")
	a.start()
	ok = await _pump([a, b], func() -> bool: return not a.game_over.is_empty() and not b.game_over.is_empty(), 900000)
	check(ok, "打完整局（%s，%d 份状态，第 %d 回合）" % [_took(), _count(a, "state"), a.game_over.get("round", -1)])
	if ok:
		check(a.game_over["winner"] == b.game_over["winner"], "双方同一终局：%s" % a.game_over["reason"])
		check(a.status == "open" and b.status == "open", "专家 AI 思考期间没把真人判成掉线")
		print("      相邻状态最长间隔 %d ms（专家 AI 决策会堵住服务器，看它有多长）" % _max_state_gap_ms(a))
	a.leave(); b.leave()
	await _pump([a, b], func() -> bool: return a.code == "" and b.code == "", 10000)
	a.dispose()
	b.dispose()


func s_concurrent_rooms() -> void:
	_scene("并发：三个房间同时开打")
	var pairs: Array = []
	var all: Array = []
	for k in 3:
		var a := _client("甲%d" % k)
		var b := _client("乙%d" % k)
		pairs.append([a, b])
		all.append(a)
		all.append(b)
	check(await _connect_all(all), "六个客户端都连上")
	var ready := true
	for k in 3:
		if not await _room_2p(pairs[k][0], pairs[k][1], 0, 20260920 + k):
			ready = false
	check(ready, "三个房间都就绪")
	for k in 3:
		pairs[k][0].start()
	var ok := await _pump(all, func() -> bool:
		for c in all:
			if c.game_over.is_empty():
				return false
		return true, 600000)
	var winners: Array = []
	for k in 3:
		winners.append(pairs[k][0].game_over.get("winner", -9))
	check(ok, "三局都打完（%s，胜方 %s）" % [_took(), str(winners)])
	var same := true
	for k in 3:
		if pairs[k][0].game_over.get("winner", -9) != pairs[k][1].game_over.get("winner", -8):
			same = false
	check(same, "每个房间两边终局一致，房间之间互不串")
	for c in all:
		c.leave()
	await _pump(all, func() -> bool:
		for c in all:
			if c.code != "":
				return false
		return true, 10000)
	for c in all:
		c.dispose()
