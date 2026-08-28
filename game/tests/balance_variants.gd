## balance_variants.gd —— 平衡方案对比：多套旋钮 × 多种人数，输出癌症方胜率矩阵
##
## 运行：godot --headless --path game --script res://tests/balance_variants.gd
## 加新方案：在 _variants() 里加一个 CWTuning 配置即可，不需要改引擎。
##
## 为什么要按人数复查：【无氧呼吸】除以「连通块中癌细胞数量」，
## 导致癌方阵营总收入与人数无关（人越多每人越穷），而免疫方总收入随人数线性增长。
## 所以在 4 人局调平的数值，换成 2 人／6 人局会完全失衡。
extends SceneTree

const GAMES := 150
const PLAYER_COUNTS := [2, 4, 6]
const BASE_SEED := 24400000


## 常备对照组：每一项都在回答「这块拿掉／加上会怎样」，而不只是罗列候选。
## 想试新数值就照着加一个 CWTuning，不需要改引擎。
##
## 2026-08-28：基线从已删除的 recommended() 换成 CWTuning.new()（= PRD）。
## PRD 本身不含低保与封顶，所以原来的「去封顶／去低保」在新基线上是空操作
## （跑出来会和「规则原文」一模一样），因此反过来问「加上会怎样」——
## 问的还是同一个问题：这个阻尼到底起多大作用。见 docs/平衡方案_PRD版.md 四·乙。
func _variants() -> Array[CWTuning]:
	var out: Array[CWTuning] = []

	var raw := CWTuning.new()
	raw.name = "规则原文"
	out.append(raw)

	# 原发灶是癌方能不能活过前 3 回合的唯一支柱：拆掉它，规则原文直接 0%
	var no_lesion := CWTuning.new()
	no_lesion.name = "规则原文-无原发灶"
	no_lesion.solid_at_cancer_spawn = false
	out.append(no_lesion)

	# 人数缩放：PRD 只有癌方按己方细胞数均分，免疫方不均分（《平衡测试报告》#29 复发）
	out.append(CWTuning.split_income())

	# 封顶防领先方滚雪球。PRD 去掉了它，本行是把它加回来看能不能压住癌方
	# 数值沿用旧 recommended() 标定过的 3.5——但那是在旧收入公式下标的，只是起点，不是已验证值
	var with_cap := CWTuning.new()
	with_cap.name = "规则原文+封顶"
	with_cap.anaerobic_cap = 35
	with_cap.aerobic_cap = 35
	out.append(with_cap)

	# 低保防落后方直接崩盘，主要在 6 人局起作用（那里免疫供能最薄）。数值同上，是起点不是定论
	var with_floor := CWTuning.new()
	with_floor.name = "规则原文+低保"
	with_floor.anaerobic_floor = 12
	with_floor.aerobic_floor = 19
	out.append(with_floor)

	# 增生让地盘能脱离癌细胞自行生长；PRD 默认开着（4%/相邻癌性组织），关掉看它值多少
	var no_pro := CWTuning.new()
	no_pro.name = "规则原文-无增生"
	no_pro.proliferate_per_adjacent = 0
	out.append(no_pro)

	return out


func _initialize() -> void:
	_run()


func _run() -> void:
	print("Cell War 平衡矩阵：每格 %d 局，启发式 AI 互搏，数字为癌症方胜率" % GAMES)
	print("（卡牌/世界事件未定义 → 均为「无卡无事件版」结果）\n")
	var header := "%-20s" % "方案"
	for n in PLAYER_COUNTS:
		header += "%22s" % ("%d人局" % n)
	print(header)
	print("-".repeat(20 + 22 * PLAYER_COUNTS.size()))
	for tune in _variants():
		var row := "%-20s" % tune.name
		for n in PLAYER_COUNTS:
			var r := await _run_variant(tune, n)
			# 格式：癌胜率 (平均回合/被回合上限判定的局数)
			row += "%5d%% %2.0f回合 限%2d 占%3.0f" % [
				r["cancer"] * 100 / GAMES, r["rounds"], r["by_limit"], r["cancerous"]]
		print(row)
	print("\n格式：癌胜率 (平均终局回合 / 由回合上限判定的局数，共 %d 局)" % GAMES)
	print("目标：癌胜率接近 50%；「限」不宜为 0（否则上限规则形同虚设）也不宜过高。")
	quit(0)


func _run_variant(tune: CWTuning, n_players: int) -> Dictionary:
	var cancer_wins := 0
	var rounds_sum := 0
	var by_limit := 0
	var cancerous_sum := 0
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
		if g.win_kind.begins_with("limit_"):
			by_limit += 1
		rounds_sum += g.round_no
		cancerous_sum += g.count_tissue(CWData.Tissue.CANCER) 			+ g.count_tissue(CWData.Tissue.SOLID)
		g.dispose()
	return {
		"cancer": cancer_wins, "rounds": float(rounds_sum) / GAMES, "by_limit": by_limit,
		"cancerous": float(cancerous_sum) / GAMES,
	}
