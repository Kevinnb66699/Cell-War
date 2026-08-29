## cw_card_fx.gd —— 卡牌效果：**立即结算**的那一批（事件卡 + 无修饰的即时技能）
##
## 这里只住「结算完就完事」的卡。剩下的三类各有前置，实现前别塞进来：
##   - 修饰/触发类 35 张（"下一次攻击…"、"本回合…"）→ 等修饰器框架（PRD差异对照 5.1 #26，
##     和世界事件共用同一套）
##   - 永久技能 22 张 → 等装备位（#27）
##   - 要玩家中途做选择的事件（趋化募集/效应细胞浸润/炎症风暴/全身免疫动员/基因组不稳定
##     第20回合起的二择…）→ 等打牌交互定型后走 bridge.ask
##
## 三条口径，写新卡前先读：
##   ① 扣能量一律走 game.immune_hit / cancer_hit（五步管线），卡牌伤害不算「攻击」——
##      树突减半、巨噬吸血都不触发（那两条 PRD 明写"攻击"），但【标记】×2 与
##      【囊性护甲】照吃（它们管的是"损失"）。
##   ② 卡牌造成的组织转化**不给抗原记忆**（说明 #18 的口径外推），
##      除非卡面明写（目前只有【局部吞噬】）。
##   ③ 癌症卡的分期数值查 CWCardData.cancer_phase(game.round_no)，
##      永久技能将来也按当前回合取值（PRD：不在装备时锁定）。
class_name CWCardFx
extends RefCounted

var game: CWGame


# ============ 入口 1：事件卡（抽到立即结算，CWCards.draw 调用）============

## 返回 false = 这张事件还没实现（调用方如实记日志，别装作生效了）。
func resolve_event(cell: Dictionary, card: String) -> bool:
	match card:
		"急性炎症反应":
			_gain(cell, 15)
		"抗原摄取":
			var n := 2 if _adjacent_cancerous(cell["pos"]) else 1
			game.gain_memory(n)
			game.log_msg("　【抗原摄取】免疫方 +%d 抗原记忆（%d）" % [n, game.memory])
		"抗原呈递增强":
			game.gain_memory(3)
			game.log_msg("　【抗原呈递增强】免疫方 +3 抗原记忆（%d）" % game.memory)
		"局部吞噬":
			_local_phagocytosis(cell)
		"骨髓动员":
			_marrow_mobilization()
		"克隆扩增":
			for c in game.living_cells(CWData.Faction.IMMUNE):
				c["energy"] += _amp(10)
			_gain(cell, 5, "额外")
			game.log_msg("　【克隆扩增】所有免疫细胞 +%s 能量" % CWData.fmt(_amp(10)))
		"IFN-γ释放":
			_ifn_burst(cell, cell["pos"])
		"全身性免疫清除":
			_systemic_clearance()
		"糖酵解爆发":
			## 立刻结算一次无氧呼吸，不影响 E 阶段的正常结算
			var g := game.world.anaerobic_gain_for(cell)
			_gain(cell, g, "糖酵解爆发")
		"克隆增殖":
			_clonal_growth(cell)
		"肿瘤血管生成":
			var v: int = _amp([10, 20, 25][_phase()])
			for c in game.living_cells(CWData.Faction.CANCER):
				c["energy"] += v
			_gain(cell, 5, "额外")
			game.log_msg("　【肿瘤血管生成】所有癌细胞 +%s 能量" % CWData.fmt(v))
		_:
			return false
	return true


# ============ 入口 2：即时技能（从手牌打出，CWActions 调用）============

