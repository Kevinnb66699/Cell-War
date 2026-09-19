## cw_kernel_inproc.gd —— 本地 GDScript 内核的句柄实现（口径二 · 批 0 步 9，规格 A-3.5）
##
## CWGame 一行不改：只往 bridges 里塞一个 CWKernelBridge，它把引擎的桥回调翻译成有序条目入队；
## ask 转交 cfg 里的 decider（无头测试 / AI / 回放的作答者）或入队等 answer()；roll 有消费者时 await barrier。
## 批 0 只在无头测试里跑（不接线，规格 §0.1）；批 1 接线时 CWUIBridge 从 bridges 里退出来、变成 decider，
## 它的 show_* 改由播放队列（CWPlayQueue）调用。
##
## 观测：observe(viewer) 现编一份 envelope（CWObsCodec）装进 CWMirror；中途询问期间用正在等的那一问（_open_ask）当 ask。
## 批 1 步 3（规格 B-2 ①～⑩）：adopt / rules / autorun+run() / step_once / set_decider+entry_seq+discard_* / observe_viewer 的 sync 节拍 /
## query 四条 / decider 路也写 _open_ask 且 abort 能唤醒 decider / open_hands 公开可写 + observe_envelope / barrier_on + barrier_hits。
class_name CWKernelInProc
extends CWKernel

const BARRIER_TIMEOUT_MS := 5000   ## 消费者循环没在跑（_fading / teardown / 教程跨章）时的兜底：超时放行并报错，死锁跑不掉测试

var game: CWGame
var bridge: CWKernelBridge
var deciders := {}                  ## pid → CWBridge：ask 转交它（无头测试 / AI / 回放）；没有就入队等 answer()
var has_consumer := false           ## 有消费者才 barrier（无头测试、AI 互搏都不等）
var barrier_on := true              ## ⑩ 跟 CWSettings.dice_anim：关着时 roll 不等 ack（省掉那一帧）
var barrier_hits := 0               ## ⑩ 真正等过 ack 的 roll 计数（t_barrier_release 的断言）
var barrier_timeouts := 0           ## 超时强制放行的次数：护栏④「abort 永远排在 stop 之前」的测试直接断言它为 0
var open_hands := false             ## ⑨ 房主开的「观众全见」（cw_room.gd watch_hands）—— 中途能改，所以公开可写
var observe_viewer: Variant = null  ## ⑥ 观测节拍开关：设了就在每次问人之前、终局之前各推一条 sync（A-1.5）；独立于 has_consumer
var adopted := false                ## ① 收养模式：game 不归句柄所有（close() 不 dispose）
var _step_open := true              ## 拍板 2 的行动边界：开局那段（落子 / 开局演出）也算一步，第一问之前先 step_end 收掉
var barrier_timeout_ms := BARRIER_TIMEOUT_MS
var winner := -1

var _entries: Array = []            ## 条目队列。批 0 保留整局（单局条目量小）；丢弃水位线随 C# 侧 PresentationDroppedBefore 的口径以后再定
var _next_seq := 1
var _ask_serial := 0
var _open_ask := {}                 ## 正在等 answer() 的那一问：{ask_id, req, index}
var _barrier_seq := 0               ## > 0 = 有一条 roll 在等 ack
var _step_drive := false
var _autorun := true
var _obs_rev := 0                 ## 每次 observe +1，只用于排序与去重
var _running := false

signal _answered(ask_id: int)


