## elm_actions.gd —— ActionsUpdater（迁移 cw_actions）：纯函数，父 update 的处理环节。
##
## 对应拍板 3：子 Updater 是父 update 处理环节的一部分（签名 (state,...) -> void，
## 改传入的副本）。由 elm_game._advance_turn 驱动，不被外壳单独驱动。
##
## 一个「执行中的动作」展开成显式子状态（s["act"] + s["act_state"]）：
##   · act == null        -> 在选动作（TURN_ACTIVE 产出 action ask）
##   · act_state 推进     -> 内部计算 / 产出动作内 ask（attack_target / differentiate /
##                           confirm ×2 / remodel_target）/ 完成（_finish_action）
## 逐行复刻 cw_actions.gd 的行为（含 build_options 的选项顺序，保证 decision 同序等价）。
class_name ElmActions
extends RefCounted


# ============ 行动菜单（选项顺序与 cw_actions 完全一致，保证 idx 同序）============

static func build_options(s: Dictionary, cell: Dictionary) -> Array:
	var opts: Array = []
	if cell["faction"] == CWData.Faction.IMMUNE:
		_immune_options(s, cell, opts)
	else:
		_cancer_options(s, cell, opts)
	opts.append({ "label": "结束回合", "data": { "act": "end" } })
	return opts


