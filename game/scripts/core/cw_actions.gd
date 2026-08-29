## cw_actions.gd —— 主动技能与移动/攻击结算
##
## build_options(cell) 生成当前所有合法行动（含费用校验），execute() 执行。
## enter_tile() 是「进入一格」的唯一入口：定殖 / 净化 / 特殊组织收取 / 标记刷新
## 都在这里统一触发（移动、血管传送、复活落位、各种传送共用，见说明 #9）。
##
## **一个组织内只能容纳一个细胞**（PRD 棋盘设定）。所以凡是「把细胞放到某格」的地方，
## 合法性判断都是 `game.cells_at(c).is_empty()`，不再区分敌我。
## 唯一的例外是免疫【迁移】进癌细胞所在格 —— 那一下是为了触发攻击，
## 而攻击结算完之后要么癌细胞死了（免疫进格）、要么免疫弹回原格，落定时仍是一格一个。
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
	game.card_fx.hand_options(cell, opts)
	_discard_options(cell, opts)
	opts.append({ "label": "结束回合", "data": { "act": "end" } })
	return opts


func _immune_options(cell: Dictionary, opts: Array) -> void:
	var lvl := game.immune_level
	for n in CWData.neighbors(cell["pos"]):
		var enemies: Array = game.cells_at(n, CWData.Faction.CANCER)
		if enemies.is_empty():
			# 空格才谈得上「迁移」；有己方细胞占着就去不了（一格一细胞）
			if not game.cells_at(n).is_empty():
				continue
		elif not _attackable(enemies[0]):
			continue          # 骨肉瘤【刚性屏障】：站在固化癌组织上时不可被攻击
		var cost: int = game.tune.immune_move_cancerous[lvl] if game.is_cancerous(n) \
			else game.tune.immune_move_healthy[lvl]
		if not game.can_pay(cell, cost):
			continue
		var tag := "攻击" if not enemies.is_empty() else "迁移"
		opts.append({
			"label": "%s→%s（%s 能量）" % [tag, str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if _can_draw(cell) and game.can_pay(cell, CWData.IMMUNE_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（0.5 能量）", "data": { "act": "draw" } })
	if lvl >= 2 and not cell["differentiated"]:
		for t in _diff_choices():
			opts.append({
				"label": "分化为%s（免费）" % CWData.IMMUNE_TYPE_NAMES[t],
				"data": { "act": "differentiate", "type": t },
			})
	if cell["itype"] == CWData.ImmuneType.B_CELL \
			and cell["antibody_used"] < CWData.ANTIBODY_MAX_PER_ROUND \
			and game.can_pay(cell, CWData.ANTIBODY_COST):
		opts.append({ "label": "抗体（1.0 能量）", "data": { "act": "antibody" } })
	if cell["itype"] == CWData.ImmuneType.T_CELL:
		if cell["toxin_used"] < CWData.TOXIN_MAX_PER_ROUND \
				and game.can_pay(cell, CWData.TOXIN_COST) and not _toxin_targets(cell).is_empty():
			opts.append({ "label": "细胞毒素（1.0 能量）", "data": { "act": "toxin" } })
		if game.tile(cell["pos"])["tissue"] == CWData.Tissue.SOLID \
				and game.can_pay(cell, CWData.LYSE_COST):
			## 「裂解后要不要立刻净化」也是一个决定，摊成两个顶层选项 ——
			## 埋在 execute() 里再问一次，AI 就没法把一个行动当成原子来推演了
			opts.append({ "label": "裂解并净化（1.0 能量）",
				"data": { "act": "lyse", "purge": true } })
			opts.append({ "label": "裂解，暂不净化（1.0 能量）",
				"data": { "act": "lyse", "purge": false } })


## 骨肉瘤【刚性屏障】：免疫细胞无法攻击**处于固化癌组织上**的骨肉瘤细胞，
## 必须先用【裂解】等技能破除其所在格的固化状态。
func _attackable(target: Dictionary) -> bool:
	return not (target["ctype"] == CWData.CancerType.OSTEO
		and game.tile(target["pos"])["tissue"] == CWData.Tissue.SOLID)


func _cancer_options(cell: Dictionary, opts: Array) -> void:
	for n in CWData.neighbors(cell["pos"]):
		if not game.cells_at(n).is_empty():
			continue          # 一格一细胞：有任何细胞占着就去不了
		var cost := _cancer_move_cost(cell, n)
		if not game.can_pay(cell, cost):
			continue
		opts.append({
			"label": "移动→%s（%s 能量）" % [str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if _can_draw(cell) and game.can_pay(cell, CWData.CANCER_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（1.0 能量）", "data": { "act": "draw" } })
	if not cell["mutate_used"] and game.can_pay(cell, CWData.MUTATE_COST):
		opts.append({ "label": "突变（0.5 能量）", "data": { "act": "mutate" } })
	_type_options(cell, opts)


## 四种癌细胞各自的主动技能（PRD 癌细胞种类）
func _type_options(cell: Dictionary, opts: Array) -> void:
	match cell["ctype"]:
		CWData.CancerType.MELANOMA:
			# 【早期血行转移】：站在血管格上，每世界回合 1 次
			if not cell["metastasis_used"] \
					and CWData.special_of(cell["pos"]) == CWData.Special.VESSEL \
					and game.can_pay(cell, CWData.MELANOMA_HOMING_COST):
				for c in _homing_targets():
					opts.append({
						"label": "早期血行转移→%s（1.0 能量）" % str(c),
						"data": { "act": "homing", "to": c },
					})
		CWData.CancerType.SIGNET:
			# 【黏液破裂】：耗尽全部能量并死亡，至少要有 2.0
			if cell["energy"] >= CWData.MUCUS_MIN_ENERGY:
				opts.append({ "label": "黏液破裂（耗尽能量并死亡）", "data": { "act": "mucus" } })
		CWData.CancerType.SCLC:
			# 【转移】：向某方向跃进 5 格
			if game.can_pay(cell, CWData.METASTASIS_COST):
				for c in _jump_targets(cell):
					opts.append({
						"label": "转移：跃进至 %s（1.0 能量）" % str(c),
						"data": { "act": "jump", "to": c },
					})


## 能不能抽卡：每回合 3 次上限 + 手牌 8 张上限。
## 手牌满时**选项直接不出现** —— 团队 2026-08-28 定：想抽就先主动弃牌，
## 决策权留在玩家手上，也不必在抽完之后再插一次「弃哪张」的询问。
func _can_draw(cell: Dictionary) -> bool:
	return cell["draws_used"] < CWData.DRAW_MAX_PER_TURN \
		and cell["hand"].size() < CWData.HAND_MAX


func _cancer_move_cost(cell: Dictionary, dest: Vector2i) -> int:
	if game.is_cancerous(dest):
		return CWData.CANCER_MOVE_CANCEROUS
	# 小细胞肺癌【极简胞浆】：移动至健康组织的消耗**永久**降为 0.3
	if cell["ctype"] == CWData.CancerType.SCLC:
		return CWData.SCLC_MOVE_HEALTHY
	# 黑色素瘤【伪足穿透】：目标健康组织与 ≥2 格癌性组织相邻时，本次移动只要 0.2
	if cell["ctype"] == CWData.CancerType.MELANOMA and _cancerous_adj(dest) >= CWData.PSEUDOPOD_MIN_ADJ:
		return CWData.PSEUDOPOD_COST
	return CWData.CANCER_MOVE_HEALTHY


func _cancerous_adj(c: Vector2i) -> int:
	var n := 0
	for m in CWData.neighbors(c):
		if game.is_cancerous(m):
			n += 1
	return n


## 这个细胞**理论上**会用到哪些主动技能，按「细胞种类 + 免疫等级」列，
## **不看当前能量、位置、次数**。返回的是 act 串，顺序即按钮从左到右的顺序。
##
## 只给界面用：团队 2026-08-28 定「按钮不消失、只变暗」，
## 那就需要一份**稳定的按钮集合** —— 否则花掉能量会让按钮凭空少一个，
## 行动栏宽度跟着跳，连数字快捷键的编号都会变。
##
## **引擎和 AI 一律走 build_options()**，那里只列当前合法的行动。
## 这两份清单的差集，就是界面上该画成灰色的那些按钮。
func action_kinds(cell: Dictionary) -> Array[String]:
	var out: Array[String] = ["move", "draw"]
	if cell["faction"] == CWData.Faction.IMMUNE:
		## 分化只在 III 级解锁、且每个细胞一辈子一次 —— 用掉之后按钮就不该再占位了
		if game.immune_level >= 2 and not cell["differentiated"]:
			out.append("differentiate")
		match cell["itype"]:
			CWData.ImmuneType.B_CELL:
				out.append("antibody")
			CWData.ImmuneType.T_CELL:
				out.append("toxin")
				out.append("lyse")
	else:
		out.append("mutate")
		match cell["ctype"]:
			CWData.CancerType.MELANOMA:
				out.append("homing")
			CWData.CancerType.SIGNET:
				out.append("mucus")
			CWData.CancerType.SCLC:
				out.append("jump")
	return out


# ============ 执行 ============

func execute(cell: Dictionary, data: Dictionary) -> void:
	match data["act"]:
		"move":
			await _do_move(cell, data["to"], data["cost"])
		"draw":
			_do_draw(cell)
		"differentiate":
			_do_differentiate(cell, data["type"])
		"antibody":
			await _do_antibody(cell)
		"toxin":
			_do_toxin(cell)
		"lyse":
			_do_lyse(cell, data["purge"])
		"mutate":
			await _do_mutate(cell)
		"homing":
			_do_homing(cell, data["to"])
		"mucus":
			_do_mucus(cell)
		"jump":
			_do_jump(cell, data["to"])
		"play":
			game.card_fx.play(cell, data)
		"discard":
			_do_discard(cell, data["card"])


# ---- 移动 / 攻击 ----

func _do_move(cell: Dictionary, to: Vector2i, cost: int) -> void:
	if not game.pay(cell, cost):
		return
	if cell["faction"] == CWData.Faction.CANCER:
		enter_tile(cell, to)
		return
	# 免疫迁移：目标格有癌细胞 → 触发攻击。一格一细胞，所以最多只有一个。
	var enemies: Array = game.cells_at(to, CWData.Faction.CANCER)
	if enemies.is_empty():
		enter_tile(cell, to)
		return
	var target: Dictionary = enemies[0]
	var r: int = await game.roll_shown(6, "攻击", cell["pid"], to)
	if r <= 2:
		game.log_msg("　攻击掷骰 %d：失败，%s 被反弹回原格" % [r, game.cell_name(cell)])
		game.announce("攻击失败", to)
		# 规则原文反弹不造成伤害（旋钮默认 0）；平衡测试可给癌方反击手段
		if game.tune.counter_dmg_on_fail > 0:
			game.cancer_hit(cell, game.tune.counter_dmg_on_fail, "反弹")
			if not cell["alive"]:
				return
	else:
		var dmg: int = game.tune.attack_dmg_crit if r == 6 else game.tune.attack_dmg_success
		var verdict := "大成功" if r == 6 else "成功"
		game.log_msg("　攻击掷骰 %d：%s" % [r, verdict])
		game.announce("攻击%s" % verdict, to)
		game.immune_hit(target, dmg, cell)
	# 目标格已无存活癌细胞才进入（击杀进格；否则返回原格）
	if game.cells_at(to, CWData.Faction.CANCER).is_empty():
		enter_tile(cell, to)
	else:
		game.log_msg("　%s 返回原格" % game.cell_name(cell))


## 进入一格的统一结算：癌细胞【定殖】、免疫【净化】、特殊组织收取、黏液清除、标记刷新
func enter_tile(cell: Dictionary, dest: Vector2i) -> void:
	cell["pos"] = dest
	var t: Dictionary = game.tile(dest)
	if cell["faction"] == CWData.Faction.CANCER and t["tissue"] == CWData.Tissue.HEALTHY:
		_to_cancer(dest, true)
		game.log_msg("　【定殖】%s 转为癌组织" % str(dest))
	elif cell["faction"] == CWData.Faction.IMMUNE and t["tissue"] == CWData.Tissue.CANCER:
		t["tissue"] = CWData.Tissue.HEALTHY
		t["newborn"] = false
		t["solid"] = 0
		game.gain_memory(1)
		game.log_msg("　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(dest), game.memory])
		if cell["itype"] == CWData.ImmuneType.MACRO:
			cell["energy"] += CWData.MACRO_HEAL_PURIFY
			game.log_msg("　巨噬【吞噬】恢复 0.3 能量")
	# 「粘液」无法被技能清除，但被免疫细胞接触后立即消失（PRD 印戒细胞癌）
	if cell["faction"] == CWData.Faction.IMMUNE and t["mucus"]:
		t["mucus"] = false
		game.log_msg("　【黏液】%s 的黏液被免疫细胞清除" % str(dest))
	collect_special(cell, dest)
	game.update_marks()


## 收取特殊组织存储（进入时 & 产出瞬间站于其上时调用）
func collect_special(cell: Dictionary, c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	if t["special"] == CWData.Special.CORE and t["store"] > 0:
		cell["energy"] += t["store"]
		game.log_msg("　%s 从代谢核心获取 %s 能量" % [game.cell_name(cell), CWData.fmt(t["store"])])
		t["store"] = 0
	elif t["special"] == CWData.Special.MARROW and t["cards"] > 0:
		## 手牌满时不发卡，**卡留在骨髓里**下次再来拿（团队 2026-08-28 定，不浪费）
		if cell["hand"].size() >= CWData.HAND_MAX:
			game.log_msg("　%s 手牌已满，骨髓的卡留着" % game.cell_name(cell))
		else:
			t["cards"] = 0
			game.cards.draw(cell, "骨髓")


# ---- 通用技能 ----

## 【基因表达】：每个行动回合最多 3 次（PRD 主动技能）
func _do_draw(cell: Dictionary) -> void:
	var cost: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
		else CWData.CANCER_DRAW_COST
	if game.pay(cell, cost):
		cell["draws_used"] += 1
		game.cards.draw(cell, "基因表达")


## 手牌可随时弃置（PRD 卡牌规则 3）。手牌满想抽新卡时先弃再抽（团队 2026-08-28 定）。
func _discard_options(cell: Dictionary, opts: Array) -> void:
	for card in cell["hand"]:
		opts.append({ "label": "弃置【%s】" % card, "data": { "act": "discard", "card": card } })


func _do_discard(cell: Dictionary, card: String) -> void:
	if card in cell["hand"]:
		cell["hand"].erase(card)
		game.log_msg("%s 弃置【%s】（手牌余 %d）" % [
			game.cell_name(cell), card, cell["hand"].size()])


# ---- 免疫技能 ----

func _diff_choices() -> Array:
	var out: Array = []
	for t in [CWData.ImmuneType.B_CELL, CWData.ImmuneType.T_CELL,
			CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		if t not in game.differentiated:  # 每种细胞全阵营仅能有一个
			out.append(t)
	return out


func _do_differentiate(cell: Dictionary, t: int) -> void:
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
	var roll: int = await game.roll_shown(3, "抗体", cell["pid"], cell["pos"])
	var x: int = 1 if roll <= 2 else 2
	game.announce("抗体：转化 %d 格" % x, cell["pos"])
	for c in game.pick_random(eligible, x):
		_to_healthy(c)
		game.log_msg("【抗体】无目标 → %s 转为健康组织" % str(c))


func _toxin_targets(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER:
			out.append(n)
	return out


## 【细胞毒素】（PRD T 细胞）：消耗 1.0，使**相邻所有格**中的癌组织转为健康组织，
## 对范围内所有癌细胞造成 1.0 能量损失，并使范围内**新生健康组织**所有格进入「坏死」。
## 每世界回合最多 3 次。
##
## 注意这里**不再**回避「有癌细胞站着的格」（旧说明 #20）—— PRD 写的是「所有格中的癌组织」，
## 而且同一条技能紧接着就要对那些癌细胞造成伤害，显然是打算连人带地一起处理。
## 癌细胞站在健康组织上是合法的过渡态：【定殖】只在「经过」时触发（说明 #9），
## 已经站着的不会重新把脚下染回去。
func _do_toxin(cell: Dictionary) -> void:
	var targets := _toxin_targets(cell)
	if targets.is_empty() or not game.pay(cell, CWData.TOXIN_COST):
		return
	cell["toxin_used"] += 1
	for c in targets:
		_to_healthy(c)
		game.tile(c)["necrosis"] = CWData.NECROSIS_TOXIN
	game.log_msg("【细胞毒素】相邻 %d 格癌组织转为健康组织并进入「坏死」（不积累记忆）" % targets.size())
	for n in CWData.neighbors(cell["pos"]):
		for enemy in game.cells_at(n, CWData.Faction.CANCER):
			game.immune_hit(enemy, CWData.ATTACK_DMG_SUCCESS, cell)


func _do_lyse(cell: Dictionary, purge: bool) -> void:
	if not game.pay(cell, CWData.LYSE_COST):
		return
	var pos: Vector2i = cell["pos"]
	var t: Dictionary = game.tile(pos)
	t["tissue"] = CWData.Tissue.CANCER
	t["solid"] = 0
	game.log_msg("【裂解】%s 由固化癌组织转为癌组织" % str(pos))
	if purge:
		t["tissue"] = CWData.Tissue.HEALTHY
		game.gain_memory(1)
		game.log_msg("　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(pos), game.memory])


# ---- 癌症通用技能 ----

func _do_mutate(cell: Dictionary) -> void:
	if not game.pay(cell, CWData.MUTATE_COST):
		return
	cell["mutate_used"] = true
	await _roll_mutation(cell)


func _roll_mutation(cell: Dictionary) -> void:
	var r: int = await game.roll_shown(3, "突变", cell["pid"], cell["pos"])
	match r:
		1:
			game.log_msg("【突变】无事发生")
			game.announce("突变：无事发生", cell["pos"])
		2:
			game.log_msg("【突变】抽卡，并削减 1 抗原记忆")
			game.announce("突变：抽一张 · 记忆 -1", cell["pos"])
			game.cards.draw(cell, "突变")
			game.reduce_memory(1)
		3:
			# 效果扣减可致死（区别于费用支付，见规则总则）
			cell["energy"] -= CWData.MUTATE_EXTRA_LOSS
			game.log_msg("【突变】再扣 1.0 能量（余 %s），削减 3 抗原记忆" % CWData.fmt(maxi(cell["energy"], 0)))
			game.announce("突变：能量 -1.0 · 记忆 -3", cell["pos"])
			game.reduce_memory(3)
			if cell["energy"] <= 0:
				game.kill(cell)


# ---- 恶性黑色素瘤 ----

## 【早期血行转移】的落点：全场任意一个**无细胞占据**的健康组织。
## PRD 原文写的是「未被免疫细胞占据」，但棋盘规则是一格只能有一个细胞，
## 所以实际约束更严 —— 己方细胞占着的格同样去不了。
func _homing_targets() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY and game.cells_at(c).is_empty():
			out.append(c)
	out.sort()   # 固定候选顺序，保证同种子可复现
	return out


func _do_homing(cell: Dictionary, to: Vector2i) -> void:
	if not game.pay(cell, CWData.MELANOMA_HOMING_COST):
		return
	cell["metastasis_used"] = true
	game.log_msg("【早期血行转移】%s 自血管转移至 %s" % [game.cell_name(cell), str(to)])
	enter_tile(cell, to)   # 落地即【定殖】，把该格转为癌组织


# ---- 印戒细胞癌 ----

## 【黏液破裂】：耗尽全部能量（至少 2.0）并死亡。自身所在格及周围 2 格所有组织进入
## 「黏液侵染」，其中随机最多 8 格立即转为癌组织，范围内的免疫细胞损失 2.0 能量。
##
## ⚠ PRD 只说了「粘液」无法被技能清除、被免疫细胞接触后消失，**没有写它本身有什么效果**。
## 这里如实实现成一个标记：会随棋盘存续、会被免疫细胞踩掉，但不产生任何结算影响。
## 等 PRD 补上效果再往 t["mucus"] 上挂。
func _do_mucus(cell: Dictionary) -> void:
	var area: Array[Vector2i] = []
	for c in game.tiles.keys():
		if CWData.hex_dist(c, cell["pos"]) <= CWData.MUCUS_RADIUS:
			area.append(c)
	area.sort()
	for c in area:
		game.tile(c)["mucus"] = true
	var healthy: Array[Vector2i] = []
	for c in area:
		if game.tile(c)["tissue"] == CWData.Tissue.HEALTHY:
			healthy.append(c)
	var picked: Array = game.pick_random(healthy, CWData.MUCUS_MAX_CONVERT)
	for c in picked:
		_to_cancer(c, true)
	game.log_msg("【黏液破裂】%s 引爆：%d 格进入黏液侵染，其中 %d 格转为癌组织" % [
		game.cell_name(cell), area.size(), picked.size()])
	game.announce("黏液破裂", cell["pos"])
	for c in area:
		for immune in game.cells_at(c, CWData.Faction.IMMUNE):
			game.cancer_hit(immune, CWData.MUCUS_IMMUNE_LOSS, "黏液破裂")
	game.kill(cell)   # 自毁型技能：耗尽能量并死亡（说明 #8 的同类）
	game.update_marks()


# ---- 小细胞肺癌 ----

## 【转移】：向某方向跃进 5 格。落点必须在棋盘上且无细胞占据。
func _jump_targets(cell: Dictionary) -> Array:
	var out: Array = []
	for d in CWData.DIRS:
		var to: Vector2i = cell["pos"] + d * CWData.METASTASIS_RANGE
		if CWData.is_on_board(to) and game.cells_at(to).is_empty():
			out.append(to)
	return out


## 跃进路径上不触发【定殖】、代谢核心/骨髓收取等效果，**终点可以触发**（PRD）——
## 所以这里直接 enter_tile 到终点，中间格连碰都不碰。
func _do_jump(cell: Dictionary, to: Vector2i) -> void:
	if not game.pay(cell, CWData.METASTASIS_COST):
		return
	game.log_msg("【转移】%s 跃进 5 格至 %s" % [game.cell_name(cell), str(to)])
	enter_tile(cell, to)


# ---- 组织状态切换（只有这两个函数能改 tissue，别在别处手写）----

## 健康组织 → 癌组织。newborn 决定本世界回合能否被【固化】计数。
## 「坏死」是健康组织才有的状态，转成癌组织时一并清掉。
func _to_cancer(c: Vector2i, newborn: bool) -> void:
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.CANCER
	t["newborn"] = newborn
	t["solid"] = 0
	t["necrosis"] = 0


## 癌组织 → 健康组织（毒素/抗体反噬用；不积累记忆，见说明 #18）
func _to_healthy(c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	t["tissue"] = CWData.Tissue.HEALTHY
	t["newborn"] = false
	t["solid"] = 0
