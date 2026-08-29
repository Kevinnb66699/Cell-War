## cw_card_fx.gd —— 卡牌效果：事件卡 + 已实现的即时技能（含需中途选择的一批）
##
## 还没住进来的两类各有前置，实现前别塞进来：
##   - 修饰/触发类 35 张（"下一次攻击…"、"本回合…"）→ 等修饰器框架（PRD差异对照 5.1 #26，
##     和世界事件共用同一套）
##   - 永久技能 22 张 → 等装备位（#27）
##
## **中途选择的口径**（2026-08-29 定，「需中途选择」批随此落地）：
##   结算里要玩家做的决定走 `await game.ask(pid, req)`，kind 取
##   free_move（走一步/停）/ pick_cell（选细胞）/ pick_tile（选格）/ pick（按钮二选一…）。
##   凡是「可以不做」的询问，**下标 0 恒为「停止/放弃」**——基类桥永远答 0，
##   所以脚本桥/断线兜底天然安全。选项照旧 {label, data}，带 to 的界面上点棋盘。
##   由此 resolve_event / play 都是协程，抽卡链路（draw→enter_tile→collect_special）
##   一路 await 到流程状态机（架构说明书「询问桥」节）。
##
## 三条口径，写新卡前先读：
##   ① 扣能量一律走 game.immune_hit / cancer_hit（五步管线），卡牌伤害不算「攻击」——
##      树突减半、巨噬吸血都不触发（那两条 PRD 明写"攻击"），但【标记】×2 与
##      【囊性护甲】照吃（它们管的是"损失"）。
##   ② 卡牌造成的组织转化**不给抗原记忆**（说明 #18 的口径外推），
##      除非卡面明写（目前只有【局部吞噬】）；经由【净化】的转化照常给（enter_tile 统一管）。
##   ③ 癌症卡的分期数值查 CWCardData.cancer_phase(game.round_no)，
##      永久技能将来也按当前回合取值（PRD：不在装备时锁定）。
class_name CWCardFx
extends RefCounted

## 【基因组不稳定】从第 20 世界回合起掷两次二选一（PRD 明写 20，恰与Ⅲ期起点重合，
## 但这是卡面自己的数字，不跟分期表走）
const GENOME_TWIN_ROUND := 20

var game: CWGame


# ============ 入口 1：事件卡（抽到立即结算，CWCards.draw 调用）============

## 返回 false = 这张事件还没实现（调用方如实记日志，别装作生效了）。
## 每张已实现的事件**自己喊一句带效果的通报**（试玩第四轮后 Kevin 要求：
## 光说「立即结算」看不出发生了什么）——即时结算的报结果，要选择的先报「给了什么」。
func resolve_event(cell: Dictionary, card: String) -> bool:
	match card:
		"急性炎症反应":
			_gain(cell, 15)
			_evt(card, "自身 +%s 能量" % CWData.fmt(_amp(15)), cell["pos"])
		"抗原摄取":
			var n := 2 if _adjacent_cancerous(cell["pos"]) else 1
			game.gain_memory(n)
			game.log_msg("　【抗原摄取】免疫方 +%d 抗原记忆（%d）" % [n, game.memory])
			_evt(card, "+%d 抗原记忆" % n, cell["pos"])
		"抗原呈递增强":
			game.gain_memory(3)
			game.log_msg("　【抗原呈递增强】免疫方 +3 抗原记忆（%d）" % game.memory)
			_evt(card, "+3 抗原记忆", cell["pos"])
		"局部吞噬":
			_local_phagocytosis(cell)
		"骨髓动员":
			_marrow_mobilization(cell)
		"克隆扩增":
			for c in game.living_cells(CWData.Faction.IMMUNE):
				c["energy"] += _amp(10)
			_gain(cell, 5, "额外")
			game.log_msg("　【克隆扩增】所有免疫细胞 +%s 能量" % CWData.fmt(_amp(10)))
			_evt(card, "全体免疫 +%s · 自身另 +%s" % [
				CWData.fmt(_amp(10)), CWData.fmt(_amp(5))], cell["pos"])
		"IFN-γ释放":
			_ifn_burst(cell, cell["pos"], "事件【IFN-γ释放】")
		"全身性免疫清除":
			_systemic_clearance(cell)
		"趋化募集":
			_evt(card, "免费移动最多 2 步", cell["pos"])
			await _free_walk(cell, 2, false, card)
		"效应细胞浸润":
			_evt(card, "免费移动最多 2 步 · 可进癌组织", cell["pos"])
			await _free_walk(cell, 2, true, card)
		"炎症风暴":
			await _inflammation_storm(cell, card)
		"免疫风暴":
			await _immune_storm(cell, card)
		"全身免疫动员":
			await _mobilization(cell, card)
		"糖酵解爆发":
			## 立刻结算一次无氧呼吸，不影响 E 阶段的正常结算
			var g := game.world.anaerobic_gain_for(cell)
			_gain(cell, g, "糖酵解爆发")
			_evt(card, "+%s 能量" % CWData.fmt(_amp(g)), cell["pos"])
		"克隆增殖":
			_clonal_growth(cell)
		"肿瘤血管生成":
			var v: int = _amp([10, 20, 25][_phase()])
			for c in game.living_cells(CWData.Faction.CANCER):
				c["energy"] += v
			_gain(cell, 5, "额外")
			game.log_msg("　【肿瘤血管生成】所有癌细胞 +%s 能量" % CWData.fmt(v))
			_evt(card, "全体癌细胞 +%s · 自身另 +%s" % [
				CWData.fmt(v), CWData.fmt(_amp(5))], cell["pos"])
		"基因组不稳定":
			_evt(card, "免费【突变】", cell["pos"])
			await _genome_instability(cell)
		_:
			return false
	return true