## 把当前能打的手牌摊成顶层选项（流程状态机约定：所有决定都是顶层选项）。
## 带目标的卡一目标一选项；随机结算的卡一张一选项。打出不花能量（PRD 没有出牌费）。
func hand_options(cell: Dictionary, opts: Array) -> void:
	## 【细胞应激】本回合打牌收费；付不起就一张也打不出（选项直接不出现）
	if _stress_fee() > 0 and not game.can_pay(cell, _stress_fee()):
		return
	for card in cell["hand"]:
		match card:
			"基质降解":
				for n in CWData.neighbors(cell["pos"]):
					if game.tile(n)["tissue"] == CWData.Tissue.SOLID:
						opts.append(_opt(card, "→%s" % str(n), { "to": n }))
			"抗体依赖细胞毒作用":
				for t in _cancer_cells_in_range(cell["pos"], 2):
					if _adjacent_healthy(t["pos"]):
						opts.append(_opt(card, "→%s" % game.cell_name(t), { "cid": t["id"] }))
			"交叉呈递":
				var r := 4 if cell["itype"] == CWData.ImmuneType.DENDRITIC else 2
				for t in _cancer_cells_in_range(cell["pos"], r):
					if not t["marked"]:
						opts.append(_opt(card, "→%s" % game.cell_name(t), { "cid": t["id"] }))
			"溶酶体强化":
				if not _adjacent_plain_cancer_empty(cell["pos"]).is_empty():
					opts.append(_opt(card, ""))
			"IFN-γ高峰":
				for t in game.living_cells(CWData.Faction.IMMUNE):
					if _ifn_has_effect(t["pos"]):
						opts.append(_opt(card, "→%s" % game.cell_name(t), { "cid": t["id"] }))
			"免疫增援":
				for t in game.living_cells(CWData.Faction.IMMUNE):
					if t["pid"] != cell["pid"] and not _empty_healthy_in_range(t["pos"], 2).is_empty():
						opts.append(_opt(card, "→%s 附近" % game.cell_name(t), { "cid": t["id"] }))
			"乳酸酸化":
				for n in CWData.neighbors(cell["pos"]):
					for t in game.cells_at(n, CWData.Faction.IMMUNE):
						opts.append(_opt(card, "→%s" % game.cell_name(t), { "cid": t["id"] }))
			"基质硬化":
				var cands: Array[Vector2i] = [cell["pos"]]
				cands.append_array(CWData.neighbors(cell["pos"]))
				for c in cands:
					var t: Dictionary = game.tile(c)
					if t["tissue"] == CWData.Tissue.CANCER and not t["newborn"]:
						opts.append(_opt(card, "→%s" % str(c), { "to": c }))
			"肿瘤细胞募集":
				var r: int = [2, 3, 3][_phase()]
				if _empty_cancerous_in_range(cell["pos"], r).is_empty():
					continue
				for t in game.living_cells(CWData.Faction.CANCER):
					if t["pid"] != cell["pid"]:
						opts.append(_opt(card, "→%s" % game.cell_name(t), { "cid": t["id"] }))
			_:
				pass   ## 修饰类/永久/待交互的卡：还打不出去，选项不出现


## 打出。效果结算完成后弃置（【即时技能】：结算后弃置）。
func play(cell: Dictionary, data: Dictionary) -> void:
	var card: String = data["card"]
	if not card in cell["hand"]:
		return
	game.log_msg("%s 打出【%s】" % [game.cell_name(cell), card])
	var fee := _stress_fee()
	if fee > 0:
		if not game.pay(cell, fee):
			return   ## 选项层已按费用把过关，这里只是兜底
		game.log_msg("　【细胞应激】支付 %s 能量" % CWData.fmt(fee))
	match card:
		"基质降解":
			var t: Dictionary = game.tile(data["to"])
			t["tissue"] = CWData.Tissue.CANCER
			t["solid"] = 0
			game.log_msg("　%s 由固化癌组织转为癌组织（计数清零）" % str(data["to"]))
		"抗体依赖细胞毒作用":
			var base := 15 if cell["itype"] == CWData.ImmuneType.B_CELL else 10
			game.immune_hit(game.cells[data["cid"]], _amp(base), cell, false)
		"交叉呈递":
			var target: Dictionary = game.cells[data["cid"]]
			target["marked"] = true
			game.log_msg("　%s 获得【标记】" % game.cell_name(target))
		"溶酶体强化":
			_lysosome(cell)
		"IFN-γ高峰":
			_ifn_burst(cell, game.cells[data["cid"]]["pos"])
		"免疫增援":
			_reinforce(cell, game.cells[data["cid"]])
		"乳酸酸化":
			_lactic_acid(cell, game.cells[data["cid"]])
		"基质硬化":
			_stroma_harden(data["to"])
		"肿瘤细胞募集":
			_recruit(cell, game.cells[data["cid"]])
		_:
			game.log_msg("　（该卡效果未实现，未弃置）")
			return
	cell["hand"].erase(card)


# ============ 各卡的结算 ============

## 【局部吞噬】随机 1 格相邻、无细胞占据的普通癌组织 → 健康，+1 记忆（卡面明写才给记忆）
func _local_phagocytosis(cell: Dictionary) -> void:
	var cands: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER and game.cells_at(n).is_empty():
			cands.append(n)
	if cands.is_empty():
		game.log_msg("　【局部吞噬】相邻没有可转化的癌组织，落空")
		return
	var c: Vector2i = cands[game.rng.randi_range(0, cands.size() - 1)]
	_to_healthy(c)
	game.gain_memory(1)
	game.log_msg("　【局部吞噬】%s 转为健康组织，+1 抗原记忆（%d）" % [str(c), game.memory])


