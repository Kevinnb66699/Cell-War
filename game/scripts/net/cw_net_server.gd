## cw_net_server.gd —— 联机服务器：连接、握手、大厅、房间路由、心跳与排空
##
## 纯 RefCounted，不进场景树：宿主（server/server_main.gd 或测试）每帧调 poll()。
## 传输是 WebSocket（TCP）：云安全组只放了 TCP 8611，ENet（UDP）实测不通（2026-09-02）。
## 所有房间跑在同一个进程里：一局状态不到 1 MB，而一个无头 Godot 进程要 123 MB（实测）。
##
## 排空（drain）：置 true 后拒绝建房与开局，等最后一局打完发 drained 信号，宿主退出、systemd 拉起新版。
##
## 单线程的代价：AI 席决策期间本进程不轮询网络。两条对策（2026-09-02 回归里 4 人房打不完整局查出来的）：
## ① CWNetBridge 让 AI 席每次决策前先让出一帧（next_frame），一整个 AI 回合不再一口气堵死；
## ② poll() 发现自己上一次被堵了超过 STALL_FORGIVE_MS，就把这段时间从所有客户端的「最后一次来信」
##    和悬着的计时期限里免掉 —— 被堵住的是服务器，不能算玩家掉线或超时。
class_name CWNetServer
extends RefCounted

signal drained

var peer := WebSocketMultiplayerPeer.new()
var port := 0
var rng := RandomNumberGenerator.new()
var clients := {}      ## client id -> {nick, room, hello, last_seen, ip, sec, count, kick_at}
var rooms := {}        ## 房间码 -> CWRoom
## 最近打完的几局回放，**落盘**（Kevin 2026-09-09 定；我原本提的是只放内存）。
##
## **这是服务器第一次往盘上写东西** —— 设计 §九 原本写着「只存内存状态、不落盘」，
## 已随本次改动一并改掉。存的是棋盘决策 + 昵称，没有凭据也没有 IP。
## 换来的是：服务器重启（非排空）之后回放还在，而那台机器 `Restart=always`，
## 只放内存的话「补看上一局」这件事在崩一次之后就没了。
##
## 目录与客户端那份**分开**（`CWReplay.DIR` 是客户端的）：同一进程里起服务器 + 客户端
## 是测试的常态，共用一个目录会互相看见对方的文件。
var replays: Array = []
const REPLAY_DIR := "user://server_replays"
const REPLAY_KEEP := 50     ## 全服留最近几局（Kevin 2026-09-09 定）
var _replay_seq := 0
var drain := false
var quiet := false     ## 测试时不打印
var idle_ms := CWNet.ROOM_IDLE_MS   ## 空房多久自动关（测试调短）
var _started := false
var _drained := false
var _last_poll := 0
const STALL_FORGIVE_MS := 1000


func start(p_port: int, bind_address: String = "*") -> Error:
	peer.inbound_buffer_size = 1 << 20
	peer.outbound_buffer_size = 1 << 20
	peer.max_queued_packets = 4096
	var err := peer.create_server(p_port, bind_address)
	if err != OK:
		return err
	port = p_port
	rng.randomize()
	peer.peer_connected.connect(_on_connected)
	peer.peer_disconnected.connect(_on_disconnected)
	_load_replays()
	_started = true
	return OK


func stop() -> void:
	for cid in clients.keys():
		_drop(cid)
	for r in rooms.values():
		close_room(r)
	peer.close()
	_started = false


func now_ms() -> int:
	return Time.get_ticks_msec()


## 让出一帧：AI 席决策之间调，好让本进程去收发一次网络（宿主是 SceneTree 时才有帧可让）
func next_frame() -> void:
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		await (ml as SceneTree).process_frame


func say(s: String) -> void:
	if not quiet:
		print("%s %s" % [Time.get_time_string_from_system(), s])


