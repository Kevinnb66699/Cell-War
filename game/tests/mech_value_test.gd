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
	t_mech_purify_supply()
	t_mech_solidify()
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


## —— 免疫【净化】断供反事实 ——
## 免疫方主循环：踩癌格→转健康→癌方连通块缩/裂→断供。
## 解析用 `purify_supply_gain` 预测净化后的癌方总供给变化，
## 引擎实测：快照 → 真执行 move 选项 → 读跳后总供给 → 回滚。逐位对拍。
func t_mech_purify_supply() -> void:
	print("[机制·免疫净化断供]")
	var checked := 0
	var bad := 0
	for si in 6:
		var g := make_game(4, 44001 + si)
		g.sim_quiet = true
		for _step_i in 400:
			var req: Dictionary = await g.pending()
			if req.is_empty():
				break
			var pid: int = req["pid"]
			if req["kind"] == "action" \
					and g.player(pid)["faction"] == CWData.Faction.IMMUNE:
				for oi in req["options"].size():
					var opt: Dictionary = req["options"][oi]
					if opt["data"].get("act", "") != "move":
						continue
					var to: Vector2i = opt["data"]["to"]
					## 只验「迁入无细胞普通癌格 = 纯净化」：
					## 迁入有细胞癌格是攻击；固化癌组织（SOLID）免疫普通 move 不净化（T 裂解才转）；
					## 【骨样硬化】标记格免疫须停留一回合才净化（不立即净化）
					if g.tiles[to]["tissue"] != CWData.Tissue.CANCER \
							or not g.cells_at(to).is_empty() \
							or int(g.tiles[to].get("ossify_at", 0)) > 0:
						continue
					checked += 1
					var predicted_after: int = MechValue.total_supply(g) \
						+ MechValue.purify_supply_gain(g, to)
					var snap: Dictionary = g.snapshot()
					var round_before: int = g.round_no
					await g.step(oi)
					## 守卫：免疫必须真的到达 to（move 可能因能量/合法性失败没执行）
					var arrived := false
					for c in g.living_cells(CWData.Faction.IMMUNE):
						if int(c["pid"]) == pid and c["pos"] == to:
							arrived = true
					if not arrived:
						g.restore(snap)
						continue
					## 守卫：若 move 是全局最后一次行动，step 会一路推进到 E 阶段结算
					## （增生/侵蚀改癌布局），total_supply 就不是「纯净化后」了 —— 跳过这类 case
					if g.round_no != round_before \
							or String(g.flow.get("stage", "")) != "turn":
						g.restore(snap)
						continue
					var actual_after: int = MechValue.total_supply(g)
					var step_tissue: int = g.tiles[to]["tissue"]
					var step_im_ok: bool = g.living_cells(CWData.Faction.IMMUNE).size() > 0
					g.restore(snap)
					if predicted_after != actual_after:
						bad += 1
						check(false, "净化 %s 解析 %d != 实测 %d（预测前=%d, step 后 to tissue=%d）" % [
							str(to), predicted_after, actual_after,
							predicted_after - MechValue.purify_supply_gain(g, to), step_tissue])
			var idx: int = await g.ask(req["pid"], req)
			await g.step(idx)
		g.dispose()
	check(checked >= 1, "至少采样到一次净化（共 %d 次）" % checked)
	check(bad == 0, "净化断供反事实与引擎实测逐位一致（%d 次，%d 偏差）" % [
		checked, bad])


## —— 癌方【E-固化】单格生灭 ——
## 确定性过程：有癌细胞停留 → 每世界回合 +1.0（SOLIDIFY_STEP）；无细胞且计数>0 → −0.5。
## 计数到阈值（I 期 3.0 / II·III 期 2.0）即转固化癌组织，转后不再累计、SOLID 不衰减。
## 验证：手工构造「A 格有细胞停（solid=5）、B 格无人停（solid=15）」，
## 逐世界回合调用引擎 _solidify() + _decay()，与解析 solidify_after / decay_after 逐位对拍。
func t_mech_solidify() -> void:
	print("[机制·固化生灭]")
	var g := bare_game()
	var ca := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 500)
	g.cells.append(ca)
	var a: Dictionary = g.tiles[Vector2i(1, 0)]
	var b: Dictionary = g.tiles[Vector2i(0, 1)]
	a["tissue"] = CWData.Tissue.CANCER
	a["solid"] = 5
	b["tissue"] = CWData.Tissue.CANCER
	b["solid"] = 15
	var th: int = g.solidify_threshold()
	check(th == 30, "I 期固化阈值 30（实测 %d）" % th)

	var solid_ok := true
	var decay_ok := true
	var solidified_at := -1
	for r in 5:
		g.world._solidify()
		g.world._decay()
		var want_a: Dictionary = MechValue.solidify_after(5, r + 1, th)
		if int(a["solid"]) != int(want_a["solid"]):
			solid_ok = false
			check(false, "回合 %d：A 格 solid %d != 解析 %d" % [
				r + 1, int(a["solid"]), int(want_a["solid"])])
		var a_solidified: bool = int(a["tissue"]) == CWData.Tissue.SOLID
		if a_solidified != bool(want_a["solidified"]):
			solid_ok = false
			check(false, "回合 %d：A 格固化状态 %s != 解析 %s" % [
				r + 1, a_solidified, want_a["solidified"]])
		if a_solidified and solidified_at < 0:
			solidified_at = r + 1
		var want_b: int = MechValue.decay_after(15, r + 1)
		if int(b["solid"]) != want_b:
			decay_ok = false
			check(false, "回合 %d：B 格 solid %d != 解析 %d" % [
				r + 1, int(b["solid"]), want_b])
	check(solid_ok, "A 格逐回合计数/固化与解析一致（5 回合）")
	check(decay_ok, "B 格逐回合衰减与解析一致（5 回合）")
	check(solidified_at == 3, "A 格第 3 回合转固化（5+1.0×3=35 ≥ 30，实测第 %d 回合）" % solidified_at)
	## 固化后不再累计：第 4、5 回合 solid 应保持 35（引擎 _solidify 对 SOLID 直接 continue）
	check(int(a["solid"]) == 5 + CWData.SOLIDIFY_STEP * 3, "转固化后 solid 不再涨（%d）" % int(a["solid"]))
	check(int(b["solid"]) == 0, "B 格衰减到 0 不再衰减")
	## rounds_to_solidify：从 5 开始持续停留要几回合（阈值 30）
	check(MechValue.rounds_to_solidify(5, th) == 3, "rounds_to_solidify(5,30)=3")
	check(MechValue.rounds_to_solidify(25, th) == 1, "rounds_to_solidify(25,30)=1")
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
