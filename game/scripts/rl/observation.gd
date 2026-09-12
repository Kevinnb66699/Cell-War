## RL Actor 视角编码。只读取白名单字段，不从 snapshot() 删秘密后再导出。
## 能量仍为十分整数；坐标为 [q, r]；非字符串键字典为 {"$map": [[key, value], ...]}。
## 新增记录字段默认不导出，schema_issues() 使验证器能要求人工审查；新增规则
## 状态也应同步此处和 SCHEMA_VERSION。data / equip_seq / fx_* 是公开效果参数映射，
## 其键是卡名、细胞号或坐标，属于数据，不是可自动扩展的私有状态容器。
extends RefCounted

const SCHEMA_VERSION := 1
const TILE_FIELDS := [
	"tissue", "special", "solid", "necrosis", "mucus", "newborn", "ossify_at",
	"store", "cards", "prod", "toxin_round",
]
const PLAYER_FIELDS := ["id", "name", "faction", "cell_id", "cancer_type"]
const CELL_FIELDS := [
	"id", "pid", "faction", "pos", "itype", "ctype", "energy", "alive",
	"marked", "mark_left", "mark_round", "effector_used", "equipped", "play_n",
	"equip_seq", "fx_turn", "fx_round", "differentiated", "armor_used", "mutate_used",
	"toxin_used", "antibody_used", "metastasis_used", "jump_used", "draws_used",
	"attacks_used", "respawn_round", "camp_round", "camp_pos", "neutral_until",
	"chain_left", "chain_running", "chain_bonus",
]
const MOD_FIELDS := ["name", "uses", "until", "seq", "data"]
const EVENT_FIELDS := ["name", "left", "stacks", "doubled", "data"]
const CHEMO_FIELDS := ["at", "left", "by"]
const TRACK_FIELDS := ["cid", "at", "left"]
const FLOW_FIELDS := ["stage", "i", "acts"]


static func observe(game: CWGame, req: Dictionary) -> Dictionary:
	## 连锁询问可能问到队友；current_pid 只表示行动回合，不能决定谁能看手牌。
	var pid := int(req.get("pid", -1))
	var tiles: Array = []
	var positions: Array = game.tiles.keys()
	positions.sort()
	for pos in positions:
		var tile := _select(game.tiles[pos], TILE_FIELDS)
		tile["pos"] = _json(pos)
		tiles.append(tile)
	var cells: Array = []
	for source in game.cells:
		var cell := _select(source, CELL_FIELDS)
		cell["hand_count"] = source["hand"].size()
		if int(source["pid"]) == pid:
			cell["hand"] = _json(source["hand"])
		cell["mods"] = _records(source["mods"], MOD_FIELDS)
		cells.append(cell)
	## pool 是初始公开事件全集减去已公开抽取；只给集合，不暴露内部排列。
	var pool: Array = game.events["pool"].duplicate()
	pool.sort()
	return {
		"schema_version": SCHEMA_VERSION,
		"observer_pid": pid,
		"board_radius": game.board_radius,
		"players": _records(game.players, PLAYER_FIELDS),
		"order": _json(game.order),
		"tiles": tiles,
		"cells": cells,
		"global": {
			"round_no": game.round_no, "memory": game.memory, "immune_level": game.immune_level,
			"differentiated": _json(game.differentiated), "cancer_win_streak": game.cancer_win_streak,
			"effector_round": game.effector_round, "chemo": _select(game.chemo, CHEMO_FIELDS),
			"chemo_track": _select(game.chemo_track, TRACK_FIELDS),
			"events": {"remaining_pool": pool, "active": _records(game.events["active"], EVENT_FIELDS),
				"double_next": game.events["double_next"]},
			"phase": game.phase, "current_pid": game.current_pid, "flow": _select(game.flow, FLOW_FIELDS),
			"winner": game.winner, "win_kind": game.win_kind, "win_reason": game.win_reason,
			"rules": _json(game.tune.rules_state()),
		},
		"request": {
			"kind": str(req.get("kind", "")), "pid": pid, "tag": str(req.get("tag", "")),
			"prompt": str(req.get("prompt", "")), "options": candidates(req),
		},
		## 完整可见历史先保正确性；训练时可在传输层按席位维护日志游标。
		"logs": _json(CWNet.logs_for(game, pid, 0)),
	}