func poll() -> void:
	if not _started:
		return
	var t := now_ms()
	if _last_poll > 0 and t - _last_poll > STALL_FORGIVE_MS:
		var gap := t - _last_poll
		for c in clients.values():
			c["last_seen"] += gap
		for r in rooms.values():
			r.forgive_stall(gap)
	_last_poll = t
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var cid := peer.get_packet_peer()
		var bytes := peer.get_packet()
		_handle(cid, bytes)
	var now := now_ms()
	for cid in clients.keys():
		var c: Dictionary = clients[cid]
		if c["kick_at"] > 0 and now >= c["kick_at"]:
			_kick(cid, "")
		elif now - c["last_seen"] > CWNet.DEAD_MS:
			_kick(cid, "")
	for r in rooms.values():
		r.tick(now)
		if r.state == CWRoom.State.CLOSED or (r.members.is_empty() and r.empty_since > 0
				and now - r.empty_since > idle_ms):
			close_room(r)
	if not drain:
		_drained = false
	elif not _drained:
		var busy := false
		for r in rooms.values():
			if r.state == CWRoom.State.PLAYING:
				busy = true
		if not busy:
			_drained = true
			drained.emit()


func send(cid: int, msg: Dictionary) -> void:
	if not clients.has(cid):
		return
	peer.set_target_peer(cid)
	var err := peer.put_packet(CWNet.encode(msg))
	if err != OK:
		say("发送失败 #%d：%d" % [cid, err])


# ---- 连接 ----
func _on_connected(cid: int) -> void:
	var ip := ""
	var wsp := peer.get_peer(cid)
	if wsp != null:
		ip = wsp.get_connected_host()
	var same := 0
	for c in clients.values():
		if ip != "" and c["ip"] == ip:
			same += 1
	if same >= CWNet.MAX_PER_IP:
		peer.disconnect_peer(cid)
		return
	clients[cid] = { "nick": "", "room": "", "hello": false, "last_seen": now_ms(), "ip": ip,
		"sec": 0, "count": 0, "kick_at": 0 }


func _on_disconnected(cid: int) -> void:
	_drop(cid)


func _drop(cid: int) -> void:
	if not clients.has(cid):
		return
	var c: Dictionary = clients[cid]
	clients.erase(cid)
	## 这条路是**掉线**（socket 断了、DEAD_MS 判死、被踢），不传 voluntary ——
	## 这些人没有表示要走，投降投票仍然要等他们那一票（断满 DROP_TO_LEFT_MS 才自动转「已离开」）
	if c["room"] != "" and rooms.has(c["room"]):
		rooms[c["room"]].leave(cid)
	if c["hello"]:
		say("断开 #%d %s" % [cid, c["nick"]])


## 发完错误再断（错误码空 = 直接断）
func _kick(cid: int, code: String) -> void:
	if not clients.has(cid):
		return
	if code != "":
		_error(cid, code)
	peer.disconnect_peer(cid)
	_drop(cid)


## 把客户端从它的房间里解绑（房间那边已经/将要把它从成员表移除）。
##
## `voluntary` 只有一处传 true：玩家自己点了「离开房间」。掉线、被踢、
## 以及重连时旧连接让位都不算 —— 那些人没有表示要走。
## 投降投票据此区分「人走了」和「网断了」，见 CWRoom.leave。
func unbind(cid: int, voluntary: bool = false) -> void:
	if not clients.has(cid):
		return
	var code: String = clients[cid]["room"]
	clients[cid]["room"] = ""
	if code != "" and rooms.has(code):
		rooms[code].leave(cid, voluntary)


func close_room(r: CWRoom) -> void:
	if not rooms.has(r.code):
		return
	rooms.erase(r.code)
	if r.state == CWRoom.State.PLAYING:
		r._abort_game()
	r.state = CWRoom.State.CLOSED
	for cid in r.members.keys():
		if clients.has(cid):
			clients[cid]["room"] = ""
			_error(cid, "room_closed")
	r.members.clear()
	say("关房 %s" % r.code)


func _error(cid: int, code: String) -> void:
	send(cid, { "t": "error", "code": code, "msg": CWNet.error_text(code) })


func _room_of(cid: int) -> CWRoom:
	var code: String = clients[cid]["room"]
	return rooms.get(code) if code != "" else null


