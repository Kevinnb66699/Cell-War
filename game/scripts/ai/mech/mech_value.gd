## mech_value.gd —— 机制估值：单操作/单卡的解析期望价值（纯函数静态层）
##
## 定位（对齐 2026-09 讨论）：
##   · 目标 = 练训练 + 研究平衡，不是做公平对战的强 AI → 允许解析先验喂给模型；
##   · 整局不可数学分析，但**单个操作/单卡**的期望价值可以纯分析估算；
##   · 这些解析估值 = 平衡研究的直接产出（能量/地盘当量表），也是训练的先验特征/奖励塑形；
##   · 本模块只做「机制→期望」的封闭计算，**不读 UI、不持有状态、不推进引擎**。
##
## 能量单位：与引擎一致，**十分位整数**（10 = 1.0 能量）。期望值允许浮点。
##
## ⚠ 判定口径必须与引擎 CWActions.base_verdict 一致（attacker 为空时的基础判定）：
##   d6 → 1,2 fail；3,4,5 success；6 crit。带技能/事件修正的真实攻击链由 L1 测试
##   （快照→step→读结算）与引擎对拍，不在这里复制整套修正。
class_name MechValue
extends RefCounted


## —— 免疫【攻击】——

## 基础判定：d6 骰面 → "fail"/"success"/"crit"。
## 口径 = CWActions.base_verdict(r, {})（无技能修饰时）。
static func attack_verdict(r: int) -> String:
	return "crit" if r == 6 else ("fail" if r <= 2 else "success")


## 单骰面结算（十分位整数）：{ verdict, target = 对方损失, self_loss = 攻击者自损 }
## fail：目标无损，攻击者被反弹自损 COUNTER_DMG_ON_FAIL；
## success：目标损 ATTACK_DMG_SUCCESS；crit：目标损 ATTACK_DMG_CRIT。
static func attack_face(r: int) -> Dictionary:
	var v := attack_verdict(r)
	var target := 0
	var self_loss := 0
	if v == "fail":
		self_loss = CWData.COUNTER_DMG_ON_FAIL
	elif v == "crit":
		target = CWData.ATTACK_DMG_CRIT
	else:
		target = CWData.ATTACK_DMG_SUCCESS
	return { "verdict": v, "target": target, "self_loss": self_loss }


## 期望值（浮点十分位）：{ target, self_loss }
##   target = (3×ATTACK_DMG_SUCCESS + 1×ATTACK_DMG_CRIT)/6 = 25/3 ≈ 8.3333
##   self_loss = (2×COUNTER_DMG_ON_FAIL)/6 = 5/3 ≈ 1.6667
static func attack_ev() -> Dictionary:
	var t := 0.0
	var s := 0.0
	for r in range(1, 7):
		var f := attack_face(r)
		t += f["target"]
		s += f["self_loss"]
	return { "target": t / 6.0, "self_loss": s / 6.0 }


## —— 癌方【E-无氧呼吸】连通块供给 ——
##
## 核心机制（PRD 2026-09-12 + issue #43）：能量按**连通块**算，不是按总面积。
##   pool = (块内癌组织数^0.3 × coef + 全图固化数 × solid_bonus) × 分期增益   （块池，浮点十分位）
##   gain = round(pool × k(块内癌细胞数) / 100 ÷ 块内癌细胞数)      （k = 80/100/120）
##   每细胞兜底 anaerobic_floor（2.0）
## 分期增益 = `CWData.ANAEROBIC_STAGE_MUL_BY_STAGE`（环境恶化，issue #56：II 期 ×1.2、III 期 ×1.5），
## 位置照抄引擎的 `CWWorld._stage_boost()`：乘在**池子**上，k / 均分 / 四舍五入 / 兜底 2.0 都排在它之后。
## 对齐 cw_world._anaerobic_pool / _split_share / anaerobic_gain_for（默认规则下逐位一致）。
## ⚠ **这份镜像不会自己跟着引擎走**：引擎每改一次无氧口径，这里就要同改一次 —— issue #56 第一版
## 只改了引擎，从肿瘤 II 期起两边差 20% / 50%，而 `t_mech_anaerobic` 的三局 60 步都跨不到第 6 世界回合，
## 对拍全绿地放它过去（改判：那条测试现在额外钉 round_no = 6 / 11 两档）。
## 组件拆开是为了能算「假如块变了」的反事实（小细胞跳块 / 断供 / 连块）。

