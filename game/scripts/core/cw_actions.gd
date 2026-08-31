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
	opts.append_array(immune_move_options(cell))
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
			and game.can_pay(cell, antibody_cost(cell)):
		opts.append({ "label": "抗体（%s 能量）" % CWData.fmt(antibody_cost(cell)),
			"data": { "act": "antibody" } })
	if cell["itype"] == CWData.ImmuneType.T_CELL:
		if cell["toxin_used"] < CWData.TOXIN_MAX_PER_ROUND \
				and game.can_pay(cell, CWData.TOXIN_COST) and not _toxin_targets(cell).is_empty():
			opts.append({ "label": "细胞毒素（1.0 能量）", "data": { "act": "toxin" } })
		if game.tile(cell["pos"])["tissue"] == CWData.Tissue.SOLID:
			## 「裂解后要不要立刻净化」也是一个决定，摊成两个顶层选项 ——
			## 埋在 execute() 里再问一次，AI 就没法把一个行动当成原子来推演了。
			## 净化那一档在【免疫抑制因子】生效时要加 0.2 净化费（定案 W5）。
			var purge_cost: int = _purge_cost(cell)
			if game.can_pay(cell, purge_cost):
				opts.append({ "label": "裂解并净化（%s 能量）" % CWData.fmt(purge_cost),
					"data": { "act": "lyse", "purge": true } })
			if game.can_pay(cell, CWData.LYSE_COST):
				opts.append({ "label": "裂解，暂不净化（1.0 能量）",
					"data": { "act": "lyse", "purge": false } })