## key 标识当前问题中的语义候选，不是跨局动作 ID；它不含下标、标签或列表顺序。
## 同名同目标的重复卡等价，允许重复 key；实际执行仍回传当前 req.options 的下标。
static func candidates(req: Dictionary) -> Array:
	var out: Array = []
	for option in req.get("options", []):
		var data: Variant = _json(option.get("data", {}))
		var semantic := {"kind": str(req.get("kind", "")), "tag": str(req.get("tag", "")), "data": data}
		out.append({"key": canonical(semantic).sha256_text(), "data": data,
			"label": str(option.get("label", ""))})
	return out


static func canonical(value: Variant) -> String:
	return JSON.stringify(_json(value), "", true)


## 供环境验证器使用；只报告未审字段路径，不把未知值放进模型观测。
static func schema_issues(game: CWGame) -> Array[String]:
	var issues: Array[String] = []
	for pos in game.tiles:
		_unknown(game.tiles[pos], TILE_FIELDS, "tile", issues)
	for cell in game.cells:
		_unknown(cell, CELL_FIELDS + ["hand", "mods"], "cell", issues)
		for mod in cell["mods"]:
			_unknown(mod, MOD_FIELDS, "cell.mods", issues)
	for player in game.players:
		_unknown(player, PLAYER_FIELDS, "player", issues)
	_unknown(game.events, ["pool", "active", "double_next"], "events", issues)
	for event in game.events["active"]:
		_unknown(event, EVENT_FIELDS, "events.active", issues)
	_unknown(game.chemo, CHEMO_FIELDS, "chemo", issues)
	_unknown(game.chemo_track, TRACK_FIELDS, "chemo_track", issues)
	_unknown(game.flow, FLOW_FIELDS, "flow", issues)
	issues.sort()
	return issues


static func _unknown(source: Dictionary, fields: Array, path: String, issues: Array[String]) -> void:
	for key in source:
		if key not in fields:
			var issue := "%s.%s" % [path, str(key)]
			if issue not in issues:
				issues.append(issue)


static func _select(source: Dictionary, fields: Array) -> Dictionary:
	var out := {}
	for field in fields:
		if source.has(field):
			out[field] = _json(source[field])
	return out


static func _records(source: Array, fields: Array) -> Array:
	var out: Array = []
	for record in source:
		out.append(_select(record, fields))
	return out


static func _json(value: Variant) -> Variant:
	if value is Vector2i:
		return [value.x, value.y]
	if value is Dictionary:
		var string_keys := true
		for key in value:
			if not (key is String or key is StringName):
				string_keys = false
				break
		if string_keys:
			var out := {}
			var keys: Array = value.keys()
			keys.sort()
			for key in keys:
				out[str(key)] = _json(value[key])
			return out
		## 世界事件用细胞号或 Vector2i 作键，直接 str(key) 会丢类型与坐标结构。
		var entries: Array = []
		for key in value:
			entries.append([_json(key), _json(value[key])])
		entries.sort_custom(func(a: Array, b: Array) -> bool: return canonical(a[0]) < canonical(b[0]))
		return {"$map": entries}
	if value is Array or value is PackedStringArray or value is PackedInt32Array \
			or value is PackedInt64Array or value is PackedFloat32Array or value is PackedFloat64Array:
		var out: Array = []
		for item in value:
			out.append(_json(item))
		return out
	if value == null or value is bool or value is int or value is float or value is String:
		return value
	if value is StringName:
		return str(value)
	push_error("RL observation: unsupported value type %d" % typeof(value))
	return null
