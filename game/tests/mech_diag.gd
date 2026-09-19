## mech_diag.gd —— 意图癌决策诊断：为什么「呆」
##
## 跑 N 局意图癌（MechBridge 同款决策逻辑）vs 普通免，对每个癌方 action 记录：
##   1. 选「不动」的占比 —— 呆的直接证据（1 步评估下移动即时收益 < 成本 → 频繁不动）；
##   2. scorer 三分量的典型量级 —— 谁主导决策（能量差是几百量级，供给/地盘是几十，量纲失衡？）；
##   3. 选中 move 相对当前局面的增量（供给 Δ / 地盘 Δ / 能量 Δ）。
##
## 运行：<godot> --headless --path game --script res://tests/mech_diag.gd -- games=8
extends SceneTree


class DiagBridge extends CWHeuristicBridge:
	var no_move := 0
	var moves := 0
	var total := 0
	var supply_delta := 0.0
	var progress_delta := 0.0
	var energy_delta := 0.0
	var cur_supply := 0.0
	var cur_progress := 0.0
	var cur_energy_diff := 0.0

	func ask(req: Dictionary) -> int:
		if req["kind"] == "action" \
				and game.player(req["pid"])["faction"] == CWData.Faction.CANCER:
			total += 1
			var intent := MechIntent.new()
			var best: Dictionary = await intent.best_by(game, req["pid"], MechBridge._cancer_score)
			## 当前读数（决策前的局面）
			var ct: int = game.count_tissue(CWData.Tissue.CANCER)
			var st: int = game.count_tissue(CWData.Tissue.SOLID)
			var ce := 0
			var ie := 0
			for c in game.living_cells(CWData.Faction.CANCER):
				ce += int(c["energy"])
			for c in game.living_cells(CWData.Faction.IMMUNE):
				ie += int(c["energy"])
			cur_supply = float(MechValue.total_supply(game))
			cur_progress = float(ct + 2 * st)
			cur_energy_diff = float(ce - ie)
			if best.has("path") and best["path"].size() > 0:
				moves += 1
				var m: Dictionary = best["metrics"]
				supply_delta += float(m["cancer_supply"]) - cur_supply
				progress_delta += float(m["win_progress"]) - cur_progress
				energy_delta += float(m["cancer_energy"]) - float(m["immune_energy"]) - cur_energy_diff
				var idx := -1
				for i in req["options"].size():
					var d: Dictionary = req["options"][i]["data"]
					if d.get("act", "") == "move" and d.get("to", Vector2i(-999, -999)) == best["path"][0]:
						idx = i
				if idx >= 0:
					return idx
			else:
				no_move += 1
		return await super.ask(req)


func _initialize() -> void:
	await _run()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var games_n: int = int(args.get("games", 8))
	var seed_base: int = int(args.get("seed", 60000))
	print("mech_diag: %d 局 意图癌 vs 普通免" % games_n)
	var stats := DiagBridge.new()
	for gi in games_n:
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[4], seed_base + gi)
		g.sim_quiet = true
		for pid in g.order:
			var b: CWBridge
			if g.player(pid)["faction"] == CWData.Faction.CANCER:
				b = stats          ## 同一只诊断桥（记录所有癌席的决策）
			else:
				b = CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		await g.run_game()
		g.dispose()
	var denom: float = maxf(stats.total, 1)
	print("癌方 action 总数: %d" % stats.total)
	print("选「不动」: %d（%.1f%%）　选 move: %d（%.1f%%）" % [
		stats.no_move, stats.no_move * 100.0 / denom,
		stats.moves, stats.moves * 100.0 / denom])
	print("选中 move 的平均增量: 供给 %+.2f / 地盘 %+.2f / 能量差 %+.2f" % [
		stats.supply_delta / maxf(stats.moves, 1),
		stats.progress_delta / maxf(stats.moves, 1),
		stats.energy_delta / maxf(stats.moves, 1)])
	print("决策点 scorer 三分量典型量级: 供给 ~%.0f, 地盘 ~%.0f, 能量差 ~%.0f" % [
		stats.cur_supply / denom, stats.cur_progress / denom, stats.cur_energy_diff / denom])
	quit(0)
