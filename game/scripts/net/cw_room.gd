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

## 一个房间最多几个观众（Kevin 2026-09-09 定「按推荐的来」）。
## **这不是产品洁癖，是服务器的账**：每步 `push_state` 要给每个成员发一份状态，
## 观众再多单线程那边每步就多做几次序列化。观战视角本身已经合并成一份（见 push_state），
## 但发送与日志游标仍是逐人的。
const MAX_WATCHERS := 8

var code := ""
var public := true
var timer_secs := 60            ## 每次决策的秒数，0 = 不限
## 世界事件开关（Kevin 2026-09-08）。房主建房时拨，整局有效。
## **只存在房间这一份**：开局时喂给 `game.tune`，之后随快照下发给客户端 ——
## 客户端的影子对局据此判断该不该等事件，不必自己收一份设置。
var world_events := true
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
var _vote := {}                 ## 正在进行的投降投票 {faction, by, agreed:{pid:true}, deadline}
var _vote_block := {}           ## 阵营 -> 冷却到第几个世界回合（含）为止不许再发起


## `left` / `off_at` 是**投降投票**要用的（2026-09-09）：
## · `left = true`  主动点了「离开房间」——人已经走了，投票不计入他
## · `left = false` 且 `online = false` 是**网络断开**，仍要计入（他可能马上回来）
## · `off_at` 掉线的时刻（ms），断满 `CWNet.DROP_TO_LEFT_MS` 由 tick() 转成 left
##
## ⚠ 这两种情况**此前是同一条路**（本文件 leave() 的原注释就写着「主动离开与掉线同路」），
## 而且掉线 20 秒后 `CWNet.DEAD_MS` 会把连接判死、照样走 leave() ——
## 不显式区分的话，20 秒之后两者的席位状态一模一样，分不出来。
static func empty_seat() -> Dictionary:
	return { "kind": "", "client": -1, "nick": "", "ready": false, "tier": "", "token": "",
		"online": false, "left": false, "off_at": 0 }


static func ai_seat(tier: String) -> Dictionary:
	var s := empty_seat()
	s["kind"] = "ai"
	s["tier"] = tier
	s["nick"] = CWNet.AI_TIERS[tier]
	return s


func configure(p_server: CWNetServer, p_code: String, players: int, timer: int,
		p_public: bool, p_world_events: bool = true) -> void:
	server = p_server
	code = p_code
	player_count = players
	timer_secs = timer
	public = p_public
	world_events = p_world_events
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


## 主动离开与掉线走同一条路，**只差 `voluntary` 这一个标记**（2026-09-09）：
## 投降投票要区分「人走了」和「网断了」—— 前者不计入、后者要计入（见 CWNet 那段注释）。
## 席位状态其余部分完全一样，所以只在这里分叉，别的地方不必知道。
func leave(cid: int, voluntary: bool = false) -> void:
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
			s["left"] = voluntary
			s["off_at"] = server.now_ms()
			_refresh_vote()   ## 少一个人要投 → 可能正好凑齐（或投票该作废了）
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


## 此刻有几个观众（在房里但没坐席位的人）
func watchers() -> int:
	var n := 0
	for cid in members.keys():
		if pid_of_client(cid) < 0:
			n += 1
	return n


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
		s["left"] = false     ## 回来了就不再是「已离开」，重新计入投票
		s["off_at"] = 0
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


