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
	t_mech_colonize_supply()
	t_mech_infra_savings()
	t_mech_intent_eval()
	t_mech_intent_select()
	t_mech_bridge()
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


## —— 癌组织「能量杠杆」边际：定殖供给收益 ——
## 癌组织是双重杠杆：能量维度（块^0.3 递减）在这条测试验证；
## 扩张成本维度（癌格越多越便宜）在移动费用侧，留待下一条。
## 1) 纯杠杆形状 `tile_supply_marginal`：只转一格（细胞不动），手工转癌后
##    用引擎 anaerobic_gain_for 求和算供给差，与解析逐位对拍。
## 2) 定殖完整动作 `colonize_supply_gain`（含细胞移动）：真实对局采样
##    癌方 move 到健康格（普通定殖），快照→真执行→回滚，与引擎逐位对拍。
func t_mech_colonize_supply() -> void:
	print("[机制·癌方定殖能量边际]")
	## 1. 纯杠杆形状（合成局面）
	var g := bare_game()
	var ca := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, Vector2i(0, 0),
		-1, CWData.CancerType.SCLC, 500)
	g.cells.append(ca)
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)]:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	var to := Vector2i(0, 1)  ## 与块相邻的健康格
	check(g.tiles[to]["tissue"] == CWData.Tissue.HEALTHY, "to 初始为健康格")
	g.tiles[to]["tissue"] = CWData.Tissue.CANCER
	var after := 0
	for c in g.living_cells(CWData.Faction.CANCER):
		after += g.world.anaerobic_gain_for(c)
	g.tiles[to]["tissue"] = CWData.Tissue.HEALTHY
	var before := 0
	for c in g.living_cells(CWData.Faction.CANCER):
		before += g.world.anaerobic_gain_for(c)
	var want: int = after - before
	check(MechValue.tile_supply_marginal(g, to) == want,
		"纯边际：转一格供给变化 %d == 引擎 %d" % [
			MechValue.tile_supply_marginal(g, to), want])
	g.dispose()

	## 2. 定殖完整动作（真实对局采样）
	var checked := 0
	var bad := 0
	for si in 6:
		var g2 := make_game(4, 45001 + si)
		g2.sim_quiet = true
		for _step_i in 400:
			var req: Dictionary = await g2.pending()
			if req.is_empty():
				break
			var pid: int = req["pid"]
			if req["kind"] == "action" \
					and g2.player(pid)["faction"] == CWData.Faction.CANCER:
				for oi in req["options"].size():
					var opt: Dictionary = req["options"][oi]
					if opt["data"].get("act", "") != "move":
						continue
					var to2: Vector2i = opt["data"]["to"]
					## 只验普通健康格定殖：跳过已是癌格、特殊格（抽卡/收款干扰）
					if g2.is_cancerous(to2) \
							or g2.tile(to2)["special"] != CWData.Special.NONE:
						continue
					var src: Dictionary = {}
					for c in g2.living_cells(CWData.Faction.CANCER):
						if int(c["pid"]) == pid:
							src = c
					if src.is_empty():
						continue
					checked += 1
					var predicted_after: int = MechValue.total_supply(g2) \
						+ MechValue.colonize_supply_gain(g2, src, to2)
					var snap: Dictionary = g2.snapshot()
					var round_before: int = g2.round_no
					await g2.step(oi)
					## 守卫：细胞真的到了 to（move 成功）且没推进到 E 阶段
					var arrived := false
					for c in g2.living_cells(CWData.Faction.CANCER):
						if int(c["pid"]) == pid and c["pos"] == to2:
							arrived = true
					if not arrived or g2.round_no != round_before \
							or String(g2.flow.get("stage", "")) != "turn":
						g2.restore(snap)
						continue
					var actual_after: int = MechValue.total_supply(g2)
					g2.restore(snap)
					if predicted_after != actual_after:
						bad += 1
						check(false, "定殖 %s 解析 %d != 实测 %d" % [
							str(to2), predicted_after, actual_after])
			var idx: int = await g2.ask(req["pid"], req)
			await g2.step(idx)
		g2.dispose()
	check(checked >= 1, "至少采样到一次定殖（共 %d 次）" % checked)
	check(bad == 0, "定殖能量边际与引擎实测逐位一致（%d 次，%d 偏差）" % [
		checked, bad])


