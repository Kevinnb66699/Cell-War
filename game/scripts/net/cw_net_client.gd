## cw_net_client.gd —— 联机客户端：连接、心跳、报文收发、影子对局与房间视图（无界面；界面与机器人都用它）
##
## 影子对局（shadow）：一个只读的 CWGame，每收到 sync 里附带的老 view 就 restore 它。它没有桥、也永远不 run_game。
## **批 1 步 8 起只剩机器人在用**：界面客户端锁到观测镜像（CWKernelRemote 持的 CWMirror），
## 服务器只给 hello 自报 bot:true 的客户端多发那份 view —— AI 桥要 game.world / actions / rng，MC 还要 fork 整局，
## 镜像一样都给不了、也不该给（批 1 规格 A-3.4）。批 2 AI 进 C# 之后这一整块删掉。
## 询问（ask）由使用者处理：界面把 req 交给 CWUIBridge.ask，机器人设 autoplay 用 AI 桥作答。
## 报文顺序：服务器一步之内先发 step_begin、再发演出（roll/result/notice…）、最后 step_end + sync，界面按收到的顺序播完再落地状态 ——
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
## 正在进行的投降投票（服务器裁决，客户端只画）。空 = 没有。
## 字段见 CWRoom._refresh_vote：{faction, by, need, agreed, left_ms}
var surrender_vote := {}
## 收到的聊天，**新的在后**（界面从尾巴往回读最近几条）。{nick, seat, faction, text}
var chat_log: Array = []
var replay_list: Array = []      ## 服务器回放目录（只有摘要）
var replay_data := {}            ## 最近一次 get_replay 取回来的正文
var error_seq := 0            ## 收到第几条 error 报文（对局界面靠它认出新错误）
var inbox: Array = []                    ## 所有收到的报文（测试与机器人用；界面用 message 信号）
var autoplay: CWBridge                   ## 机器人模式：收到 ask 就用这个桥作答（桥的 game 会指向 shadow）
var bot := false                         ## hello 自报机器人（A-3.4）：服务器只给机器人在 sync 里带 view；后半段才装 autoplay 的客户端要先把它设 true
var pending_ask := {}                    ## 最近收到、尚未作答的询问
## 顺序播放模式（界面用）：对局流报文先进 stream，等使用者 apply_now；机器人与测试保持 false
var sequenced := false
var stream: Array = []
const STREAM_KINDS := ["state", "sync", "ask", "roll", "result", "notice", "erosion", "beam", "fx", "card_played", "event_drawn", "card_drawn", "game_over", "step_begin", "step_end"]   ## sync / step_* 是批 1 步 8 服务器升 v30 后发的
var query_results: Array = []            ## S→C query_result（批 1 E-1 (a) 的 RPC 应答）：不进 stream（不是演出），CWKernelRemote.drain 来取
const INBOX_MAX := 2000                  ## inbox 只给测试和机器人翻，界面跑一整晚也别让它无限长
## 握手超时：TCP 握手包丢了、或来源 IP 被云安全组限流时，WebSocketPeer 会无限期停在 CONNECTING、不报任何错
## （2026-09-03 线上验收两次撞到：几分钟内第 15 个短连接的握手根本没到服务器，18 秒后又一切正常）。
## 到点就当连接失败发 disconnected，界面据此报错 / 重试，别让人对着「连接中…」干等。
var connect_timeout_ms := 10000       ## 测试把它调短
## 当前往返时延（毫秒），-1 = 还没量到。**复用已有的心跳**：ping 发出时记时刻，pong 回来就是一个往返，
## 所以刷新周期 = CWNet.HEARTBEAT_MS（5 秒）。要更勤只能加密心跳，那是协议节奏，不为一个读数改（Kevin 2026-09-07）。
var ping_ms := -1
var _ping_sent := 0
var _last_ping := 0
var _connect_started := 0
## 报文外壳上的 games_played：换局边界。envelope 里**没有等价物**（rev 是生产者内部号、跨局连续），
## 这是房间的产品逻辑、不该进协议。提成公开字段供 CWKernelRemote / CWMatch 判「新的一局 ⇒ 清日志缓冲」
var game_no := -1


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
				## bot = 机器人客户端（autoplay 作答）：服务器据此在 sync 里额外带一份老 view / turn / logs（A-3.4）。
				## 界面客户端不带这个标记 ⇒ 每步只收 envelope，省掉一次全盘深拷
				var hello := { "t": "hello", "ver": hello_version, "nick": nick, "bot": bot or autoplay != null }
				if token != "":
					hello["token"] = token
					hello["room"] = code
				send(hello)
				_last_ping = Time.get_ticks_msec()
				## 握手之后先补一发：不然要等满一个心跳周期才有第一个读数
				_ping_sent = _last_ping
				send({ "t": "ping" })
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
				_ping_sent = _last_ping
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
				forget_ping()
				disconnected.emit(ws.get_close_code(), ws.get_close_reason())