## 联机局里把引擎默认的「免疫A / 癌症B」换成玩家昵称（Kevin 2026-09-07）。
##
## 改的是 `game.players[pid]["name"]`，而 players 在快照里、也进状态哈希 —— 看着危险，其实最稳：
## 客户端的影子对局是 init() 之后 **restore 服务器的视角快照**，名字随快照一起过去，
## 两边永远一致。反过来「客户端自己按 seats 改名」才会掉进哈希不一致的坑。
## 所以这件事**只能在服务器做**，而且必须在 init() 之后、任何快照推送之前。
##
## AI 席不改：它们的 nick 是档位名（「新手」「专家」），两个同档 AI 会重名，
## 反倒不如「免疫A / 免疫B」认得清。空昵称同理保留默认。
func _name_seats() -> void:
	for pid in game.order:
		if pid >= seats.size():
			continue
		var s: Dictionary = seats[pid]
		if s["kind"] != "human":
			continue
		var nick := String(s["nick"]).strip_edges()
		if nick == "":
			continue
		game.players[pid]["name"] = nick


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
	## 必须在 init 之前：开局第一步就可能撞上事件回合
	game.tune.world_events_on = world_events
	var seed_value: int = seed_override if seed_override != 0 else server.rng.randi()
	game.init(CWData.FACTION_ORDER[player_count], seed_value)
	game.record_replay = true          ## 真对局才录（MC 推演不录，见 CWGame.ask）
	_name_seats()
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
	## 回放**发给玩家**：服务器存在自己盘上没意义，要看的人在客户端那头。
	## 这是 S→C 方向的新字段，老客户端读不到、行为照旧，所以不用升 NET_VERSION。
	broadcast({ "t": "game_over", "winner": winner, "reason": game.win_reason,
		"kind": game.win_kind, "round": game.round_no, "replay": CWReplay.of(game) })
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
	_vote = {}
	_vote_block = {}   ## 冷却按世界回合算，下一局回合数从头来，留着会误伤


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


## 服务器每帧调：计时到点就代打；顺带推投降投票的两个钟。
func tick(now: int) -> void:
	if state != State.PLAYING:
		return
	## 断线够久 → 视同已离开，不再计入投票。
	## 没有这一条的话，一个再也不回来、又没点过「离开房间」的人，
	## 能把队友永远锁在这一局里（全票制下他那一票永远凑不齐）。
	var turned := false
	for s in seats:
		if s["kind"] == "human" and not s["online"] and not s["left"] \
				and s["off_at"] > 0 and now - s["off_at"] >= CWNet.DROP_TO_LEFT_MS:
			s["left"] = true
			turned = true
	if turned:
		_refresh_vote()
	if not _vote.is_empty() and now >= int(_vote["deadline"]):
		_end_vote("超时")
	if _ask.is_empty():
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


# ---- 投降投票（2026-09-09）----
## 服务器是**唯一裁判**：谁必须投、够不够票、超时与冷却全在这儿算。
## 客户端只负责「把我这一票送上来」和「把当前票况画出来」——
## 让客户端自己判会给作弊留口子（改个客户端就能替队友投同意）。
##
## 规则见 `CWNet` 那段常量的注释：AI 一律同意、主动离开不计入、网络断开要计入。


## 这一阵营此刻必须投票的席位（**在线真人**）。AI 与已离开的不在其中 = 自动同意。
func _voters(faction: int) -> Array[int]:
	var out: Array[int] = []
	for pid in seats.size():
		var s: Dictionary = seats[pid]
		if s["kind"] != "human" or s["left"]:
			continue
		if CWData.FACTION_ORDER[player_count][pid] == faction:
			out.append(pid)
	return out


## 收到一票（或发起）。`agree=false` 当场否决 —— 全票制下一个反对就没戏了，
## 拖着只是让发起人干等 30 秒。
func surrender(cid: int, agree: Variant) -> String:
	if state != State.PLAYING or game == null:
		return "not_waiting"
	var pid := pid_of_client(cid)
	if pid < 0:
		return "not_seated"
	var faction: int = CWData.FACTION_ORDER[player_count][pid]
	var yes: bool = agree if typeof(agree) == TYPE_BOOL else true
	if _vote.is_empty():
		if not yes:
			return "no_vote"          ## 没投票可反对
		## `_vote_block` 存的是「到这个世界回合就能再发起」。
		## ⚠ 这里原来写 `>= round_no`，把冷却拖成了**两个**世界回合
		## （否决那轮拦一次、下一轮又拦一次），而定的是「隔一个世界回合」。
		## 世界回合很长，两轮下来玩家的体感就是「再也发不起了」（Kevin 2026-09-09 报）。
		if game.round_no < int(_vote_block.get(faction, 0)):
			return "vote_cooldown"
		_vote = { "faction": faction, "by": pid, "agreed": { pid: true },
			"deadline": server.now_ms() + CWNet.SURRENDER_VOTE_MS }
		game.log_msg("【投降】%s 发起投降投票" % seats[pid]["nick"])
		_refresh_vote()
		return ""
	if _vote["faction"] != faction:
		return "no_vote"              ## 对方阵营的投票，与你无关
	if not yes:
		_end_vote("有人反对")
		return ""
	if _vote["agreed"].has(pid):
		return "voted"
	_vote["agreed"][pid] = true
	_refresh_vote()
	return ""


