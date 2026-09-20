## mech_strength.gd —— 意图 AI 强度对局（只打三种组合）
##
## 2026-09-20 定：其余 AI（mc/mcts/普通对普通）对意图 AI 的评估没意义，不再跑。
## 只打三种（意图 = MechBridge，普通 = CWHeuristicBridge）：
##   heu/mech   普通免 vs 意图癌  ← 意图癌弱项
##   mech/heu   意图免 vs 普通癌  ← 意图免强项
##   mech/mech  意图癌 vs 意图免  ← 意图对意图
##   mev = MechBridge + 数据拟合位置估值（MechValue.position_eval，2026-09-20 体检产物）
##
## 运行：
##   <godot> --headless --path game --script res://tests/mech_strength.gd -- \
##       games=8 save_replays=1
##   immune_ai/cancer_ai=heu|mech 可指定单跑某一种（start= 并发分片，种子基 seed + start + gi）。
## 种子：同配置同 game_id 可复现。
extends SceneTree


const AI_TYPES := ["heu", "mech", "mev", "mel", "abs"]


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
			{ "name": "heu/mech", "cancer": "mech", "immune": "heu" },
			{ "name": "mech/heu", "cancer": "heu", "immune": "mech" },
			{ "name": "mech/mech", "cancer": "mech", "immune": "mech" },
		]
	for cfg in configs:
		var cancer_wins := 0
		var immune_wins := 0
		var rounds_sum := 0
		var win_kinds := {}   ## win_kind → 次数（击杀赢 immune_clear / 拖回合 limit_* / 加权 cancer_weighted / 投降）
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
			var wk := String(g.win_kind)
			win_kinds[wk] = int(win_kinds.get(wk, 0)) + 1
			g.dispose()
		print("== %-12s 癌 %2d / 免 %2d / 平 %2d / 平均 %.1f 回合  [win_kind %s]" % [
			cfg["name"], cancer_wins, immune_wins,
			games_n - cancer_wins - immune_wins, rounds_sum / float(games_n),
			str(win_kinds)])
	quit(0)


func _make_bridge(kind: String, g: CWGame) -> CWBridge:
	var b: CWBridge
	match kind:
		"mech":
			b = MechBridge.new()
		"mev":
			var mb := MechBridge.new()
			mb.use_fit_eval = true
			MechBridge._fit_linear_on = false
			b = mb
		"abs":
			var ab := MechBridge.new()
			ab.use_search = true
			ab.use_fit_eval = true
			MechBridge._fit_linear_on = true
			b = ab
		"mel":
			var mb2 := MechBridge.new()
			mb2.use_fit_eval = true
			MechBridge._fit_linear_on = true
			b = mb2
		_:
			b = CWHeuristicBridge.new()
	b.game = g
	return b
