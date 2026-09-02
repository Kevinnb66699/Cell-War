## cw_state_codec.gd —— 规则状态的快照、规范化编码与哈希
##
## 这里是「什么会改变下一步结算」的唯一清单。表现层状态（日志、桥、提示文本）
## 不放进来；play_n 只是给仍存活条目发序号的单调计数，条目本身的 seq 已保留先后。
class_name CWStateCodec
extends RefCounted


static func snapshot(game: CWGame) -> Dictionary:
	return {
		"tiles": game.tiles.duplicate(true),
		"cells": game.cells.duplicate(true),
		"players": game.players.duplicate(true), "order": game.order.duplicate(),
		"differentiated": game.differentiated.duplicate(),
		"flow": game.flow.duplicate(), "pending": game._pending.duplicate(true),
		"round_no": game.round_no, "memory": game.memory, "immune_level": game.immune_level,
		"winner": game.winner, "win_reason": game.win_reason, "win_kind": game.win_kind,
		"cancer_win_streak": game.cancer_win_streak,
		"current_pid": game.current_pid, "phase": game.phase,
		"events": game.events.duplicate(true), "rng": game.rng.state,
		"tune": game.tune.rules_state(),
	}


static func restore(game: CWGame, snap: Dictionary) -> void:
	game.tiles = snap["tiles"].duplicate(true)
	game.cells = snap["cells"].duplicate(true)
	game.players = snap["players"].duplicate(true)
	game.order = snap.get("order", game.order).duplicate()
	game.differentiated = snap["differentiated"].duplicate()
	game.flow = snap["flow"].duplicate()
	game._pending = snap["pending"].duplicate(true)
	game.round_no = snap["round_no"]
	game.memory = snap["memory"]
	game.immune_level = snap["immune_level"]
	game.winner = snap["winner"]
	game.win_reason = snap["win_reason"]
	game.win_kind = snap["win_kind"]
	game.cancer_win_streak = snap.get("cancer_win_streak", 0)
	game.current_pid = snap["current_pid"]
	game.phase = snap["phase"]
	game.events = snap["events"].duplicate(true)
	game.rng.state = snap["rng"]
	## v1 旧档没有旋钮：保留新建对局的默认规则，不能因补校验拒读旧档。
	if snap.get("tune") is Dictionary:
		game.tune.restore_rules_state(snap["tune"])


static func state_hash(game: CWGame) -> String:
	var state := snapshot(game)
	## 这些字段参与恢复，但不改变规则的后续演进。
	state.erase("phase")
	state.erase("win_reason")
	state.erase("win_kind")
	for cell in state["cells"]:
		cell.erase("play_n")
	return _encode(state).sha256_text()


static func _encode(value: Variant) -> String:
	if value is Dictionary:
		var entries: Array[String] = []
		for key in value.keys():
			entries.append(_encode(key) + ":" + _encode(value[key]))
		entries.sort()
		return "D{" + ",".join(entries) + "}"
	if value is Array:
		var entries: Array[String] = []
		for item in value:
			entries.append(_encode(item))
		return "A[" + ",".join(entries) + "]"
	if value is Vector2i:
		return "V(%d,%d)" % [value.x, value.y]
	if value is String:
		return "S" + var_to_str(value)
	return "%d:%s" % [typeof(value), var_to_str(value)]