# ============ 入口 2：即时技能（从手牌打出，CWActions 调用）============

## 把当前能打的手牌摊成顶层选项（流程状态机约定：所有决定都是顶层选项）。
## 带目标的卡一目标一选项；随机结算的卡一张一选项。打出不花能量（PRD 没有出牌费）。
## 中途还有别的决定的卡（代谢耦联的方向数额、基质重塑的后续格、炎症性趋化的后两步）
## 只摊**第一个**决定，其余在 play() 里经 game.ask 追问。
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
			"炎症性趋化":
				for d in _chemotaxis_steps(cell):
					opts.append(_opt(card, "→%s" % str(d["to"]), d))
			"代谢耦联":
				## 免疫版和癌症版同名同数值，只差目标阵营 —— 一份实现按自身阵营选队友
				for t in game.living_cells(cell["faction"]):
					if t["id"] == cell["id"]:
						continue
					if not _couple_tiers(cell).is_empty() or not _couple_tiers(t).is_empty():
						opts.append(_opt(card, "→%s" % game.cell_name(t), { "cid": t["id"] }))
			"基质重塑":
				for c in _solid_in_range(cell["pos"], 2):
					opts.append(_opt(card, "→%s" % str(c), { "to": c }))
			"放疗":
				var all: Array = game.tiles.keys()
				all.sort()   ## 固定候选顺序，保证同种子可复现
				for c in all:
					if game.is_cancerous(c):
						opts.append(_opt(card, "→%s" % str(c), { "to": c }))
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
				pass   ## 修饰类/永久的卡：还打不出去，选项不出现


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
			_ifn_burst(cell, game.cells[data["cid"]]["pos"], "【IFN-γ高峰】")
		"免疫增援":
			await _reinforce(cell, game.cells[data["cid"]])
		"炎症性趋化":
			await _chemotaxis(cell, data)
		"代谢耦联":
			await _couple(cell, game.cells[data["cid"]])
		"基质重塑":
			await _remodel(cell, data["to"])
		"放疗":
			_radiotherapy(data["to"])
		"乳酸酸化":
			_lactic_acid(cell, game.cells[data["cid"]])
		"基质硬化":
			_stroma_harden(data["to"])
		"肿瘤细胞募集":
			await _recruit(cell, game.cells[data["cid"]])
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
		_evt("局部吞噬", "落空（相邻无癌组织）", cell["pos"])
		return
	var c: Vector2i = cands[game.rng.randi_range(0, cands.size() - 1)]
	_to_healthy(c)
	game.gain_memory(1)
	game.log_msg("　【局部吞噬】%s 转为健康组织，+1 抗原记忆（%d）" % [str(c), game.memory])
	_evt("局部吞噬", "1 格转健康 · +1 记忆", c)


