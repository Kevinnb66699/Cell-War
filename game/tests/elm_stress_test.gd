## elm_stress_test.gd —— 强化等价验证：多种子 × 多桥策略 × 2/4/6 人局
##
## Dummy 恒 0 只覆盖 idx=0 的决策路径；本测试用固定随机/最后一项等桥策略，
## 覆盖更多动作分支（抗体无目标、重塑、裂解、突变、自爆、复活选位……），
## 对真实 cw_* 与迁移 elm_* 做全对局对比（winner + state_hash + logs）。
## 桥按固定 seed 生成决策序列：真实、迁移各自 new 同 seed 的桥 -> 决策序列一致。
extends SceneTree


## 固定 seed 的桥：决策 = 在选项范围内随机
class RandomBridge:
	extends CWBridge
	var rng := RandomNumberGenerator.new()

	func ask(req: Dictionary) -> int:
		return rng.randi_range(0, req["options"].size() - 1)


## 固定 seed 的桥：决策 = 恒 0（Dummy）
class ZeroBridge:
	extends CWBridge

	func ask(_req: Dictionary) -> int:
		return 0


## 固定 seed 的桥：决策 = 最后一项
class LastBridge:
	extends CWBridge

	func ask(req: Dictionary) -> int:
		return req["options"].size() - 1


func _init():
	print("========================================")
	print("  强化等价验证：多种子 × 多桥 × 2/4/6 人局")
	print("========================================")
	await _run()
	quit()


func _run() -> void:
	var seeds: Array = [1, 42, 999, 20240326, 777]
	var bridge_makers := {
		"Zero": func() -> CWBridge: return ZeroBridge.new(),
		"Last": func() -> CWBridge: return LastBridge.new(),
		"Random": func() -> CWBridge: return RandomBridge.new(),
	}
	var pass_all := true
	var total := 0
	for n in [2, 4, 6]:
		var faction_list: Array = CWData.FACTION_ORDER[n]
		for seed in seeds:
			for bname in bridge_makers:
				var make: Callable = bridge_makers[bname]
				var r: Dictionary = await _run_one(seed, faction_list, n, bname, make)
				total += 1
				var line := "  %d 人局 seed=%d %-4s winner=%s hash=%s  %s" % [
					n, seed, bname, r["winner"], r["hash"],
					"✓" if r["ok"] else "✗ — " + r["why"]]
				print(line)
				if not r["ok"]:
					pass_all = false
					for d in r["diff_head"]:
						print("      " + d)
	print("========================================")
	print("  强化等价: %d/%d 通过  " % [total - (0 if pass_all else 0), total] + ("✓" if pass_all else "✗ 存在失败"))
	print("========================================")


func _run_one(seed_value: int, faction_list: Array, _n: int, bname: String,
		make: Callable) -> Dictionary:
	# ---- 真实 ----
	var g := CWGame.new()
	g.init(faction_list, seed_value)
	# 随机桥：所有玩家共享同一桥实例（单一决策序列）——迁移单桥同 seed 可对齐
	if bname == "Random":
		var shared := RandomBridge.new()
		shared.rng.seed = seed_value
		for pid in g.order:
			g.bridges[pid] = shared
	else:
		for pid in g.order:
			g.bridges[pid] = make.call()
	var winner: int = await g.run_game()
	var g_hash: String = g.state_hash()
	var g_logs: Array = Array(g.logs)

	# ---- 迁移（用同样的桥类，但桥对象各自 new）----
	var shell := ElmShell.new()
	var br: CWBridge = make.call()
	if bname == "Random":
		br.rng.seed = seed_value
	shell.bridge = br
	var mr := shell.run_full(seed_value, faction_list, CWTuning.new())
	var s: Dictionary = mr["state"]

	var res := { "ok": true, "why": "", "diff_head": [], "winner": winner, "hash": ElmGame.state_hash(s) }
	if int(s["winner"]) != winner:
		res["ok"] = false
		res["why"] = "winner %s vs %s" % [s["winner"], winner]
	if ElmGame.state_hash(s) != g_hash:
		res["ok"] = false
		res["why"] = "state_hash 不等"
		res["diff_head"] = _first_diff_line(s, g)
	if s["logs"].size() != g_logs.size():
		res["ok"] = false
		res["why"] = "logs 数量 %d vs %d" % [s["logs"].size(), g_logs.size()]
		for i in mini(s["logs"].size(), g_logs.size()):
			if String(s["logs"][i]) != String(g_logs[i]):
				if res["diff_head"].size() < 3:
					res["diff_head"].append("log[%d] '%s' vs '%s'" % [i, s["logs"][i], g_logs[i]])
	else:
		for i in g_logs.size():
			if String(s["logs"][i]) != String(g_logs[i]):
				res["ok"] = false
				res["why"] = "log[%d] 不同" % i
				res["diff_head"].append("log[%d] '%s' vs '%s'" % [i, s["logs"][i], g_logs[i]])
				break
	g.dispose()
	return res


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
				or a["marked"] != b["marked"] or a["respawn_round"] != b["respawn_round"]:
			out.append("cell %d: %s vs %s" % [i, a, b])
			break
	return out