## 重算票况：够了就认输，不够就把最新进度广播出去。
## **每次席位或回合有变动都要叫一次** —— 少一个要投的人（离开 / 掉线转已离开）
## 可能正好把票凑齐，不重算的话投票会卡在那儿直到超时。
func _refresh_vote() -> void:
	if _vote.is_empty():
		return
	if state != State.PLAYING or game == null or game.is_over():
		_vote = {}
		return
	var need := _voters(_vote["faction"])
	var missing: Array[int] = []
	for pid in need:
		if not _vote["agreed"].has(pid):
			missing.append(pid)
	if missing.is_empty():
		_pass_vote()
		return
	broadcast({ "t": "surrender_vote", "faction": _vote["faction"], "by": _vote["by"],
		"need": need, "agreed": _vote["agreed"].keys(),
		"left_ms": maxi(0, int(_vote["deadline"]) - server.now_ms()) })


## 全票通过：认输。**顺序照 CWMatch.surrender_now** —— 先定结果，再唤醒卡住的询问，
## 否则 run_game 会拿着一个无意义的答案替人多走一步（`winner >= 0` 那条跳出就是为它加的）。
func _pass_vote() -> void:
	var faction: int = _vote["faction"]
	_vote = {}
	broadcast({ "t": "surrender_vote", "faction": -1 })   ## 收起票面
	game.surrender(faction)
	if not _ask.is_empty():
		var a := _ask
		_ask = {}
		a["waiter"].done.emit(0)


func _end_vote(why: String) -> void:
	if _vote.is_empty():
		return
	var faction: int = _vote["faction"]
	_vote = {}
	if game != null:
		_vote_block[faction] = game.round_no + CWNet.SURRENDER_COOLDOWN_ROUNDS
		game.log_msg("【投降】投票未通过（%s）" % why)
	broadcast({ "t": "surrender_vote", "faction": -1 })


func push_state(turn_pid: int) -> void:
	if game == null:
		return
	var h := game.state_hash()
	## **观众的视角只算一次**：他们的 pid 全是 -1，`view_for` 出来的快照逐字节相同，
	## 而那是一次全盘深拷 —— 逐人各算一遍的话，围观人数会直接变成每步的延迟。
	## 日志仍要逐人算（各人的游标不同），那个便宜得多。
	var watcher_view := {}
	for cid in members.keys():
		var pid := pid_of_client(cid)
		if pid < 0 and watcher_view.is_empty():
			watcher_view = CWNet.view_for(game, -1)
		push_state_to(cid, turn_pid, h, watcher_view if pid < 0 else {})


## `ready_view` = 已经算好的视角（`push_state` 给观众共用的那一份）；空 = 自己算
func push_state_to(cid: int, turn_pid: int, h: String = "", ready_view: Dictionary = {}) -> void:
	if game == null:
		return
	var pid := pid_of_client(cid)
	var from: int = _log_cursor.get(cid, 0)
	var lines := CWNet.logs_for(game, pid, from)
	_log_cursor[cid] = game.logs.size()
	var view: Dictionary = ready_view if not ready_view.is_empty() else CWNet.view_for(game, pid)
	server.send(cid, { "t": "state", "view": view, "logs": lines,
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
		"world_events": world_events,
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
		"timer": timer_secs, "world_events": world_events, "host": members.get(host, ""),
		"watchers": watchers(), "watch_max": MAX_WATCHERS,
		"state": "playing" if state == State.PLAYING else "waiting" }
