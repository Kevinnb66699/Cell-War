## mech_strength.gd —— AI 组合强度对局（任意队 vs 任意队）
##
## 免疫/癌两队可各自指定 AI：heu（启发式）/ mc（扁平蒙特卡洛）/ mcts（UCT）/ mech（意图级）。
## 默认跑四组基准（heu/heu, heu/mech, mech/heu, mech/mech）；
## 给了 immune_ai + cancer_ai 就跑单一组合。可选存回放（写 user://replays，主菜单「回放」可看）。
##
## 运行：
##   <godot> --headless --path game --script res://tests/mech_strength.gd -- \
##       games=8 immune_ai=mech cancer_ai=mc save_replays=1
##   start=<偏移>：并发分片用 —— 每个 worker 拿不相交的 game_id 段（seed_base + start + gi），
##   同配置多进程各跑一段再合并，种子不撞、可复现。
## 种子：每个 game_id 用 seed_base + start + gi 派生，同配置同 game_id 可复现。
extends SceneTree


const AI_TYPES := ["heu", "mc", "mcts", "mech"]


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
	var start: int = int(args.get("start", 0))
	var save_replays: bool = args.get("save_replays", "0") == "1"
	print("mech_strength: %d 局 %d 人（种子基 %d + start %d）save_replays=%s" % [
		games_n, players, seed_base, start, save_replays])

	var configs: Array
	var imm_arg: String = args.get("immune_ai", "")
	var can_arg: String = args.get("cancer_ai", "")
	if imm_arg != "" or can_arg != "":
		if imm_arg == "" or can_arg == "" or not imm_arg in AI_TYPES or not can_arg in AI_TYPES:
			print("!! immune_ai/cancer_ai 必须成对给且 ∈ %s" % str(AI_TYPES))
			quit(2)
			return
		configs = [{ "name": "%s/%s" % [imm_arg, can_arg], "immune": imm_arg, "cancer": can_arg }]
	else:
		configs = [
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
			g.init(CWData.FACTION_ORDER[players], seed_base + start + gi)
			g.sim_quiet = true
			g.record_replay = save_replays   ## 存回放才录（MC 推演不录，见 CWGame.ask 头注）
			for pid in g.order:
				var fac: int = g.player(pid)["faction"]
				var which: String = cfg["cancer"] if fac == CWData.Faction.CANCER else cfg["immune"]
				var b: CWBridge = _make_bridge(which, g)
				g.bridges[pid] = b
			await g.run_game()
			if save_replays:
				var tape: Dictionary = CWReplay.of(g)
				var path: String = CWReplay.save(tape)
				if path != "":
					print("  [replay] %s game_%04d → %s" % [cfg["name"], gi, path])
			if g.winner == CWData.Faction.CANCER:
				cancer_wins += 1
			elif g.winner == CWData.Faction.IMMUNE:
				immune_wins += 1
			rounds_sum += g.round_no
			g.dispose()
		print("== %-12s 癌 %2d / 免 %2d / 平 %2d / 平均 %.1f 回合" % [
			cfg["name"], cancer_wins, immune_wins,
			games_n - cancer_wins - immune_wins, rounds_sum / float(games_n)])
	quit(0)


func _make_bridge(kind: String, g: CWGame) -> CWBridge:
	var b: CWBridge
	match kind:
		"mc":
			var mc := CWMonteCarloBridge.new()
			mc.rollouts = 2
			mc.horizon = 40
			mc.max_sim_steps = 192     ## 对齐 UI「较强」档预算
			b = mc
		"mcts":
			var mcts := CWMCTSBridge.new()
			mcts.iterations = 60
			mcts.horizon = 8
			mcts.max_sim_steps = 256   ## 轻预算（对齐 nn_sanity 用的档）
			b = mcts
		"mech":
			b = MechBridge.new()
		_:
			b = CWHeuristicBridge.new()
	b.game = g
	return b
