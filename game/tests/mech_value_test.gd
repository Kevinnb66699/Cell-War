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
	t_mech_sclc_jump()
	t_mech_attack_chain()
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


## —— 小细胞肺癌【转移】跳块收益反事实（L0/L1）——
## 用户点名的核心机制：跳走成两个连通块以获得更多总能量供给。
## 解析模型用 `total_supply + sclc_jump_supply_gain` 预测「跳后总供给」，
## 引擎实测：快照 → 真实执行 jump 选项 → 读跳后总供给 → 回滚。两者必须逐位一致 ——
## 这证明「解析组件能算引擎查询算不了的反事实，且与引擎行为相符」。
## 钉癌种保证局里有 SCLC；只验证落点为普通格（无骨髓/核心等特殊组织的抽卡/收款干扰）。
func t_mech_sclc_jump() -> void:
	print("[机制·小细胞跳块收益]")
	var jump_checked := 0
	var jump_bad := 0
	for si in 6:
		var g := CWGame.new()
		g.tune.cancer_types = [CWData.CancerType.SCLC, CWData.CancerType.SCLC]
		g.init(CWData.FACTION_ORDER[4], 42001 + si)
		g.sim_quiet = true
		for pid in g.order:
			var b := CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		for _step_i in 400:
			var req: Dictionary = await g.pending()
			if req.is_empty():
				break
			var pid: int = req["pid"]
			if req["kind"] == "action" \
					and g.player(pid)["faction"] == CWData.Faction.CANCER:
				for oi in req["options"].size():
					var opt: Dictionary = req["options"][oi]
					if opt["data"].get("act", "") != "jump":
						continue
					var to: Vector2i = opt["data"]["to"]
					## 只验普通格落点：避免骨髓/核心在 step 里抽卡/收款引入中途询问
					if g.tile(to)["special"] != CWData.Special.NONE:
						continue
					var src: Dictionary = _sclc_of_pid(g, pid, to)
					if src.is_empty():
						continue
					jump_checked += 1
					var predicted_after: int = MechValue.total_supply(g) \
						+ MechValue.sclc_jump_supply_gain(g, src, to)
					var snap: Dictionary = g.snapshot()
					await g.step(oi)
					var actual_after: int = MechValue.total_supply(g)
					g.restore(snap)
					if predicted_after != actual_after:
						jump_bad += 1
						check(false, "跳块至 %s 解析 %d != 实测 %d" % [
							str(to), predicted_after, actual_after])
			var idx: int = await g.ask(req["pid"], req)
			await g.step(idx)
		g.dispose()
	check(jump_checked >= 1, "至少采样到一次跳选项（共 %d 次）" % jump_checked)
	check(jump_bad == 0, "跳块收益反事实与引擎实测逐位一致（%d 次，%d 偏差）" % [
		jump_checked, jump_bad])


## —— L1：免疫攻击真实结算与解析模型逐面对拍 ——
## 手工构造「免疫在 (0,0)、癌细胞在 (1,0) 癌格」局面，用 rig_rng 钉住攻击骰的每一面，
## 真实执行迁移（触发攻击），验证：
##   · 目标能量损失 == MechValue.attack_face(face).target
##   · 攻击者能量损失 == 迁移费 10 + 反弹 attack_face(face).self_loss（fail 才有）
##   · 攻击者弹回原格
## 再跑 4000 次真实随机攻击，统计均值 ≈ 25/3（大数定律验证期望）。
func t_mech_attack_chain() -> void:
	print("[L1·攻击真实结算]")
	var g := bare_game()
	var im := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1, 500)
	var ca := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 500)
	g.cells.append(im)
	g.cells.append(ca)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER

	## 1. 逐面钉骰验证
	for face in range(1, 7):
		im["energy"] = 500
		ca["energy"] = 500
		im["pos"] = Vector2i.ZERO
		im["attacks_used"] = 0
		var e0: int = im["energy"]
		var c0: int = ca["energy"]
		_rig_next(g, 6, [face])
		await g.actions._do_move(im, Vector2i(1, 0), 0)
		var f: Dictionary = MechValue.attack_face(face)
		check(ca["energy"] == c0 - int(f["target"]),
			"骰面 %d：目标损 %d" % [face, f["target"]])
		check(im["energy"] == e0 - 10 - int(f["self_loss"]),
			"骰面 %d：免疫损 %d（迁移10 + 反弹%d）" % [face, 10 + int(f["self_loss"]), f["self_loss"]])
		check(im["pos"] == Vector2i.ZERO, "骰面 %d：免疫弹回原格" % face)

	## 2. 真实随机 4000 次，均值收敛到 25/3
	var total := 0
	for _i in 4000:
		im["energy"] = 500
		ca["energy"] = 500
		im["pos"] = Vector2i.ZERO
		im["attacks_used"] = 0
		await g.actions._do_move(im, Vector2i(1, 0), 0)
		total += 500 - int(ca["energy"])
	var mean := total / 4000.0
	check(absf(mean - 25.0 / 3.0) < 0.5,
		"真实攻击均值 %f ≈ 25/3（4000 次）" % mean)
	g.dispose()


## —— 测试助手：rig_rng 钉骰 ——
const RIG := preload("res://tests/rig_rng.gd")
var _rig: Object

func _rig_next(g: CWGame, sides: int, want: Array) -> void:
	if _rig == null or not (g.rng == _rig):
		var r := RIG.new()
		r.inner = g.rng
		g.rng = r
		_rig = r
	for w in want:
		assert(int(w) >= 1 and int(w) <= sides)
		g.rng.queue.append(int(w))


func bare_game() -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 1)
	g.setup.build_board()
	return g


## 该席位中与落点 to 相距 5 格（一跳）的存活 SCLC；没有则返回空字典。
func _sclc_of_pid(g: CWGame, pid: int, to: Vector2i) -> Dictionary:
	for cell in g.living_cells(CWData.Faction.CANCER):
		if int(cell["pid"]) == pid \
				and int(cell["ctype"]) == CWData.CancerType.SCLC \
				and CWData.hex_dist(cell["pos"], to) == CWData.METASTASIS_RANGE:
			return cell
	return {}


## 建一个带启发式桥的对局（不跑流程），用于读引擎常量/判定。
func make_game(n_players: int, seed_value: int) -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[n_players], seed_value)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	return g