## 【骨髓动员】全体免疫 +0.5；健康且空仓的骨髓立即产 1 张卡。
## 产出瞬间站在其上的细胞立即收取（说明 #9 与 S 阶段产出同口径）。
func _marrow_mobilization(drawer: Dictionary) -> void:
	for c in game.living_cells(CWData.Faction.IMMUNE):
		c["energy"] += _amp(5)
	game.log_msg("　【骨髓动员】所有免疫细胞 +%s 能量" % CWData.fmt(_amp(5)))
	var produced := 0
	for m in CWData.MARROWS:
		var t: Dictionary = game.tile(m)
		if t["tissue"] != CWData.Tissue.HEALTHY or t["cards"] > 0:
			continue
		t["cards"] = 1
		produced += 1
		game.log_msg("　骨髓 %s 立即产出 1 张卡牌" % str(m))
		for standing in game.cells_at(m):
			await game.actions.collect_special(standing, m)
	_evt("骨髓动员", "全体免疫 +%s · %d 骨髓产卡" % [
		CWData.fmt(_amp(5)), produced], drawer["pos"])


## 【IFN-γ释放】（事件，圆心=抽卡者）/【IFN-γ高峰】（技能，圆心=所选免疫细胞）共用：
## 2 格内癌细胞 −1.0，普通癌组织固化计数 −1.0（不低于 0）。
## title 是通报抬头（"事件【IFN-γ释放】" / "【IFN-γ高峰】"），效果说明两处共用。
func _ifn_burst(source: Dictionary, center: Vector2i, title: String) -> void:
	var hit := 0
	for t in _cancer_cells_in_range(center, 2):
		game.immune_hit(t, _amp(10), source, false)
		hit += 1
	for c in _tiles_in_range(center, 2):
		var t: Dictionary = game.tile(c)
		if t["tissue"] == CWData.Tissue.CANCER and t["solid"] > 0:
			t["solid"] = maxi(t["solid"] - 10, 0)   ## 固化计数不是能量，不受【信号放大】影响
	game.log_msg("　【IFN-γ】%s 周围 2 格：癌细胞 −%s 能量，固化计数 −1.0" % [
		str(center), CWData.fmt(_amp(10))])
	game.announce("%s%d 个癌细胞 −%s · 固化 −1.0" % [
		title, hit, CWData.fmt(_amp(10))], center)


func _ifn_has_effect(center: Vector2i) -> bool:
	if not _cancer_cells_in_range(center, 2).is_empty():
		return true
	for c in _tiles_in_range(center, 2):
		var t: Dictionary = game.tile(c)
		if t["tissue"] == CWData.Tissue.CANCER and t["solid"] > 0:
			return true
	return false


## 【全身性免疫清除】全场「与健康组织相邻、无癌细胞占据」的普通癌组织，随机最多 10 格 → 健康
func _systemic_clearance(drawer: Dictionary) -> void:
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
	_evt("全身性免疫清除", "%d 格癌组织转健康" % picked.size(), drawer["pos"])


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
	_evt("克隆增殖", "%d 格转癌组织" % picked.size(), cell["pos"])


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
	await game.actions.enter_tile(cell, dest)


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
	await game.actions.enter_tile(target, dest)


# ============ 需中途选择的一批（2026-08-29 落地）============

