## cw_actions.gd —— 主动技能与移动/攻击结算
##
## build_options(cell) 生成当前所有合法行动（含费用校验），execute() 执行。
## enter_tile() 是「进入一格」的唯一入口：定殖 / 净化 / 特殊组织收取 / 标记刷新
## 都在这里统一触发（移动、血管传送、复活落位共用，见说明 #9）。
class_name CWActions
extends RefCounted

var game: CWGame


# ============ 行动菜单 ============

func build_options(cell: Dictionary) -> Array:
	var opts: Array = []
	if cell["faction"] == CWData.Faction.IMMUNE:
		_immune_options(cell, opts)
	else:
		_cancer_options(cell, opts)
	opts.append({ "label": "结束回合", "data": { "act": "end" } })
	return opts


func _immune_options(cell: Dictionary, opts: Array) -> void:
	var lvl := game.immune_level
	for n in CWData.neighbors(cell["pos"]):
		var enemies: Array = game.cells_at(n, CWData.Faction.CANCER)
		# 树突状细胞无法发动攻击 → 不能进入癌细胞所在格（说明 #14）
		if not enemies.is_empty() and cell["itype"] == CWData.ImmuneType.DENDRITIC:
			continue
		var cost: int = game.tune.immune_move_cancerous[lvl] if game.is_cancerous(n) \
			else game.tune.immune_move_healthy[lvl]
		if not game.can_pay(cell, cost):
			continue
		var tag := "攻击" if not enemies.is_empty() else "迁移"
		opts.append({
			"label": "%s→%s（%s 能量）" % [tag, str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if game.can_pay(cell, CWData.IMMUNE_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（0.5 能量）", "data": { "act": "draw" } })
	if lvl >= 2 and not cell["differentiated"] and not _diff_choices().is_empty():
		opts.append({ "label": "分化（免费）", "data": { "act": "differentiate" } })
	if cell["itype"] == CWData.ImmuneType.B_CELL \
			and cell["antibody_used"] < CWData.ANTIBODY_MAX_PER_ROUND \
			and game.can_pay(cell, CWData.ANTIBODY_COST):
		opts.append({ "label": "抗体（1.0 能量）", "data": { "act": "antibody" } })
	if cell["itype"] == CWData.ImmuneType.T_CELL:
		if game.can_pay(cell, CWData.TOXIN_COST) and not _toxin_targets(cell).is_empty():
			opts.append({ "label": "细胞毒素（1.0 能量）", "data": { "act": "toxin" } })
		if game.tile(cell["pos"])["tissue"] == CWData.Tissue.SOLID \
				and game.can_pay(cell, CWData.LYSE_COST):
			opts.append({ "label": "裂解（1.0 能量）", "data": { "act": "lyse" } })


func _cancer_options(cell: Dictionary, opts: Array) -> void:
	for n in CWData.neighbors(cell["pos"]):
		# 癌细胞无法向免疫细胞占据的组织移动
		if not game.cells_at(n, CWData.Faction.IMMUNE).is_empty():
			continue
		var cost := _cancer_move_cost(cell, n)
		if not game.can_pay(cell, cost):
			continue
		opts.append({
			"label": "移动→%s（%s 能量）" % [str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if game.can_pay(cell, CWData.CANCER_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（1.0 能量）", "data": { "act": "draw" } })
	if not cell["mutate_used"] and game.can_pay(cell, CWData.MUTATE_COST):
		opts.append({ "label": "突变（0.5 能量）", "data": { "act": "mutate" } })
	if cell["ctype"] == CWData.CancerType.BLAST and cell["energy"] > 0 \
			and not _blast_targets(cell).is_empty():
		opts.append({ "label": "自爆（消耗所有能量）", "data": { "act": "blast" } })
	if cell["ctype"] == CWData.CancerType.REMODEL and not cell["remodel_used"] \
			and game.can_pay(cell, CWData.REMODEL_COST) \
			and not _remodel_targets(cell).is_empty():
		opts.append({ "label": "基质重塑（1.0 能量）", "data": { "act": "remodel" } })


func _cancer_move_cost(cell: Dictionary, dest: Vector2i) -> int:
	if game.is_cancerous(dest):
		return CWData.CANCER_MOVE_CANCEROUS
	# 侵袭型：每世界回合前 2 次移动至健康组织 -0.2（说明 #17）
	if cell["ctype"] == CWData.CancerType.INVASIVE and cell["invasive_used"] < 2:
		return CWData.CANCER_MOVE_HEALTHY - CWData.INVASIVE_DISCOUNT
	return CWData.CANCER_MOVE_HEALTHY


# ============ 执行 ============

func execute(cell: Dictionary, data: Dictionary) -> void:
	match data["act"]:
		"move":
			await _do_move(cell, data["to"], data["cost"])
		"draw":
			_do_draw(cell)
		"differentiate":
			await _do_differentiate(cell)
		"antibody":
			await _do_antibody(cell)
		"toxin":
			_do_toxin(cell)
		"lyse":
			await _do_lyse(cell)
		"mutate":
			await _do_mutate(cell)
		"blast":
			_do_blast(cell)
		"remodel":
			await _do_remodel(cell)


# ---- 移动 / 攻击 ----

func _do_move(cell: Dictionary, to: Vector2i, cost: int) -> void:
	if not game.pay(cell, cost):
		return
	if cell["faction"] == CWData.Faction.CANCER:
		if not game.is_cancerous(to) \
				and cell["ctype"] == CWData.CancerType.INVASIVE and cell["invasive_used"] < 2:
			cell["invasive_used"] += 1
		enter_tile(cell, to)
		return
	# 免疫迁移：目标格有癌细胞 → 触发攻击
	var enemies: Array = game.cells_at(to, CWData.Faction.CANCER)
	if enemies.is_empty():
		enter_tile(cell, to)
		return
	var target: Dictionary = enemies[0]
	if enemies.size() > 1:
		var topts: Array = []
		for e in enemies:
			topts.append({
				"label": "%s（能量 %s）" % [game.cell_name(e), CWData.fmt(e["energy"])],
				"data": { "cid": e["id"] },
			})
		var idx: int = await game.ask(cell["pid"], {
			"kind": "attack_target", "prompt": "选择攻击目标", "options": topts,
		})
		target = game.cells[topts[idx]["data"]["cid"]]
	var r: int = await game.roll_shown(6, "攻击", cell["pid"])
	if r <= 2:
		game.log_msg("　攻击掷骰 %d：失败，%s 被反弹回原格" % [r, game.cell_name(cell)])
		# 规则原文反弹不造成伤害（旋钮默认 0）；平衡测试可给癌方反击手段
		if game.tune.counter_dmg_on_fail > 0:
			cell["energy"] -= game.tune.counter_dmg_on_fail
			game.log_msg("　反弹造成 %s 能量损失（余 %s）" % [
				CWData.fmt(game.tune.counter_dmg_on_fail), CWData.fmt(maxi(cell["energy"], 0))])
			if cell["energy"] <= 0:
				game.kill(cell)
				return
	else:
		var dmg: int = game.tune.attack_dmg_crit if r == 6 else game.tune.attack_dmg_success
		game.log_msg("　攻击掷骰 %d：%s" % [r, "大成功" if r == 6 else "成功"])
		game.immune_hit(target, dmg, cell)
	# 目标格已无存活癌细胞才进入（击杀进格；否则返回原格）
	if game.cells_at(to, CWData.Faction.CANCER).is_empty():
		enter_tile(cell, to)
	else:
		game.log_msg("　%s 返回原格" % game.cell_name(cell))


## 进入一格的统一结算：癌细胞【定殖】、免疫【净化】、特殊组织收取、标记刷新
func enter_tile(cell: Dictionary, dest: Vector2i) -> void:
	cell["pos"] = dest
	var t: Dictionary = game.tile(dest)
	if cell["faction"] == CWData.Faction.CANCER and t["tissue"] == CWData.Tissue.HEALTHY:
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
		game.log_msg("　【定殖】%s 转为癌组织" % str(dest))
	elif cell["faction"] == CWData.Faction.IMMUNE and t["tissue"] == CWData.Tissue.CANCER:
		t["tissue"] = CWData.Tissue.HEALTHY
		t["newborn"] = false
		t["solid"] = 0
		t["sticky"] = 0
		game.gain_memory(1)
		game.log_msg("　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(dest), game.memory])
		if cell["itype"] == CWData.ImmuneType.MACRO:
			cell["energy"] += CWData.MACRO_HEAL_PURIFY
			game.log_msg("　巨噬【吞噬】恢复 0.2 能量")
	collect_special(cell, dest)
	game.update_marks()
	if cell["faction"] == CWData.Faction.IMMUNE:
		game.check_immune_win()  # 占住固化格可能封死复活 → 立即胜利（说明 #25）


## 收取特殊组织存储（进入时 & 产出瞬间站于其上时调用）
func collect_special(cell: Dictionary, c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	if t["special"] == CWData.Special.CORE and t["store"] > 0:
		cell["energy"] += t["store"]
		game.log_msg("　%s 从代谢核心获取 %s 能量" % [game.cell_name(cell), CWData.fmt(t["store"])])
		t["store"] = 0
	elif t["special"] == CWData.Special.MARROW and t["cards"] > 0:
		t["cards"] = 0
		game.cards.draw(cell, "骨髓")


# ---- 通用技能 ----

func _do_draw(cell: Dictionary) -> void:
	var cost: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
		else CWData.CANCER_DRAW_COST
	if game.pay(cell, cost):
		game.cards.draw(cell, "基因表达")


# ---- 免疫技能 ----

func _diff_choices() -> Array:
	var out: Array = []
	for t in [CWData.ImmuneType.B_CELL, CWData.ImmuneType.T_CELL,
			CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		if t not in game.differentiated:  # 每种细胞全阵营仅能有一个
			out.append(t)
	return out


func _do_differentiate(cell: Dictionary) -> void:
	var choices := _diff_choices()
	var opts: Array = []
	for t in choices:
		opts.append({ "label": "分化为%s" % CWData.IMMUNE_TYPE_NAMES[t], "data": { "type": t } })
	var idx: int = await game.ask(cell["pid"], {
		"kind": "differentiate", "prompt": "选择分化方向", "options": opts,
	})
	var t: int = opts[idx]["data"]["type"]
	cell["itype"] = t
	cell["differentiated"] = true
	game.differentiated.append(t)
	game.log_msg("【分化】%s 分化为 %s" % [game.player(cell["pid"])["name"], CWData.IMMUNE_TYPE_NAMES[t]])
	game.update_marks()  # 分化出树突 → 立即标记相邻癌细胞


func _do_antibody(cell: Dictionary) -> void:
	if not game.pay(cell, CWData.ANTIBODY_COST):
		return
	cell["antibody_used"] += 1
	var targets: Array = []
	for c in game.living_cells(CWData.Faction.CANCER):
		for n in CWData.neighbors(c["pos"]):
			if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
				targets.append(c)
				break
	if not targets.is_empty():
		game.log_msg("【抗体】命中 %d 个与健康组织邻接的癌细胞" % targets.size())
		for c in targets:
			game.immune_hit(c, CWData.ANTIBODY_DAMAGE, cell)
		return
	# 无目标 → 随机将与健康组织相邻的 X 格癌组织转为健康（2/3→1，1/3→2）
	var eligible: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] != CWData.Tissue.CANCER:
			continue
		if not game.cells_at(c, CWData.Faction.CANCER).is_empty():
			continue  # 说明 #20：不转化有癌细胞停留的格
		for n in CWData.neighbors(c):
			if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
				eligible.append(c)
				break
	if eligible.is_empty():
		game.log_msg("【抗体】无目标且无可转化癌组织，效果落空")
		return
	var roll: int = await game.roll_shown(3, "抗体", cell["pid"])
	var x: int = 1 if roll <= 2 else 2
	for c in game.pick_random(eligible, x):
		_to_healthy(c)
		game.log_msg("【抗体】无目标 → %s 转为健康组织" % str(c))


func _toxin_targets(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER \
				and game.cells_at(n, CWData.Faction.CANCER).is_empty():
			out.append(n)
	return out


func _do_toxin(cell: Dictionary) -> void:
	var targets := _toxin_targets(cell)
	if targets.is_empty() or not game.pay(cell, CWData.TOXIN_COST):
		return
	for c in targets:
		_to_healthy(c)
	game.log_msg("【细胞毒素】相邻 %d 格癌组织转为健康组织（不积累记忆）" % targets.size())


func _do_lyse(cell: Dictionary) -> void:
	if not game.pay(cell, CWData.LYSE_COST):
		return
	var pos: Vector2i = cell["pos"]
	var t: Dictionary = game.tile(pos)
	t["tissue"] = CWData.Tissue.CANCER
	t["solid"] = 0
	t["sticky"] = 0
	game.log_msg("【裂解】%s 由固化癌组织转为癌组织" % str(pos))
	var idx: int = await game.ask(cell["pid"], {
		"kind": "confirm", "tag": "lyse_purge", "prompt": "是否立刻触发【净化】？",
		"options": [{ "label": "立刻净化", "data": {} }, { "label": "暂不", "data": {} }],
	})
	if idx == 0:
		t["tissue"] = CWData.Tissue.HEALTHY
		game.gain_memory(1)
		game.log_msg("　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(pos), game.memory])
		game.check_immune_win()


# ---- 癌症技能 ----

func _do_mutate(cell: Dictionary) -> void:
	if not game.pay(cell, CWData.MUTATE_COST):
		return
	cell["mutate_used"] = true
	var nothing: bool = await _roll_mutation(cell)
	# 基因不稳定型：结果为无事发生时，可付 0.5 再突变一次（每世界回合限一次）
	if nothing and cell["alive"] and cell["ctype"] == CWData.CancerType.UNSTABLE \
			and not cell["unstable_used"] and game.can_pay(cell, CWData.MUTATE_COST):
		var idx: int = await game.ask(cell["pid"], {
			"kind": "confirm", "tag": "remutate", "prompt": "基因不稳定：付 0.5 能量再次突变？",
			"options": [{ "label": "再次突变", "data": {} }, { "label": "放弃", "data": {} }],
		})
		if idx == 0 and game.pay(cell, CWData.MUTATE_COST):
			cell["unstable_used"] = true
			await _roll_mutation(cell)


## 返回是否「无事发生」
func _roll_mutation(cell: Dictionary) -> bool:
	var r: int = await game.roll_shown(3, "突变", cell["pid"])
	match r:
		1:
			game.log_msg("【突变】无事发生")
			return true
		2:
			game.log_msg("【突变】抽卡，并削减 1 抗原记忆")
			game.cards.draw(cell, "突变")
			game.reduce_memory(1)
		3:
			# 效果扣减可致死（区别于费用支付，见规则总则）
			cell["energy"] -= CWData.MUTATE_EXTRA_LOSS
			game.log_msg("【突变】再扣 1.0 能量（余 %s），削减 3 抗原记忆" % CWData.fmt(maxi(cell["energy"], 0)))
			game.reduce_memory(3)
			if cell["energy"] <= 0:
				game.kill(cell)
	return false


func _blast_targets(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in game.tiles.keys():
		if CWData.hex_dist(c, cell["pos"]) > 2:
			continue
		if game.tiles[c]["tissue"] != CWData.Tissue.HEALTHY:
			continue
		if not game.cells_at(c, CWData.Faction.IMMUNE).is_empty():
			continue  # 免疫细胞所在格不受转化（与侵蚀同理）
		out.append(c)
	return out


func _do_blast(cell: Dictionary) -> void:
	var targets := _blast_targets(cell)
	game.log_msg("【自爆】%s 引爆！相邻 2 格内 %d 格健康组织转为癌组织" % [
		game.cell_name(cell), targets.size()])
	for c in targets:
		var t: Dictionary = game.tile(c)
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
	game.kill(cell)  # 自爆是「费用不能降至 0」的唯一例外（说明 #8）
	game.update_marks()


func _remodel_targets(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if game.tile(n)["tissue"] != CWData.Tissue.HEALTHY:
			continue
		if not game.cells_at(n, CWData.Faction.IMMUNE).is_empty():
			continue  # 目标有免疫细胞时无法发动
		var cancerous_adj := 0
		for m in CWData.neighbors(n):
			if game.is_cancerous(m):
				cancerous_adj += 1
		if cancerous_adj >= 2:
			out.append(n)
	return out


func _do_remodel(cell: Dictionary) -> void:
	var targets := _remodel_targets(cell)
	if targets.is_empty():
		return
	var opts: Array = []
	for c in targets:
		opts.append({ "label": "转化 %s" % str(c), "data": { "to": c } })
	var idx: int = await game.ask(cell["pid"], {
		"kind": "remodel_target", "prompt": "选择要转化的健康组织", "options": opts,
	})
	if not game.pay(cell, CWData.REMODEL_COST):
		return
	cell["remodel_used"] = true
	var c: Vector2i = opts[idx]["data"]["to"]
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.CANCER
	t["newborn"] = true
	t["solid"] = 0
	t["sticky"] = 0
	game.log_msg("【基质重塑】%s 转为癌组织" % str(c))


## 癌组织 → 健康组织（毒素/抗体反噬用；不积累记忆，见说明 #18）
func _to_healthy(c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.HEALTHY
	t["newborn"] = false
	t["solid"] = 0
	t["sticky"] = 0
