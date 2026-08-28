## elm_migrate_test.gd —— 迁移验证：真实 core（cw_*） vs Elm 迁移版（elm_*）行为等价
##
## 方法：同种子、同一决策（DummyBridge 恒返回 0，隔离桥差异、只比逻辑），
## 真实 g.run_game() 与迁移版 ElmShell.run_full() 各自跑完同一对局，逐项对比。
## 若全等 → 迁移版与真实逻辑等价（rng 复刻 + 纯函数化 + 状态机摊平成立）。
##
## 迁移验证 1：cw_setup -> ElmSetup（SETUP 阶段）
## 迁移验证 2：cw_game.run_game -> ElmShell.run_full（完整对局，2/4/6 人局）
extends SceneTree


class DummyBridge:
	extends CWBridge

	func ask(_req: Dictionary) -> int:
		return 0


func _init():
	print("========================================")
	print("  迁移验证：cw_* 真实 vs elm_* 迁移版 行为等价")
	print("========================================")
	await _run()
	quit()


func _run() -> void:
	_test_setup()
	print("")
	_test_full_game()
	quit()


## 迁移验证 1：SETUP 阶段等价（沿用原验证）
func _test_setup() -> void:
	print("----- 验证 1：cw_setup -> ElmSetup -----")
	var seed_value := 12345
	var faction_list: Array = CWData.FACTION_ORDER[4]

	var g := CWGame.new()
	g.init(faction_list, seed_value)
	for pid in g.order:
		g.bridges[pid] = DummyBridge.new()
	await g.setup.run()

	var shell := ElmShell.new()
	shell.bridge = DummyBridge.new()
	var mr := shell.run_to_setup(seed_value, faction_list, CWTuning.new())
	var s: Dictionary = mr["state"]

	var ok := true
	var why := ""
	if int(g.rng.state) != int(s["rng_state"]):
		ok = false
		why = "rng_state: %d vs %d" % [g.rng.state, s["rng_state"]]
	for c in g.tiles:
		var a: Dictionary = g.tiles[c]
		var b: Dictionary = s["tiles"][c]
		if a["tissue"] != b["tissue"] or a["solid"] != b["solid"] or a["sticky"] != b["sticky"] \
				or a["newborn"] != b["newborn"] or a["store"] != b["store"] \
				or a["cards"] != b["cards"] or a["prod"] != b["prod"] or a["special"] != b["special"]:
			ok = false
			why = "tile %s: %s vs %s" % [str(c), a, b]
	for i in g.cells.size():
		var a: Dictionary = g.cells[i]
		var b: Dictionary = s["cells"][i]
		if a["pid"] != b["pid"] or a["faction"] != b["faction"] or a["pos"] != b["pos"] \
				or a["itype"] != b["itype"] or a["ctype"] != b["ctype"] \
				or a["energy"] != b["energy"] or a["alive"] != b["alive"] \
				or a["marked"] != b["marked"]:
			ok = false
			why = "cell %d: %s vs %s" % [i, a, b]
	for i in g.players.size():
		if g.players[i].get("cancer_type", -1) != s["players"][i].get("cancer_type", -1):
			ok = false
			why = "cancer_type %d" % i
	var verdict := "✓" if ok else "✗ — " + why
	print("  cells=%d steps=%d pc=%s  行为等价: %s" % [
		s["cells"].size(), mr["steps"], s["pc"], verdict])
	g.dispose()


## 迁移验证 2：完整对局等价（2/4/6 人局）
func _test_full_game() -> void:
	print("----- 验证 2：cw_game.run_game -> ElmShell.run_full -----")
	var all_ok := true
	for n in [2, 4, 6]:
		var seed_value: int = 12345 + n
		var faction_list: Array = CWData.FACTION_ORDER[n]
		var r: Dictionary = await _run_one(seed_value, faction_list)
		if not r["ok"]:
			all_ok = false
		print("  %d 人局：winner=%s hash=%s  steps=%d  %s" % [
			n, r["winner"], r["hash"], r["steps"],
			"✓ 等价" if r["ok"] else "✗ 不等价 — " + r["why"]])
		if not r["ok"]:
			for line in r["diff_head"]:
				print("    " + line)
	print("  完整对局行为等价: " + ("✓ 全部通过" if all_ok else "✗ 存在失败"))