## 【趋化募集】/【效应细胞浸润】共用的免费连走：每步问一次「走哪 / 停」。
## into_cancer=false 只能进健康组织（趋化募集）；true 还可进普通癌组织（浸润，
## 进格照常触发【净化】——enter_tile 统一管）。两张卡都只许进**无细胞占据**的格，
## 固化癌组织都不行（卡面写的是「健康组织或癌组织」，固化是另一个词）。
## 免费 = 不扣能量也不占【迁移激活】的免费首移（那是给「移动」行动的）。
func _free_walk(cell: Dictionary, steps: int, into_cancer: bool, tag: String) -> void:
	for step_no in steps:
		if not cell["alive"]:
			return
		var opts: Array = [{ "label": "停在这里", "data": { "stop": true } }]
		for n in CWData.neighbors(cell["pos"]):
			if not game.cells_at(n).is_empty():
				continue
			var t: Dictionary = game.tile(n)
			if t["tissue"] == CWData.Tissue.HEALTHY \
					or (into_cancer and t["tissue"] == CWData.Tissue.CANCER):
				opts.append({ "label": "移动→%s" % str(n), "data": { "to": n } })
		if opts.size() == 1:
			game.log_msg("　【%s】没有可进入的相邻格，提前结束" % tag)
			return
		var idx: int = await game.ask(cell["pid"], {
			"kind": "free_move", "tag": tag,
			"prompt": "【%s】第 %d/%d 步（免费，可提前停止）" % [tag, step_no + 1, steps],
			"options": opts,
		})
		var data: Dictionary = opts[idx]["data"]
		if data.get("stop", false):
			game.log_msg("　【%s】提前停止" % tag)
			return
		game.log_msg("　【%s】%s 免费移动至 %s" % [tag, game.cell_name(cell), str(data["to"])])
		await game.actions.enter_tile(cell, data["to"])