# ---- 报文 ----
func _handle(cid: int, bytes: PackedByteArray) -> void:
	if not clients.has(cid):
		return
	var c: Dictionary = clients[cid]
	c["last_seen"] = now_ms()
	if bytes.size() > CWNet.MAX_PACKET:
		_kick(cid, "bad_message")
		return
	var msg := CWNet.decode(bytes)
	if msg.is_empty():
		_kick(cid, "bad_message")
		return
	var t: String = msg["t"]
	if not c["hello"]:
		if t != "hello" or msg.get("ver", -1) != CWNet.NET_VERSION:
			send(cid, { "t": "error", "code": "version", "msg": CWNet.error_text("version"),
				"server_ver": CWNet.NET_VERSION })
			c["kick_at"] = now_ms() + 500     ## 让错误先送到
			return
		c["hello"] = true
		c["nick"] = CWNet.clean_nick(msg.get("nick", ""))
		send(cid, { "t": "welcome", "client_id": cid, "ver": CWNet.NET_VERSION, "maintenance": drain })
		say("连接 #%d %s（%s）" % [cid, c["nick"], c["ip"]])
		var token: Variant = msg.get("token", "")
		if token is String and token != "":
			_reconnect(cid, str(msg.get("room", "")), token)
		return
	if t != "answer" and t != "ping":
		var sec := now_ms() / 1000
		if c["sec"] != sec:
			c["sec"] = sec
			c["count"] = 0
		c["count"] += 1
		if c["count"] > CWNet.RATE_PER_SEC:
			_kick(cid, "rate")
			return
	match t:
		"ping":
			send(cid, { "t": "pong" })
		"list_rooms":
			send(cid, lobby_view())
		"list_replays":
			send(cid, replay_list())
		"get_replay":
			var rep := replay_of(int(msg.get("id", 0)))
			if rep.is_empty():
				_error(cid, "no_replay")
			else:
				send(cid, { "t": "replay", "id": rep["id"], "data": rep })
		"create_room":
			_create_room(cid, msg)
		"join_room":
			_join_room(cid, str(msg.get("code", "")))
		"reconnect":
			_reconnect(cid, str(msg.get("code", "")), str(msg.get("token", "")))
		"leave_room":
			unbind(cid, true)   ## true = **主动**离开（投降投票不再计入他，见 CWRoom.leave）
			send(cid, { "t": "left" })     ## 回一声，客户端据此清掉本地的房间状态（比本地先清更稳：房间视图可能还在路上）
		_:
			var r := _room_of(cid)
			if r == null:
				_error(cid, "not_in_room")
				return
			var e := ""
			match t:
				"sit": e = r.sit(cid, msg.get("seat"))
				"stand": e = r.stand(cid)
				"ready": e = r.set_ready(cid, msg.get("ready", true))
				"set_ai": e = r.set_ai(cid, msg.get("seat"), msg.get("tier", ""))
				"kick": e = r.kick(cid, msg.get("seat"))
				"start": e = r.start(cid)
				"answer": e = r.answer(cid, msg.get("ask_id"), msg.get("index"))
				"surrender": e = r.surrender(cid, msg.get("agree", true))
				"chat": e = r.chat(cid, str(msg.get("text", "")))
				_: e = "bad_message"
			if e != "":
				_error(cid, e)


func _create_room(cid: int, msg: Dictionary) -> void:
	if drain:
		_error(cid, "maintenance")
		return
	var n: Variant = msg.get("players", 4)
	var timer: Variant = msg.get("timer", 60)
	var pub: Variant = msg.get("public", true)
	## 老客户端不带这个字段 → 默认开（与改动之前的行为一致）
	var wev: Variant = msg.get("world_events", true)
	if not (n in CWNet.PLAYER_CHOICES) or typeof(timer) != TYPE_INT or timer < 0 \
			or timer > CWNet.TIMER_MAX or typeof(pub) != TYPE_BOOL \
			or typeof(wev) != TYPE_BOOL:
		_error(cid, "bad_param")
		return
	unbind(cid)
	var code := CWNet.make_code(rng)
	while rooms.has(code):
		code = CWNet.make_code(rng)
	var r := CWRoom.new()
	r.configure(self, code, n, timer, pub, wev)
	var sd: Variant = msg.get("seed", 0)
	if sd is int:
		r.seed_override = sd
	rooms[code] = r
	clients[cid]["room"] = code
	r.join(cid, clients[cid]["nick"])
	say("建房 %s：%d 人，计时 %d s，%s%s，房主 %s" % [code, n, timer,
		"公开" if pub else "私密", "" if wev else "，无世界事件", clients[cid]["nick"]])