## 免疫的迁移/攻击选项（含费用与可支付校验）。
## 单独成函数是因为【全身免疫动员】的「立即迁移 1 次」也用这一份 ——
## 迁移合法性和定价只定义一处，事件和行动栏永远口径一致。
func immune_move_options(cell: Dictionary) -> Array:
	var opts: Array = []
	for n in CWData.neighbors(cell["pos"]):
		if not _is_move_legal_now(cell, n):
			continue          # 与提交时复验的是同一份谓词
		var enemies: Array = game.cells_at(n, CWData.Faction.CANCER)
		var cost := _move_cost_mod(cell, n, _move_base_cost(cell, n))
		if not game.can_pay(cell, cost):
			continue
		var tag := "攻击" if not enemies.is_empty() else "迁移"
		opts.append({
			"label": "%s→%s（%s 能量）" % [tag, str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	return opts


## 骨肉瘤【刚性屏障】：免疫细胞无法攻击**处于固化癌组织上**的骨肉瘤细胞，
## 必须先用【裂解】等技能破除其所在格的固化状态。
func _attackable(target: Dictionary) -> bool:
	return not (target["ctype"] == CWData.CancerType.OSTEO
		and game.tile(target["pos"])["tissue"] == CWData.Tissue.SOLID)


# ---- 合法性谓词：选项生成与提交复验**共用同一份** ----
#
# 2026-08-31 队友审查发现 CWCost.commit() 只重新报价、不复验合法性，而注释却写着
# 「重新验证 → 重新报价」。取消打断窗口后这条路暂时走不到（pending 生成选项后
# 紧接着就 step 执行），但它是契约债：联机延迟、重复提交、快照回滚后复用旧选择、
# 异步询问期间盘面变化，任何一条都会把它变成真 bug。
#
# **两边必须复用同一个函数。** 各写一套的话，就又长出了「标价与收费对不上」那类问题。

## 迁移/攻击到相邻格是否合法。不看能量（那是报价的事），只看盘面。
func _is_move_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	if not cell["alive"] or not CWData.is_on_board(to):
		return false
	if not (to in CWData.neighbors(cell["pos"])):
		return false
	if cell["faction"] == CWData.Faction.CANCER:
		return game.cells_at(to).is_empty()          ## 一格一细胞
	## 免疫：空格才谈得上「迁移」；有癌细胞则这一下是攻击，要过刚性屏障
	var enemies: Array = game.cells_at(to, CWData.Faction.CANCER)
	if enemies.is_empty():
		return game.cells_at(to).is_empty()
	return _attackable(enemies[0])


## 黑色素瘤【早期血行转移】：站在血管格上、本世界回合还没用过、落点是空的健康组织
func _is_homing_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	if not cell["alive"] or cell["metastasis_used"]:
		return false
	if CWData.special_of(cell["pos"]) != CWData.Special.VESSEL:
		return false
	return game.tile(to)["tissue"] == CWData.Tissue.HEALTHY and game.cells_at(to).is_empty()


## 小细胞肺癌【转移】：落点在棋盘上且无细胞占据
func _is_jump_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	return cell["alive"] and CWData.is_on_board(to) and game.cells_at(to).is_empty()


## T 细胞【裂解】：脚下仍是固化癌组织
func _is_lyse_legal_now(cell: Dictionary) -> bool:
	return cell["alive"] and game.tile(cell["pos"])["tissue"] == CWData.Tissue.SOLID


func _cancer_options(cell: Dictionary, opts: Array) -> void:
	for n in CWData.neighbors(cell["pos"]):
		if not _is_move_legal_now(cell, n):
			continue          # 与提交时复验的是同一份谓词
		var cost := _move_cost_mod(cell, n, _move_base_cost(cell, n))
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
			var homing_cost := _skill_move_cost(cell, CWData.MELANOMA_HOMING_COST)
			if not cell["metastasis_used"] \
					and CWData.special_of(cell["pos"]) == CWData.Special.VESSEL \
					and game.can_pay(cell, homing_cost):
				for c in _homing_targets():
					opts.append({
						"label": "早期血行转移→%s（%s 能量）" % [str(c), CWData.fmt(homing_cost)],
						"data": { "act": "homing", "to": c },
					})
		CWData.CancerType.SIGNET:
			# 【黏液破裂】：耗尽全部能量并死亡，至少要有 2.0
			if cell["energy"] >= CWData.MUCUS_MIN_ENERGY:
				opts.append({ "label": "黏液破裂（耗尽能量并死亡）", "data": { "act": "mucus" } })
		CWData.CancerType.SCLC:
			# 【转移】：向某方向跃进 5 格
			var jump_cost := _skill_move_cost(cell, CWData.METASTASIS_COST)
			if game.can_pay(cell, jump_cost):
				for c in _jump_targets(cell):
					opts.append({
						"label": "转移：跃进至 %s（%s 能量）" % [str(c), CWData.fmt(jump_cost)],
						"data": { "act": "jump", "to": c },
					})


## 能不能抽卡：每回合 3 次上限 + 手牌 8 张上限。
## 手牌满时**选项直接不出现** —— 团队 2026-08-28 定：想抽就先主动弃牌，
## 决策权留在玩家手上，也不必在抽完之后再插一次「弃哪张」的询问。
func _can_draw(cell: Dictionary) -> bool:
	return cell["draws_used"] < CWData.DRAW_MAX_PER_TURN \
		and cell["hand"].size() < CWData.HAND_MAX


## 四个单价都走 `game.tune`（默认值 = CWData 常量 = PRD），
## 因为「占地单价」是平衡的根因，要能不改引擎就扫。见 CWTuning「癌方移动费用」那段。
func _cancer_move_cost(cell: Dictionary, dest: Vector2i) -> int:
	if game.is_cancerous(dest):
		return game.tune.cancer_move_cancerous
	# 小细胞肺癌【极简胞浆】：移动至健康组织的消耗**永久**降为折后价（口径 #82 后是 0.7）
	if cell["ctype"] == CWData.CancerType.SCLC:
		return game.tune.sclc_move_healthy
	# 黑色素瘤【伪足穿透】：目标健康组织与 ≥2 格癌性组织相邻时走折后价（口径 #82 后是 0.5）
	if cell["ctype"] == CWData.CancerType.MELANOMA and _cancerous_adj(dest) >= CWData.PSEUDOPOD_MIN_ADJ:
		return game.tune.pseudopod_cost
	return game.tune.cancer_move_healthy


func _cancerous_adj(c: Vector2i) -> int:
	var n := 0
	for m in CWData.neighbors(c):
		if game.is_cancerous(m):
			n += 1
	return n


## 移动费的**基准价**（设计 §四 的第②层）：行动本身 + 免疫等级 + 细胞自带技能
## （黑色素瘤【伪足穿透】、小细胞肺癌【极简胞浆】都在 _cancer_move_cost 里）。
## 基准价之上的所有修饰交给 CWCost —— 卡牌、永久技能、世界事件一律以
## CostModifier 的形式登记在 CWCost.TEMPLATES，本文件不再自己判谁减多少。
func _move_base_cost(cell: Dictionary, dest: Vector2i) -> int:
	if cell["faction"] == CWData.Faction.CANCER:
		return _cancer_move_cost(cell, dest)
	if game.is_cancerous(dest):
		return game.tune.immune_move_cancerous[game.immune_level]
	return game.tune.immune_move_healthy[game.immune_level]


## 移动到某格要多少钱（**纯查询**，不消耗任何额度）。行动菜单、AI 评估、界面价签都走这个。
## 2026-08-30 起转由 CWCost 计算：修饰按语义阶段排序，来源顺序只是同阶段的平局规则。
func _move_cost_mod(cell: Dictionary, dest: Vector2i, base: int) -> int:
	return game.cost.quote(CWCost.context(cell, CWCost.Action.MOVE, base, dest))["final"]


## 技能移动（小细胞肺癌【转移】、黑色素瘤【早期血行转移】）的报价。
## 它们不是【迁移】，走 CELL_SKILL 上下文——目前只有【基质阻隔】的翻倍挂得上。
func _skill_move_cost(cell: Dictionary, base: int) -> int:
	return game.cost.quote(CWCost.context(cell, CWCost.Action.CELL_SKILL, base))["final"]


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
			await _do_draw(cell)
		"differentiate":
			_do_differentiate(cell, data["type"])
		"antibody":
			await _do_antibody(cell)
		"toxin":
			_do_toxin(cell)
		"lyse":
			await _do_lyse(cell, data["purge"])
		"mutate":
			await _do_mutate(cell)
		"homing":
			await _do_homing(cell, data["to"])
		"mucus":
			_do_mucus(cell)
		"jump":
			await _do_jump(cell, data["to"])
		"play":
			await game.card_fx.play(cell, data)
		"discard":
			_do_discard(cell, data["card"])


# ---- 移动 / 攻击 ----

## 骰面 → 基础判定。默认 1~2 失败 / 3~5 成功 / 6 大成功；
## 攻击者装备【免疫突触成熟】时改为 1/6 失败、1/2 成功、1/3 大成功
## （d6 落法：1 失败 / 2~4 成功 / 5~6 大成功）。
func base_verdict(r: int, attacker: Dictionary = {}) -> String:
	if not attacker.is_empty() and game.has_skill(attacker, "免疫突触成熟"):
		return "crit" if r >= 5 else ("fail" if r == 1 else "success")
	return "crit" if r == 6 else ("fail" if r <= 2 else "success")


## 基础判定再套世界事件修正（并给，不重掷）——
## 【细胞毒】失败并给成功（PRD：5/6 成功、1/6 大成功）；
## 【免疫伪装】大成功并给成功（PRD：1/3 失败、2/3 成功；2026-08-29 按 PRD 改判）
func attack_outcome(r: int, attacker: Dictionary = {}) -> String:
	var out := base_verdict(r, attacker)
	if out == "fail" and game.event_stacks("细胞毒") > 0:
		out = "success"
	if out == "crit" and game.event_stacks("免疫伪装") > 0:
		out = "success"
	return out


## base = 报价的起点。默认 -1 表示「现算」（_move_base_cost）——
## 只有【炎症性趋化】那种自带基准价（每步 0.2）的调用点需要显式传进来。
##
## cost 是**调用方看到的旧价钱**，只用来核对；真正扣多少以 commit() 当场重算为准
## （设计 §七.2「不把旧价格当权威」）。两者不一致说明选项建好之后局面变了，
## 喊一声，别静默按另一个价钱扣费。
func _do_move(cell: Dictionary, to: Vector2i, cost: int, base: int = -1) -> void:
	var ctx := CWCost.context(cell, CWCost.Action.MOVE,
		base if base >= 0 else _move_base_cost(cell, to), to, 0,
		func() -> bool: return _is_move_legal_now(cell, to))
	var q := game.cost.commit(ctx)
	if q.is_empty():
		return          ## 不合法或付不起——能量、修饰、闸门一概没动
	if int(q["final"]) != cost:
		game.log_msg("! 移动费标价 %s 与兑现 %s 不一致（局面已变）" % [
			CWData.fmt(cost), CWData.fmt(int(q["final"]))])
	if cell["faction"] == CWData.Faction.CANCER:
		var was_healthy: bool = game.tile(to)["tissue"] == CWData.Tissue.HEALTHY
		await enter_tile(cell, to)
		## 【RAS持续激活】每行动回合第一次通过【移动】触发【定殖】→ 恢复（分期）。
		## 只认移动——enter_tile 也服务传送/复活，所以钩在这里而不是那里
		if was_healthy and game.has_skill(cell, "RAS持续激活") \
				and game.first_this_turn(cell, "RAS持续激活"):
			var ras: int = CWData.RAS_HEAL[CWCardData.cancer_phase(game.round_no)]
			cell["energy"] += ras
			game.log_msg("　【RAS持续激活】首次定殖：恢复 %s 能量（现 %s）" % [
				CWData.fmt(ras), CWData.fmt(cell["energy"])])
		return
	# 免疫迁移：目标格有癌细胞 → 触发攻击。一格一细胞，所以最多只有一个。
	var enemies: Array = game.cells_at(to, CWData.Faction.CANCER)
	if enemies.is_empty():
		await enter_tile(cell, to)
		return
	var target: Dictionary = enemies[0]
	## ---- 判定链（定案 #59/#60）----
	## 骰面 → 世界事件并给（attack_outcome）→【补体调理】失败自动重掷（重掷严格不劣，
	## 不必发问）→ 防御方【PD-L1表达】最后压一级。【高亲和力克隆】不掷骰直接大成功，
	## 管骰面概率的世界事件因此不介入，但 PD-L1 照压（它压的是「判定」不是骰面）。
	## 补体调理/高亲和力克隆骑在「下一次攻击」上：无论结果如何，这次攻击就把它们消耗掉。
	var opsonin := game.spend_mods(cell, "补体调理")
	var affinity := game.spend_mods(cell, "高亲和力克隆")
	var was_marked: bool = target["marked"]   ## 【抗原呈递强化】要知道攻击前的标记状态
	## 【抗体亲和力成熟】每行动回合第一次攻击「与健康组织相邻」的癌细胞 +0.5。
	## 闸门在攻击**发动**时消耗（判定失败也算攻过，口径 #70），加成只在命中时兑现
	var matured := 0
	if game.has_skill(cell, "抗体亲和力成熟") and _adjacent_healthy(to) \
			and game.first_this_turn(cell, "抗体亲和力成熟"):
		matured = CWData.MATURED_ATTACK_EXTRA
	var outcome: String
	var r := 0
	if affinity > 0:
		outcome = "crit"
		game.log_msg("　【高亲和力克隆】不进行随机判定，直接视为大成功")
	else:
		r = await game.roll_shown(6, "攻击", cell["pid"], to)
		outcome = _judged(r, cell)
		var rerolls := opsonin
		while outcome == "fail" and rerolls > 0:
			rerolls -= 1
			game.log_msg("　【补体调理】攻击失败：重新判定一次，以第二次结果为准")
			r = await game.roll_shown(6, "攻击", cell["pid"], to)
			outcome = _judged(r, cell)
	for i in game.spend_mods(target, "PD-L1表达"):
		var was := outcome
		outcome = _downgrade(outcome)
		game.log_msg("　【PD-L1表达】判定下降一级（%s → %s）" % [
			VERDICT_NAMES[was], VERDICT_NAMES[outcome]])
	if outcome == "fail":
		game.log_msg("　攻击失败，%s 被反弹回原格" % game.cell_name(cell))
		game.announce("攻击失败", to)
		## 【抗原变异】攻击失败 → 被攻击的癌细胞抽牌（按层数）
		for i in game.event_stacks("抗原变异"):
			await game.cards.draw(target, "抗原变异")
		## PRD：攻击失败时攻击者「自身-0.5能量」（口径 #84）。走 cancer_hit 而不是直接扣，
		## 是为了让它和别的损失一样吃减伤/护盾/死亡检查——注意按口径 #62，
		## 反弹**不算**「癌细胞技能造成的损失」，【缺氧适应】挡不住它。
		if game.tune.counter_dmg_on_fail > 0:
			game.cancer_hit(cell, game.tune.counter_dmg_on_fail, "反弹")
			if not cell["alive"]:
				return
	else:
		var crit := outcome == "crit"
		var dmg: int = game.tune.attack_dmg_crit if crit else game.tune.attack_dmg_success
		game.announce("攻击%s" % ("大成功" if crit else "成功"), to)
		## 「攻击成功后」的修饰/技能在此消耗（定案 #58：含大成功）。
		## 额外伤害走管线第②步「固定数值增加」——被【标记】翻倍是管线顺序使然。
		var extra := CWData.OPSONIN_EXTRA * opsonin + CWData.AFFINITY_EXTRA * affinity + matured
		var perf := game.spend_mods(cell, "穿孔素-颗粒酶")
		if perf > 0:
			var per: int = CWData.PERFORIN_EXTRA_T if cell["itype"] == CWData.ImmuneType.T_CELL \
				else CWData.PERFORIN_EXTRA
			extra += per * perf
		## 【细胞毒性增强】非 T：每行动回合首次攻击成功 +1.0（进管线的②固定增加）；
		## T 细胞：每次成功 +1.0 且「不受减伤效果影响」（口径 #67）——按设计 §6.4
		## 做成**关联到主攻击的次级伤害事件**，带 UNPREVENTABLE：
		## 它跳过数值减免，但**不**跳过日志、实际伤害统计、BCL-2 与死亡检查。
		var cytotox_direct := 0
		if game.has_skill(cell, "细胞毒性增强"):
			if cell["itype"] == CWData.ImmuneType.T_CELL:
				cytotox_direct = CWData.CYTOTOX_EXTRA
			elif game.first_this_turn(cell, "细胞毒性增强"):
				extra += CWData.CYTOTOX_EXTRA
		if extra > 0:
			game.log_msg("　攻击类修饰：额外造成 %s 能量损失" % CWData.fmt(extra))
		## 【抗原丢失】的免疫判定住在管线的「替代/免疫」层（设计 §5.2），这里不再自己拦：
		## 被整体免疫的事件视为未造成伤害，护盾、标记与斩杀都不会被骗掉
		## 主攻击与它的次级伤害**必须同批**（2026-08-31 队友审查问题 2 的第四条语义）：
		## 拆开的话主伤害先结算死亡、【BCL-2抗凋亡】先把能量拉回分期值，
		## 次级伤害再补一刀 —— 反而可能绕过 BCL-2 把人打死。
		var group := game.damage.next_group()
		var events: Array = [game.damage.event(cell, target, dmg, CWDamage.Kind.ATTACK,
			[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK], "攻击", extra, group)]
		if cytotox_direct > 0:
			events.append(game.damage.event(cell, target, cytotox_direct,
				CWDamage.Kind.ATTACK,
				[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK, CWDamage.Tag.DIRECT,
					CWDamage.Tag.UNPREVENTABLE, CWDamage.Tag.NO_LIFESTEAL],
				"细胞毒性增强", 0, group))
		## 【吞噬体成熟】的伤害后斩杀、巨噬【吞噬】的吸血都在 CWDamage 的伤后触发
		## 队列里（设计 §5.7）——2026-08-31 从这里挪走：死亡只该在死亡阶段发生，
		## 在攻击流程里另起一刀等于绕开那条约定
		game.damage.submit(events)
		## 【补体级联】的组织转化不是能量损失，【抗原丢失】拦不住它
		for i in game.spend_mods(cell, "补体级联"):
			_cascade(target)
		## 【抗原变异】攻击大成功 → 攻击方抽牌（按层数）
		if crit:
			for i in game.event_stacks("抗原变异"):
				await game.cards.draw(cell, "抗原变异")
	## 【抗原呈递强化】每世界回合第一次攻击未被【标记】的癌细胞后 → 施加【标记】。
	## 「攻击…后」按**攻击发动**读（口径 #70）：判定失败算攻过，把目标当场打死也算攻过，
	## 所以额度在这里就烧掉。**alive 判断刻意放在闸门之后**（团队 2026-08-30 定案 C）——
	## 写成两层是为了让「打死了也扣额度」是个自觉的选择，而不是 and 求值顺序的副产品。
	if game.has_skill(cell, "抗原呈递强化") and not was_marked \
			and game.first_this_round(cell, "抗原呈递强化"):
		if target["alive"]:
			game.apply_mark(target, cell)
			game.log_msg("　【抗原呈递强化】为 %s 施加【标记】" % game.cell_name(target))
		else:
			## 不出这一句的话，玩家看不出本世界回合的施加额度已经没了
			game.log_msg("　【抗原呈递强化】目标已死亡，本世界回合的施加额度就此用掉")
	# 目标格已无存活癌细胞才进入（击杀进格；否则返回原格）
	if game.cells_at(to, CWData.Faction.CANCER).is_empty():
		await enter_tile(cell, to)
	else:
		game.log_msg("　%s 返回原格" % game.cell_name(cell))


const VERDICT_NAMES := { "fail": "失败", "success": "成功", "crit": "大成功" }


## 骰面 → 判定，顺带把世界事件的并给记进日志（重掷时会再走一遍）
func _judged(r: int, attacker: Dictionary) -> String:
	var base := base_verdict(r, attacker)
	var out := attack_outcome(r, attacker)
	if base == "fail" and out != "fail":
		game.log_msg("　【细胞毒】攻击不会失败：判定并给成功")
	elif base == "crit" and out != "crit":
		game.log_msg("　【免疫伪装】攻击不会大成功：判定并给成功")
	game.log_msg("　攻击掷骰 %d：%s" % [r, VERDICT_NAMES[out]])
	return out


## 【PD-L1表达】：大成功→成功、成功→失败、失败不变
func _downgrade(v: String) -> String:
	match v:
		"crit":
			return "success"
		"success":
			return "fail"
	return "fail"


## 【补体级联】攻击成功后：目标癌细胞相邻的普通癌组织里，随机最多 2 格无细胞占据 → 健康
func _cascade(target: Dictionary) -> void:
	var cands: Array[Vector2i] = []
	for n in CWData.neighbors(target["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER and game.cells_at(n).is_empty():
			cands.append(n)
	var picked: Array = game.pick_random(cands, CWData.CASCADE_MAX_TILES)
	if picked.is_empty():
		game.log_msg("　【补体级联】目标相邻无可转化的癌组织，落空")
		return
	for c in picked:
		_to_healthy(c)
		game.log_msg("　【补体级联】%s 转为健康组织" % str(c))


## 进入一格的统一结算：癌细胞【定殖】、免疫【净化】、特殊组织收取、黏液清除、标记刷新。
## 是协程：踩上骨髓可能抽到要中途选择的事件卡（await 链见 cw_card_fx 头注），
## 所有调用点都要 await —— 漏了 await 的那条链会脱离结算顺序，复现测试会当场炸。
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
		if game.event_stacks("免疫抑制因子") > 0:
			game.log_msg("　【净化】%s 转为健康组织（免疫抑制因子：不获得抗原记忆）" % str(dest))
		else:
			game.gain_memory(1)
			game.log_msg("　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(dest), game.memory])
		if cell["itype"] == CWData.ImmuneType.MACRO:
			cell["energy"] += CWData.MACRO_HEAL_PURIFY
			game.log_msg("　巨噬【吞噬】恢复 0.3 能量")
		await _on_purify(cell)
	# 「粘液」无法被技能清除，但被免疫细胞接触后立即消失（PRD 印戒细胞癌）
	if cell["faction"] == CWData.Faction.IMMUNE and t["mucus"]:
		t["mucus"] = false
		game.log_msg("　【黏液】%s 的黏液被免疫细胞清除" % str(dest))
	await collect_special(cell, dest)
	game.update_marks()


## 收取特殊组织存储（进入时 & 产出瞬间站于其上时调用）
func collect_special(cell: Dictionary, c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	if t["special"] == CWData.Special.CORE and t["store"] > 0:
		var gain: int = t["store"]
		for i in game.event_stacks("代谢加速"):
			gain *= 2   ## 【代谢加速】进入代谢核心获得的能量翻倍
		cell["energy"] += gain
		game.log_msg("　%s 从代谢核心获取 %s 能量" % [game.cell_name(cell), CWData.fmt(gain)])
		t["store"] = 0
	elif t["special"] == CWData.Special.MARROW and t["cards"] > 0:
		## 手牌满时不发卡，**卡留在骨髓里**下次再来拿（团队 2026-08-28 定，不浪费）
		if cell["hand"].size() >= CWData.HAND_MAX:
			game.log_msg("　%s 手牌已满，骨髓的卡留着" % game.cell_name(cell))
		else:
			t["cards"] = 0
			await game.cards.draw(cell, "骨髓")


# ---- 通用技能 ----

## 【基因表达】：每个行动回合最多 3 次（PRD 主动技能）
func _do_draw(cell: Dictionary) -> void:
	var cost: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
		else CWData.CANCER_DRAW_COST
	if game.pay(cell, cost):
		cell["draws_used"] += 1
		await game.cards.draw(cell, "基因表达")


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


## 【抗体亲和力成熟】B 细胞强化：抗体费 1.0 → 0.5、每目标伤害 1.0 → 1.5
func antibody_cost(cell: Dictionary) -> int:
	return CWData.MATURED_ANTIBODY_COST if game.has_skill(cell, "抗体亲和力成熟") \
		else CWData.ANTIBODY_COST


func _do_antibody(cell: Dictionary) -> void:
	if not game.pay(cell, antibody_cost(cell)):
		return
	cell["antibody_used"] += 1
	var dmg: int = CWData.MATURED_ANTIBODY_DMG if game.has_skill(cell, "抗体亲和力成熟") \
		else CWData.ANTIBODY_DAMAGE
	var targets: Array = []
	for c in game.living_cells(CWData.Faction.CANCER):
		for n in CWData.neighbors(c["pos"]):
			if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
				targets.append(c)
				break
	if not targets.is_empty():
		game.log_msg("【抗体】命中 %d 个与健康组织邻接的癌细胞" % targets.size())
		## 多目标同时结算（设计 §5.5）。attack=false：抗体是「技能」不是普通攻击——
		## 树突/巨噬那两条挂不上（B 细胞专属，本就挂不上），
		## 而【DNA损伤修复】明写挡「技能」，要挡得到它
		game.immune_hit_area(targets, dmg, cell, "抗体")
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
	var victims: Array = []
	for n in CWData.neighbors(cell["pos"]):
		victims.append_array(game.cells_at(n, CWData.Faction.CANCER))
	## attack=false：细胞毒素是「技能」，同上（T 细胞专属）；【DNA损伤修复】可挡
	game.immune_hit_area(victims, CWData.ATTACK_DMG_SUCCESS, cell, "细胞毒素")


## 【裂解】的费用；purge=true 时【免疫抑制因子】的净化费经 PURIFY 上下文加在最后
func _purge_cost(cell: Dictionary) -> int:
	return game.cost.quote(CWCost.context(cell, CWCost.Action.PURIFY,
		CWData.LYSE_COST))["final"]


func _do_lyse(cell: Dictionary, purge: bool) -> void:
	var act := CWCost.Action.PURIFY if purge else CWCost.Action.CELL_SKILL
	if game.cost.commit(CWCost.context(cell, act, CWData.LYSE_COST, Vector2i.MAX, 0,
			func() -> bool: return _is_lyse_legal_now(cell))).is_empty():
		return
	var pos: Vector2i = cell["pos"]
	var t: Dictionary = game.tile(pos)
	t["tissue"] = CWData.Tissue.CANCER
	t["solid"] = 0
	game.log_msg("【裂解】%s 由固化癌组织转为癌组织" % str(pos))
	if purge:
		t["tissue"] = CWData.Tissue.HEALTHY
		if game.event_stacks("免疫抑制因子") > 0:
			game.log_msg("　【净化】%s 转为健康组织（免疫抑制因子：不获得抗原记忆）" % str(pos))
		else:
			game.gain_memory(1)
			game.log_msg("　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(pos), game.memory])
		await _on_purify(cell)


## 净化后的永久技能连锁——enter_tile 与裂解的「顺带净化」共用一个口。
## 是协程：【免疫记忆库】要抽卡（抽到事件卡还可能连锁发问）
func _on_purify(cell: Dictionary) -> void:
	if game.has_skill(cell, "模式识别增强") and game.first_this_round(cell, "模式识别增强"):
		cell["energy"] += CWData.SKILL_HEAL
		game.log_msg("　【模式识别增强】本世界回合首次净化：恢复 0.5 能量")
	if game.has_skill(cell, "效应记忆形成") and game.first_this_round(cell, "效应记忆形成"):
		game.gain_memory(1)
		cell["energy"] += CWData.SKILL_HEAL
		game.log_msg("　【效应记忆形成】本世界回合首次净化：+1 抗原记忆，恢复 0.5 能量")
	if game.has_skill(cell, "免疫记忆库") and game.first_this_round(cell, "免疫记忆库"):
		game.log_msg("　【免疫记忆库】本世界回合首次净化：免费抽取 1 张")
		await game.cards.draw(cell, "免疫记忆库")


# ---- 癌症通用技能 ----

func _do_mutate(cell: Dictionary) -> void:
	if not game.pay(cell, CWData.MUTATE_COST):
		return
	cell["mutate_used"] = true
	await roll_mutation(cell)


## 掷骰 + 结算拆成两半：【基因组不稳定】第 20 回合起要「掷两次、玩家挑一个结果」，
## 它只想复用结算那一半（apply_mutation），掷骰自己另掷
func roll_mutation(cell: Dictionary) -> void:
	var r: int = await game.roll_shown(3, "突变", cell["pid"], cell["pos"])
	await apply_mutation(cell, r)


func apply_mutation(cell: Dictionary, r: int) -> void:
	match r:
		1:
			game.log_msg("【突变】无事发生")
			game.announce("突变：无事发生", cell["pos"])
		2:
			game.log_msg("【突变】抽卡，并削减 1 抗原记忆")
			game.announce("突变：抽一张 · 记忆 -1", cell["pos"])
			await game.cards.draw(cell, "突变")
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
	if game.cost.commit(CWCost.context(cell, CWCost.Action.CELL_SKILL,
			CWData.MELANOMA_HOMING_COST, to, 0,
			func() -> bool: return _is_homing_legal_now(cell, to))).is_empty():
		return
	cell["metastasis_used"] = true
	game.log_msg("【早期血行转移】%s 自血管转移至 %s" % [game.cell_name(cell), str(to)])
	await enter_tile(cell, to)   # 落地即【定殖】，把该格转为癌组织


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
	var victims: Array = []
	for c in area:
		victims.append_array(game.cells_at(c, CWData.Faction.IMMUNE))
	game.cancer_hit_area(victims, CWData.MUCUS_IMMUNE_LOSS, "黏液破裂", true)
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
	if game.cost.commit(CWCost.context(cell, CWCost.Action.CELL_SKILL,
			CWData.METASTASIS_COST, to, 0,
			func() -> bool: return _is_jump_legal_now(cell, to))).is_empty():
		return
	game.log_msg("【转移】%s 跃进 5 格至 %s" % [game.cell_name(cell), str(to)])
	await enter_tile(cell, to)


func _adjacent_healthy(pos: Vector2i) -> bool:
	for n in CWData.neighbors(pos):
		if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
			return true
	return false


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