## 【炎症风暴】选 1 个免疫细胞：其相邻无细胞占据的普通癌组织 → 健康；相邻癌细胞 −0.5
func _inflammation_storm(cell: Dictionary, card: String) -> void:
	_evt(card, "选择 1 个免疫细胞", cell["pos"])
	var target := await _pick_immune(cell["pid"], card)
	var purged := 0
	var hit := 0
	for n in CWData.neighbors(target["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER and game.cells_at(n).is_empty():
			_to_healthy(n)
			purged += 1
		for enemy in game.cells_at(n, CWData.Faction.CANCER):
			game.immune_hit(enemy, _amp(5), cell, false)
			hit += 1
	game.log_msg("　【炎症风暴】以 %s 为中心：%d 格转健康，%d 个癌细胞 −%s" % [
		game.cell_name(target), purged, hit, CWData.fmt(_amp(5))])
	_evt(card, "%d 格转健康 · %d 敌 −%s" % [purged, hit, CWData.fmt(_amp(5))], target["pos"])


## 【免疫风暴】选 1 个免疫细胞：2 格内癌细胞 −1.0；范围内**无癌细胞占据**的普通癌组织 → 健康
func _immune_storm(cell: Dictionary, card: String) -> void:
	_evt(card, "选择 1 个免疫细胞", cell["pos"])
	var target := await _pick_immune(cell["pid"], card)
	var hit := 0
	for t in _cancer_cells_in_range(target["pos"], 2):
		game.immune_hit(t, _amp(10), cell, false)
		hit += 1
	var purged := 0
	for c in _tiles_in_range(target["pos"], 2):
		if game.tile(c)["tissue"] == CWData.Tissue.CANCER \
				and game.cells_at(c, CWData.Faction.CANCER).is_empty():
			_to_healthy(c)
			purged += 1
	game.log_msg("　【免疫风暴】以 %s 为中心 2 格：%d 个癌细胞 −%s，%d 格转健康" % [
		game.cell_name(target), hit, CWData.fmt(_amp(10)), purged])
	_evt(card, "%d 敌 −%s · %d 格转健康" % [hit, CWData.fmt(_amp(10)), purged], target["pos"])


## 风暴类的「选择 1 个免疫细胞」。抽卡者是免疫，所以候选至少有它自己，选择是强制的
## （事件抽取后立即生效，PRD 没给「放弃」）。
func _pick_immune(pid: int, tag: String) -> Dictionary:
	var opts: Array = []
	for t in game.living_cells(CWData.Faction.IMMUNE):
		opts.append({ "label": "选择 %s" % game.cell_name(t),
			"data": { "cid": t["id"], "to": t["pos"] } })
	var idx: int = await game.ask(pid, {
		"kind": "pick_cell", "tag": tag,
		"prompt": "【%s】选择 1 个免疫细胞" % tag, "options": opts,
	})
	return game.cells[opts[idx]["data"]["cid"]]


## 【全身免疫动员】全体免疫 +1.5，然后**每个**免疫细胞由它的玩家决定要不要立即迁移 1 次。
## 迁移按正常口径结算：费用照付（+1.5 就是给这个用的）、进癌细胞格照常触发攻击 ——
## PRD 只说「可以立即【迁移】1次」，没写免费（对照 §六 待团队确认）。
func _mobilization(drawer: Dictionary, card: String) -> void:
	for c in game.living_cells(CWData.Faction.IMMUNE):
		c["energy"] += _amp(15)
	game.log_msg("　【全身免疫动员】所有免疫细胞 +%s 能量" % CWData.fmt(_amp(15)))
	_evt(card, "全体免疫 +%s · 各可迁移 1 次" % CWData.fmt(_amp(15)), drawer["pos"])
	for c in game.living_cells(CWData.Faction.IMMUNE):
		if not c["alive"]:
			continue   ## 前面谁的迁移把局面打乱了也不怕：轮到时再核对一遍
		var moves: Array = game.actions.immune_move_options(c)
		if moves.is_empty():
			continue
		var opts: Array = [{ "label": "放弃迁移", "data": { "stop": true } }]
		opts.append_array(moves)
		var idx: int = await game.ask(c["pid"], {
			"kind": "free_move", "tag": card,
			"prompt": "【%s】%s 可立即迁移 1 次（费用照付）" % [card, game.cell_name(c)],
			"options": opts,
		})
		var data: Dictionary = opts[idx]["data"]
		if data.get("stop", false):
			continue
		await game.actions._do_move(c, data["to"], data["cost"])


## 【基因组不稳定】免费【突变】，不计次数限制；第 20 世界回合起掷两次、玩家挑一个结算
func _genome_instability(cell: Dictionary) -> void:
	game.log_msg("　【基因组不稳定】免费发动 1 次【突变】（不计入次数限制）")
	if game.round_no < GENOME_TWIN_ROUND:
		await game.actions.roll_mutation(cell)
		return
	var r1: int = await game.roll_shown(3, "突变", cell["pid"], cell["pos"])
	var r2: int = await game.roll_shown(3, "突变", cell["pid"], cell["pos"])
	var r := r1
	if r1 != r2:
		var opts: Array = [
			{ "label": _mutation_label(r1), "data": { "r": r1 } },
			{ "label": _mutation_label(r2), "data": { "r": r2 } },
		]
		var idx: int = await game.ask(cell["pid"], {
			"kind": "pick", "tag": "基因组不稳定",
			"prompt": "【基因组不稳定】两次判定选一个结算", "options": opts,
		})
		r = opts[idx]["data"]["r"]
	else:
		game.log_msg("　两次判定相同（%d），无需选择" % r1)
	await game.actions.apply_mutation(cell, r)


func _mutation_label(r: int) -> String:
	match r:
		1: return "无事发生"
		2: return "抽 1 张 · 记忆 −1"
	return "能量 −1.0 · 记忆 −3"


## 【炎症性趋化】的一步有哪些去处：相邻的健康/普通癌组织（固化不行），
## 己方细胞占着的去不了、癌细胞占着的算攻击（卡面明写「正常触发…攻击」）。
## 每步基准 0.2，过 _move_cost_mod —— 免疫抑制的净化费、基质阻隔的翻倍、
## 迁移激活的免费首移都照常适用（这是「移动」，事件文本没排除它）。
func _chemotaxis_steps(cell: Dictionary) -> Array:
	var out: Array = []
	for n in CWData.neighbors(cell["pos"]):
		var t: Dictionary = game.tile(n)
		if t["tissue"] != CWData.Tissue.HEALTHY and t["tissue"] != CWData.Tissue.CANCER:
			continue
		if not game.cells_at(n, CWData.Faction.IMMUNE).is_empty():
			continue
		var cost: int = game.actions._move_cost_mod(cell, n, CWData.CHEMOTAX_STEP_COST)
		if game.can_pay(cell, cost):
			out.append({ "to": n, "cost": cost })
	return out


## 【炎症性趋化】连走最多 3 步：第 1 步就是手牌选项选好的目标，后两步逐步追问
func _chemotaxis(cell: Dictionary, first: Dictionary) -> void:
	await game.actions._do_move(cell, first["to"], first["cost"])
	for step_no in [2, 3]:
		if not cell["alive"]:
			return
		var steps := _chemotaxis_steps(cell)
		if steps.is_empty():
			game.log_msg("　【炎症性趋化】没有可走的下一步，提前结束")
			return
		var opts: Array = [{ "label": "停在这里", "data": { "stop": true } }]
		for d in steps:
			opts.append({ "label": "移动→%s（%s 能量）" % [str(d["to"]), CWData.fmt(d["cost"])],
				"data": d })
		var idx: int = await game.ask(cell["pid"], {
			"kind": "free_move", "tag": "炎症性趋化",
			"prompt": "【炎症性趋化】第 %d/3 步（可提前停止）" % step_no,
			"options": opts,
		})
		var data: Dictionary = opts[idx]["data"]
		if data.get("stop", false):
			game.log_msg("　【炎症性趋化】提前停止")
			return
		await game.actions._do_move(cell, data["to"], data["cost"])


## 【代谢耦联】payer 付得起哪几档：转 1.0/1.5/2.0，接收方得 1.2/2.0/2.5。
## 两侧数额都过【信号放大】（定案 W8：卡牌效果的能量增减翻倍，「失去」也是增减）；
## 支付按「费用」口径（game.pay，不能降至 0），接收是纯获得。
func _couple_tiers(payer: Dictionary) -> Array:
	var out: Array = []
	for tier in [[10, 12], [15, 20], [20, 25]]:
		var pay: int = _amp(tier[0])
		var get: int = _amp(tier[1])
		if payer["energy"] > pay:
			out.append({ "label": "转出 %s（接收方得 %s）" % [CWData.fmt(pay), CWData.fmt(get)],
				"data": { "pay": pay, "get": get } })
	return out


## 【代谢耦联】结算：先问方向（谁付给谁），再问数额。只有一种选择就不问。
func _couple(cell: Dictionary, ally: Dictionary) -> void:
	var dirs: Array = []
	if not _couple_tiers(cell).is_empty():
		dirs.append({ "label": "送给 %s" % game.cell_name(ally),
			"data": { "from": cell["id"], "to_cid": ally["id"] } })
	if not _couple_tiers(ally).is_empty():
		dirs.append({ "label": "向 %s 索取" % game.cell_name(ally),
			"data": { "from": ally["id"], "to_cid": cell["id"] } })
	var di := 0
	if dirs.size() > 1:
		di = await game.ask(cell["pid"], { "kind": "pick", "tag": "代谢耦联",
			"prompt": "【代谢耦联】选择转移方向", "options": dirs })
	var payer: Dictionary = game.cells[dirs[di]["data"]["from"]]
	var getter: Dictionary = game.cells[dirs[di]["data"]["to_cid"]]
	var tiers := _couple_tiers(payer)
	var ti := 0
	if tiers.size() > 1:
		ti = await game.ask(cell["pid"], { "kind": "pick", "tag": "代谢耦联",
			"prompt": "【代谢耦联】选择转移数额", "options": tiers })
	var pay: int = tiers[ti]["data"]["pay"]
	var get: int = tiers[ti]["data"]["get"]
	if not game.pay(payer, pay):
		game.log_msg("　【代谢耦联】%s 付不出 %s，落空" % [game.cell_name(payer), CWData.fmt(pay)])
		return
	getter["energy"] += get
	game.log_msg("　【代谢耦联】%s 转出 %s，%s 获得 %s（现 %s）" % [
		game.cell_name(payer), CWData.fmt(pay),
		game.cell_name(getter), CWData.fmt(get), CWData.fmt(getter["energy"])])


func _solid_in_range(center: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in _tiles_in_range(center, r):
		if game.tile(c)["tissue"] == CWData.Tissue.SOLID:
			out.append(c)
	return out


## 【基质重塑】：手牌选项选好的第 1 格固化先拆掉，再问要不要拆第 2 格；
## 随后从「拆过的格及其相邻格」里选最多 2 格无细胞占据的普通癌组织转健康。
## 每一段都可提前停（「最多」给的是上限，不是义务）。
func _remodel(cell: Dictionary, first: Vector2i) -> void:
	var chosen: Array[Vector2i] = [first]
	_crack(first)
	var more: Array = []
	for c in _solid_in_range(cell["pos"], 2):
		more.append({ "label": "再拆 %s" % str(c), "data": { "to": c } })
	if not more.is_empty():
		var opts: Array = [{ "label": "只拆这一格", "data": { "stop": true } }]
		opts.append_array(more)
		var idx: int = await game.ask(cell["pid"], {
			"kind": "pick_tile", "tag": "基质重塑",
			"prompt": "【基质重塑】还可再拆 1 格固化癌组织", "options": opts,
		})
		var data: Dictionary = opts[idx]["data"]
		if not data.get("stop", false):
			chosen.append(data["to"])
			_crack(data["to"])
	for heal_no in 2:
		var cands := _remodel_heal_cands(chosen)
		if cands.is_empty():
			return
		var opts: Array = [{ "label": "到此为止", "data": { "stop": true } }]
		for c in cands:
			opts.append({ "label": "转化 %s" % str(c), "data": { "to": c } })
		var idx: int = await game.ask(cell["pid"], {
			"kind": "pick_tile", "tag": "基质重塑",
			"prompt": "【基质重塑】选择要转健康的癌组织（第 %d/2 格）" % (heal_no + 1),
			"options": opts,
		})
		var data: Dictionary = opts[idx]["data"]
		if data.get("stop", false):
			return
		_to_healthy(data["to"])
		game.log_msg("　【基质重塑】%s 转为健康组织" % str(data["to"]))


func _crack(c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.CANCER
	t["solid"] = 0
	game.log_msg("　【基质重塑】%s 由固化癌组织转为癌组织（计数清零）" % str(c))


## 【基质重塑】第二段的候选：拆过的格自身 + 它们的相邻格里，无细胞占据的普通癌组织。
## 拆过的格刚变成普通癌组织，自己就是合法候选（PRD「从这些组织及其相邻格中」）。
func _remodel_heal_cands(chosen: Array[Vector2i]) -> Array[Vector2i]:
	var seen := {}
	var out: Array[Vector2i] = []
	for base in chosen:
		var around: Array[Vector2i] = [base]
		around.append_array(CWData.neighbors(base))
		for c in around:
			if seen.has(c):
				continue
			seen[c] = true
			if game.tile(c)["tissue"] == CWData.Tissue.CANCER and game.cells_at(c).is_empty():
				out.append(c)
	return out


## 【放疗】以所选癌性组织为起点，随机生长出含它的连通 15 格区域：
## 区域内所有癌性组织（含固化、含有细胞站着的）→ 健康，全部 15 格进入「坏死」5 轮。
## 「坏死」沿用毒素那套倒计时（不为免疫供能、可被定殖，定殖时清除——同一口径）。
func _radiotherapy(start: Vector2i) -> void:
	var region: Array[Vector2i] = [start]
	var in_region := { start: true }
	var frontier: Array[Vector2i] = CWData.neighbors(start)
	while region.size() < CWData.RADIO_REGION and not frontier.is_empty():
		var i := game.rng.randi_range(0, frontier.size() - 1)
		var c: Vector2i = frontier[i]
		frontier.remove_at(i)
		if in_region.has(c):
			continue   ## 同一格会从多个方向进候选，去重靠这里
		region.append(c)
		in_region[c] = true
		for n in CWData.neighbors(c):
			if not in_region.has(n):
				frontier.append(n)
	var cleared := 0
	for c in region:
		if game.is_cancerous(c):
			_to_healthy(c)
			cleared += 1
		game.tile(c)["necrosis"] = maxi(game.tile(c)["necrosis"], CWData.NECROSIS_RADIO)
	game.log_msg("　【放疗】以 %s 为起点的 %d 格区域：%d 格癌性组织转为健康，全部进入「坏死」（%d 轮）" % [
		str(start), region.size(), cleared, CWData.NECROSIS_RADIO])
	game.announce("放疗：%d 格转健康 · %d 格坏死" % [cleared, region.size()], start)


# ============ 工具 ============

func _phase() -> int:
	return CWCardData.cancer_phase(game.round_no)


## 事件卡的一句话通报（试玩后定：必须带上造成了什么效果）
func _evt(card: String, text: String, at: Vector2i) -> void:
	game.announce("事件【%s】%s" % [card, text], at)


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