## 【骨髓动员】全体免疫 +0.5；健康且空仓的骨髓立即产 1 张卡。
## 产出瞬间站在其上的细胞立即收取（说明 #9 与 S 阶段产出同口径）。
func _marrow_mobilization() -> void:
	for c in game.living_cells(CWData.Faction.IMMUNE):
		c["energy"] += _amp(5)
	game.log_msg("　【骨髓动员】所有免疫细胞 +%s 能量" % CWData.fmt(_amp(5)))
	for m in CWData.MARROWS:
		var t: Dictionary = game.tile(m)
		if t["tissue"] != CWData.Tissue.HEALTHY or t["cards"] > 0:
			continue
		t["cards"] = 1
		game.log_msg("　骨髓 %s 立即产出 1 张卡牌" % str(m))
		for standing in game.cells_at(m):
			game.actions.collect_special(standing, m)


## 【IFN-γ释放】（事件，圆心=抽卡者）/【IFN-γ高峰】（技能，圆心=所选免疫细胞）共用：
## 2 格内癌细胞 −1.0，普通癌组织固化计数 −1.0（不低于 0）
func _ifn_burst(source: Dictionary, center: Vector2i) -> void:
	for t in _cancer_cells_in_range(center, 2):
		game.immune_hit(t, _amp(10), source, false)
	for c in _tiles_in_range(center, 2):
		var t: Dictionary = game.tile(c)
		if t["tissue"] == CWData.Tissue.CANCER and t["solid"] > 0:
			t["solid"] = maxi(t["solid"] - 10, 0)   ## 固化计数不是能量，不受【信号放大】影响
	game.log_msg("　【IFN-γ】%s 周围 2 格：癌细胞 −%s 能量，固化计数 −1.0" % [
		str(center), CWData.fmt(_amp(10))])


func _ifn_has_effect(center: Vector2i) -> bool:
	if not _cancer_cells_in_range(center, 2).is_empty():
		return true
	for c in _tiles_in_range(center, 2):
		var t: Dictionary = game.tile(c)
		if t["tissue"] == CWData.Tissue.CANCER and t["solid"] > 0:
			return true
	return false


## 【全身性免疫清除】全场「与健康组织相邻、无癌细胞占据」的普通癌组织，随机最多 10 格 → 健康
func _systemic_clearance() -> void:
	var cands: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] == CWData.Tissue.CANCER \
				and game.cells_at(c, CWData.Faction.CANCER).is_empty() \
				and _adjacent_healthy_tile(c):
			cands.append(c)
	var picked := _pick_random(cands, 10)
	for c in picked:
		_to_healthy(c)
	game.log_msg("　【全身性免疫清除】%d 格癌组织转为健康组织" % picked.size())


## 【克隆增殖】相邻、未被免疫占据的健康组织，随机最多 1/2/3 格（按分期）→ 癌组织
func _clonal_growth(cell: Dictionary) -> void:
	var cands: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY \
				and game.cells_at(n, CWData.Faction.IMMUNE).is_empty():
			cands.append(n)
	var picked := _pick_random(cands, [1, 2, 3][_phase()])
	for c in picked:
		_to_cancer(c)
	game.log_msg("　【克隆增殖】%d 格健康组织转为癌组织" % picked.size())


## 【溶酶体强化】相邻、无细胞占据的普通癌组织，随机最多 4 格 → 健康；巨噬每格回 0.3
func _lysosome(cell: Dictionary) -> void:
	var picked := _pick_random(_adjacent_plain_cancer_empty(cell["pos"]), 4)
	for c in picked:
		_to_healthy(c)
	game.log_msg("　【溶酶体强化】%d 格癌组织转为健康组织" % picked.size())
	if cell["itype"] == CWData.ImmuneType.MACRO and not picked.is_empty():
		_gain(cell, 3 * picked.size(), "巨噬")


## 【免疫增援】自身传送到所选队友相邻 2 格内的随机空健康组织。落地算「进入」（说明 #9）
func _reinforce(cell: Dictionary, ally: Dictionary) -> void:
	var cands := _empty_healthy_in_range(ally["pos"], 2)
	var dest: Vector2i = cands[game.rng.randi_range(0, cands.size() - 1)]
	game.log_msg("　%s 传送至 %s（%s 附近）" % [game.cell_name(cell), str(dest), game.cell_name(ally)])
	game.actions.enter_tile(cell, dest)


## 【乳酸酸化】相邻免疫细胞 −0.8/1.5/2.0（分期）；其相邻癌性组织 ≥3 格时额外 −0.5
func _lactic_acid(cell: Dictionary, target: Dictionary) -> void:
	var base: int = [8, 15, 20][_phase()]
	var adj := 0
	for n in CWData.neighbors(target["pos"]):
		if game.is_cancerous(n):
			adj += 1
	if adj >= 3:
		base += 5
	game.cancer_hit(target, _amp(base), "乳酸酸化")