static func _immune_options(s: Dictionary, cell: Dictionary, opts: Array) -> void:
	var lvl: int = s["immune_level"]
	for n in CWData.neighbors(cell["pos"]):
		var enemies: Array = ElmGame.cells_at(s, n, CWData.Faction.CANCER)
		# 树突状细胞无法发动攻击 → 不能进入癌细胞所在格（说明 #14）
		if not enemies.is_empty() and cell["itype"] == CWData.ImmuneType.DENDRITIC:
			continue
		var cost: int = s["tune"].immune_move_cancerous[lvl] if ElmGame.is_cancerous(s, n) \
			else s["tune"].immune_move_healthy[lvl]
		if not ElmGame.can_pay(s, cell, cost):
			continue
		var tag := "攻击" if not enemies.is_empty() else "迁移"
		opts.append({
			"label": "%s→%s（%s 能量）" % [tag, str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if ElmGame.can_pay(s, cell, CWData.IMMUNE_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（0.5 能量）", "data": { "act": "draw" } })
	if lvl >= 2 and not cell["differentiated"] and not _diff_choices(s).is_empty():
		opts.append({ "label": "分化（免费）", "data": { "act": "differentiate" } })
	if cell["itype"] == CWData.ImmuneType.B_CELL \
			and cell["antibody_used"] < CWData.ANTIBODY_MAX_PER_ROUND \
			and ElmGame.can_pay(s, cell, CWData.ANTIBODY_COST):
		opts.append({ "label": "抗体（1.0 能量）", "data": { "act": "antibody" } })
	if cell["itype"] == CWData.ImmuneType.T_CELL:
		if ElmGame.can_pay(s, cell, CWData.TOXIN_COST) and not _toxin_targets(s, cell).is_empty():
			opts.append({ "label": "细胞毒素（1.0 能量）", "data": { "act": "toxin" } })
		if s["tiles"][cell["pos"]]["tissue"] == CWData.Tissue.SOLID \
				and ElmGame.can_pay(s, cell, CWData.LYSE_COST):
			opts.append({ "label": "裂解（1.0 能量）", "data": { "act": "lyse" } })


static func _cancer_options(s: Dictionary, cell: Dictionary, opts: Array) -> void:
	for n in CWData.neighbors(cell["pos"]):
		# 癌细胞无法向免疫细胞占据的组织移动
		if not ElmGame.cells_at(s, n, CWData.Faction.IMMUNE).is_empty():
			continue
		var cost: int = _cancer_move_cost(s, cell, n)
		if not ElmGame.can_pay(s, cell, cost):
			continue
		opts.append({
			"label": "移动→%s（%s 能量）" % [str(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if ElmGame.can_pay(s, cell, CWData.CANCER_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（1.0 能量）", "data": { "act": "draw" } })
	if not cell["mutate_used"] and ElmGame.can_pay(s, cell, CWData.MUTATE_COST):
		opts.append({ "label": "突变（0.5 能量）", "data": { "act": "mutate" } })
	if cell["ctype"] == CWData.CancerType.BLAST and cell["energy"] > 0 \
			and not _blast_targets(s, cell).is_empty():
		opts.append({ "label": "自爆（消耗所有能量）", "data": { "act": "blast" } })
	if cell["ctype"] == CWData.CancerType.REMODEL and not cell["remodel_used"] \
			and ElmGame.can_pay(s, cell, CWData.REMODEL_COST) \
			and not _remodel_targets(s, cell).is_empty():
		opts.append({ "label": "基质重塑（1.0 能量）", "data": { "act": "remodel" } })


static func _cancer_move_cost(s: Dictionary, cell: Dictionary, dest: Vector2i) -> int:
	if ElmGame.is_cancerous(s, dest):
		return CWData.CANCER_MOVE_CANCEROUS
	# 侵袭型：每世界回合前 2 次移动至健康组织 -0.2（说明 #17）
	if cell["ctype"] == CWData.CancerType.INVASIVE and cell["invasive_used"] < 2:
		return CWData.CANCER_MOVE_HEALTHY - CWData.INVASIVE_DISCOUNT
	return CWData.CANCER_MOVE_HEALTHY


# ============ 动作执行 ============

## 应用「action」ask 的答案：选中一个动作（或结束回合）。
## 非 end -> 初始化 s["act"]/act_state/act_data，交给 advance_action 执行。
static func apply_action(s: Dictionary, idx: int, effects: Array) -> void:
	var pending: Dictionary = s["pending"]
	var pid: int = pending["pid"]
	var cell: Dictionary = ElmGame.cell_of(s, pid)
	var options: Array = pending["options"]
	var data: Dictionary = options[idx]["data"]
	s["action_guard"] = int(s["action_guard"]) + 1
	if data["act"] == "end":
		ElmGame.add_log(s, effects, "　%s 结束回合（能量 %s）" % [
			s["players"][pid]["name"], CWData.fmt(cell["energy"])])
		s["turn_index"] = int(s["turn_index"]) + 1
		s["act"] = null
		s["act_state"] = ""
		return
	s["act"] = data["act"]
	s["act_data"] = data
	s["act_state"] = String(data["act"]) + "_start"
	s["act_pid"] = pid


## 推进当前 act 一步：内部多步一口气推进，直到「产出动作内 ask」或「动作完成」。
static func advance_action(s: Dictionary, effects: Array) -> void:
	match String(s["act"]):
		"move":
			_advance_move(s, effects)
		"draw":
			_do_draw(s, effects)
			_finish_action(s)
		"differentiate":
			_advance_diff(s, effects)
		"antibody":
			_advance_antibody(s, effects)
		"toxin":
			_do_toxin(s, effects)
			_finish_action(s)
		"lyse":
			_advance_lyse(s, effects)
		"mutate":
			_advance_mutate(s, effects)
		"blast":
			_do_blast(s, effects)
			_finish_action(s)
		"remodel":
			_advance_remodel(s, effects)


static func _finish_action(s: Dictionary) -> void:
	s["act"] = null
	s["act_state"] = ""
	s["act_data"] = {}


# ---- 移动 / 攻击（复刻 cw_actions._do_move）----

static func _advance_move(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 10:
		guard += 1
		match String(s["act_state"]):
			"move_start":
				var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
				var data: Dictionary = s["act_data"]
				var to: Vector2i = data["to"]
				var cost: int = data["cost"]
				if not ElmGame.pay(s, cell, cost):
					_finish_action(s)
					return
				if cell["faction"] == CWData.Faction.CANCER:
					if not ElmGame.is_cancerous(s, to) \
							and cell["ctype"] == CWData.CancerType.INVASIVE and cell["invasive_used"] < 2:
						cell["invasive_used"] += 1
					enter_tile(s, cell, to, effects)
					_finish_action(s)
					return
				# 免疫迁移：目标格有癌细胞 → 触发攻击
				var enemies: Array = ElmGame.cells_at(s, to, CWData.Faction.CANCER)
				if enemies.is_empty():
					enter_tile(s, cell, to, effects)
					_finish_action(s)
					return
				if enemies.size() > 1:
					var topts: Array = []
					for e in enemies:
						topts.append({
							"label": "%s（能量 %s）" % [ElmGame.cell_name(s, e), CWData.fmt(e["energy"])],
							"data": { "cid": e["id"] },
						})
					ElmGame.ask_effect(s, effects, "attack_target", s["act_pid"], "选择攻击目标", topts)
					s["act_state"] = "move_choose"
					return
				s["move_target_id"] = enemies[0]["id"]
				s["act_state"] = "move_roll"
			"move_choose":
				# decision 已把选中的目标 id 写入 move_target_id
				s["act_state"] = "move_roll"
			"move_roll":
				_move_roll(s, effects)
				return
			_:
				_finish_action(s)
				return


## 应用「attack_target」ask 的答案：记录选中的目标 cell id，回到 move_roll 结算
static func apply_attack_target(s: Dictionary, idx: int, _effects: Array) -> void:
	var opts: Array = s["pending"]["options"]
	s["move_target_id"] = opts[idx]["data"]["cid"]
	s["act_state"] = "move_choose"


## 攻击掷骰 + 结算（复刻 cw_actions._do_move 的免疫攻击段 + game.immune_hit）
static func _move_roll(s: Dictionary, effects: Array) -> void:
	var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
	var data: Dictionary = s["act_data"]
	var to: Vector2i = data["to"]
	var target: Dictionary = s["cells"][s["move_target_id"]]
	var rr: Dictionary = ElmGame._randi_range(s["rng_state"], 1, 6)
	s["rng_state"] = rr["state"]
	var r: int = rr["value"]
	effects.append({
		"kind": "roll_show", "reason": "攻击", "value": r, "sides": 6,
		"pid": s["act_pid"], "at": to,
	})
	if r <= 2:
		ElmGame.add_log(s, effects, "　攻击掷骰 %d：失败，%s 被反弹回原格" % [r, ElmGame.cell_name(s, cell)])
		# 规则原文反弹不造成伤害（旋钮默认 0）；平衡测试可给癌方反击手段
		if s["tune"].counter_dmg_on_fail > 0:
			cell["energy"] -= s["tune"].counter_dmg_on_fail
			ElmGame.add_log(s, effects, "　反弹造成 %s 能量损失（余 %s）" % [
				CWData.fmt(s["tune"].counter_dmg_on_fail),
				CWData.fmt(maxi(cell["energy"], 0))])
			if cell["energy"] <= 0:
				ElmGame.kill(s, cell, effects)
				_finish_action(s)
				return
	else:
		var dmg: int = s["tune"].attack_dmg_crit if r == 6 else s["tune"].attack_dmg_success
		ElmGame.add_log(s, effects, "　攻击掷骰 %d：%s" % [r, "大成功" if r == 6 else "成功"])
		ElmGame.immune_hit(s, target, dmg, cell, effects)
	# 目标格已无存活癌细胞才进入（击杀进格；否则返回原格）
	if cell["alive"] and ElmGame.cells_at(s, to, CWData.Faction.CANCER).is_empty():
		enter_tile(s, cell, to, effects)
	elif cell["alive"]:
		ElmGame.add_log(s, effects, "　%s 返回原格" % ElmGame.cell_name(s, cell))
	_finish_action(s)


## 进入一格的统一结算：癌细胞【定殖】、免疫【净化】、特殊组织收取、标记刷新
## （复刻 cw_actions.enter_tile；移动、血管传送、复活落位共用）
static func enter_tile(s: Dictionary, cell: Dictionary, dest: Vector2i, effects: Array) -> void:
	cell["pos"] = dest
	var t: Dictionary = s["tiles"][dest]
	if cell["faction"] == CWData.Faction.CANCER and t["tissue"] == CWData.Tissue.HEALTHY:
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
		ElmGame.add_log(s, effects, "　【定殖】%s 转为癌组织" % str(dest))
	elif cell["faction"] == CWData.Faction.IMMUNE and t["tissue"] == CWData.Tissue.CANCER:
		t["tissue"] = CWData.Tissue.HEALTHY
		t["newborn"] = false
		t["solid"] = 0
		t["sticky"] = 0
		ElmGame.gain_memory(s, 1)
		ElmGame.add_log(s, effects, "　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(dest), s["memory"]])
		if cell["itype"] == CWData.ImmuneType.MACRO:
			cell["energy"] += CWData.MACRO_HEAL_PURIFY
			ElmGame.add_log(s, effects, "　巨噬【吞噬】恢复 0.2 能量")
	collect_special(s, cell, dest, effects)
	ElmGame.update_marks(s)
	if cell["faction"] == CWData.Faction.IMMUNE:
		ElmGame.check_immune_win(s)  # 占住固化格可能封死复活 → 立即胜利（说明 #25）


## 收取特殊组织存储（进入时 & 产出瞬间站于其上时调用）
static func collect_special(s: Dictionary, cell: Dictionary, c: Vector2i, effects: Array) -> void:
	var t: Dictionary = s["tiles"][c]
	if t["special"] == CWData.Special.CORE and t["store"] > 0:
		cell["energy"] += t["store"]
		ElmGame.add_log(s, effects, "　%s 从代谢核心获取 %s 能量" % [
			ElmGame.cell_name(s, cell), CWData.fmt(t["store"])])
		t["store"] = 0
	elif t["special"] == CWData.Special.MARROW and t["cards"] > 0:
		t["cards"] = 0
		ElmCards.draw(s, cell, "骨髓", effects)


# ---- 通用技能 ----

static func _do_draw(s: Dictionary, effects: Array) -> void:
	var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
	var cost: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
		else CWData.CANCER_DRAW_COST
	if ElmGame.pay(s, cell, cost):
		ElmCards.draw(s, cell, "基因表达", effects)


# ---- 免疫技能 ----

static func _diff_choices(s: Dictionary) -> Array:
	var out: Array = []
	for t in [CWData.ImmuneType.B_CELL, CWData.ImmuneType.T_CELL,
			CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		if t not in s["differentiated"]:  # 每种细胞全阵营仅能有一个
			out.append(t)
	return out


static func _advance_diff(s: Dictionary, effects: Array) -> void:
	match String(s["act_state"]):
		"differentiate_start":
			var opts: Array = []
			for t in _diff_choices(s):
				opts.append({ "label": "分化为%s" % CWData.IMMUNE_TYPE_NAMES[t], "data": { "type": t } })
			ElmGame.ask_effect(s, effects, "differentiate", s["act_pid"], "选择分化方向", opts)
			s["act_state"] = "differentiate_apply"
		"differentiate_apply":
			# decision 已应用分化；这里直接收尾
			_finish_action(s)
		_:
			_finish_action(s)


static func apply_differentiate(s: Dictionary, idx: int, effects: Array) -> void:
	var pid: int = s["pending"]["pid"]
	var cell: Dictionary = ElmGame.cell_of(s, pid)
	var opts: Array = s["pending"]["options"]
	var t: int = opts[idx]["data"]["type"]
	cell["itype"] = t
	cell["differentiated"] = true
	s["differentiated"].append(t)
	ElmGame.add_log(s, effects, "【分化】%s 分化为 %s" % [
		s["players"][pid]["name"], CWData.IMMUNE_TYPE_NAMES[t]])
	ElmGame.update_marks(s)  # 分化出树突 → 立即标记相邻癌细胞
	s["act_state"] = "differentiate_apply"


static func _advance_antibody(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 10:
		guard += 1
		match String(s["act_state"]):
			"antibody_start":
				var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
				if not ElmGame.pay(s, cell, CWData.ANTIBODY_COST):
					_finish_action(s)
					return
				cell["antibody_used"] += 1
				var targets: Array = []
				for c in ElmGame.living_cells(s, CWData.Faction.CANCER):
					for n in CWData.neighbors(c["pos"]):
						if s["tiles"][n]["tissue"] == CWData.Tissue.HEALTHY:
							targets.append(c)
							break
				if not targets.is_empty():
					ElmGame.add_log(s, effects, "【抗体】命中 %d 个与健康组织邻接的癌细胞" % targets.size())
					for c in targets:
						ElmGame.immune_hit(s, c, CWData.ANTIBODY_DAMAGE, cell, effects)
					_finish_action(s)
					return
				# 无目标 → 随机将与健康组织相邻的 X 格癌组织转为健康（2/3→1，1/3→2）
				var eligible: Array[Vector2i] = []
				for c in s["tiles"].keys():
					if s["tiles"][c]["tissue"] != CWData.Tissue.CANCER:
						continue
					if not ElmGame.cells_at(s, c, CWData.Faction.CANCER).is_empty():
						continue  # 说明 #20：不转化有癌细胞停留的格
					for n in CWData.neighbors(c):
						if s["tiles"][n]["tissue"] == CWData.Tissue.HEALTHY:
							eligible.append(c)
							break
				if eligible.is_empty():
					ElmGame.add_log(s, effects, "【抗体】无目标且无可转化癌组织，效果落空")
					_finish_action(s)
					return
				s["ab_eligible"] = eligible
				s["act_state"] = "antibody_roll"
			"antibody_roll":
				var cell2: Dictionary = ElmGame.cell_of(s, s["act_pid"])
				var rr: Dictionary = ElmGame._randi_range(s["rng_state"], 1, 3)
				s["rng_state"] = rr["state"]
				var roll: int = rr["value"]
				effects.append({
					"kind": "roll_show", "reason": "抗体", "value": roll, "sides": 3,
					"pid": s["act_pid"], "at": cell2["pos"],
				})
				var x: int = 1 if roll <= 2 else 2
				var pr: Dictionary = ElmGame._pick_random(s["rng_state"], s["ab_eligible"], x)
				s["rng_state"] = pr["state"]
				for c in pr["picked"]:
					_to_healthy(s, c)
					ElmGame.add_log(s, effects, "【抗体】无目标 → %s 转为健康组织" % str(c))
				_finish_action(s)
				return
			_:
				_finish_action(s)
				return


static func _toxin_targets(s: Dictionary, cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if s["tiles"][n]["tissue"] == CWData.Tissue.CANCER \
				and ElmGame.cells_at(s, n, CWData.Faction.CANCER).is_empty():
			out.append(n)
	return out


static func _do_toxin(s: Dictionary, effects: Array) -> void:
	var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
	var targets := _toxin_targets(s, cell)
	if targets.is_empty() or not ElmGame.pay(s, cell, CWData.TOXIN_COST):
		return
	for c in targets:
		_to_healthy(s, c)
	ElmGame.add_log(s, effects, "【细胞毒素】相邻 %d 格癌组织转为健康组织（不积累记忆）" % targets.size())


static func _advance_lyse(s: Dictionary, effects: Array) -> void:
	match String(s["act_state"]):
		"lyse_start":
			var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
			if not ElmGame.pay(s, cell, CWData.LYSE_COST):
				_finish_action(s)
				return
			var pos: Vector2i = cell["pos"]
			var t: Dictionary = s["tiles"][pos]
			t["tissue"] = CWData.Tissue.CANCER
			t["solid"] = 0
			t["sticky"] = 0
			ElmGame.add_log(s, effects, "【裂解】%s 由固化癌组织转为癌组织" % str(pos))
			ElmGame.ask_effect(s, effects, "confirm", s["act_pid"],
				"是否立刻触发【净化】？",
				[{ "label": "立刻净化", "data": {} }, { "label": "暂不", "data": {} }],
				"lyse_purge")
			s["act_state"] = "lyse_ask"
		"lyse_ask":
			# decision 已应用净化与否；这里直接收尾
			_finish_action(s)
		_:
			_finish_action(s)


static func apply_lyse_confirm(s: Dictionary, idx: int, effects: Array) -> void:
	if idx == 0:
		var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
		var pos: Vector2i = cell["pos"]
		var t: Dictionary = s["tiles"][pos]
		t["tissue"] = CWData.Tissue.HEALTHY
		ElmGame.gain_memory(s, 1)
		ElmGame.add_log(s, effects, "　【净化】%s 转为健康组织（抗原记忆 %d）" % [str(pos), s["memory"]])
		ElmGame.check_immune_win(s)
	s["act_state"] = "lyse_ask"


# ---- 癌症技能 ----

static func _advance_mutate(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 10:
		guard += 1
		match String(s["act_state"]):
			"mutate_start":
				var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
				if not ElmGame.pay(s, cell, CWData.MUTATE_COST):
					_finish_action(s)
					return
				cell["mutate_used"] = true
				var nothing: bool = _roll_mutation(s, cell, effects)
				# 基因不稳定型：结果为无事发生时，可付 0.5 再突变一次（每世界回合限一次）
				if nothing and cell["alive"] and cell["ctype"] == CWData.CancerType.UNSTABLE \
						and not cell["unstable_used"] and ElmGame.can_pay(s, cell, CWData.MUTATE_COST):
					ElmGame.ask_effect(s, effects, "confirm", s["act_pid"],
						"基因不稳定：付 0.5 能量再次突变？",
						[{ "label": "再次突变", "data": {} }, { "label": "放弃", "data": {} }],
						"remutate")
					s["act_state"] = "mutate_ask"
					return
				_finish_action(s)
				return
			"mutate_ask":
				# decision 已应用再突变与否；这里直接收尾
				_finish_action(s)
				return
			_:
				_finish_action(s)
				return


static func apply_remutate_confirm(s: Dictionary, idx: int, effects: Array) -> void:
	if idx == 0:
		var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
		if ElmGame.pay(s, cell, CWData.MUTATE_COST):
			cell["unstable_used"] = true
			_roll_mutation(s, cell, effects)
	s["act_state"] = "mutate_ask"


## 返回是否「无事发生」（复刻 cw_actions._roll_mutation）
static func _roll_mutation(s: Dictionary, cell: Dictionary, effects: Array) -> bool:
	var rr: Dictionary = ElmGame._randi_range(s["rng_state"], 1, 3)
	s["rng_state"] = rr["state"]
	var r: int = rr["value"]
	effects.append({
		"kind": "roll_show", "reason": "突变", "value": r, "sides": 3,
		"pid": s["act_pid"], "at": cell["pos"],
	})
	match r:
		1:
			ElmGame.add_log(s, effects, "【突变】无事发生")
			return true
		2:
			ElmGame.add_log(s, effects, "【突变】抽卡，并削减 1 抗原记忆")
			ElmCards.draw(s, cell, "突变", effects)
			ElmGame.reduce_memory(s, 1)
		3:
			# 效果扣减可致死（区别于费用支付，见规则总则）
			cell["energy"] -= CWData.MUTATE_EXTRA_LOSS
			ElmGame.add_log(s, effects, "【突变】再扣 1.0 能量（余 %s），削减 3 抗原记忆" %
				CWData.fmt(maxi(cell["energy"], 0)))
			ElmGame.reduce_memory(s, 3)
			if cell["energy"] <= 0:
				ElmGame.kill(s, cell, effects)
	return false


static func _blast_targets(s: Dictionary, cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in s["tiles"].keys():
		if CWData.hex_dist(c, cell["pos"]) > 2:
			continue
		if s["tiles"][c]["tissue"] != CWData.Tissue.HEALTHY:
			continue
		if not ElmGame.cells_at(s, c, CWData.Faction.IMMUNE).is_empty():
			continue  # 免疫细胞所在格不受转化（与侵蚀同理）
		out.append(c)
	return out


static func _do_blast(s: Dictionary, effects: Array) -> void:
	var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
	var targets := _blast_targets(s, cell)
	ElmGame.add_log(s, effects, "【自爆】%s 引爆！相邻 2 格内 %d 格健康组织转为癌组织" % [
		ElmGame.cell_name(s, cell), targets.size()])
	for c in targets:
		var t: Dictionary = s["tiles"][c]
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
	ElmGame.kill(s, cell, effects)  # 自爆是「费用不能降至 0」的唯一例外（说明 #8）
	ElmGame.update_marks(s)


static func _remodel_targets(s: Dictionary, cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if s["tiles"][n]["tissue"] != CWData.Tissue.HEALTHY:
			continue
		if not ElmGame.cells_at(s, n, CWData.Faction.IMMUNE).is_empty():
			continue  # 目标有免疫细胞时无法发动
		var cancerous_adj := 0
		for m in CWData.neighbors(n):
			if ElmGame.is_cancerous(s, m):
				cancerous_adj += 1
		if cancerous_adj >= 2:
			out.append(n)
	return out


static func _advance_remodel(s: Dictionary, effects: Array) -> void:
	match String(s["act_state"]):
		"remodel_start":
			var cell: Dictionary = ElmGame.cell_of(s, s["act_pid"])
			var targets := _remodel_targets(s, cell)
			if targets.is_empty():
				_finish_action(s)
				return
			var opts: Array = []
			for c in targets:
				opts.append({ "label": "转化 %s" % str(c), "data": { "to": c } })
			ElmGame.ask_effect(s, effects, "remodel_target", s["act_pid"],
				"选择要转化的健康组织", opts)
			s["act_state"] = "remodel_apply"
		"remodel_apply":
			# decision 已应用转化；这里直接收尾
			_finish_action(s)
		_:
			_finish_action(s)


static func apply_remodel_target(s: Dictionary, idx: int, effects: Array) -> void:
	var pid: int = s["pending"]["pid"]
	var cell: Dictionary = ElmGame.cell_of(s, pid)
	var opts: Array = s["pending"]["options"]
	if not ElmGame.pay(s, cell, CWData.REMODEL_COST):
		s["act_state"] = "remodel_apply"
		return
	cell["remodel_used"] = true
	var c: Vector2i = opts[idx]["data"]["to"]
	var t: Dictionary = s["tiles"][c]
	t["tissue"] = CWData.Tissue.CANCER
	t["newborn"] = true
	t["solid"] = 0
	t["sticky"] = 0
	ElmGame.add_log(s, effects, "【基质重塑】%s 转为癌组织" % str(c))
	s["act_state"] = "remodel_apply"


## 癌组织 → 健康组织（毒素/抗体反噬用；不积累记忆，见说明 #18）
static func _to_healthy(s: Dictionary, c: Vector2i) -> void:
	var t: Dictionary = s["tiles"][c]
	t["tissue"] = CWData.Tissue.HEALTHY
	t["newborn"] = false
	t["solid"] = 0
	t["sticky"] = 0
