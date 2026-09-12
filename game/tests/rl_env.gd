extends SceneTree
## Python 启动的单环境 worker。只连接 127.0.0.1；JSONL 消息保留活跃协程。
## audit/info 是验证侧元数据，不属于 Actor 输入；Actor 只消费 observation。

const Observation := preload("res://scripts/rl/observation.gd")
const RLBridge := preload("res://scripts/rl/bridge.gd")
const Fixtures := preload("res://tests/rl_fixtures.gd")
const Contracts := preload("res://tests/rl_observation_checks.gd")
const PROTOCOL := 1

class DirectReplay extends CWBridge:
	var expected: Array = []
	var seen := 0
	var issues: Array[String] = []
	func ask(req: Dictionary) -> int:
		if seen >= expected.size():
			issues.append("extra ask")
			game.aborted = true
			return 0
		var entry: Dictionary = expected[seen]
		var signature := Observation.canonical({"pid": req["pid"], "kind": req["kind"],
			"tag": req.get("tag", ""), "options": Observation.candidates(req)})
		if signature.sha256_text() != entry["request_hash"]:
			issues.append("request mismatch at %d" % seen)
		if game.state_hash() != entry["state_hash"]:
			issues.append("state mismatch at %d" % seen)
		var index: int = entry["index"]
		seen += 1
		if index < 0 or index >= req["options"].size():
			issues.append("invalid recorded index")
			game.aborted = true
			return 0
		return index

var peer := StreamPeerTCP.new()
var incoming := PackedByteArray()
var connected := false
var last_activity := 0
var game: CWGame
var bridge: CWBridge
var request := {}
var serial := 0
var episode := 0
var busy := false
var replaying := false
var trace: Array = []
var config := {}
var final_hash := ""
var final_winner := -1
var was_truncated := false

func _initialize() -> void:
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	var port := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("port="):
			port = int(arg.substr(5))
	if port <= 0 or peer.connect_to_host("127.0.0.1", port) != OK:
		push_error("RL environment needs a loopback port")
		quit(1)
	last_activity = Time.get_ticks_msec()

func _process(_delta: float) -> bool:
	peer.poll()
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if not connected:
			connected = true
			peer.set_no_delay(true)
			_send({"t": "ready", "protocol": PROTOCOL, "godot": Engine.get_version_info()["string"],
				"fixtures": Fixtures.cases()})
		var available := peer.get_available_bytes()
		if available > 0:
			var part := peer.get_data(available)
			if part[0] != OK:
				quit(1)
				return false
			incoming.append_array(part[1])
			while incoming.has(10):
				var at := incoming.find(10)
				var raw := incoming.slice(0, at).get_string_from_utf8()
				incoming = incoming.slice(at + 1)
				last_activity = Time.get_ticks_msec()
				var message: Variant = JSON.parse_string(raw)
				if message is Dictionary:
					_command(message)
				else:
					_error("invalid_json")
	elif connected:
		quit(1)
	if Time.get_ticks_msec() - last_activity > 120000:
		push_error("RL worker watchdog: no command or progress for 120 seconds")
		quit(1)
	return false

func _send(message: Dictionary) -> void:
	if peer.put_data((JSON.stringify(message) + "\n").to_utf8_buffer()) != OK:
		quit(1)

func _error(reason: String) -> void:
	_send({"t": "error", "reason": reason, "episode": episode, "ask_id": serial,
		"state_hash": game.state_hash() if game != null else ""})

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value))

