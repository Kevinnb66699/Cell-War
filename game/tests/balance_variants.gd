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

	# 回答 Kevin 的问题：回合上限 20 还是 15？
	# 关注「限」列——被回合上限判定的对局占比。太低说明上限规则形同虚设。
	for limit in [30, 20, 15, 12]:
		var t := CWTuning.recommended()
		t.name = "上限%d回合" % limit
		t.limit_round = limit
		out.append(t)

	return out


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
			# 格式：癌胜率 (平均回合/被回合上限判定的局数)
			row += "%7d%% (%2.0f/限%2d)" % [
				r["cancer"] * 100 / GAMES, r["rounds"], r["by_limit"]]
		print(row)
	print("\n格式：癌胜率 (平均终局回合 / 由回合上限判定的局数，共 %d 局)" % GAMES)
	print("目标：癌胜率接近 50%；「限」不宜为 0（否则上限规则形同虚设）也不宜过高。")
	quit(0)


func _run_variant(tune: CWTuning, n_players: int) -> Dictionary:
	var cancer_wins := 0
	var rounds_sum := 0
	var by_limit := 0
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
		g.dispose()
	return {
		"cancer": cancer_wins, "rounds": float(rounds_sum) / GAMES, "by_limit": by_limit,
	}
