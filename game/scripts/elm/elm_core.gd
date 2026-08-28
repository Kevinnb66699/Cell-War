## elm_core.gd -- Elm 化原型·切片 3（msg 驱动：step / decision）
##
## 核心纠正（见 docs/架构说明书.md · 演出与逻辑解耦 / 重构目标架构）：
##   状态机**不等待**。它停在某个 state（可能恰好呈现一个 ask = pending）。
##   **外界是推动者**：外界读 state，看到 ask 就发 decision msg；看到在内部
##   环节就发 step msg。state 才变一次。ask 不是 update 等的对象，decision 才是 msg。
##
##   msg 最小集合 = { step（推进内部）, decision(idx)（回答当前 ask） }。
##   演出不阻塞（roll_show 只进队列），演出回执不是 msg。
##
## update 是被动的一步转移函数：收到一个 msg 做一次转移（内部可跑多个不需
## 外部决策的纯计算环节，合法），返回新 state + effects。新 state 可能停在
## ask（pending != null）--那是 state 的属性，不是 update 在等。
class_name ElmCore
extends RefCounted

const DIRS: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]


# ---- 不可变 state 的构造 ----

static func make_initial_state(seed_value: int, n_players: int) -> Dictionary:
	var players: Array = []
	for i in n_players:
		players.append({
			"pid": i, "name": "P%d" % i,
			"faction": 0 if i % 2 == 0 else 1,  # 0=癌 1=免疫
			"cancer_type": -1,
		})
	return {
		"pc": "INIT", "rng_state": seed_value,
		"players": players, "tiles": {}, "cells": [],
		"next_pid": 0, "pending": null,
		"combat_count": 0, "logs": [],
	}


# ---- 纯函数 rng ----

static func _roll(rng_state: int, sides: int) -> Dictionary:
	var r := RandomNumberGenerator.new()
	r.state = rng_state
	var v := r.randi_range(1, sides)
	return { "value": v, "state": r.state }


# ---- 中央 Updater（被动一步转移）----

## 收到一个 msg 做一次转移。step -> 推进内部到下一个 ask/DONE；
## decision -> 应用当前 ask 的答案 + 继续推进。不"等待"。
static func update(state: Dictionary, msg: Dictionary) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	var effects: Array = []
	match String(msg.get("kind", "")):
		"step":
			_advance(s, effects)
		"decision":
			_apply_decision(s, int(msg.get("idx", 0)), effects)
		_:
			pass  # 未知 msg：不动（状态机不自走）
	return { "state": s, "effects": effects }


