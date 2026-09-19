## mech_rule_sim.gd —— 模拟「癌击杀胜」规则的价值（不碰引擎）
##
## 引擎当前只有免疫侧击杀胜（immune_clear：癌细胞全灭+无复活固化癌组织），
## **没有**对称的癌侧击杀胜（免疫全灭+无可复活点 → 癌胜）。
## 本脚本跑意图癌 vs 普通免，在引擎判定之外，每个世界回合采样检测：
##   「无存活免疫细胞 且 无健康骨髓（可复活点）」→ 记为潜在癌击杀胜点。
## 统计：这类时刻出现的局数、以及若按此规则判胜，意图癌胜率变化。
##
## 运行：<godot> --headless --path game --script res://tests/mech_rule_sim.gd -- games=20
extends SceneTree


func _initialize() -> void:
	await _run()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var games_n: int = int(args.get("games", 20))
	var seed_base: int = int(args.get("seed", 80000))
	print("mech_rule_sim: %d 局 意图癌 vs 普通免（模拟癌击杀胜规则）" % games_n)
	var engine_wins := { "cancer": 0, "immune": 0, "limit/other": 0 }
	var kill_points := 0        ## 检测到「免疫全灭+无健康骨髓」的局数（本应癌击杀胜）
	var kill_first_round := -1  ## 最早出现该时刻的回合
	for gi in games_n:
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[4], seed_base + gi)
		g.sim_quiet = true
		for pid in g.order:
			var b: CWBridge = MechBridge.new() if g.player(pid)["faction"] == CWData.Faction.CANCER \
				else CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		var had_kill_point := false
		var last_round := -1
		while true:
			var req: Dictionary = await g.pending()
			if req.is_empty():
				break
			if g.round_no != last_round:
				last_round = g.round_no
				## 每回合开始（E 阶段刚结算完）：免疫全灭 + 无健康骨髓？
				var imm_alive: int = g.living_cells(CWData.Faction.IMMUNE).size()
				var healthy_marrows := 0
				for m in CWData.MARROWS:
					if g.tiles[m]["tissue"] == CWData.Tissue.HEALTHY:
						healthy_marrows += 1
				if imm_alive == 0 and healthy_marrows == 0:
					had_kill_point = true
					if kill_first_round < 0:
						kill_first_round = g.round_no
			var idx: int = await g.ask(req["pid"], req)
			await g.step(idx)
		if g.winner == CWData.Faction.CANCER:
			engine_wins["cancer"] += 1
		elif g.winner == CWData.Faction.IMMUNE:
			engine_wins["immune"] += 1
		else:
			engine_wins["limit/other"] += 1
		if had_kill_point:
			kill_points += 1
		print("  局 %d: 引擎=%s（%s） 癌击杀胜点=%s%s" % [
			gi, "癌" if g.winner == CWData.Faction.CANCER else "免",
			g.win_kind, "有" if had_kill_point else "无",
			"" if kill_first_round < 0 else "（最早第 %d 回合）" % kill_first_round])
		g.dispose()
	var total: float = float(games_n)
	print("引擎胜率：癌 %d（%.0f%%）/ 免 %d（%.0f%%）" % [
		engine_wins["cancer"], engine_wins["cancer"] * 100.0 / total,
		engine_wins["immune"], engine_wins["immune"] * 100.0 / total])
	print("检测到「免疫全灭+无健康骨髓」（本应癌击杀胜）：%d/%d 局（%.0f%%）" % [
		kill_points, games_n, kill_points * 100.0 / total])
	if kill_first_round >= 0:
		print("最早击杀胜点回合：%d" % kill_first_round)
	quit(0)
