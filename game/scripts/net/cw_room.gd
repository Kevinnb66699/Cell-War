## cw_room.gd —— 联机房间：席位、等待室、对局宿主、每客户端的视角推送
##
## 一个房间 = 一份 CWGame + 一个 CWNetBridge（注册给所有 pid）+ 席位表。
## 服务器每帧 poll → 报文分发到这里；真人作答通过 Waiter 信号把挂在 ask_human 里的引擎协程接着往下推，
## 引擎一路跑到下一次需要真人作答的询问再挂起 —— 中间的 AI 席位、演出广播、状态推送全在这一次调用里完成。
## 所以控制权在服务器手里时，引擎要么已结束、要么正停在某个真人的询问上（_ask 非空）。
##
## 掉线（docs/联机设计 §六）：对局中席位保留、标离线；正悬着的询问若房间有计时就等到期限（给他重连的机会），
## 没计时就立刻由启发式代打；之后轮到他的询问都由启发式即时代打，直到凭令牌重连。
## 所有真人都离线 → 中止对局、关房。等待室里掉线 = 起身。
class_name CWRoom
extends RefCounted

class Waiter extends RefCounted:
	signal done(index: int)

enum State { WAITING, PLAYING, CLOSED }

var code := ""
var public := true
var timer_secs := 60            ## 每次决策的秒数，0 = 不限
var player_count := 4
var seed_override := 0          ## 非 0 则每局用这个种子（测试用）
var seats: Array = []           ## 下标 = pid，元素见 empty_seat()
var members := {}               ## client id -> 昵称（房里所有人，含没坐下的）
var host := -1                  ## 房主的 client id
var state := State.WAITING
var game: CWGame
var bridge: CWNetBridge
var server: CWNetServer
var empty_since := 0            ## members 空了的时刻（ms），0 = 不空
var games_played := 0
var timeouts := 0               ## 超时代打次数（统计/测试）

var _ask := {}                  ## 正悬着的真人询问 {pid, ask_id, req, deadline, waiter}
var _ask_seq := 0
var _log_cursor := {}           ## client id -> 已发到第几行日志


static func empty_seat() -> Dictionary:
	return { "kind": "", "client": -1, "nick": "", "ready": false, "tier": "", "token": "", "online": false }


static func ai_seat(tier: String) -> Dictionary:
	var s := empty_seat()
	s["kind"] = "ai"
	s["tier"] = tier
	s["nick"] = CWNet.AI_TIERS[tier]
	return s


func configure(p_server: CWNetServer, p_code: String, players: int, timer: int, p_public: bool) -> void:
	server = p_server
	code = p_code
	player_count = players
	timer_secs = timer
	public = p_public
	seats = []
	for i in players:
		seats.append(empty_seat())


# ---- 成员 ----
func join(cid: int, nick: String) -> void:
	members[cid] = nick
	empty_since = 0
	if host < 0:
		host = cid
	push_room()
	if state == State.PLAYING:
		_log_cursor[cid] = 0
		push_state_to(cid, _ask.get("pid", -1))


## 主动离开与掉线同路
func leave(cid: int) -> void:
	if not members.has(cid):
		return
	members.erase(cid)
	_log_cursor.erase(cid)
	var pid := pid_of_client(cid)
	if pid >= 0:
		var s: Dictionary = seats[pid]
		if state == State.PLAYING:
			s["client"] = -1
			s["online"] = false
			s["ready"] = false
		else:
			seats[pid] = empty_seat()
	if cid == host:
		host = -1
		for c in members:          ## 先让坐着的真人接房主
			if pid_of_client(c) >= 0:
				host = c
				break
		if host < 0 and not members.is_empty():
			host = members.keys()[0]
	if state == State.PLAYING and pid >= 0:
		_on_seat_offline()
	if members.is_empty():
		empty_since = server.now_ms()
		if state == State.PLAYING:
			_abort_game()
		return
	push_room()


func pid_of_client(cid: int) -> int:
	for pid in seats.size():
		if seats[pid]["kind"] == "human" and seats[pid]["client"] == cid:
			return pid
	return -1


func _any_human_online() -> bool:
	for s in seats:
		if s["kind"] == "human" and s["online"]:
			return true
	return false


func _on_seat_offline() -> void:
	if not _any_human_online():
		_abort_game()
		return
	## 悬着的询问正是他的：无计时立刻代打；有计时等到期限，给重连留机会
	if not _ask.is_empty() and not seats[_ask["pid"]]["online"] and timer_secs <= 0:
		_auto_answer()