## —— 癌组织「扩张成本」杠杆（基础设施，递增曲线）——
## 与能量侧（块^0.3 递减）方向相反：癌格越多，周围健康格进入越便宜
## （癌格=便宜落点 0.2 vs 1.2；黑素瘤伪足：目标健康格邻接癌性组织 ≥3 → 0.5−0.1×(adj−3)）。
## 1) 合成：黑素瘤伪足门槛跨过 —— to 邻接 2 癌格，定殖后健康邻居 n 邻接变 3 → 打折。
## 2) 真实对局采样：癌方 move 进健康格，`colonize_infra_savings` 与引擎手工转癌后的成本差对拍。
func t_mech_infra_savings() -> void:
	print("[机制·癌组织扩张成本杠杆]")
	## 1. 合成：伪足门槛跨过
	var g := bare_game()
	var mel := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, Vector2i(0, 0),
		-1, CWData.CancerType.MELANOMA, 500)
	g.cells.append(mel)
	## to=(0,1)：邻接 (0,0),(1,0) 两癌格 → 进 to 无伪足（12）
	## n=(1,1)：邻接 (1,0),(2,0) 两癌格，定殖 to 后 +1=3 → 伪足（5）
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	var to := Vector2i(0, 1)
	check(g.tiles[to]["tissue"] == CWData.Tissue.HEALTHY, "to 初始为健康格")
	check(g.actions._cancer_move_cost(mel, to) == CWData.CANCER_MOVE_HEALTHY,
		"定殖前进 to = 1.2（adj=2 无伪足）")
	var n1 := Vector2i(1, 1)
	check(g.actions._cancer_move_cost(mel, n1) == CWData.CANCER_MOVE_HEALTHY,
		"定殖前进 n = 1.2（adj=2 无伪足）")
	## 引擎手工转癌算 want
	var before_to: int = g.actions._cancer_move_cost(mel, to)
	var before_n: int = g.actions._cancer_move_cost(mel, n1)
	g.tiles[to]["tissue"] = CWData.Tissue.CANCER
	var after_to: int = g.actions._cancer_move_cost(mel, to)
	var after_n: int = g.actions._cancer_move_cost(mel, n1)
	g.tiles[to]["tissue"] = CWData.Tissue.HEALTHY
	var want: int = (before_to - after_to) + (before_n - after_n)
	check(MechValue.tile_entry_cost(g, mel, to) == before_to,
		"tile_entry_cost(to) 包装引擎（%d）" % before_to)
	check(MechValue.colonize_infra_savings(g, mel, to) == want,
		"基础设施收益：定殖 to 解析 %d == 引擎 %d（进 to −%d、邻居 n 伪足 −%d）" % [
			MechValue.colonize_infra_savings(g, mel, to), want,
			before_to - after_to, before_n - after_n])
	g.dispose()

	## 2. 真实对局采样：任意癌种 move 进健康格
	var checked := 0
	var bad := 0
	for si in 6:
		var g2 := make_game(4, 46001 + si)
		g2.sim_quiet = true
		for _step_i in 400:
			var req: Dictionary = await g2.pending()
			if req.is_empty():
				break
			var pid: int = req["pid"]
			if req["kind"] == "action" \
					and g2.player(pid)["faction"] == CWData.Faction.CANCER:
				for oi in req["options"].size():
					var opt: Dictionary = req["options"][oi]
					if opt["data"].get("act", "") != "move":
						continue
					var to2: Vector2i = opt["data"]["to"]
					if g2.is_cancerous(to2) \
							or g2.tile(to2)["special"] != CWData.Special.NONE:
						continue
					var src: Dictionary = {}
					for c in g2.living_cells(CWData.Faction.CANCER):
						if int(c["pid"]) == pid:
							src = c
					if src.is_empty():
						continue
					checked += 1
					var got: int = MechValue.colonize_infra_savings(g2, src, to2)
					## 引擎手工转癌对拍（只读交易）
					var t: Dictionary = g2.tiles[to2]
					var saved: int = t["tissue"]
					var before_total: int = MechValue.tile_entry_cost(g2, src, to2)
					var before_nbs := 0
					var after_nbs := 0
					var nbs: Array = g2.neighbors(to2)
					for n in nbs:
						if g2.tiles[n]["tissue"] == CWData.Tissue.HEALTHY:
							before_nbs += MechValue.tile_entry_cost(g2, src, n)
					t["tissue"] = CWData.Tissue.CANCER
					var after_total: int = MechValue.tile_entry_cost(g2, src, to2)
					for n in nbs:
						if g2.tiles[n]["tissue"] == CWData.Tissue.HEALTHY:
							after_nbs += MechValue.tile_entry_cost(g2, src, n)
					t["tissue"] = saved
					var want2: int = (before_total - after_total) + (before_nbs - after_nbs)
					if got != want2:
						bad += 1
						check(false, "基础设施 %s 解析 %d != 引擎 %d" % [
							str(to2), got, want2])
			var idx: int = await g2.ask(req["pid"], req)
			await g2.step(idx)
		g2.dispose()
	check(checked >= 1, "至少采样到一次定殖（共 %d 次）" % checked)
	check(bad == 0, "基础设施收益与引擎逐位一致（%d 次，%d 偏差）" % [checked, bad])