func _command(message: Dictionary) -> void:
	match message.get("t", ""):
		"reset":
			if busy:
				_error("busy")
				return
			var players: Variant = message.get("players", 4)
			var seed_value: Variant = message.get("seed", 1)
			var fixture: String = str(message.get("fixture", ""))
			if not _integer(players) or int(players) not in [2, 4, 6] or not _integer(seed_value) \
					or (fixture != "" and (fixture not in Fixtures.cases() or int(players) != 4)):
				_error("invalid_reset")
				return
			config = {"players": int(players), "seed": int(seed_value), "fixture": fixture}
			episode += 1
			trace.clear()
			was_truncated = false
			_new_game()
			var new_bridge := RLBridge.new()
			new_bridge.game = game
			new_bridge.environment = root.get_node("Environment")
			bridge = new_bridge
			_install_bridge()
			_run_episode()
		"step":
			if request.is_empty() or replaying:
				_error("no_pending")
				return
			if not _integer(message.get("episode")) or int(message["episode"]) != episode \
					or not _integer(message.get("ask_id")) or int(message["ask_id"]) != serial:
				_error("stale_request")
				return
			var index: Variant = message.get("index")
			if not _integer(index) or int(index) < 0 or int(index) >= request["options"].size():
				_error("invalid_index")
				return
			var signature := Observation.canonical({"pid": request["pid"], "kind": request["kind"],
				"tag": request.get("tag", ""), "options": Observation.candidates(request)})
			trace.append({"request_hash": signature.sha256_text(), "state_hash": game.state_hash(),
				"index": int(index), "pid": request["pid"], "kind": request["kind"]})
			request = {}
			bridge.answered.emit(int(index))
		"probe":
			if request.is_empty():
				_error("no_pending")
			else:
				_send({"t": "probe", "result": Contracts.run(game, request), "state_hash": game.state_hash()})
		"abort":
			if request.is_empty():
				_error("no_pending")
				return
			was_truncated = true
			game.aborted = true
			request = {}
			bridge.answered.emit(0)
		"replay":
			if busy or was_truncated or final_hash == "":
				_error("replay_unavailable")
				return
			_verify_replay()
		"close":
			if not request.is_empty():
				game.aborted = true
				request = {}
				bridge.answered.emit(0)
			if game != null:
				game.dispose()
			quit(0)
		_:
			_error("unknown_command")

func _new_game() -> void:
	if game != null:
		game.dispose()
	game = CWGame.new()
	game.init(CWData.FACTION_ORDER[config["players"]], config["seed"])
	game.record_replay = true
	request = {}

func _install_bridge() -> void:
	for pid in game.order:
		game.bridges[pid] = bridge

func _run_episode() -> void:
	busy = true
	if config["fixture"] == "":
		await game.run_game()
	else:
		await Fixtures.run_case(config["fixture"], game)
	busy = false
	final_hash = game.state_hash()
	final_winner = game.winner
	var rewards := {}
	for p in game.players:
		rewards[str(p["id"])] = 0 if game.winner < 0 else (1 if p["faction"] == game.winner else -1)
	_send({"t": "done", "episode": episode, "terminated": game.winner >= 0,
		"truncated": was_truncated, "fixture_complete": config["fixture"] != "",
		"winner": game.winner, "rewards": rewards, "decisions": trace.size(),
		"recorded_choices": game.replay.size(), "state_hash": final_hash, "round": game.round_no})

func offer(req: Dictionary) -> void:
	request = req
	serial += 1
	last_activity = Time.get_ticks_msec()
	var issues: Array = Observation.schema_issues(game)
	_send({"t": "ask", "episode": episode, "ask_id": serial,
		"observation": Observation.observe(game, req),
		"info": {"state_hash": game.state_hash(), "schema_issues": issues,
			"top_level": not game._pending.is_empty(), "current_pid": game.current_pid}})

func _verify_replay() -> void:
	busy = true
	replaying = true
	var expected_hash := final_hash
	var expected_winner := final_winner
	_new_game()
	var direct := DirectReplay.new()
	direct.game = game
	direct.expected = trace
	bridge = direct
	_install_bridge()
	if config["fixture"] == "":
		await game.run_game()
	else:
		await Fixtures.run_case(config["fixture"], game)
	if direct.seen != trace.size():
		direct.issues.append("missing asks")
	if game.state_hash() != expected_hash or game.winner != expected_winner:
		direct.issues.append("final state or winner mismatch")
	if game.replay.size() != trace.size():
		direct.issues.append("recording count mismatch")
	busy = false
	replaying = false
	last_activity = Time.get_ticks_msec()
	_send({"t": "replay", "decisions": direct.seen, "issues": direct.issues,
		"state_hash": game.state_hash()})

## RefCounted 桥持有普通 Node，避免把 SceneTree 强制当 Node；这个节点只转发询问。
class EnvironmentNode extends Node:
	var controller: SceneTree
	func offer(req: Dictionary) -> void:
		controller.offer(req)

func _init() -> void:
	var node := EnvironmentNode.new()
	node.name = "Environment"
	node.controller = self
	root.add_child.call_deferred(node)