## 块池（浮点十分位）。coef/exp < 0 时按人数取（四人 2.0 / 六人 2.8）。
## `overrides`：反事实用的 tissue 覆盖（coord → Tissue），如「假设 to 已转癌」。
## `solid_override`：全图固化数的反事实修正（如净化掉一块固化 → −1）；-1 = 用引擎当前值。
static func block_pool(g: CWGame, block: Array, overrides: Dictionary = {}, solid_override: int = -1) -> float:
	var coef: int = g.tune.anaerobic_block_coef
	if coef < 0:
		coef = CWData.anaerobic_block_coef(g.order.size())
	var exp_pct: int = g.tune.anaerobic_block_exp
	if exp_pct < 0:
		exp_pct = CWData.anaerobic_block_exp(g.order.size())
	if coef > 0:
		var plain := 0
		for c in block:
			var tissue: int = int(overrides.get(c, g.tiles[c]["tissue"]))
			if tissue == CWData.Tissue.CANCER:
				plain += 1
		var exp_term := pow(float(plain), exp_pct / 100.0) if plain > 0 else 0.0
		var solid: int = g.count_tissue(CWData.Tissue.SOLID) if solid_override < 0 else solid_override
		return _stage_boost(g, exp_term * float(coef) + float(solid * g.tune.anaerobic_solid_bonus))
	## 退回线性式（coef == 0 对照档）
	var pool := 0.0
	for c in block:
		var tissue: int = int(overrides.get(c, g.tiles[c]["tissue"]))
		pool += g.tune.anaerobic_per_solid \
			if tissue == CWData.Tissue.SOLID else g.tune.anaerobic_per_cancer
	return _stage_boost(g, pool)


## 【E-无氧呼吸】的**环境恶化增益**（issue #56）：II 期 ×1.2、III 期 ×1.5，乘在池子上、不取整。
## 逐位镜像 `CWWorld._stage_boost()` —— 连 coef == 0 的线性对照档也照吃这一刀，引擎那边也是这么写的。
static func _stage_boost(g: CWGame, pool: float) -> float:
	return pool * CWData.ANAEROBIC_STAGE_MUL_BY_STAGE[g.tumor_stage()] / 100.0


## 块内存活的癌细胞数（对齐 anaerobic_gain_for 的口径：living_cells 过滤）。
static func block_cell_count(g: CWGame, block: Array) -> int:
	var members := {}
	for c in block:
		members[c] = true
	var count := 0
	for cell in g.living_cells(CWData.Faction.CANCER):
		if members.has(cell["pos"]):
			count += 1
	return count


## 块池均分给块内每个癌细胞的份额（十分位整数，含 k 系数 / 兜底 / 封顶）。
static func block_share(g: CWGame, block: Array, count: int, overrides: Dictionary = {}, solid_override: int = -1) -> int:
	var n := maxi(count, 1)
	var pool := block_pool(g, block, overrides, solid_override)
	var scaled := pool * CWData.anaerobic_cells_k(n) / 100.0
	var gain: int = int(round(scaled / float(n))) if g.tune.anaerobic_split else int(round(scaled))
	return g.tune.clamp_income(gain, g.tune.anaerobic_floor, g.tune.anaerobic_cap)


## 单个癌细胞的该回合无氧收入（十分位整数），含瓦伯格/GLUT1 加成。
## 与 cw_world.anaerobic_gain_for 逐位一致（默认规则下）。
static func cell_income(g: CWGame, cell: Dictionary) -> int:
	return cell_income_layout(g, _current_cancer_tiles(g),
		g.living_cells(CWData.Faction.CANCER), cell)


## —— 布局版：给定「癌性格集合 + 癌细胞列表」计算供给 ——
## 引擎的 blocks_of / anaerobic_gain_for 只能算当前局面；这里把块计算参数化为
## 任意布局，才能做反事实（小细胞跳块 / 断供 / 连块 / 净化）。当前局面只是特例。

## 当前癌性组织格集合（CANCER + SOLID，与 is_cancerous 同口径）。
static func _current_cancer_tiles(g: CWGame) -> Dictionary:
	var out := {}
	for c in g.tiles.keys():
		if g.is_cancerous(c):
			out[c] = true
	return out