func open(cfg: Dictionary) -> bool:
	if _state != State.IDLE:
		return false
	_set_state(State.STARTING)
	has_consumer = bool(cfg.get("consumer", false))
	_step_drive = bool(cfg.get("step_drive", false))
	open_hands = bool(cfg.get("open_hands", false))
	observe_viewer = cfg.get("observe_viewer", null)
	_autorun = bool(cfg.get("autorun", true))
	adopted = cfg.has("adopt") and cfg["adopt"] != null
	if adopted:
		## ① 收养：教程（assemble 设的 win_checks=false 不在快照里）与服务器（cw_room.gd:start 那十行不动）共用
		game = cfg["adopt"]
		if cfg.has("record_replay"):
			game.record_replay = bool(cfg["record_replay"])
	else:
		game = CWGame.new()
		## ⚠ tune.cancer_types / world_events_on 必须在 init 之前（match.gd:459-460、cw_room.gd:366-370 同）。
		## world_events_on 是世界事件删除（2026-09-19）后留下的冻结旋钮，拨了也没有事件。
		if cfg.has("cancer_types"):
			game.tune.cancer_types = cfg["cancer_types"]
		if cfg.has("world_events_on"):
			game.tune.world_events_on = bool(cfg["world_events_on"])
		game.init(cfg["factions"], int(cfg.get("seed", 0)))
		if cfg.has("rules"):
			game.tune.restore_rules_state(cfg["rules"])   ## ② 自定义规则的回放：排在 init 之后、world_state 之前
		game.record_replay = bool(cfg.get("record_replay", false))
	deciders = {}
	if cfg.has("decider") and cfg["decider"] != null:
		for pid in game.order:
			deciders[pid] = cfg["decider"]
	if cfg.has("deciders"):
		deciders.merge(cfg["deciders"], true)
	for d in deciders.values():
		_attach_engine(d, game)
	## ① 收养且没有消费者（服务器 adopt 模式）：不装 CWKernelBridge、不连 log_line —— 演出仍由原桥（CWNetBridge）同步广播，
	## 句柄只管 observe / query / save。收养且有消费者（教程）照常装桥：询问与演出都要经队列
	if not adopted or has_consumer:
		bridge = CWKernelBridge.new()
		bridge.kernel = self
		bridge.game = game
		for pid in game.order:
			game.bridges[pid] = bridge   ## 只注册**一个**桥对象（对象去重）
		game.log_line.connect(_on_log_line)
	if not adopted and cfg.has("world_state"):
		game.restore(cfg["world_state"])
	_set_state(State.READY)
	if not _step_drive and _autorun:
		_run()   ## fire-and-forget 协程：跑到终局
	return true


## ③ autorun=false 的局从这里起跑（cw_room.gd：建局 → _name_seats() → _run() 的次序一行不动）
func run() -> void:
	if game == null or _running or _step_drive or _state != State.READY:
		return
	_run()


func close() -> void:
	if game == null:
		return
	if not adopted:
		abort()   ## 收养的对局不归句柄：close() 不给它置 aborted（要中止得显式调 abort()，A-1.6 的次序本来就是 abort → stop → close）
	if adopted:
		## ① 收养的对局不归句柄：不 dispose、不清 deciders 的 game，只把自己的钩子摘掉
		if game.log_line.is_connected(_on_log_line):
			game.log_line.disconnect(_on_log_line)
	else:
		for d in deciders.values():
			_attach_engine(d, null)
		game.dispose()
	game = null
	bridge = null


func abort() -> void:
	if game == null or game.aborted:
		return
	game.aborted = true
	_barrier_seq = 0
	abort_ask()


func version() -> Dictionary:
	return { "host_abi": 1, "rules_build": "gd-inproc", "ruleset_digest": "" }


func caps() -> Dictionary:
	return { "stream_sync": false, "step_drive": _step_drive, "rollout": false, "save": true, "authority": true, "query_sync": true }


# ---- 观测 ----
## 按席位裁剪过的镜像（规格 A-3.3）。ask 取正在等 answer() 的那一问；没有就是顶层 pending（decider 驱动时中途询问不经这里）。
## 用 game._pending 而不是 game.pending()：后者会推进流程。
func observe(viewer: int, logs_from := 0) -> RefCounted:
	if game == null:
		return null
	_obs_rev += 1
	var m := CWMirror.new()
	var err := m.sync_from(game, _obs_ctx(viewer, logs_from))
	if err != "":
		push_error("observe：%s" % err)
		return null
	return m


## ⑨ 原始 envelope：服务器逐 viewer 各编一份时省掉「编码 → 校验 → 解码」的往返
func observe_envelope(viewer: int, logs_from := 0) -> Dictionary:
	if game == null:
		return {}
	_obs_rev += 1
	return CWObsCodec.encode(game, _obs_ctx(viewer, logs_from))


