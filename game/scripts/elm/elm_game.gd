## elm_game.gd —— 迁移版中央 Game：不可变 state + 纯函数 update（被动一步转移）
##
## 对应 cw_game.gd 的目标形态（见 docs/重构API设计.md）：
##   · state 不可变（duplicate 模拟；差分/事件链后续优化）
##   · rng 进 state：掷骰 = 纯函数消耗 rng_state，不经过桥
##   · update(state, msg) -> {state, effects}，无 await / 无桥引用
##   · msg = {step} / {decision, idx}；ask 不是 msg（state 呈现的需求）
##
## 本文件目前只实现 SETUP 阶段（迁移 cw_setup 的验证骨架），
## 后续阶段（WORLD/TURN/ACTIONS）按同一形态逐个迁移。
class_name ElmGame
extends RefCounted


# ---- 纯函数 rng（精确复刻 cw_game.rng 语义）----
## seed -> 初始 state：真实代码 rng.seed=seed 后连续 randi_range；
## 迁移版把 rng.state 存进 state，每次掷骰 new RNG + 重设 state，序列逐位一致
## （已在 tests/rng_repro.gd 验证）。
static func _rng_state_from_seed(seed_value: int) -> int:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r.state


static func _randi_range(rng_state: int, from_i: int, to_i: int) -> Dictionary:
	var r := RandomNumberGenerator.new()
	r.state = rng_state
	var v := r.randi_range(from_i, to_i)
	return { "value": v, "state": r.state }


## 复刻 cw_game.pick_random（均匀取 n 个不重复）
static func _pick_random(rng_state: int, arr: Array, n: int) -> Dictionary:
	var pool := arr.duplicate()
	var out: Array = []
	var st := rng_state
	while out.size() < n and not pool.is_empty():
		var rr := _randi_range(st, 0, pool.size() - 1)
		st = rr["state"]
		out.append(pool.pop_at(rr["value"]))
	return { "picked": out, "state": st }


# ---- state 构造（复刻 cw_game.init：players/order 生成 + rng seed）----
static func make_initial_state(seed_value: int, faction_list: Array, tune) -> Dictionary:
	var players: Array = []
	var order: Array = []
	var immune_i := 0
	var cancer_i := 0
	for i in faction_list.size():
		var f: int = faction_list[i]
		var seq := ""
		if f == CWData.Faction.IMMUNE:
			seq = char(65 + immune_i)
			immune_i += 1
		else:
			seq = char(65 + cancer_i)
			cancer_i += 1
		var pname := ("免疫" if f == CWData.Faction.IMMUNE else "癌症") + seq
		players.append({ "id": i, "name": pname, "faction": f, "cell_id": i })
		order.append(i)
	return {
		"pc": "SETUP_BUILD", "rng_state": _rng_state_from_seed(seed_value),
		"tiles": {}, "cells": [], "players": players, "order": order,
		"round_no": 1, "memory": 0, "immune_level": 0, "differentiated": [],
		"winner": -1, "win_reason": "", "win_kind": "",
		"tune": tune, "next_pid": 0, "pending": null, "logs": [],
	}


# ---- 中央 update（被动一步转移，不等待）----
static func update(state: Dictionary, msg: Dictionary) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	var effects: Array = []
	match String(msg.get("kind", "")):
		"step":
			_advance(s, effects)
		"decision":
			_apply_decision(s, int(msg.get("idx", 0)), effects)
		_:
			pass
	return { "state": s, "effects": effects }


## 推进内部环节到下一个 ask 或阶段完成（状态机不自走，由 step/decision 触发）
static func _advance(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 1000:
		guard += 1
		match String(s["pc"]):
			"SETUP_BUILD":
				ElmSetup.build_board(s)
				ElmSetup.place_initial_cancer(s)
				ElmSetup.assign_cancer_types(s)
				s["pc"] = "SETUP_PLACE"
				s["next_pid"] = 0
			"SETUP_PLACE":
				if s["next_pid"] >= s["order"].size():
					ElmSetup.place_primary_lesions(s)
					ElmSetup.update_marks(s)
					s["pc"] = "SETUP_DONE"
					continue
				var pid: int = s["order"][s["next_pid"]]
				var p: Dictionary = player(s, pid)
				var options: Array = ElmSetup.place_options(s, p)
				if options.is_empty():
					s["next_pid"] += 1
					continue
				s["pending"] = { "kind": "setup_place", "pid": pid, "options": options }
				effects.append({
					"kind": "ask", "pid": pid,
					"req": { "kind": "setup_place", "prompt": "%s 选择初始位置" % p["name"], "options": options },
				})
				break
			"SETUP_DONE":
				break
			_:
				break


## 应用一个 decision（按 pending.kind 路由到子 Updater），然后继续推进
static func _apply_decision(s: Dictionary, idx: int, effects: Array) -> void:
	if s["pending"] == null:
		return
	match String(s["pending"].get("kind", "")):
		"setup_place":
			ElmSetup.apply_place(s, idx)
			s["pending"] = null
			s["next_pid"] += 1
		_:
			pass
	_advance(s, effects)


# ---- 查询工具（复刻 cw_game 相关静态查询）----
static func player(s: Dictionary, pid: int) -> Dictionary:
	return s["players"][pid]


static func living_cells(s: Dictionary, faction: int = -1) -> Array:
	var out: Array = []
	for c in s["cells"]:
		if c["alive"] and (faction < 0 or c["faction"] == faction):
			out.append(c)
	return out


static func cells_at(s: Dictionary, pos: Vector2i, faction: int = -1) -> Array:
	var out: Array = []
	for c in s["cells"]:
		if c["alive"] and c["pos"] == pos and (faction < 0 or c["faction"] == faction):
			out.append(c)
	return out