func send(msg: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.put_packet(CWNet.encode(msg))


# ---- 发给服务器的操作 ----
## 说一句话。空话不发 —— 服务器那头也会拒，但没必要为一个空串跑一趟。
## team = 只发给同一档的人（坐着的按阵营，观众自成一档）
func say(text: String, team: bool = false) -> void:
	var msg := text.strip_edges()
	if msg.is_empty():
		return
	send({ "t": "chat", "text": msg.substr(0, CWNet.CHAT_MAX),
		"scope": "team" if team else "all" })


func fetch_replays() -> void:
	send({ "t": "list_replays" })


func fetch_replay(id: int) -> void:
	send({ "t": "get_replay", "id": id })


func list_rooms() -> void:
	send({ "t": "list_rooms" })


func create_room(players: int, timer: int, public: bool, seed_value: int = 0,
		watch_hands: bool = false) -> void:
	var m := { "t": "create_room", "players": players, "timer": timer, "public": public,
		"watch_hands": watch_hands }
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


## key = 语义键（批 1 A-9：服务器按 key 现算反查、下标兜底；v29 服务器只读 index，多一个字段无害）
func answer(ask_id: int, index: int, key := "") -> void:
	if not pending_ask.is_empty() and pending_ask["ask_id"] == ask_id:
		pending_ask = {}
	send({ "t": "answer", "ask_id": ask_id, "index": index, "key": key })


## 投降：没有正在进行的投票就是**发起**，有就是**投票**。
## 够不够票、超时、冷却全由服务器算 —— 客户端自己判会给作弊留口子。
func surrender(agree: bool = true) -> void:
	send({ "t": "surrender", "agree": agree })


# ---- 收到的报文 ----
## 顺序播放模式下由使用者在合适的时机调：让一条对局流报文真正生效
func apply_now(m: Dictionary) -> void:
	_apply(m)


func _apply(m: Dictionary) -> void:
	match m["t"]:
		"welcome":
			client_id = m.get("client_id", -1)
		"pong":
			## 一来一回就是一个往返。服务器的 pong 是收到即回，排队开销算在延时里 —— 这正是玩家感觉到的那个延时
			if _ping_sent > 0:
				ping_ms = Time.get_ticks_msec() - _ping_sent
		"room":
			if m.get("code", "") != code:      ## 换了房间：上一局的记录作废
				game_no = -1
				logs = []
				game_over = {}
				pending_ask = {}
			room = m
			code = m.get("code", "")
			my_seat = m.get("you_seat", -1)
			token = m.get("token", "")
		"chat":
			## **不进对局流**：聊天是「此刻」的事，跟着演出排队的话，
			## 一句「等一下别打」会在演完两个动画之后才出现，那就没意义了
			## （同 surrender_vote 的理由）
			chat_log.append(m)
			if chat_log.size() > 200:
				chat_log.pop_front()
		"replays":
			replay_list = m.get("list", [])
		"replay":
			var d: Variant = m.get("data")
			if typeof(d) == TYPE_DICTIONARY and CWReplay.valid(d):
				replay_data = d
				CWReplay.write(d)      ## 下下来就落到本地，之后不用再联网也能看
		"sync":
			_apply_sync(m)
		"ask":
			pending_ask = m
		"game_over":
			game_over = m
			pending_ask = {}
			surrender_vote = {}
			## 联机局的回放由服务器随终局发下来（本地局是 CWMain 自己存）。
			## 存不下就算了 —— 一局回放丢了不该影响任何别的事
			var rep: Variant = m.get("replay")
			if typeof(rep) == TYPE_DICTIONARY and CWReplay.valid(rep):
				CWReplay.write(rep)
		"surrender_vote":
			## **不进 stream**：票面是「此刻」的状态，跟着对局流排队播的话，
			## 倒计时会连着演出一起延后，30 秒的窗口就对不上了
			surrender_vote = {} if int(m.get("faction", -1)) < 0 else m
			## 盖一个收到时刻。服务器**只在票况变化时**广播，`left_ms` 是那一刻的快照，
			## 界面照着它画就永远停在 30 秒 —— 倒数得由客户端自己走表，
			## 从这个时刻起算（见 CWSurrenderVote.deadline_of）。
			if not surrender_vote.is_empty():
				surrender_vote["at_ms"] = Time.get_ticks_msec()
		"query_result":
			query_results.append(m)
		"left":
			_clear_room()
		"error":
			last_error = m
			## 序号让对局界面认得出「又来了一条」——**对局中联机面板是隐藏的**，
			## 它那句 `_set_status()` 写进的是看不见的标签。2026-09-09 Kevin 报
			## 「投降只能发起一次」，真相就是冷却被拒之后**零反馈**，看着像坏了。
			error_seq += 1
			if m.get("code", "") in ["room_closed", "kicked"]:
				_clear_room()


## 断线时读数作废：重连前那个数字已经没有意义了
func forget_ping() -> void:
	ping_ms = -1
	_ping_sent = 0


func _clear_room() -> void:
	room = {}
	code = ""
	token = ""
	my_seat = -1
	pending_ask = {}
	surrender_vote = {}


## 机器人客户端的那半：服务器只给 hello 自报 bot 的客户端在 sync 里带 `view` / `turn` / `logs`（A-3.4）。
## 界面客户端 sequenced=true，sync 进 stream、由 CWKernelRemote 翻成条目装进 CWMirror，**走不到这里**。
func _apply_sync(m: Dictionary) -> void:
	if not m.has("view"):
		return
	var view: Dictionary = m["view"]
	var n: int = view["players"].size()
	if shadow == null or shadow.players.size() != n:
		if shadow != null:
			shadow.dispose()
		shadow = CWGame.new()
		shadow.init(CWData.FACTION_ORDER[n], 0)
	if m.get("game", 0) != game_no:      ## 新的一局：日志从头记
		game_no = m.get("game", 0)
		logs = []
		shadow.logs = []
		game_over = {}
	shadow.restore(view)
	## 服务器每次问人之前推一份状态，turn 就是被问的那一席（CWNetBridge.ask）；
	## 快照里没有这个字段（瞬态），补上，右栏才知道落子 / 复活阶段轮到谁
	shadow.asking_pid = int(m.get("turn", -1))
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