## 凭令牌把一个新连接接回席位；等待室里席位已经被清空，令牌自然对不上
func reconnect(cid: int, nick: String, token: String) -> String:
	if token == "":
		return "bad_token"
	for pid in seats.size():
		var s: Dictionary = seats[pid]
		if s["kind"] != "human" or s["token"] != token:
			continue
		if s["client"] >= 0 and s["client"] != cid:
			var old: int = s["client"]       ## 同一个人开了第二个窗口：旧连接让位
			members.erase(old)
			_log_cursor.erase(old)
			server.send(old, { "t": "error", "code": "room_closed", "msg": CWNet.error_text("room_closed") })
			server.unbind(old)
		s["client"] = cid
		s["online"] = true
		if nick != "":
			s["nick"] = nick
		members[cid] = s["nick"]
		empty_since = 0
		if host < 0:
			host = cid
		_log_cursor[cid] = 0
		push_room()
		if state == State.PLAYING:
			push_state_to(cid, _ask.get("pid", -1))
			if not _ask.is_empty() and _ask["pid"] == pid:
				_send_ask()
		return ""
	return "bad_token"


# ---- 等待室 ----
func sit(cid: int, seat: Variant) -> String:
	if state != State.WAITING:
		return "not_waiting"
	if typeof(seat) != TYPE_INT or seat < 0 or seat >= seats.size():
		return "bad_seat"
	if seats[seat]["kind"] != "":
		return "" if seats[seat]["client"] == cid else "seat_taken"
	var old := pid_of_client(cid)
	if old >= 0:
		seats[old] = empty_seat()
	var s := empty_seat()
	s["kind"] = "human"
	s["client"] = cid
	s["nick"] = members[cid]
	s["online"] = true
	s["token"] = CWNet.make_token(server.rng)
	seats[seat] = s
	push_room()
	return ""


func stand(cid: int) -> String:
	if state != State.WAITING:
		return "not_waiting"
	var pid := pid_of_client(cid)
	if pid < 0:
		return "not_seated"
	seats[pid] = empty_seat()
	push_room()
	return ""


func set_ready(cid: int, flag: Variant) -> String:
	if state != State.WAITING:
		return "not_waiting"
	var pid := pid_of_client(cid)
	if pid < 0:
		return "not_seated"
	seats[pid]["ready"] = bool(flag)
	push_room()
	return ""


func set_ai(cid: int, seat: Variant, tier: Variant) -> String:
	if cid != host:
		return "not_host"
	if state != State.WAITING:
		return "not_waiting"
	if typeof(seat) != TYPE_INT or seat < 0 or seat >= seats.size():
		return "bad_seat"
	if seats[seat]["kind"] == "human":
		return "seat_taken"
	if tier == null or tier == "":
		seats[seat] = empty_seat()
	elif tier is String and CWNet.AI_TIERS.has(tier):
		seats[seat] = ai_seat(tier)
	else:
		return "bad_param"
	push_room()
	return ""


func kick(cid: int, seat: Variant) -> String:
	if cid != host:
		return "not_host"
	if state != State.WAITING:
		return "not_waiting"
	if typeof(seat) != TYPE_INT or seat < 0 or seat >= seats.size():
		return "bad_seat"
	var s: Dictionary = seats[seat]
	if s["kind"] != "human" or s["client"] == cid:
		return "bad_seat"
	var victim: int = s["client"]
	server.send(victim, { "t": "error", "code": "kicked", "msg": CWNet.error_text("kicked") })
	server.unbind(victim)      ## 里面会调回 leave(victim)
	return ""


func start(cid: int) -> String:
	if cid != host:
		return "not_host"
	if state != State.WAITING:
		return "not_waiting"
	if server.drain:
		return "maintenance"
	var humans := 0
	for s in seats:
		if s["kind"] == "":
			return "seat_empty"
		if s["kind"] == "human":
			humans += 1
	if humans == 0:
		return "no_human"
	for s in seats:
		if s["kind"] == "human" and not s["ready"]:
			return "not_ready"
	game = CWGame.new()
	var seed_value: int = seed_override if seed_override != 0 else server.rng.randi()
	game.init(CWData.FACTION_ORDER[player_count], seed_value)
	bridge = CWNetBridge.new()
	bridge.room = self
	bridge.game = game
	bridge.heur.game = game
	bridge.mc.game = game
	for pid in game.order:
		game.bridges[pid] = bridge
	state = State.PLAYING
	_log_cursor.clear()
	push_room()
	server.say("房间 %s 开局：%d 人，种子 %d，计时 %d s" % [code, player_count, seed_value, timer_secs])
	_run()
	return ""


func _run() -> void:
	var winner: int = await game.run_game()
	if state != State.PLAYING:          ## 中途被中止 / 关房
		_teardown_game()
		return
	push_state(-1)
	games_played += 1
	broadcast({ "t": "game_over", "winner": winner, "reason": game.win_reason,
		"kind": game.win_kind, "round": game.round_no })
	server.say("房间 %s 终局：%s（第 %d 回合）" % [code, game.win_reason, game.round_no])
	state = State.WAITING
	for s in seats:
		s["ready"] = false
	_teardown_game()
	push_room()