## 【基质硬化】所选普通癌组织固化计数 +1/+1.5/+2（分期）。
## 计数到达 3 立即转固化 —— PRD「计数到达3时转为固化癌组织」没限定只在 E 阶段结算。
## 门槛判定（含【固化加速】的 2.0 线）统一走 game.raise_solid。
func _stroma_harden(pos: Vector2i) -> void:
	var amt: int = [10, 15, 20][_phase()]
	game.log_msg("　%s 固化计数 +%s（现 %s）" % [
		str(pos), CWData.fmt(amt), CWData.fmt(game.tile(pos)["solid"] + amt)])
	game.raise_solid(pos, amt)


## 【肿瘤细胞募集】把所选癌细胞传送到**自身**周围 2/3/3 格内随机空癌性组织。落地算「进入」
func _recruit(cell: Dictionary, target: Dictionary) -> void:
	var cands := _empty_cancerous_in_range(cell["pos"], [2, 3, 3][_phase()])
	var dest: Vector2i = cands[game.rng.randi_range(0, cands.size() - 1)]
	game.log_msg("　%s 被募集至 %s" % [game.cell_name(target), str(dest)])
	game.actions.enter_tile(target, dest)


# ============ 工具 ============

func _phase() -> int:
	return CWCardData.cancer_phase(game.round_no)


func _opt(card: String, suffix: String, extra: Dictionary = {}) -> Dictionary:
	var data := { "act": "play", "card": card }
	data.merge(extra)
	return { "label": "打出【%s】%s" % [card, suffix], "data": data }


## 【信号放大】：卡牌效果中的能量增减翻倍（定案 W8：即时技能卡翻、事件卡按同口径翻，
## 永久技能卡与细胞自带技能不翻——本模块只住前两类，能量数值全部过这一层）
func _amp(n: int) -> int:
	for i in game.event_stacks("信号放大"):
		n *= 2
	return n


func _stress_fee() -> int:
	return 5 * game.event_stacks("细胞应激")   ## 【细胞应激】打牌费 0.5/层


func _gain(cell: Dictionary, n: int, tag: String = "") -> void:
	var v := _amp(n)
	cell["energy"] += v
	game.log_msg("　%s %s+%s 能量（现 %s）" % [
		game.cell_name(cell), tag, CWData.fmt(v), CWData.fmt(cell["energy"])])


## 组织转化不走「进入」，所以不给记忆、不触发收取；黏液/新生按增生同口径处理
func _to_healthy(c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.HEALTHY
	t["solid"] = 0
	t["newborn"] = false


func _to_cancer(c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.CANCER
	t["newborn"] = true
	t["solid"] = 0


func _adjacent_cancerous(pos: Vector2i) -> bool:
	for n in CWData.neighbors(pos):
		if game.is_cancerous(n):
			return true
	return false


func _adjacent_healthy(pos: Vector2i) -> bool:
	for n in CWData.neighbors(pos):
		if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
			return true
	return false


func _adjacent_healthy_tile(c: Vector2i) -> bool:
	return _adjacent_healthy(c)


func _adjacent_plain_cancer_empty(pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(pos):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER and game.cells_at(n).is_empty():
			out.append(n)
	return out


func _tiles_in_range(center: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in game.tiles.keys():
		if CWData.hex_dist(center, c) <= r:
			out.append(c)
	return out


func _cancer_cells_in_range(center: Vector2i, r: int) -> Array:
	var out: Array = []
	for t in game.living_cells(CWData.Faction.CANCER):
		if CWData.hex_dist(center, t["pos"]) <= r:
			out.append(t)
	return out


func _empty_healthy_in_range(center: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in _tiles_in_range(center, r):
		if c != center and game.tile(c)["tissue"] == CWData.Tissue.HEALTHY \
				and game.cells_at(c).is_empty():
			out.append(c)
	return out


func _empty_cancerous_in_range(center: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in _tiles_in_range(center, r):
		if c != center and game.is_cancerous(c) and game.cells_at(c).is_empty():
			out.append(c)
	return out


## 洗牌式抽 n 个（不放回）。**必须走 game.rng**，同种子可复现
func _pick_random(cands: Array, n: int) -> Array:
	var pool := cands.duplicate()
	var out: Array = []
	while out.size() < n and not pool.is_empty():
		var i := game.rng.randi_range(0, pool.size() - 1)
		out.append(pool[i])
		pool.remove_at(i)
	return out
