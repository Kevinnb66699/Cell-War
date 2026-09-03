## cw_net_client.gd —— 联机客户端：连接、心跳、报文收发、影子对局与房间视图（无界面；界面与机器人都用它）
##
## 影子对局（shadow）：一个只读的 CWGame，每收到 state 就 restore 服务器发来的视角快照，
## 现有棋盘 / 面板 / 日志照常从它读。它没有桥、也永远不 run_game。
## 询问（ask）由使用者处理：界面把 req 交给 CWUIBridge.ask，机器人设 autoplay 用 AI 桥作答。
## 报文顺序：服务器每步之后先发演出（roll/result/notice）再发 state，界面按收到的顺序播完再换状态 ——
## 所以界面把 sequenced 置 true：对局流（STREAM_KINDS）不再即时生效，而是排进 stream，
## 由 CWMatch 逐条取走、演完一条再 apply_now 下一条；房间 / 大厅 / 错误这些照旧即时生效。
class_name CWNetClient
extends RefCounted

signal message(msg: Dictionary)
signal connected
signal disconnected(code: int, reason: String)

var ws := WebSocketPeer.new()
var url := ""
var nick := "玩家"
var hello_version := CWNet.NET_VERSION   ## 测试用：装成别的版本
var status := "closed"                   ## closed / connecting / open
var client_id := -1
var room := {}                           ## 最近一次 room 视图
var code := ""
var token := ""                          ## 坐下后服务器发的重连令牌
var my_seat := -1
var shadow: CWGame
var logs: PackedStringArray = []         ## 本局累积的对局日志（已按视角隐去他人牌名）
var last_state := {}
var last_error := {}
var game_over := {}
var inbox: Array = []                    ## 所有收到的报文（测试与机器人用；界面用 message 信号）
var autoplay: CWBridge                   ## 机器人模式：收到 ask 就用这个桥作答（桥的 game 会指向 shadow）
var pending_ask := {}                    ## 最近收到、尚未作答的询问
## 顺序播放模式（界面用）：对局流报文先进 stream，等使用者 apply_now；机器人与测试保持 false
var sequenced := false
var stream: Array = []
const STREAM_KINDS := ["state", "ask", "roll", "result", "notice", "game_over"]
const INBOX_MAX := 2000                  ## inbox 只给测试和机器人翻，界面跑一整晚也别让它无限长
## 握手超时：TCP 握手包丢了、或来源 IP 被云安全组限流时，WebSocketPeer 会无限期停在 CONNECTING、不报任何错
## （2026-09-03 线上验收两次撞到：几分钟内第 15 个短连接的握手根本没到服务器，18 秒后又一切正常）。
## 到点就当连接失败发 disconnected，界面据此报错 / 重试，别让人对着「连接中…」干等。
var connect_timeout_ms := 10000       ## 测试把它调短
var _last_ping := 0
var _connect_started := 0
var _game_no := -1


func connect_to(p_url: String, p_nick: String = "", reconnect_code: String = "", reconnect_token: String = "") -> Error:
	url = p_url
	if p_nick != "":
		nick = p_nick
	code = reconnect_code
	token = reconnect_token
	ws = WebSocketPeer.new()
	ws.inbound_buffer_size = 1 << 20
	ws.outbound_buffer_size = 1 << 20
	ws.max_queued_packets = 4096
	var err := ws.connect_to_url(url)
	status = "connecting" if err == OK else "closed"
	_connect_started = Time.get_ticks_msec()
	return err


func close() -> void:
	if status != "closed":
		ws.close()


## 每帧调。机器人模式下会在这里作答（await 只在 AI 桥真的挂起时才挂起，现有 AI 桥都不挂起）。
func poll() -> void:
	ws.poll()
	match ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if status == "connecting":
				status = "open"
				var hello := { "t": "hello", "ver": hello_version, "nick": nick }
				if token != "":
					hello["token"] = token
					hello["room"] = code
				send(hello)
				_last_ping = Time.get_ticks_msec()
				connected.emit()
			while ws.get_available_packet_count() > 0:
				var m := CWNet.decode(ws.get_packet())
				if m.is_empty():
					continue
				if sequenced and m["t"] in STREAM_KINDS:
					stream.append(m)
				else:
					_apply(m)
				inbox.append(m)
				if inbox.size() > INBOX_MAX:
					inbox.pop_front()
				message.emit(m)
			if Time.get_ticks_msec() - _last_ping > CWNet.HEARTBEAT_MS:
				_last_ping = Time.get_ticks_msec()
				send({ "t": "ping" })
			if autoplay != null and not pending_ask.is_empty():
				await _auto_answer()
		WebSocketPeer.STATE_CONNECTING:
			if Time.get_ticks_msec() - _connect_started > connect_timeout_ms:
				ws.close()
				status = "closed"
				disconnected.emit(-1, "connect timeout")
		WebSocketPeer.STATE_CLOSED:
			if status != "closed":
				status = "closed"
				disconnected.emit(ws.get_close_code(), ws.get_close_reason())