## —— 意图评估器骨架 ——
## 意图 = 行动方的一串「迁移目标」（净化/定殖/攻击都由迁移触发）。
## `MechIntent.evaluate_path` 在引擎副本上按序执行路径，返回「做完之后的地图和能量」读数，
## 并复原真局面（评估不改动游戏）。验证：
## 1) 复原纯度：评估前后 state_hash 不变；
## 2) 读数与引擎一致：手工执行同一路径后，count_tissue / total_supply / 胜利进度逐一对上；
## 3) 非法路径：ok=false、执行步数对、真局面仍复原。
func t_mech_intent_eval() -> void:
	print("[意图·迁移路径评估]")
	var g := make_game(4, 47001)
	g.sim_quiet = true
	var path: Array = []
	var pid := -1
	for _i in 300:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		var p: int = req["pid"]
		if req["kind"] == "action" \
				and g.player(p)["faction"] == CWData.Faction.CANCER:
			for opt in req["options"]:
				if opt["data"].get("act", "") == "move" and path.size() < 2:
					path.append(opt["data"]["to"])
			pid = p
			break
		var idx: int = await g.ask(req["pid"], req)
		await g.step(idx)
	check(not path.is_empty() and pid >= 0, "找到癌方 action 边界与路径（%d 步）" % path.size())
	if path.is_empty():
		g.dispose()
		return
	var hash_before: String = g.state_hash()
	var intent := MechIntent.new()
	var m: Dictionary = await intent.evaluate_path(g, pid, path)
	check(g.state_hash() == hash_before, "评估后真局面复原（state_hash 不变）")

	## 引擎对拍：手工执行同一路径，直接读引擎值
	var snap: Dictionary = g.snapshot()
	var steps := 0
	for to in path:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		if int(req["pid"]) != pid:
			break
		var idx2 := -1
		for i in req["options"].size():
			var d: Dictionary = req["options"][i]["data"]
			if d.get("act", "") == "move" and d.get("to", Vector2i(-999, -999)) == to:
				idx2 = i
		if idx2 < 0:
			break
		await g.step(idx2)
		steps += 1
	var ct: int = g.count_tissue(CWData.Tissue.CANCER)
	var st: int = g.count_tissue(CWData.Tissue.SOLID)
	check(m["cancer_tiles"] == ct and m["solid_tiles"] == st,
		"地图读数与引擎一致（癌 %d 固化 %d）" % [ct, st])
	check(m["cancer_supply"] == MechValue.total_supply(g),
		"供给读数与引擎一致（%d）" % m["cancer_supply"])
	check(m["win_progress"] == ct + 2 * st,
		"胜利进度读数一致（%d）" % m["win_progress"])
	check(m["steps_done"] == steps,
		"执行步数与手工一致（%d/%d）" % [m["steps_done"], steps])
	g.restore(snap)

	## 非法路径（棋盘外目标）：ok=false、步数 0、真局面复原
	var m2: Dictionary = await intent.evaluate_path(g, pid, [Vector2i(99, 99)])
	check(m2["ok"] == false, "非法目标 → ok=false")
	check(m2["steps_done"] == 0, "非法目标 → 0 步")
	check(g.state_hash() == hash_before, "非法路径后真局面仍复原")
	g.dispose()


