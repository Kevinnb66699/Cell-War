## mech_strength.gd —— 意图 AI（MechBridge）vs 启发式 AI 的强度对局
##
## 四种配置各跑 N 局，报「癌胜 / 免胜 / 平均回合」：
##   heu/heu    启发式 vs 启发式（现有基线）
##   heu/mech   免疫启发式 vs 癌方意图 AI
##   mech/heu   免疫意图 AI vs 癌方启发式
##   mech/mech  双方意图 AI
##
## 运行：<godot> --headless --path game --script res://tests/mech_strength.gd -- games=12 players=4
## 种子：每个 game_id 用 49000 + game_id 派生，同配置同 game_id 可复现。
extends SceneTree


func _initialize() -> void:
	await _run()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var games_n: int = int(args.get("games", 12))
	var players: int = int(args.get("players", 4))
	var seed_base: int = int(args.get("seed", 49000))
	print("mech_strength: %d 局/配置 %d 人（种子基 %d）" % [games_n, players, seed_base])

	var configs := [
		{ "name": "heu/heu", "cancer": "heu", "immune": "heu" },
		{ "name": "heu/mech", "cancer": "mech", "immune": "heu" },
		{ "name": "mech/heu", "cancer": "heu", "immune": "mech" },
		{ "name": "mech/mech", "cancer": "mech", "immune": "mech" },
	]
	for cfg in configs:
		var cancer_wins := 0
		var immune_wins := 0
		var rounds_sum := 0
		for gi in games_n:
			var g := CWGame.new()
			g.init(CWData.FACTION_ORDER[players], seed_base + gi)
			g.sim_quiet = true
			for pid in g.order:
				var fac: int = g.player(pid)["faction"]
				var which: String = cfg["cancer"] if fac == CWData.Faction.CANCER else cfg["immune"]
				var b: CWBridge = MechBridge.new() if which == "mech" else CWHeuristicBridge.new()
				b.game = g
				g.bridges[pid] = b
			await g.run_game()
			if g.winner == CWData.Faction.CANCER:
				cancer_wins += 1
			elif g.winner == CWData.Faction.IMMUNE:
				immune_wins += 1
			rounds_sum += g.round_no
			g.dispose()
		print("== %-10s 癌 %2d / 免 %2d / 平 %2d / 平均 %.1f 回合" % [
			cfg["name"], cancer_wins, immune_wins,
			games_n - cancer_wins - immune_wins, rounds_sum / float(games_n)])
	quit(0)