## 推进所有不需要外部决策的内部环节，直到停在 ask（pending != null）或 DONE。
## 由 step msg 触发。若进入时已在 ask（pending != null），则不动--状态机不自走。
static func _advance(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 100:
		guard += 1
		match String(s.pc):
			"INIT":
				_build_board(s)
				_place_initial_cancer(s)
				s.logs.append("INIT 棋盘 %d 格，癌区 %d 格" % [s.tiles.size(), _count_cancer(s)])
				s.pc = "ASSIGN_TYPES"
			"ASSIGN_TYPES":
				_assign_cancer_types(s)
				s.pc = "PLACE"
				s.pending = null
			"PLACE":
				if s.next_pid >= s.players.size():
					s.pc = "COMBAT"
					continue
				if s.pending != null:
					break  # 已停在 ask：等外界 decision，不自走
				var p: Dictionary = s.players[s.next_pid]
				var options := _place_options(s, p)
				if options.is_empty():
					s.logs.append("%s 无合法落子格，跳过" % p["name"])
					s.next_pid += 1
					continue
				s.pending = { "kind": "setup_place", "pid": p["pid"], "options": options }
				effects.append({
					"kind": "ask", "pid": p["pid"],
					"req": { "kind": "setup_place", "prompt": "%s 选择初始位置" % p["name"], "options": options },
				})
				break  # 停在 ask，把控制权交还外界
			"COMBAT":
				# 攻击不需外部决策：一个 step 一口气把剩余攻击跑完
				if s.combat_count >= 2:
					s.pc = "DONE"
					continue
				var pair = _find_combat_pair(s)
				if pair == null:
					s.pc = "DONE"
					continue
				_do_attack(s, pair["attacker"], pair["target"], effects)
				s.combat_count += 1
			"DONE":
				break
			_:
				s.logs.append("!! 未知 pc: " + str(s.pc))
				break


## 应用一个 decision（回答当前 ask），然后继续推进到下一个 ask。
static func _apply_decision(s: Dictionary, idx: int, effects: Array) -> void:
	if s.pending == null:
		return  # 没 ask 却来 decision：忽略（shell 不该发）
	match String(s.pending.get("kind", "")):
		"setup_place":
			_apply_place_decision(s, s.pending, idx)
			s.pending = null
			s.next_pid += 1
		_:
			pass
	_advance(s, effects)


# ---- 子环节（纯函数式，改传入的 s 副本）----

static func _build_board(s: Dictionary) -> void:
	var coords: Array = [Vector2i.ZERO]
	for d in DIRS:
		coords.append(d)
	for c in coords:
		s.tiles[c] = { "tissue": 0, "pos": c }

static func _place_initial_cancer(s: Dictionary) -> void:
	var cancer: Array = [Vector2i.ZERO, DIRS[0], DIRS[1], DIRS[2]]
	for c in cancer:
		s.tiles[c]["tissue"] = 1

static func _count_cancer(s: Dictionary) -> int:
	var n := 0
	for c in s.tiles:
		if s.tiles[c]["tissue"] == 1:
			n += 1
	return n

static func _assign_cancer_types(s: Dictionary) -> void:
	var pool: Array = [0, 1, 2, 3, 4, 5]
	for p in s.players:
		if p["faction"] != 0:
			continue
		var r := _roll(s.rng_state, pool.size())
		s.rng_state = r["state"]
		var t: int = pool.pop_at(r["value"] - 1)
		p["cancer_type"] = t
		s.logs.append("%s 抽到癌种类 %d" % [p["name"], t])

static func _place_options(s: Dictionary, p: Dictionary) -> Array:
	var opts: Array = []
	var faction: int = p["faction"]
	var want := 1 if faction == 0 else 0
	for c in s.tiles:
		if s.tiles[c]["tissue"] != want:
			continue
		var blocked := false
		for cell in s.cells:
			if cell["pos"] == c:
				blocked = true
				break
		if not blocked:
			opts.append({ "label": "落子 %s" % str(c), "data": { "to": c } })
	return opts

static func _apply_place_decision(s: Dictionary, pending: Dictionary, idx: int) -> void:
	var options: Array = pending["options"]
	var data: Dictionary = options[idx]["data"]
	var pos: Vector2i = data["to"]
	var p: Dictionary = s.players[pending["pid"]]
	s.cells.append({
		"pid": p["pid"], "faction": p["faction"], "pos": pos,
		"cancer_type": p["cancer_type"], "itype": -1,
		"hp": 10, "alive": true,
	})
	s.logs.append("%s 落子于 %s" % [p["name"], str(pos)])


# ---- COMBAT 演示（验证 roll 纯函数 + 演出不阻塞）----

static func _find_combat_pair(s: Dictionary):
	for c in s.cells:
		if c["faction"] != 0 or not c["alive"]:
			continue
		for t in s.cells:
			if t["faction"] != 1 or not t["alive"]:
				continue
			if _is_adjacent(c["pos"], t["pos"]):
				return { "attacker": c, "target": t }
	return null

static func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	for d in DIRS:
		if a + d == b:
			return true
	return false

static func _do_attack(s: Dictionary, attacker: Dictionary, target: Dictionary, effects: Array) -> void:
	var r := _roll(s.rng_state, 6)
	s.rng_state = r["state"]
	var dmg: int = r["value"]
	target["hp"] -= dmg
	effects.append({
		"kind": "roll_show", "value": dmg, "sides": 6, "at": target["pos"],
		"attacker": attacker["pid"], "target": target["pid"],
	})
	if target["hp"] <= 0:
		target["alive"] = false
		s.logs.append("COMBAT %s 攻击 %s 掷 %d -> 死亡" % [attacker["pid"], target["pid"], dmg])
	else:
		s.logs.append("COMBAT %s 攻击 %s 掷 %d -> 剩 %d hp" % [attacker["pid"], target["pid"], dmg, target["hp"]])
