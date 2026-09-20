## mech_timeline.gd —— 单局进程时间线：平衡在哪个回合被打破
##
## 三组合各跑 N 局，每世界回合采样关键指标，输出：
##   1) 每局详细时间线（round: 癌格/固化/胜利进度/癌方供给/免疫等级/记忆/双方能量）；
##   2) 每局的「破点回合」：免疫升 II/III 级、首个固化癌组织、癌方胜利进度过半、能量反转；
##   3) 各组合破点回合的分布（哪一回合开始不可逆）。
##
## 运行：<godot> --headless --path game --script res://tests/mech_timeline.gd -- \
##       games=6 [players=4|6] [immune_ai=heu|cancer_ai=mech 单跑一组] [detail=1 每局全打时间线]
extends SceneTree


func _initialize() -> void:
	await _run()


func _sample(g: CWGame) -> Dictionary:
	var ct: int = g.count_tissue(CWData.Tissue.CANCER)
	var st: int = g.count_tissue(CWData.Tissue.SOLID)
	var ce := 0
	var ie := 0
	for c in g.living_cells(CWData.Faction.CANCER):
		ce += int(c["energy"])
	for c in g.living_cells(CWData.Faction.IMMUNE):
		ie += int(c["energy"])
	## 骨髓状态：健康骨髓数（免疫复活点）/ 癌化骨髓数（被踩）
	var healthy_marrows := 0
	var cancer_marrows := 0
	for m in CWData.MARROWS:
		var t: int = g.tiles[m]["tissue"]
		if t == CWData.Tissue.HEALTHY:
			healthy_marrows += 1
		elif t == CWData.Tissue.CANCER or t == CWData.Tissue.SOLID:
			cancer_marrows += 1
	## 场上存活免疫数
	var imm_alive: int = g.living_cells(CWData.Faction.IMMUNE).size()
	return {
		"round": g.round_no, "ct": ct, "st": st, "wp": ct + 2 * st,
		"supply": MechValue.total_supply(g),
		"level": g.immune_level, "mem": g.memory,
		"ce": ce, "ie": ie,
		"hmarrow": healthy_marrows, "cmarrow": cancer_marrows, "imm_alive": imm_alive,
	}


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var games_n: int = int(args.get("games", 6))
	var players: int = int(args.get("players", 4))
	var seed_base: int = int(args.get("seed", 70000))
	var detail: bool = args.get("detail", "0") == "1"
	var imm_arg: String = args.get("immune_ai", "")
	var can_arg: String = args.get("cancer_ai", "")
	var configs: Array
	if imm_arg != "" or can_arg != "":
		configs = [{ "name": "%s/%s" % [imm_arg, can_arg], "immune": imm_arg, "cancer": can_arg }]
	else:
		configs = [
			{ "name": "heu/mech", "cancer": "mech", "immune": "heu" },
			{ "name": "mech/heu", "cancer": "heu", "immune": "mech" },
			{ "name": "mech/mech", "cancer": "mech", "immune": "mech" },
		]
	print("mech_timeline: %d 局/组合, %d 人" % [games_n, players])
	for cfg in configs:
		print("########## %s (%d 人) ##########" % [cfg["name"], players])
		var break_rounds := {
			"imm_II": [], "imm_III": [], "first_solid": [], "wp_half": [], "energy_flip": [],
		}
		for gi in games_n:
			var g := CWGame.new()
			g.init(CWData.FACTION_ORDER[players], seed_base + gi)
			g.sim_quiet = true
			for pid in g.order:
				var fac: int = g.player(pid)["faction"]
				var which: String = cfg["cancer"] if fac == CWData.Faction.CANCER else cfg["immune"]
				var b: CWBridge = MechBridge.new() if (which == "mech" or which == "mev") else CWHeuristicBridge.new()
				if which == "mev": b.use_fit_eval = true
				b.game = g
				g.bridges[pid] = b
			## 驱动并逐回合采样
			var timeline: Array = []
			var last_round := -1
			var imm_II := -1
			var imm_III := -1
			var first_solid := -1
			var wp_half := -1
			var energy_flip := -1
			while true:
				var req: Dictionary = await g.pending()
				if req.is_empty():
					break
				if g.round_no != last_round:
					last_round = g.round_no
					var s := _sample(g)
					timeline.append(s)
					if s["level"] >= 1 and imm_II < 0:
						imm_II = s["round"]
					if s["level"] >= 2 and imm_III < 0:
						imm_III = s["round"]
					if s["st"] > 0 and first_solid < 0:
						first_solid = s["round"]
					if s["wp"] >= 45 and wp_half < 0:
						wp_half = s["round"]
					if s["ie"] > s["ce"] and energy_flip < 0:
						energy_flip = s["round"]
				var idx: int = await g.ask(req["pid"], req)
				await g.step(idx)
			var winner: int = g.winner
			var win_s: String = "癌" if winner == CWData.Faction.CANCER else ("免" if winner == CWData.Faction.IMMUNE else "平")
			print("  局 %d: %s胜（%d 回合） 破点：免疫II=%d 免疫III=%d 首固化=%d 癌进度过半=%d 能量反转=%d" % [
				gi, win_s, g.round_no, imm_II, imm_III, first_solid, wp_half, energy_flip])
			break_rounds["imm_II"].append(imm_II)
			break_rounds["imm_III"].append(imm_III)
			break_rounds["first_solid"].append(first_solid)
			break_rounds["wp_half"].append(wp_half)
			break_rounds["energy_flip"].append(energy_flip)
			if detail:
				var head := "    "
				for s in timeline:
					head += "r%d[癌%d固%d 进%d 供%d 级%d 忆%d 能%d/%d 髓%d/%d 免%d] " % [
						s["round"], s["ct"], s["st"], s["wp"], s["supply"],
						s["level"], s["mem"], s["ce"], s["ie"], s["hmarrow"], s["cmarrow"], s["imm_alive"]]
				print(head)
			g.dispose()
		## 汇总分布（只统计该组合里出现过的）
		for key in break_rounds:
			var vals: Array = break_rounds[key]
			var seen: Array = []
			for v in vals:
				if v >= 0 and not v in seen:
					seen.append(v)
			seen.sort()
			var cnt: int = vals.size() - vals.count(-1)
			if cnt > 0:
				print("  %s 出现 %d/%d 局，回合分布 %s" % [key, cnt, vals.size(), str(seen)])
	quit(0)