## —— 意图候选生成与选择（意图级规划闭环）——
## candidates：从当前 pending 的迁移选项生成 1 步候选路径。
## evaluate_candidates：全部评估（读数数组，评估后复原）。
## best_by：按注入的 scorer（metrics → float）选得分最高的候选。
## 验证：候选可执行、评估数与候选数一致、best 确为最大供给、全程复原。
func t_mech_intent_select() -> void:
	print("[意图·候选生成与选择]")
	var g := make_game(4, 47002)
	g.sim_quiet = true
	var pid := -1
	for _i in 300:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		var p: int = req["pid"]
		if req["kind"] == "action" \
				and g.player(p)["faction"] == CWData.Faction.CANCER:
			pid = p
			break
		var idx: int = await g.ask(req["pid"], req)
		await g.step(idx)
	check(pid >= 0, "找到癌方 action 边界")
	if pid < 0:
		g.dispose()
		return
	var intent := MechIntent.new()
	var hash_before: String = g.state_hash()
	var cands: Array = await intent.candidates(g, pid)
	check(cands.size() >= 1, "生成 >=1 个候选（%d）" % cands.size())
	var evals: Array = await intent.evaluate_candidates(g, pid)
	check(evals.size() == cands.size(), "评估数与候选数一致（%d/%d）" % [evals.size(), cands.size()])
	check(g.state_hash() == hash_before, "评估全部候选后真局面复原")
	var ok_all := true
	for e in evals:
		if not bool(e["metrics"]["ok"]):
			ok_all = false
	check(ok_all, "全部候选可执行")
	## best_by：按癌方供给选
	var best: Dictionary = await intent.best_by(g, pid,
		func(m: Dictionary) -> float: return float(m["cancer_supply"]))
	check(best.has("score"), "best 带 score")
	var max_supply := -1
	for e in evals:
		max_supply = maxi(max_supply, int(e["metrics"]["cancer_supply"]))
	check(int(best["metrics"]["cancer_supply"]) == max_supply,
		"best 是最大癌方供给（%d）" % max_supply)
	check(g.state_hash() == hash_before, "选择后真局面复原")
	g.dispose()


## —— 意图 AI 桥冒烟与确定性 ——
## MechBridge：action 用 best_by 选意图（癌/免各按自己的 scorer），其余回落启发式。
## 验证：癌方意图 AI 整局跑完、双方意图 AI 整局跑完、同种子同配置终局 state_hash 相同。
func t_mech_bridge() -> void:
	print("[桥·意图 AI 冒烟与确定性]")
	## 1. 癌方 MechBridge / 免疫启发式：整局跑完
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[4], 48001)
	g.sim_quiet = true
	for pid in g.order:
		var b: CWBridge
		if g.player(pid)["faction"] == CWData.Faction.CANCER:
			b = MechBridge.new()
		else:
			b = CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	await g.run_game()
	check(g.winner >= 0, "癌方意图 AI 整局跑完（winner=%d round=%d）" % [g.winner, g.round_no])
	g.dispose()
	## 2. 双方都 MechBridge：整局跑完
	var g2 := CWGame.new()
	g2.init(CWData.FACTION_ORDER[4], 48001)
	g2.sim_quiet = true
	for pid in g2.order:
		var b2: CWBridge = MechBridge.new()
		b2.game = g2
		g2.bridges[pid] = b2
	await g2.run_game()
	check(g2.winner >= 0, "双方意图 AI 整局跑完（winner=%d round=%d）" % [g2.winner, g2.round_no])
	g2.dispose()
	## 3. 确定性：同种子同配置 → 终局 state_hash 相同
	var h1: String = await _run_mech_hash(48002)
	var h2: String = await _run_mech_hash(48002)
	check(h1 == h2, "同种子同配置终局 state_hash 相同")


func _run_mech_hash(seed_value: int) -> String:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[4], seed_value)
	g.sim_quiet = true
	for pid in g.order:
		var b: CWBridge = MechBridge.new()
		b.game = g
		g.bridges[pid] = b
	await g.run_game()
	var h: String = g.state_hash()
	g.dispose()
	return h


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