## ask 取正在等的那一问（answer() 路与 decider 路都写 _open_ask，⑧）；没有就是顶层 pending
func _obs_ctx(viewer: int, logs_from: int) -> Dictionary:
	var req: Dictionary = _open_ask["req"] if not _open_ask.is_empty() else game._pending
	return { "viewer": viewer, "open_hands": open_hands, "logs_from": logs_from, "ask": req,
		"ask_id": int(_open_ask.get("ask_id", 0)), "rev": _obs_rev, "obs_seq": _next_seq - 1 }


## ⑥ + 拍板 2：一步收尾 —— step_end{rev} 之后紧跟 sync（observe_viewer 设了才有 sync），都在问人 / 终局之前（A-1.5 的节拍）。
## 顺序播的客户端走到 step_end 时这一步的演出已播完，紧接着的 sync 落地 = 「演出播完盘面才变」
func _close_step() -> void:
	if not _step_open or game == null:
		return
	_step_open = false
	if observe_viewer == null:
		_push("step_end", { "rev": _obs_rev })
		return
	_obs_rev += 1
	var env: Dictionary = CWObsCodec.encode(game, _obs_ctx(int(observe_viewer), 0))
	_push("step_end", { "rev": _obs_rev })
	_push("sync", { "envelope": env })


## 一问答下即开步：这一步的演出都排在它之后
func _open_step(ask_id: int, seat: int) -> void:
	if game == null or game.aborted:
		return
	_push("step_begin", { "ask_id": ask_id, "seat": seat })
	_step_open = true


func logs_for(viewer: int, from: int) -> PackedStringArray:
	var out := PackedStringArray()
	if game == null:
		return out
	for i in range(maxi(from, 0), game.logs.size()):
		out.append(_log_text_for(viewer, i))
	return out


func pull(viewer: int, since_seq: int, limit := 64) -> Array:
	var out: Array = []
	for e: Dictionary in _entries:
		if int(e["seq"]) <= since_seq:
			continue
		out.append(_crop(viewer, e))
		if out.size() >= limit:
			break
	return out


func ack(seq: int) -> void:
	if _barrier_seq == seq:
		_barrier_seq = 0


func entry_seq() -> int:
	return _next_seq - 1


## ⑤ 回放快退后重推：丢掉 seq > 给定值的条目；_next_seq 不回拨（seq 永不重编号）
func discard_after(seq: int) -> void:
	var n := _entries.size()
	while n > 0 and int(_entries[n - 1]["seq"]) > seq:
		n -= 1
	_entries.resize(n)
	if _barrier_seq > seq:
		_barrier_seq = 0


## ⑤ 播放队列播完一批：丢掉 seq <= 给定值的条目（pull 每次从 _entries[0] 全量扫，不丢会越扫越慢）
func discard_before(seq: int) -> void:
	var n := 0
	while n < _entries.size() and int(_entries[n]["seq"]) <= seq:
		n += 1
	if n > 0:
		_entries = _entries.slice(n)


# ---- 决策 ----
func answer(ask_id: int, choice: Dictionary) -> bool:
	if _open_ask.is_empty() or int(_open_ask["ask_id"]) != ask_id or bool(_open_ask.get("decider", false)):
		return false
	var req: Dictionary = _open_ask["req"]
	var opts: Array = req["options"]
	var idx := -1
	if choice.has("key"):   ## 键为准
		var want := String(choice["key"])
		for i in opts.size():
			if CWSemKey.key(req, opts[i]["data"]) == want:
				idx = i
				break
	if idx < 0 and choice.has("index"):   ## 下标兜底（回放只有下标）
		idx = int(choice["index"])
	if idx < 0 or idx >= opts.size():
		return false
	_open_ask["index"] = idx
	_answered.emit(ask_id)
	return true


func abort_ask() -> void:
	## ⑧ 卡在 decider 里的那一问（CWUIBridge._prompt）也要叫醒，否则拆局窗口复发「返回主菜单后卡死」
	var seen: Array = []
	for d in deciders.values():
		if d != null and not seen.has(d) and d.has_method("abort"):
			seen.append(d)
			d.abort()
	if _open_ask.is_empty():
		return
	_open_ask["index"] = 0   ## 中止对局固定答 0（cw_game.gd ask 的约定：「可以不做」的放下标 0）
	_answered.emit(int(_open_ask["ask_id"]))


# ---- 持久化 ----
func can_save() -> bool:
	return game != null and not game._pending.is_empty() and not game.is_over()


