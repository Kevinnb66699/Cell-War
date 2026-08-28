## elm_core.gd -- Elm 化原型·切片 1（开局落子）
##
## 验证目标架构（docs/架构说明书.md · 重构目标架构）在 GDScript 里能跑通：
##   · 不可变 state（原型用 duplicate(true) 模拟；目标形态换差分/事件链）
##   · 中央 Updater = 纯函数 update(state, msg) -> (state', effects)
##   · rng 状态进 state，抽签/掷骰纯函数化（_roll 只读写 state.rng_state）
##   · 子环节（铺棋盘 / 抽种类 / 落子）是 update 内部的纯函数步骤
##   · 唯一对外等待点 = ask（setup_place 决策）
##
## 切片范围：半径 1 六边形（7 格）+ 4 人（2 癌 2 免交替）+ 抽癌种类 + 按序落子。
## 不实现完整规则，只为跑通 update -> shell -> feed msg 回路。
class_name ElmCore
extends RefCounted

## 六边形邻居方向（轴坐标）
const DIRS: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]


# ---- 不可变 state 的构造 ----

static func make_initial_state(seed_value: int, n_players: int) -> Dictionary:
	var players: Array = []
	for i in n_players:
		players.append({
			"pid": i,
			"name": "P%d" % i,
			"faction": 0 if i % 2 == 0 else 1,  # 0=癌 1=免疫
			"cancer_type": -1,
		})
	return {
		"pc": "INIT",          # 流程位置：INIT -> ASSIGN_TYPES -> PLACE -> DONE
		"rng_state": seed_value,
		"players": players,
		"tiles": {},           # 落子格 -> {tissue, pos}
		"cells": [],           # 已落子的细胞
		"next_pid": 0,         # PLACE 循环下一个要落子的玩家
		"pending": null,       # 正在等的决策（null = 没在等）
		"logs": [],            # 日志（纯输出，不影响状态机）
	}


# ---- 纯函数 rng ----

## 给定 rng_state，产出 (value, new_state)。对外纯函数：相同输入必得相同输出。
## 用 Godot 的 RandomNumberGenerator，但只读写它的 state 属性（int）--
## 这样 rng 状态完全进 state，分支带独立 rng 状态，互不污染。
static func _roll(rng_state: int, sides: int) -> Dictionary:
	var r := RandomNumberGenerator.new()
	r.state = rng_state
	var v := r.randi_range(1, sides)
	return { "value": v, "state": r.state }


# ---- 中央 Updater（纯函数，无状态）----

## 推进到下一个 ask 或结束，返回 (新 state, effects)。
## effects 元素：{kind:"ask", pid, req} / {kind:"log", text}。
## 原型阶段用 duplicate(true) 模拟不可变；目标形态换成差分/事件链。
static func update(state: Dictionary, msg: Dictionary) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	var effects: Array = []
	var cont := true
	while cont:
		cont = false
		match s.pc:
			"INIT":
				_build_board(s)
				_place_initial_cancer(s)
				s.logs.append("INIT 棋盘 %d 格，癌区 %d 格" % [s.tiles.size(), _count_cancer(s)])
				s.pc = "ASSIGN_TYPES"
				cont = true
			"ASSIGN_TYPES":
				_assign_cancer_types(s)
				s.pc = "PLACE"
				s.next_pid = 0
				s.pending = null
				cont = true
			"PLACE":
				if s.next_pid >= s.players.size():
					s.pc = "DONE"
					cont = true
					continue
				if s.pending != null:
					# 在等落子决策：msg 应带 idx
					if msg.get("kind", "") == "decision":
						_apply_place_decision(s, s.pending, int(msg["idx"]))
						s.pending = null
						s.next_pid += 1
						cont = true
						continue
					break  # 期望 decision 但 msg 不对：停（不应发生）
				var p: Dictionary = s.players[s.next_pid]
				var options := _place_options(s, p)
				if options.is_empty():
					s.logs.append("%s 无合法落子格，跳过" % p["name"])
					s.next_pid += 1
					cont = true
					continue
				s.pending = { "pid": p["pid"], "options": options }
				effects.append({
					"kind": "ask", "pid": p["pid"],
					"req": {
						"kind": "setup_place",
						"prompt": "%s 选择初始位置" % p["name"],
						"options": options,
					},
				})
				break  # 停下等外部
			"DONE":
				break
			_:
				s.logs.append("!! 未知 pc: " + str(s.pc))
				break
	return { "state": s, "effects": effects }


# ---- 子环节（纯函数式，改传入的 s 副本）----

static func _build_board(s: Dictionary) -> void:
	var coords: Array = [Vector2i.ZERO]
	for d in DIRS:
		coords.append(d)
	for c in coords:
		s.tiles[c] = { "tissue": 0, "pos": c }  # 0=健康

static func _place_initial_cancer(s: Dictionary) -> void:
	# 中央 + 前 3 个邻居 = 4 格癌组织
	var cancer: Array = [Vector2i.ZERO, DIRS[0], DIRS[1], DIRS[2]]
	for c in cancer:
		s.tiles[c]["tissue"] = 1  # 1=癌

static func _count_cancer(s: Dictionary) -> int:
	var n := 0
	for c in s.tiles:
		if s.tiles[c]["tissue"] == 1:
			n += 1
	return n

static func _assign_cancer_types(s: Dictionary) -> void:
	# 每个癌玩家从 [0..5] 不重复抽一个种类，用 _roll 推进 s.rng_state
	var pool: Array = [0, 1, 2, 3, 4, 5]
	for p in s.players:
		if p["faction"] != 0:
			continue
		var r := _roll(s.rng_state, pool.size())
		s.rng_state = r["state"]
		var t: int = pool.pop_at(r["value"] - 1)  # 1..size -> 0..size-1
		p["cancer_type"] = t
		s.logs.append("%s 抽到癌种类 %d" % [p["name"], t])

static func _place_options(s: Dictionary, p: Dictionary) -> Array:
	# 癌玩家只能落癌组织格，免疫只能落健康组织格；已占格挡掉
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
	})
	s.logs.append("%s 落子于 %s" % [p["name"], str(pos)])
