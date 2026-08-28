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


## 常备对照组：每一项都在回答「这块拆掉会怎样」，而不只是罗列候选。
## 想试新数值就照着加一个 CWTuning，不需要改引擎。
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

	out.append(CWTuning.recommended())

	# 封顶是防雪球的主稳定器：拆掉它癌方收入会滚到免疫的 20 倍
	var no_cap := CWTuning.recommended()
	no_cap.name = "推荐-去封顶"
	no_cap.anaerobic_cap = 0
	no_cap.aerobic_cap = 0
	out.append(no_cap)

	# 低保主要在 6 人局起作用（那里免疫供能贴着低保线）
	var no_floor := CWTuning.recommended()
	no_floor.name = "推荐-去低保"
	no_floor.anaerobic_floor = 0
	no_floor.aerobic_floor = 0
	out.append(no_floor)

	# 增生：封顶生效后地盘不再变成收入，它的作用只剩「细胞少时也能扩张」
	var no_pro := CWTuning.recommended()
	no_pro.name = "推荐-去增生"
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
		var s := ElmSession.new()
		s.init_game(CWData.FACTION_ORDER[n_players], BASE_SEED + gi, tune)
		var res := s.run_full()
		var w: int = res["winner"]
		if w == CWData.Faction.CANCER:
			cancer_wins += 1
		if String(res["win_kind"]).begins_with("limit_"):
			by_limit += 1
		rounds_sum += res["round_no"]
		cancerous_sum += s.count_tissue(CWData.Tissue.CANCER) \
			+ s.count_tissue(CWData.Tissue.SOLID)
		s.dispose()
	return {
		"cancer": cancer_wins, "rounds": float(rounds_sum) / GAMES, "by_limit": by_limit,
		"cancerous": float(cancerous_sum) / GAMES,
	}
