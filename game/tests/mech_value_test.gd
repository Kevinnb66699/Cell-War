## mech_value_test.gd —— 机制估值模块 MechValue 的独立测试
##
## 定位：研究/训练用的「单操作解析期望估值」的 L0 正确性测试。
## 与主套件 headless_test.gd 独立（研究性质的新模块，快速迭代、不污染主套件）。
##
## 运行：
##   <godot> --headless --path game --script res://tests/mech_value_test.gd
##   退出码：0 = 全过，1 = 有失败。
##
## 本期覆盖（L0：机制模型本身）：
##   · 免疫【攻击】的骰面判定（fail/success/crit）与引擎 CWActions.base_verdict 逐位一致；
##   · 单骰面伤害量对照 CWData 常量；
##   · 期望值（十分位整数）的闭式解，并与逐面枚举对拍。
##   ⚠ 本期只测「基础判定」（无技能/事件修正，attacker 空）。带修正的真实攻击链留给 L1
##     （快照→step→读结算，与引擎实际结算对拍）——那才是证明「解析模型没脱离引擎」的关键。
extends SceneTree

var fails := 0
var checks := 0


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("  ok  %s" % name)
	else:
		fails += 1
		print("  FAIL %s" % name)


func _initialize() -> void:
	_run()


func _run() -> void:
	t_mech_attack_ev()
	t_mech_anaerobic()
	print("\n%d 项检查，%d 失败" % [checks, fails])
	quit(1 if fails > 0 else 0)


## —— 免疫【攻击】期望值（L0）——
func t_mech_attack_ev() -> void:
	print("[机制·免疫攻击期望]")
	var g := make_game(4, 99)
	## 1. 单骰面判定：与引擎 base_verdict（attacker 空 = 纯判定）逐位一致
	var expected := ["fail", "fail", "success", "success", "success", "crit"]
	for r in range(1, 7):
		var verdict: String = MechValue.attack_verdict(r)
		var engine: String = g.actions.base_verdict(r)
		check(verdict == expected[r - 1], "骰面 %d → %s" % [r, verdict])
		check(verdict == engine, "骰面 %d 判定与引擎一致（引擎 %s）" % [r, engine])
		check(MechValue.attack_face(r)["verdict"] == verdict, "attack_face(%d) 判定一致" % r)

	## 2. 单骰面伤害量（十分位）对照 CWData 常量
	var f1: Dictionary = MechValue.attack_face(1)
	check(f1["target"] == 0 and f1["self_loss"] == CWData.COUNTER_DMG_ON_FAIL,
		"fail：目标 0、自损 %d" % CWData.COUNTER_DMG_ON_FAIL)
	check(MechValue.attack_face(3)["target"] == CWData.ATTACK_DMG_SUCCESS,
		"success：目标损 %d" % CWData.ATTACK_DMG_SUCCESS)
	check(MechValue.attack_face(6)["target"] == CWData.ATTACK_DMG_CRIT,
		"crit：目标损 %d" % CWData.ATTACK_DMG_CRIT)

	## 3. 期望值（十分位）：target = (3×10 + 1×20)/6 = 25/3 ≈ 8.3333
	##                              self_loss = (2×5)/6 = 5/3 ≈ 1.6667
	var ev: Dictionary = MechValue.attack_ev()
	check(is_equal_approx(ev["target"], 25.0 / 3.0),
		"目标期望 %f == 25/3" % ev["target"])
	check(is_equal_approx(ev["self_loss"], 5.0 / 3.0),
		"自损期望 %f == 5/3" % ev["self_loss"])

	## 4. 与逐面枚举对拍
	var t_sum := 0.0
	var s_sum := 0.0
	for r in range(1, 7):
		var f: Dictionary = MechValue.attack_face(r)
		t_sum += f["target"]
		s_sum += f["self_loss"]
	check(is_equal_approx(ev["target"], t_sum / 6.0), "目标期望 = 六面均值")
	check(is_equal_approx(ev["self_loss"], s_sum / 6.0), "自损期望 = 六面均值")
	g.dispose()


## —— 癌方【E-无氧呼吸】连通块供给（L0）——
## 在真实对局推进过程中逐步采样：每个 pending 边界，对每个存活癌细胞的
## 解析收入 `MechValue.cell_income` 与引擎 `game.world.anaerobic_gain_for` 逐位对拍。
## 引擎查询只算当前状态；解析模型拆成 block_pool / block_share / cell_income 组件，
## 未来才能做「假如块变了」（小细胞跳块 / 断供）的反事实估算。
func t_mech_anaerobic() -> void:
	print("[机制·无氧呼吸供给]")
	var total := 0
	var bad := 0
	for si in 3:
		var g := make_game(4, 41001 + si)
		g.sim_quiet = true
		for _step in 60:
			var req: Dictionary = await g.pending()
			if req.is_empty():
				break
			var cells: Array = g.living_cells(CWData.Faction.CANCER)
			total += cells.size()
			for cell in cells:
				var want: int = g.world.anaerobic_gain_for(cell)
				var got: int = MechValue.cell_income(g, cell)
				if got != want:
					bad += 1
					check(false, "癌细胞 %d 解析供给 %d != 引擎 %d（pos=%s）" % [
						cell["id"], got, want, str(cell["pos"])])
			var idx: int = await g.ask(req["pid"], req)
			await g.step(idx)
		g.dispose()
	check(total > 50, "采样到 %d 个癌细胞·步 供给" % total)
	check(bad == 0, "解析供给与引擎逐位一致（%d 采样，%d 偏差）" % [total, bad])


## 建一个带启发式桥的对局（不跑流程），用于读引擎常量/判定。
func make_game(n_players: int, seed_value: int) -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[n_players], seed_value)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	return g