func _join_room(cid: int, code: String) -> void:
	code = code.strip_edges().to_upper()
	if not rooms.has(code):
		_error(cid, "no_room")
		return
	var r: CWRoom = rooms[code]
	## 对局中也能进 —— 进去就是**观众**（不占席位、看得到盘面、看不到任何人的手牌）。
	## 房间层其实一直支持：`CWRoom.join` 见到 PLAYING 就给新成员推一份状态、
	## 日志游标归零；挡着的只有这里从前那句 `_error(cid, "playing")`（2026-09-09 放开）。
	## 私密房同样能观战，凭房间码 —— 码给了谁谁就能看（Kevin 2026-09-09 定）。
	if r.state == CWRoom.State.PLAYING and r.watchers() >= CWRoom.MAX_WATCHERS:
		_error(cid, "watch_full")
		return
	unbind(cid)
	clients[cid]["room"] = code
	r.join(cid, clients[cid]["nick"])


func _reconnect(cid: int, code: String, token: String) -> void:
	code = code.strip_edges().to_upper()
	if not rooms.has(code):
		_error(cid, "no_room")
		return
	unbind(cid)
	var e: String = rooms[code].reconnect(cid, clients[cid]["nick"], token)
	if e != "":
		_error(cid, e)
		return
	clients[cid]["room"] = code


## 大厅分两栏：`rooms` 是能坐进去的，`live` 是**正在打、可以观战**的。
## 分栏而不是混在一起 —— 玩家点进来多半是想「找一局打」，
## 把打不了的房混在同一列里会让人一个个点过去才发现坐不下（Kevin 2026-09-09 定）。
##
## 新加的 `live` 字段旧客户端读不到，它只认 `rooms` —— 行为和从前一模一样，
## 所以这一条**不用升 NET_VERSION**（同 `beam`：服务器→客户端方向，认不出就落空）。
## 开机时把盘上的回放读回来。**读不出的一律跳过** ——
## 回放柜坏一个文件不该让服务器起不来。
func _load_replays() -> void:
	replays = []
	_replay_seq = 0
	if not DirAccess.dir_exists_absolute(REPLAY_DIR):
		return
	var names := DirAccess.get_files_at(REPLAY_DIR)
	names.sort()
	for n in names:
		if not n.ends_with(CWReplay.EXT):
			continue
		var rep := CWReplay.read("%s/%s" % [REPLAY_DIR, n])
		if rep.is_empty():
			continue
		replays.push_front(rep)          ## 文件名按 id 排过，倒着推 = 新的在前
		_replay_seq = maxi(_replay_seq, int(rep.get("id", 0)))
	while replays.size() > REPLAY_KEEP:
		replays.pop_back()


## 房间打完一局就把回放交过来。给它一个自增 id —— 客户端按 id 取正文。
## id 开机时从盘上已有的最大值接着往下走，所以重启之后不会跟旧回放撞号。
func keep_replay(rep: Dictionary) -> void:
	_replay_seq += 1
	rep["id"] = _replay_seq
	replays.push_front(rep)
	DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
	var f := FileAccess.open("%s/%08d%s" % [REPLAY_DIR, _replay_seq, CWReplay.EXT],
		FileAccess.WRITE)
	if f != null:
		f.store_string(var_to_str(rep))
		f.close()
	while replays.size() > REPLAY_KEEP:
		var old: Dictionary = replays.pop_back()
		DirAccess.remove_absolute("%s/%08d%s"
			% [REPLAY_DIR, int(old.get("id", 0)), CWReplay.EXT])


## 回放目录：**只有摘要没有正文**。正文一局几 KB，一次把二十局全推下去
## 等于每次开列表都发几百 KB，而多数时候玩家只想看其中一局。
func replay_list() -> Dictionary:
	var out: Array = []
	for r: Dictionary in replays:
		out.append({ "id": r.get("id", 0), "code": r.get("code", ""),
			"players": r.get("players", 0), "round": r.get("round", 0),
			"winner": r.get("winner", -1), "at": r.get("at", "") })
	return { "t": "replays", "list": out }


func replay_of(id: int) -> Dictionary:
	for r: Dictionary in replays:
		if int(r.get("id", 0)) == id:
			return r
	return {}


func lobby_view() -> Dictionary:
	var list: Array = []
	var live: Array = []
	for r in rooms.values():
		if not r.public:
			continue                          ## 私密房两栏都不进：它只凭房间码，观战也一样
		if r.state == CWRoom.State.WAITING:
			list.append(r.summary())
		elif r.state == CWRoom.State.PLAYING:
			live.append(r.summary())
	return { "t": "lobby", "rooms": list, "live": live, "maintenance": drain }