func _run_one(seed_value: int, faction_list: Array) -> Dictionary:
	# ---- 真实基准（返回 0 的桥，隔离桥差异，只比逻辑）----
	var g := CWGame.new()
	g.init(faction_list, seed_value)
	for pid in g.order:
		g.bridges[pid] = DummyBridge.new()
	var winner: int = await g.run_game()
	var g_hash: String = g.state_hash()
	var g_rng: int = g.rng.state
	var g_logs: Array = Array(g.logs)

	# ---- 迁移版 ----
	var shell := ElmShell.new()
	shell.bridge = DummyBridge.new()
	var mr := shell.run_full(seed_value, faction_list, CWTuning.new())
	var s: Dictionary = mr["state"]
	var s_hash: String = ElmGame.state_hash(s)

	var res := { "ok": true, "why": "", "diff_head": [], "winner": winner, "hash": s_hash, "steps": mr["steps"] }

	# 1) winner / win_kind / win_reason / round_no
	if int(s["winner"]) != winner:
		res["ok"] = false
		res["why"] = "winner %s vs %s" % [s["winner"], winner]
	if String(s["win_kind"]) != String(g.win_kind):
		res["ok"] = false
		res["why"] = "win_kind '%s' vs '%s'" % [s["win_kind"], g.win_kind]
	if String(s["win_reason"]) != String(g.win_reason):
		res["ok"] = false
		res["why"] = "win_reason '%s' vs '%s'" % [s["win_reason"], g.win_reason]
	if int(s["round_no"]) != g.round_no:
		res["ok"] = false
		res["why"] = "round_no %s vs %s" % [s["round_no"], g.round_no]

	# 2) state_hash（tiles/cells 逐格全量）
	if s_hash != g_hash:
		res["ok"] = false
		res["why"] = "state_hash 不等"
		var p1 := _first_diff_line(s, g)
		res["diff_head"] = p1

	# 3) rng_state
	if int(s["rng_state"]) != g_rng:
		res["ok"] = false
		res["why"] = "rng_state %s vs %s" % [s["rng_state"], g_rng]

	# 4) logs（数量 + 逐条）
	if s["logs"].size() != g_logs.size():
		res["ok"] = false
		res["why"] = "logs 数量 %d vs %d" % [s["logs"].size(), g_logs.size()]
		var mism := 0
		for i in mini(s["logs"].size(), g_logs.size()):
			if String(s["logs"][i]) != String(g_logs[i]):
				if mism < 3:
					res["diff_head"].append("log[%d] '%s' vs '%s'" % [i, s["logs"][i], g_logs[i]])
				mism += 1
		res["diff_head"].append("logs 前 %d 条中 %d 条不同" % [mini(s["logs"].size(), g_logs.size()), mism])
	else:
		for i in g_logs.size():
			if String(s["logs"][i]) != String(g_logs[i]):
				res["ok"] = false
				res["why"] = "log[%d] 不同" % i
				res["diff_head"].append("log[%d] '%s' vs '%s'" % [i, s["logs"][i], g_logs[i]])
				break

	g.dispose()
	return res


## 找出 tiles/cells 第一个不同的格子，帮助定位
func _first_diff_line(s: Dictionary, g: CWGame) -> Array:
	var out: Array = []
	for c in g.tiles:
		var a: Dictionary = g.tiles[c]
		var b: Dictionary = s["tiles"][c]
		if a["tissue"] != b["tissue"] or a["solid"] != b["solid"] or a["sticky"] != b["sticky"] \
				or a["newborn"] != b["newborn"] or a["store"] != b["store"] \
				or a["cards"] != b["cards"] or a["prod"] != b["prod"] or a["special"] != b["special"]:
			out.append("tile %s: %s vs %s" % [str(c), a, b])
			break
	for i in mini(g.cells.size(), s["cells"].size()):
		var a: Dictionary = g.cells[i]
		var b: Dictionary = s["cells"][i]
		if a["pid"] != b["pid"] or a["faction"] != b["faction"] or a["pos"] != b["pos"] \
				or a["itype"] != b["itype"] or a["ctype"] != b["ctype"] \
				or a["energy"] != b["energy"] or a["alive"] != b["alive"] \
				or a["marked"] != b["marked"] or a["hand"] != b["hand"] \
				or a["differentiated"] != b["differentiated"] \
				or a["escape_used"] != b["escape_used"] or a["invasive_used"] != b["invasive_used"] \
				or a["remodel_used"] != b["remodel_used"] or a["mutate_used"] != b["mutate_used"] \
				or a["unstable_used"] != b["unstable_used"] or a["antibody_used"] != b["antibody_used"] \
				or a["respawn_round"] != b["respawn_round"]:
			out.append("cell %d: %s vs %s" % [i, a, b])
			break
	return out
