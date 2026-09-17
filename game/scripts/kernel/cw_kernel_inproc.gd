## cw_kernel_inproc.gd —— 本地 GDScript 内核的句柄实现（口径二 · 批 0 步 9，规格 A-3.5）
##
## CWGame 一行不改：只往 bridges 里塞一个 CWKernelBridge，它把引擎的桥回调翻译成有序条目入队；
## ask 转交 cfg 里的 decider（无头测试 / AI / 回放的作答者）或入队等 answer()；roll 有消费者时 await barrier。
## 批 0 只在无头测试里跑（不接线，规格 §0.1）；批 1 接线时 CWUIBridge 从 bridges 里退出来、变成 decider，
## 它的 show_* 改由播放队列（CWPlayQueue）调用。
##
## 观测（observe → CWMirror）是步 8 的事，这里先返回 null。
class_name CWKernelInProc
extends CWKernel

const BARRIER_TIMEOUT_MS := 5000   ## 消费者循环没在跑（_fading / teardown / 教程跨章）时的兜底：超时放行并报错，死锁跑不掉测试

var game: CWGame
var bridge: CWKernelBridge
var deciders := {}                  ## pid → CWBridge：ask 转交它（无头测试 / AI / 回放）；没有就入队等 answer()
var has_consumer := false           ## 有消费者才 barrier（无头测试、AI 互搏、dice_anim 关着都不等）
var barrier_timeout_ms := BARRIER_TIMEOUT_MS
var winner := -1

var _entries: Array = []            ## 条目队列。批 0 保留整局（单局条目量小）；丢弃水位线随 C# 侧 PresentationDroppedBefore 的口径以后再定
var _next_seq := 1
var _ask_serial := 0
var _open_ask := {}                 ## 正在等 answer() 的那一问：{ask_id, req, index}
var _barrier_seq := 0               ## > 0 = 有一条 roll 在等 ack
var _step_drive := false
var _running := false

signal _answered(ask_id: int)


func open(cfg: Dictionary) -> bool:
	if _state != State.IDLE:
		return false
	_set_state(State.STARTING)
	game = CWGame.new()
	## ⚠ tune.cancer_types / world_events_on 必须在 init 之前（match.gd:459-460、cw_room.gd:366-370 同）
	if cfg.has("cancer_types"):
		game.tune.cancer_types = cfg["cancer_types"]
	if cfg.has("world_events_on"):
		game.tune.world_events_on = bool(cfg["world_events_on"])
	game.init(cfg["factions"], int(cfg.get("seed", 0)))
	game.record_replay = bool(cfg.get("record_replay", false))
	has_consumer = bool(cfg.get("consumer", false))
	_step_drive = bool(cfg.get("step_drive", false))
	deciders = {}
	if cfg.has("decider") and cfg["decider"] != null:
		for pid in game.order:
			deciders[pid] = cfg["decider"]
	if cfg.has("deciders"):
		deciders.merge(cfg["deciders"], true)
	for d in deciders.values():
		d.game = game
	bridge = CWKernelBridge.new()
	bridge.kernel = self
	bridge.game = game
	for pid in game.order:
		game.bridges[pid] = bridge   ## 只注册**一个**桥对象（对象去重）
	game.log_line.connect(_on_log_line)
	if cfg.has("world_state"):
		game.restore(cfg["world_state"])
	_set_state(State.READY)
	if not _step_drive:
		_run()   ## fire-and-forget 协程：跑到终局
	return true


func close() -> void:
	if game == null:
		return
	abort()
	for d in deciders.values():
		d.game = null
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
	return { "stream_sync": false, "step_drive": _step_drive, "rollout": false, "save": true, "authority": true }


# ---- 观测 ----
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


# ---- 决策 ----
func answer(ask_id: int, choice: Dictionary) -> bool:
	if _open_ask.is_empty() or int(_open_ask["ask_id"]) != ask_id:
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


# ---- 权威侧 ----
func log_msg(text: String, secret_pid := -1, public_text := "") -> void:
	if game != null:
		game.log_msg(text, secret_pid, public_text)


func surrender(faction: int) -> void:
	if game != null:
		game.surrender(faction)


func state_hash() -> String:
	return "" if game == null else game.state_hash()


# ---- 引擎那头回来的（CWKernelBridge 调）----
func _run() -> void:
	_running = true
	winner = await game.run_game()
	_running = false
	_push("game_over", { "winner": winner, "reason": game.win_reason, "kind": game.win_kind, "round": game.round_no,
		"replay": CWReplay.of(game) if game.record_replay else {} })
	_set_state(State.ENDED)


func _on_ask(req: Dictionary) -> int:
	var pid: int = int(req.get("pid", -1))
	if deciders.has(pid):
		return await deciders[pid].ask(req)
	_ask_serial += 1
	var ask_id := _ask_serial
	_open_ask = { "ask_id": ask_id, "req": req, "index": -1 }
	_set_state(State.AWAITING)
	_push("ask", { "ask_id": ask_id, "req": req, "left_ms": -1 })
	while not _open_ask.is_empty() and int(_open_ask["ask_id"]) == ask_id and int(_open_ask["index"]) < 0:
		await _answered
	var idx := 0
	if not _open_ask.is_empty() and int(_open_ask["ask_id"]) == ask_id:
		idx = int(_open_ask["index"])
	_open_ask = {}
	if _state == State.AWAITING:
		_set_state(State.READY)
	return idx


func _on_roll(m: Dictionary) -> void:
	var seq := _push("roll", m, true)
	if not has_consumer or game.aborted:
		return
	_barrier_seq = seq
	var t0 := Time.get_ticks_msec()
	var tree := Engine.get_main_loop() as SceneTree
	while _barrier_seq == seq:
		if tree == null or Time.get_ticks_msec() - t0 > barrier_timeout_ms:
			_barrier_seq = 0
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
	if viewer == VIEWER_OMNISCIENT or i >= game.log_secret.size():
		return game.logs[i]
	var secret := int(game.log_secret[i])
	return game.logs[i] if secret < 0 or secret == viewer else String(game.log_public[i])