func _teardown_game() -> void:
	if game == null:
		return
	bridge.heur.game = null
	bridge.mc.game = null
	bridge.room = null
	game.dispose()
	game = null
	bridge = null
	_ask = {}


## 中止对局：引擎停在某个真人的询问上，答它一个 0 让协程展开，run_game 看到 aborted 就收摊
func _abort_game() -> void:
	if game == null or state != State.PLAYING:
		return
	state = State.CLOSED
	game.aborted = true
	if not _ask.is_empty():
		var a := _ask
		_ask = {}
		a["waiter"].done.emit(0)
	server.close_room(self)


# ---- 对局中 ----
func ask_human(pid: int, req: Dictionary) -> int:
	_ask_seq += 1
	var now := server.now_ms()
	_ask = { "pid": pid, "ask_id": _ask_seq, "req": req,
		"deadline": now + timer_secs * 1000 if timer_secs > 0 else 0, "waiter": Waiter.new() }
	_send_ask()
	var idx: int = await _ask["waiter"].done
	_ask = {}
	return idx


func _send_ask() -> void:
	var s: Dictionary = seats[_ask["pid"]]
	if s["client"] < 0:
		return
	var dl: int = _ask["deadline"]
	server.send(s["client"], { "t": "ask", "ask_id": _ask["ask_id"], "req": _ask["req"],
		"left_ms": -1 if dl <= 0 else maxi(0, dl - server.now_ms()) })


func answer(cid: int, ask_id: Variant, index: Variant) -> String:
	var pid := pid_of_client(cid)
	if pid < 0:
		return "not_seated"
	if _ask.is_empty() or _ask["pid"] != pid or _ask["ask_id"] != ask_id:
		return "stale"
	if typeof(index) != TYPE_INT or index < 0 or index >= _ask["req"]["options"].size():
		return "bad_index"
	_ask["waiter"].done.emit(index)
	return ""


## 服务器自己被堵住了 gap 毫秒（AI 在想）：这段时间不算在玩家的计时里
func forgive_stall(gap: int) -> void:
	if not _ask.is_empty() and _ask["deadline"] > 0:
		_ask["deadline"] += gap


## 服务器每帧调：计时到点就代打
func tick(now: int) -> void:
	if state != State.PLAYING or _ask.is_empty():
		return
	var dl: int = _ask["deadline"]
	if dl > 0 and now >= dl:
		timeouts += 1
		_auto_answer()


func _auto_answer() -> void:
	var a := _ask
	var idx: int = await bridge.heur.ask(a["req"])
	if _ask != a:
		return
	a["waiter"].done.emit(idx)


func push_state(turn_pid: int) -> void:
	if game == null:
		return
	var h := game.state_hash()
	for cid in members.keys():
		push_state_to(cid, turn_pid, h)


func push_state_to(cid: int, turn_pid: int, h: String = "") -> void:
	if game == null:
		return
	var pid := pid_of_client(cid)
	var from: int = _log_cursor.get(cid, 0)
	var lines := CWNet.logs_for(game, pid, from)
	_log_cursor[cid] = game.logs.size()
	server.send(cid, { "t": "state", "view": CWNet.view_for(game, pid), "logs": lines,
		"turn": turn_pid, "hash": h if h != "" else game.state_hash(), "game": games_played })


func broadcast(msg: Dictionary) -> void:
	for cid in members.keys():
		server.send(cid, msg)


# ---- 视图 ----
func view_for(cid: int) -> Dictionary:
	var my_pid := pid_of_client(cid)
	var seat_list: Array = []
	for pid in seats.size():
		var s: Dictionary = seats[pid]
		seat_list.append({ "kind": s["kind"], "nick": s["nick"], "ready": s["ready"], "tier": s["tier"],
			"online": s["online"], "faction": CWData.FACTION_ORDER[player_count][pid] })
	var names: Array = []
	for c in members:
		names.append(members[c])
	return { "t": "room", "code": code, "public": public, "timer": timer_secs, "players": player_count,
		"state": "playing" if state == State.PLAYING else "waiting",
		"host": members.get(host, ""), "you_host": cid == host, "you_seat": my_pid,
		"token": seats[my_pid]["token"] if my_pid >= 0 else "",
		"seats": seat_list, "members": names, "games": games_played }


func push_room() -> void:
	for cid in members.keys():
		server.send(cid, view_for(cid))


## 大厅列表里的一行
func summary() -> Dictionary:
	var seated := 0
	var humans := 0
	for s in seats:
		if s["kind"] != "":
			seated += 1
		if s["kind"] == "human":
			humans += 1
	return { "code": code, "players": player_count, "seated": seated, "humans": humans,
		"timer": timer_secs, "host": members.get(host, ""),
		"state": "playing" if state == State.PLAYING else "waiting" }
