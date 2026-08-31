## balance_sim.gd —— 平衡性批量模拟：AI 互搏 N 局，输出胜率与关键指标
##
## 运行：godot --headless --path game --script res://tests/balance_sim.gd
## 改配置直接改下面三个常量（GAMES 局数 / N_PLAYERS 人数 / BASE_SEED 起始种子）。
extends SceneTree

const GAMES := 100
const N_PLAYERS := 4
const BASE_SEED := 20260800


func _initialize() -> void:
	_run()


func _run() -> void:
	print("Cell War 平衡模拟：%d 局，%d 人局，启发式 AI 互搏" % [GAMES, N_PLAYERS])
	print("（66 卡 + 18 事件全实装、AI 会抽卡打牌 → 本结果为「有卡版」平衡，2026-08-29 起）")
	var wins := { CWData.Faction.IMMUNE: 0, CWData.Faction.CANCER: 0 }
	var kinds := {}
	var rounds_sum := 0
	var cancerous_sum := 0
	var memory_sum := 0
	var level_sum := 0
	var type_games := {}
	var type_wins := {}
	for t in CWData.CancerType.values():
		type_games[t] = 0
		type_wins[t] = 0

	for gi in GAMES:
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[N_PLAYERS], BASE_SEED + gi)
		for pid in g.order:
			var b := CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		var w: int = await g.run_game()
		wins[w] += 1
		kinds[g.win_kind] = kinds.get(g.win_kind, 0) + 1
		rounds_sum += g.round_no
		cancerous_sum += g.count_tissue(CWData.Tissue.CANCER) + g.count_tissue(CWData.Tissue.SOLID)
		memory_sum += g.memory
		level_sum += g.immune_level
		for p in g.players:
			if p["faction"] == CWData.Faction.CANCER:
				type_games[p["cancer_type"]] += 1
				if w == CWData.Faction.CANCER:
					type_wins[p["cancer_type"]] += 1
		g.dispose()
		if (gi + 1) % 10 == 0:
			print("  …%d/%d 局完成" % [gi + 1, GAMES])

	print("\n========== 结果 ==========")
	print("免疫胜 %d（%d%%）  癌症胜 %d（%d%%）" % [
		wins[CWData.Faction.IMMUNE], wins[CWData.Faction.IMMUNE] * 100 / GAMES,
		wins[CWData.Faction.CANCER], wins[CWData.Faction.CANCER] * 100 / GAMES])
	print("胜利方式分布：")
	var kind_names := {
		"immune_clear": "  免疫·全灭癌细胞（I 类即时）",
		"cancer_weighted": "  癌症·加权 2/3 占地（S 类）",
		"limit_cancer": "  癌症·30 回合 ≥1/3 占地",
		"limit_immune": "  免疫·30 回合守住 1/3 线",
	}
	for k in kinds.keys():
		print("%s：%d 局" % [kind_names.get(k, k), kinds[k]])
	print("平均：终局回合 %.1f｜终局癌性组织 %.1f 格（初始 %d，30 回合线 %d）｜抗原记忆 %.1f｜免疫等级 %.1f" % [
		float(rounds_sum) / GAMES, float(cancerous_sum) / GAMES,
		CWData.INIT_CANCER_TILES, CWData.LIMIT_CANCEROUS,
		float(memory_sum) / GAMES, float(level_sum) / GAMES + 1.0])
	print("癌细胞种类表现（该种类上场的对局中癌症方胜率）：")
	for t in CWData.CancerType.values():
		if type_games[t] == 0:
			continue
		print("  %-8s 上场 %2d 局，癌胜 %2d（%d%%）" % [
			CWData.CANCER_TYPE_NAMES[t], type_games[t], type_wins[t],
			type_wins[t] * 100 / type_games[t]])
	quit(0)