func send(msg: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.put_packet(CWNet.encode(msg))


# ---- 发给服务器的操作 ----
func list_rooms() -> void:
	send({ "t": "list_rooms" })


func create_room(players: int, timer: int, public: bool, seed_value: int = 0) -> void:
	var m := { "t": "create_room", "players": players, "timer": timer, "public": public }
	if seed_value != 0:
		m["seed"] = seed_value
	send(m)


func join(p_code: String) -> void:
	send({ "t": "join_room", "code": p_code })


func reconnect(p_code: String, p_token: String) -> void:
	send({ "t": "reconnect", "code": p_code, "token": p_token })


func leave() -> void:
	send({ "t": "leave_room" })
	_clear_room()


func sit(seat: int) -> void:
	send({ "t": "sit", "seat": seat })


func stand() -> void:
	send({ "t": "stand" })


func ready(flag: bool = true) -> void:
	send({ "t": "ready", "ready": flag })


func set_ai(seat: int, tier: String) -> void:
	send({ "t": "set_ai", "seat": seat, "tier": tier })


func kick(seat: int) -> void:
	send({ "t": "kick", "seat": seat })


func start() -> void:
	send({ "t": "start" })


func answer(ask_id: int, index: int) -> void:
	if not pending_ask.is_empty() and pending_ask["ask_id"] == ask_id:
		pending_ask = {}
	send({ "t": "answer", "ask_id": ask_id, "index": index })


# ---- 收到的报文 ----
## 顺序播放模式下由使用者在合适的时机调：让一条对局流报文真正生效
func apply_now(m: Dictionary) -> void:
	_apply(m)


func _apply(m: Dictionary) -> void:
	match m["t"]:
		"welcome":
			client_id = m.get("client_id", -1)
		"room":
			if m.get("code", "") != code:      ## 换了房间：上一局的记录作废
				_game_no = -1
				logs = []
				game_over = {}
				pending_ask = {}
			room = m
			code = m.get("code", "")
			my_seat = m.get("you_seat", -1)
			token = m.get("token", "")
		"state":
			_apply_state(m)
		"ask":
			pending_ask = m
		"game_over":
			game_over = m
			pending_ask = {}
		"left":
			_clear_room()
		"error":
			last_error = m
			if m.get("code", "") in ["room_closed", "kicked"]:
				_clear_room()


func _clear_room() -> void:
	room = {}
	code = ""
	token = ""
	my_seat = -1
	pending_ask = {}


func _apply_state(m: Dictionary) -> void:
	var view: Dictionary = m["view"]
	var n: int = view["players"].size()
	if shadow == null or shadow.players.size() != n:
		if shadow != null:
			shadow.dispose()
		shadow = CWGame.new()
		shadow.init(CWData.FACTION_ORDER[n], 0)
	if m.get("game", 0) != _game_no:      ## 新的一局：日志从头记
		_game_no = m.get("game", 0)
		logs = []
		shadow.logs = []
		game_over = {}
	shadow.restore(view)
	for line in m.get("logs", []):
		logs.append(line)
		shadow.logs.append(line)
	last_state = m
	if autoplay != null:
		autoplay.game = shadow


func _auto_answer() -> void:
	var a := pending_ask
	pending_ask = {}
	if shadow == null:
		return                      ## 还没收到状态，等下一份
	autoplay.game = shadow
	var idx: int = await autoplay.ask(a["req"])
	send({ "t": "answer", "ask_id": a["ask_id"], "index": idx })


## 用完释放：影子对局的模块互相引用，不断开会漏
func dispose() -> void:
	close()
	if shadow != null:
		shadow.dispose()
		shadow = null
	if autoplay != null:
		autoplay.game = null


## 影子对局里我的细胞（没坐下 / 还没开局返回空字典）
func my_cell() -> Dictionary:
	if shadow == null or my_seat < 0 or my_seat >= shadow.players.size():
		return {}
	return shadow.cell_of(my_seat)