## 给定癌性格集合的连通块划分（BFS；块集合与遍历顺序无关）。
static func _blocks_of_layout(g: CWGame, cancer_tiles: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	for c in cancer_tiles.keys():
		if seen.has(c):
			continue
		var block: Array[Vector2i] = []
		var queue: Array[Vector2i] = [c]
		seen[c] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			block.append(cur)
			for n in g.neighbors(cur):
				if cancer_tiles.has(n) and not seen.has(n):
					seen[n] = true
					queue.append(n)
		out.append(block)
	return out


## 给定布局下某癌细胞的份额（十分位，含瓦伯格/GLUT1）。
static func cell_income_layout(g: CWGame, cancer_tiles: Dictionary, cells: Array, cell: Dictionary, overrides: Dictionary = {}, solid_override: int = -1) -> int:
	for block in _blocks_of_layout(g, cancer_tiles):
		if not block.has(cell["pos"]):
			continue
		var count := 0
		for other in cells:
			if block.has(other["pos"]):
				count += 1
		var gain := block_share(g, block, maxi(count, 1), overrides, solid_override)
		if cell["ctype"] == CWData.CancerType.SCLC and g.type_ability_on(cell):
			gain = int(ceil(gain * CWData.WARBURG_PERCENT / 100.0))
		return gain + _glut_bonus(g, cell)
	return 0


## 当前局面下癌方总无氧供给（全部存活癌细胞的份额之和）。
static func total_supply(g: CWGame) -> int:
	return total_supply_layout(g, _current_cancer_tiles(g),
		g.living_cells(CWData.Faction.CANCER))


## 给定布局下的癌方总无氧供给。
static func total_supply_layout(g: CWGame, cancer_tiles: Dictionary, cells: Array, overrides: Dictionary = {}, solid_override: int = -1) -> int:
	var total := 0
	for cell in cells:
		total += cell_income_layout(g, cancer_tiles, cells, cell, overrides, solid_override)
	return total


## 免疫【净化】的反事实断供（十分位整数）：假设 to 被净化成健康组织，
## 重算癌方总供给，返回增量（通常为负 = 免疫断供）。to 须为癌性组织。
## 净化掉固化癌组织（T 细胞裂解）时同时修正全图固化数。
static func purify_supply_gain(g: CWGame, to: Vector2i) -> int:
	var tissue: int = int(g.tiles[to]["tissue"])
	if tissue != CWData.Tissue.CANCER and tissue != CWData.Tissue.SOLID:
		return 0
	var tiles2 := _current_cancer_tiles(g)
	tiles2.erase(to)
	var solid_override := -1
	if tissue == CWData.Tissue.SOLID:
		solid_override = g.count_tissue(CWData.Tissue.SOLID) - 1
	return total_supply_layout(g, tiles2,
		g.living_cells(CWData.Faction.CANCER), {}, solid_override) - total_supply(g)


## 小细胞肺癌【转移】跳块的反事实收益（十分位整数）：
## 假设 cell 跃迁到 to（to 为健康则定殖转癌），重算癌方总供给，返回增量。
## 可为负（跳去断供 / 并入小块的收益小于让原块分食的损失）。
## ⚠ 跳块 = 「迁 5 格的定殖」，逻辑与 `colonize_supply_gain` 完全相同，这里只是别名。
static func sclc_jump_supply_gain(g: CWGame, cell: Dictionary, to: Vector2i) -> int:
	return colonize_supply_gain(g, cell, to)


## —— 癌组织「能量杠杆」边际 ——
## 癌组织是双重杠杆：能量维度（块^0.3 递减收益）在这里；
## 扩张成本维度（癌格越多后续移动越便宜）在移动费用侧（下一条）。

## 纯杠杆形状：只把 to 转癌（细胞不动），癌方总供给变化 = 这块地的能量边际。
## 与谁去踩无关 —— 是布局本身给「再占一格」的边际供给（递减曲线 ^0.3 的离散化）。
static func tile_supply_marginal(g: CWGame, to: Vector2i) -> int:
	if g.is_cancerous(to):
		return 0
	var tiles2 := _current_cancer_tiles(g)
	tiles2[to] = true
	var overrides := { to: CWData.Tissue.CANCER }
	return total_supply_layout(g, tiles2,
		g.living_cells(CWData.Faction.CANCER), overrides) - total_supply(g)


## 癌方【定殖】完整动作的反事实能量边际：cell 迁移到 to（健康则转癌），
## 含细胞移动改变块内细胞数（k 系数/均分）的影响。
## 普通迁移、小细胞跳块共用这一份。
static func colonize_supply_gain(g: CWGame, cell: Dictionary, to: Vector2i) -> int:
	var tiles2 := _current_cancer_tiles(g)
	var overrides := {}
	if g.tile(to)["tissue"] == CWData.Tissue.HEALTHY:
		tiles2[to] = true
		overrides[to] = CWData.Tissue.CANCER
	var cells2: Array = []
	for c in g.living_cells(CWData.Faction.CANCER):
		var dup: Dictionary = c.duplicate()
		if int(dup["id"]) == int(cell["id"]):
			dup["pos"] = to
		cells2.append(dup)
	return total_supply_layout(g, tiles2, cells2, overrides) - total_supply(g)


## —— 癌组织「扩张成本」杠杆（基础设施，递增曲线）——
## 与能量侧（块^0.3 递减）方向相反：癌格越多，周围健康格进入越便宜 ——
## 癌格=便宜落点（0.2 vs 1.2）；黑素瘤【伪足穿透】按目标健康格相邻癌性组织数打折
## （≥3 时 0.5−0.1×(adj−3)，钻得越深越便宜）。两条相反边际曲线的交点即癌方自然扩张规模。

## 布局层面的进入成本（位置无关）：只读目标格组织 + 邻接数 + cell 类型。
## **包装引擎 `_cancer_move_cost`**（公式权威在引擎，这里不复制第二份）。
## 不含卡牌/黏液修饰（那是 CWCost 层）；黏液加费在成本层的修饰里。
static func tile_entry_cost(g: CWGame, cell: Dictionary, dest: Vector2i) -> int:
	return int(g.actions._cancer_move_cost(cell, dest))


## 定殖 to 的反事实基础设施收益：to 转癌后，癌方「进入 to 及其健康邻居」的成本面改善。
##   = (进 to 成本差) + Σ_{健康邻居 n} max(0, 进 n 成本差)   （伪足打折在 n 侧体现）
## 实现：只读交易 —— 临时把 to 设癌、用引擎查询重算成本面、立即恢复原状。
static func colonize_infra_savings(g: CWGame, cell: Dictionary, to: Vector2i) -> int:
	if g.is_cancerous(to):
		return 0
	var t: Dictionary = g.tiles[to]
	var saved_tissue: int = t["tissue"]
	var before_to: int = tile_entry_cost(g, cell, to)
	var before_nbs := 0
	var after_nbs := 0
	var nbs: Array = g.neighbors(to)
	for n in nbs:
		if g.tiles[n]["tissue"] == CWData.Tissue.HEALTHY:
			before_nbs += tile_entry_cost(g, cell, n)
	t["tissue"] = CWData.Tissue.CANCER
	var after_to: int = tile_entry_cost(g, cell, to)
	for n in nbs:
		if g.tiles[n]["tissue"] == CWData.Tissue.HEALTHY:
			after_nbs += tile_entry_cost(g, cell, n)
	t["tissue"] = saved_tissue
	return (before_to - after_to) + (before_nbs - after_nbs)


static func _glut_bonus(g: CWGame, cell: Dictionary) -> int:
	if g.has_skill(cell, "GLUT1高表达"):
		return CWData.GLUT1_BONUS[CWCardData.cancer_phase(g.round_no)]
	return 0


## —— 癌方【E-固化】单格生灭（确定性）——
##
## 核心机制（PRD + cw_world._solidify/raise_solid）：
##   · 有癌细胞停留的（非新生、非血管）癌组织：每世界回合 solid += SOLIDIFY_STEP（+1.0）
##   · **计数只增不减**（2026-09-19 issue #64 删掉衰减那一步）：没人停留的格子计数原样留着
##   · solid 达阈值（I 期 3.0 / II·III 期 2.0，CWGame.solidify_threshold）→ 转固化癌组织
##   · 转固化后：_solidify 不再累计（tissue 非 CANCER）
## 纯确定性，无随机 —— 这是 AI 判断「蹲几回合能造一个复活点/容错」的解析基础。

## 当前固化阈值（对齐 CWGame.solidify_threshold，按肿瘤分期分档）。
static func solidify_threshold(g: CWGame) -> int:
	return int(g.solidify_threshold())


## 持续停留 rounds 个世界回合后的计数。返回 { solid, solidified }：
## 一旦到阈值即转固化（solidified=true），此后不再累计（solid 停在转固那一刻的值）。
static func solidify_after(solid: int, rounds: int, threshold: int) -> Dictionary:
	var s := solid
	var solidified := s >= threshold
	for i in rounds:
		if solidified:
			break
		s += CWData.SOLIDIFY_STEP
		if s >= threshold:
			solidified = true
	return { "solid": s, "solidified": solidified }


## 从当前计数到固化所需的持续停留回合数（按给定阈值；跨分期阈值变化需调用方分段）。
static func rounds_to_solidify(solid: int, threshold: int) -> int:
	if solid >= threshold:
		return 0
	return ceili(float(threshold - solid) / float(CWData.SOLIDIFY_STEP))
