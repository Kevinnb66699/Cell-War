## balance_variants.gd —— 平衡方案对比：多套旋钮 × 多种人数，输出癌症方胜率矩阵
##
## 运行：godot --headless --path game --script res://tests/balance_variants.gd
## 加新方案：在 _variants() 里加一个 CWTuning 配置即可，不需要改引擎。
##
## 为什么要按人数复查：【无氧呼吸】除以「连通块中癌细胞数量」，
## 导致癌方阵营总收入与人数无关（人越多每人越穷），而免疫方总收入随人数线性增长。
## 所以在 4 人局调平的数值，换成 2 人／6 人局会完全失衡。
extends SceneTree

const GAMES := 60
const PLAYER_COUNTS := [2, 4, 6]
const BASE_SEED := 20260900


func _variants() -> Array[CWTuning]:
	var out: Array[CWTuning] = []

	var base := CWTuning.new()
	base.name = "A 规则原文"
	out.append(base)

	# 团队 2026-08-26 提案：调高癌方收入 + 削免疫收入 + 癌组织向外增生
	var team := CWTuning.new()
	team.name = "B 团队案+增生3%"
	_apply_team(team)
	out.append(team)

	# 对称反馈方案：免疫收入也挂钩地盘（健康组织数），且双方都按己方细胞数均分。
	# 这样两边阵营总收入都与人数无关，人数缩放问题从根上消失；
	# 同时癌方扩张会削减免疫收入，形成与「免疫净化削减癌方收入」对等的反馈。
	# 对称反馈（免疫 0.1/格、癌方 0.5/格）+ 增生 4%：4 人局 50%、6 人局 46%。
	out.append(CWTuning.recommended())

	# 推荐方案左右各一档，便于看曲线陡不陡（增生率是最好用的细调旋钮）
	var lo := CWTuning.recommended()
	lo.name = "C− 增生3%"
	lo.proliferate_per_adjacent = 30
	out.append(lo)

	var hi := CWTuning.recommended()
	hi.name = "C+ 增生5%"
	hi.proliferate_per_adjacent = 50
	out.append(hi)

	return out


## 团队 2026-08-26 经济提案 + 增生 3%，作为以下各方案的共同基线
static func _apply_team(t: CWTuning) -> void:
	t.anaerobic_per_cancer = 4
	t.anaerobic_per_solid = 10
	t.aerobic_gain = [20, 25, 20, 20]
	t.proliferate_per_adjacent = 30


func _initialize() -> void:
	_run()


func _run() -> void:
	print("Cell War 平衡矩阵：每格 %d 局，启发式 AI 互搏，数字为癌症方胜率" % GAMES)
	print("（卡牌/世界事件未定义 → 均为「无卡无事件版」结果）\n")
	var header := "%-20s" % "方案"
	for n in PLAYER_COUNTS:
		header += "%14s" % ("%d人局" % n)
	print(header)
	print("-".repeat(20 + 14 * PLAYER_COUNTS.size()))
	for tune in _variants():
		var row := "%-20s" % tune.name
		for n in PLAYER_COUNTS:
			var r := await _run_variant(tune, n)
			# 括号内为平均终局世界回合数：越接近 30 说明对局越能打满、雪球越轻
			row += "%9d%% (%2.0f)" % [r["cancer"] * 100 / GAMES, r["rounds"]]
		print(row)
	print("\n括号内 = 平均终局世界回合（上限 30）。目标：三种人数都接近 50%，且回合数不要太短。")
	quit(0)


func _run_variant(tune: CWTuning, n_players: int) -> Dictionary:
	var cancer_wins := 0
	var rounds_sum := 0
	for gi in GAMES:
		var g := CWGame.new()
		g.tune = tune
		g.init(CWData.FACTION_ORDER[n_players], BASE_SEED + gi)
		for pid in g.order:
			var b := CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		var w: int = await g.run_game()
		if w == CWData.Faction.CANCER:
			cancer_wins += 1
		rounds_sum += g.round_no
		g.dispose()
	return { "cancer": cancer_wins, "rounds": float(rounds_sum) / GAMES }