func save() -> Dictionary:
	return {} if game == null else game.snapshot()


## 只许在单步驱动且没在跑的时候还原（跑着的协程栈里还压着旧局面）
func restore(blob: Dictionary) -> bool:
	if game == null or not _step_drive or _running:
		return false
	game.restore(blob)
	return true


func replay_tape() -> Dictionary:
	return {} if game == null else CWReplay.of(game)


# ---- 回放 / 单步驱动 ----
func pending() -> Dictionary:
	if game == null or not _step_drive:
		return {}
	return await game.pending()


func step(idx: int) -> void:
	if game == null or not _step_drive:
		return
	await game.step(idx)


## ④ 逐字照抄今天 cw_replay.gd:Player.step_once（关键帧由 Player 自己管）：三步收进内核，作答游标只此一处
func step_once() -> bool:
	if game == null or not _step_drive or game.is_over():
		return false
	var req: Dictionary = await game.pending()
	if req.is_empty():
		return false
	var idx: int = await game.ask(req["pid"], req)
	if game.aborted or game.winner >= 0:
		return false
	await game.step(idx)
	return true


## decider 拿真引擎的口子：有 attach_engine 的桥（CWUIBridge，它还要把引擎转交给挂在旁边的 MCTS 桥）走鸭子方法，
## 纯 AI 桥 / 测试 decider 退回 d.game = g。批 1 步 6+8 把 match.gd 的 bridge.game = game 换成「只挂不喂」时
## 这里漏了转调：树搜索档 mcts.game 恒 null，第一问 mcts_bridge.gd:_mcts_pick 首行 game.snapshot() 撞空
##（2026-09-19 批 2 方案调研抓到；t_kernel_attach_engine 钉住 open / set_decider / close 三处）。
static func _attach_engine(d, g) -> void:
	if d.has_method("attach_engine"):
		d.attach_engine(g)
	else:
		d.game = g


## ⑤ 中途换桥（回放 Player.attach）：deciders 只在 open 里读一次，这里补上换的口子
func set_decider(b: Object) -> void:
	if game == null or b == null:
		return
	for pid in game.order:
		deciders[pid] = b
	_attach_engine(b, game)


# ---- 权威侧 ----
func log_msg(text: String, secret_pid := -1, public_text := "") -> void:
	if game != null:
		game.log_msg(text, secret_pid, public_text)


func surrender(faction: int) -> void:
	if game != null:
		game.surrender(faction)


func state_hash() -> String:
	return "" if game == null else game.state_hash()


# ---- 纯查询（⑦，观测协议 §5.3 四条；直连 game.actions.*，不进每帧观测）----
func query(kind: String, args: Dictionary) -> Variant:
	if game == null or not args.has("cid"):
		return null
	var cid := int(args["cid"])
	if cid < 0 or cid >= game.cells.size():
		return null
	var cell: Dictionary = game.cells[cid]
	match kind:
		"plan_next_dests":
			return game.actions.plan_next_dests(cell, args["from"])
		"quote_path":
			return game.actions.quote_path(cell, args["path"])
		"cost_effects_for":
			if args.has("acts"):   ## p=2 批量形态：建行动栏一次问完
				var out := {}
				for act in args["acts"]:
					out[String(act)] = game.actions.cost_effects_for(cell, String(act))
				return out
			return game.actions.cost_effects_for(cell, String(args["act"]))
		"move_block_reason":
			return game.actions.move_block_reason(cell, args["to"])
	return null


# ---- 引擎那头回来的（CWKernelBridge 调）----
func _run() -> void:
	_running = true
	winner = await game.run_game()
	_running = false
	if game == null:
		return   ## 跑着的时候被 close() 了（拆局 / 教程跨章）：对局已经不归我们，别再往条目队列里推终局
	_close_step()   ## ⑥ 终局之前：step_end + sync
	_push("game_over", { "winner": winner, "reason": game.win_reason, "kind": game.win_kind, "round": game.round_no,
		"replay": CWReplay.of(game) if game.record_replay else {} })
	_set_state(State.ENDED)


func _on_ask(req: Dictionary) -> int:
	var pid: int = int(req.get("pid", -1))
	_ask_serial += 1
	var ask_id := _ask_serial
	## ⑧ decider 路也写 _open_ask：observe() 才带得出卡牌结算里的中途询问；abort_ask() 才知道要叫醒谁
	_open_ask = { "ask_id": ask_id, "req": req, "index": -1, "decider": deciders.has(pid) }
	_set_state(State.AWAITING)
	_close_step()   ## ⑥ 问人之前：step_end + sync（decider 路与 answer() 路都推）
	if deciders.has(pid):
		var picked: int = await deciders[pid].ask(req)   ## 不 push ask 条目：有 decider 时队列里没有 ask
		if not _open_ask.is_empty() and int(_open_ask["ask_id"]) == ask_id:
			_open_ask = {}
		if _state == State.AWAITING:
			_set_state(State.READY)
		_open_step(ask_id, pid)
		return picked
	_push("ask", { "ask_id": ask_id, "req": req, "left_ms": -1 })
	while not _open_ask.is_empty() and int(_open_ask["ask_id"]) == ask_id and int(_open_ask["index"]) < 0:
		await _answered
	var idx := 0
	if not _open_ask.is_empty() and int(_open_ask["ask_id"]) == ask_id:
		idx = int(_open_ask["index"])
	_open_ask = {}
	if _state == State.AWAITING:
		_set_state(State.READY)
	_open_step(ask_id, pid)
	return idx


func _on_roll(m: Dictionary) -> void:
	var seq := _push("roll", m, true)
	if not has_consumer or not barrier_on or game.aborted:
		return
	barrier_hits += 1
	_barrier_seq = seq
	var t0 := Time.get_ticks_msec()
	var tree := Engine.get_main_loop() as SceneTree
	while _barrier_seq == seq:
		if tree == null or Time.get_ticks_msec() - t0 > barrier_timeout_ms:
			_barrier_seq = 0
			barrier_timeouts += 1
			push_error("CWKernelInProc：roll #%d 等 ack 超时（%d ms），强制放行 —— 消费者循环没在跑？" % [seq, barrier_timeout_ms])
			printerr("SCRIPT ERROR: CWKernelInProc barrier timeout seq=%d" % seq)   ## tools/run_tests.sh 按这行判红，死锁跑不掉测试
			break
		await tree.process_frame


func _on_log_line(text: String) -> void:
	var index := game.logs.size() - 1   ## log_run 就地改写末条时再发一次同一个 index —— 消费者按 index 覆盖
	var secret: int = int(game.log_secret[index]) if index < game.log_secret.size() else -1
	var public_text: String = String(game.log_public[index]) if index < game.log_public.size() else text
	_push("log", { "index": index, "text": text, "secret_pid": secret, "public_text": public_text })


func _push(kind: String, m: Dictionary, barrier := false) -> int:
	var e := m.duplicate()
	e["t"] = kind
	e["seq"] = _next_seq
	e["barrier"] = barrier
	_next_seq += 1
	_entries.append(e)
	entry_ready.emit()
	return int(e["seq"])


## 按席位裁剪一条条目（规格 A-1.8 三档）：ask 只给主人完整选项，观众 / 别的席位只留 kind / tag / seat / prompt；秘密日志行换公开替身
func _crop(viewer: int, e: Dictionary) -> Dictionary:
	if viewer == VIEWER_OMNISCIENT:
		return e
	match e["t"]:
		"ask":
			var req: Dictionary = e["req"]
			if int(req.get("pid", -1)) == viewer:
				return e
			var c := e.duplicate()
			var r := req.duplicate()
			r["options"] = []
			c["req"] = r
			return c
		"log":
			if int(e["secret_pid"]) >= 0 and int(e["secret_pid"]) != viewer:
				var c := e.duplicate()
				c["text"] = e["public_text"]
				return c
	return e


func _log_text_for(viewer: int, i: int) -> String:
	## ⑨ 全见档观众拿原文（与 cw_obs_codec.gd:_logs / CWNet.logs_for 同口径）
	if viewer == VIEWER_OMNISCIENT or (viewer == VIEWER_WATCHER and open_hands) or i >= game.log_secret.size():
		return game.logs[i]
	var secret := int(game.log_secret[i])
	return game.logs[i] if secret < 0 or secret == viewer else String(game.log_public[i])
