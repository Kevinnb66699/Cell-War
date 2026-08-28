## elm_world.gd —— WorldUpdater（迁移 cw_world）：纯函数，父 update 的处理环节。
##
## S 阶段（回合开始）有内部多步 + 一个 revive ask（决策点 8），由 advance_s 驱动：
##   s["phase_step"] 0~7 推进内部环节，产出 revive ask 时停（revive_idx 记录进度）；
## E 阶段（回合结束）全部内部，advance_e 一次做完。
## 逐行复刻 cw_world.gd 的行为；rng 全部走 s["rng_state"] 纯函数消耗。
class_name ElmWorld
extends RefCounted


# ============ S 阶段 ============

static func advance_s(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 100:
		guard += 1
		match int(s["phase_step"]):
			0:
				ElmGame.add_log(s, effects, "━━━━ 第 %d 世界回合 ━━━━" % s["round_no"])
				_reset_round_flags(s)
				s["phase_step"] = 1
				ElmGame.check_cancer_s_win(s)  # S 类胜利判定放在最开头（说明 #27）
				if s["winner"] >= 0:
					s["pc"] = "DONE"
					return
			1:
				if CWData.is_world_event_round(s["round_no"]):
					ElmGame.add_log(s, effects, "【世界事件】本回合应触发（内容未定义，暂跳过）")  # 说明 #1
				s["phase_step"] = 2
			2:
				_tissue_production(s, effects)
				s["phase_step"] = 3
			3:
				_vessel_teleport(s, effects)
				s["phase_step"] = 4
			4:
				# 复活循环：可能产出 ask（revive），停住等 decision；否则进入下一阶段
				_revive_loop(s, effects)
				if s["pending"] != null:
					return
				s["phase_step"] = 5
			5:
				_immune_respawn(s, effects)
				s["phase_step"] = 6
			6:
				_aerobic(s, effects)
				s["phase_step"] = 7
			7:
				ElmGame.check_immune_win(s)  # 复活全部失败时可能立即满足免疫胜利
				if s["winner"] >= 0:
					s["pc"] = "DONE"
				else:
					s["pc"] = "TURN_ACTIVE"
					s["turn_index"] = 0
					s["act"] = null
					s["act_state"] = ""
					s["act_data"] = {}
					s["act_pid"] = -1
					s["action_guard"] = 0
					s["turn_open_pid"] = -1
				return
			_:
				s["pc"] = "DONE"
				return


## 应用「revive」ask 的答案：复活或放弃，然后由 _advance 继续 revive 循环
static func apply_revive(s: Dictionary, idx: int, effects: Array) -> void:
	var pending: Dictionary = s["pending"]
	var pid: int = pending["pid"]
	var cell: Dictionary = ElmGame.cell_of(s, pid)
	var options: Array = pending["options"]
	var data: Dictionary = options[idx]["data"]
	if data.get("skip", false):
		ElmGame.add_log(s, effects, "%s 放弃复活" % s["players"][pid]["name"])
		return
	var pos: Vector2i = data["to"]
	# 复活获得 2.0 能量，随后该固化癌组织降级为癌组织（计数清零，说明 #22）
	var t: Dictionary = s["tiles"][pos]
	t["tissue"] = CWData.Tissue.CANCER
	t["solid"] = 0
	t["sticky"] = 0
	cell["alive"] = true
	cell["energy"] = CWData.REVIVE_ENERGY
	ElmActions.enter_tile(s, cell, pos, effects)
	ElmGame.add_log(s, effects, "【复活】%s 复活于 %s（2.0 能量），该格降级为癌组织" % [
		ElmGame.cell_name(s, cell), str(pos)])


static func _reset_round_flags(s: Dictionary) -> void:
	for c in s["cells"]:
		c["escape_used"] = false
		c["invasive_used"] = 0
		c["remodel_used"] = false
		c["mutate_used"] = false
		c["unstable_used"] = false
		c["antibody_used"] = 0


## 代谢核心/骨髓产出；产出瞬间站在其上的细胞立即收取（说明 #9）
static func _tissue_production(s: Dictionary, effects: Array) -> void:
	for c in s["tiles"].keys():
		var t: Dictionary = s["tiles"][c]
		if t["special"] != CWData.Special.CORE and t["special"] != CWData.Special.MARROW:
			continue
		var healthy: bool = t["tissue"] == CWData.Tissue.HEALTHY
		if t["special"] == CWData.Special.CORE:
			if healthy:
				t["prod"] += 1
				if t["prod"] >= CWData.CORE_HEALTHY_PERIOD:
					t["prod"] = 0
					t["store"] = mini(t["store"] + CWData.CORE_HEALTHY_GAIN, CWData.CORE_STORE_MAX)
			else:
				t["store"] = mini(t["store"] + CWData.CORE_CANCER_GAIN, CWData.CORE_STORE_MAX)
		else:  # MARROW
			t["prod"] += 1
			var period: int = CWData.MARROW_HEALTHY_PERIOD if healthy else CWData.MARROW_CANCER_PERIOD
			if t["prod"] >= period:
				t["prod"] = 0
				t["cards"] = mini(t["cards"] + 1, CWData.MARROW_STORE_MAX)
		if t["store"] > 0 or t["cards"] > 0:
			var here: Array = ElmGame.cells_at(s, c)
			if not here.is_empty():
				ElmActions.collect_special(s, here[0], c, effects)


## 血管传送：强制；两端互换；若会导致敌对同格则整体取消（说明 #13）
static func _vessel_teleport(s: Dictionary, effects: Array) -> void:
	var a: Vector2i = CWData.VESSELS[0]
	var b: Vector2i = CWData.VESSELS[1]
	var ca: Array = ElmGame.cells_at(s, a)
	var cb: Array = ElmGame.cells_at(s, b)
	if ca.is_empty() and cb.is_empty():
		return
	if not ca.is_empty() and not cb.is_empty() \
			and ca[0]["faction"] != cb[0]["faction"]:
		ElmGame.add_log(s, effects, "【血管】两端阵营敌对，传送取消")
		return
	for cell in ca:
		ElmGame.add_log(s, effects, "【血管】%s 传送至 %s" % [ElmGame.cell_name(s, cell), str(b)])
		ElmActions.enter_tile(s, cell, b, effects)
	for cell in cb:
		ElmGame.add_log(s, effects, "【血管】%s 传送至 %s" % [ElmGame.cell_name(s, cell), str(a)])
		ElmActions.enter_tile(s, cell, a, effects)


## 【S-复活】：死亡癌细胞按行动顺序依次结算；可自愿放弃（说明 #21）
## 循环指针 s["revive_idx"]（order 下标）记录进度；产出 revive ask 时停在 pending。
static func _revive_loop(s: Dictionary, effects: Array) -> void:
	while true:
		if int(s["revive_idx"]) >= s["order"].size():
			return
		var pid: int = s["order"][s["revive_idx"]]
		s["revive_idx"] = int(s["revive_idx"]) + 1
		var p: Dictionary = s["players"][pid]
		if p["faction"] != CWData.Faction.CANCER:
			continue
		var cell: Dictionary = ElmGame.cell_of(s, pid)
		if cell["alive"]:
			continue
		var candidates: Array[Vector2i] = []
		for c in s["tiles"].keys():
			if s["tiles"][c]["tissue"] == CWData.Tissue.SOLID \
					and ElmGame.cells_at(s, c, CWData.Faction.IMMUNE).is_empty():
				candidates.append(c)
		if candidates.is_empty():
			ElmGame.add_log(s, effects, "%s 无可用固化癌组织，无法复活" % p["name"])
			continue
		var options: Array = [{ "label": "放弃本回合复活", "data": { "skip": true } }]
		for c in candidates:
			options.append({ "label": "复活于 %s" % str(c), "data": { "to": c } })
		ElmGame.ask_effect(s, effects, "revive", pid, "%s 选择复活位置" % p["name"], options)
		return


## 免疫细胞罚停期满后，在**随机**健康组织复活（2026-08-26 团队定案）
static func _immune_respawn(s: Dictionary, effects: Array) -> void:
	for cell in s["cells"]:
		if cell["alive"] or cell["faction"] != CWData.Faction.IMMUNE:
			continue
		if cell["respawn_round"] < 0 or s["round_no"] < cell["respawn_round"]:
			continue
		var healthy: Array[Vector2i] = []
		for c in s["tiles"].keys():
			if s["tiles"][c]["tissue"] == CWData.Tissue.HEALTHY:
				healthy.append(c)
		if healthy.is_empty():
			ElmGame.add_log(s, effects, "%s 无健康组织可复活，继续等待" % ElmGame.cell_name(s, cell))
			continue
		healthy.sort()  # 固定候选顺序，保证同种子可复现
		var pr: Dictionary = ElmGame._pick_random(s["rng_state"], healthy, 1)
		s["rng_state"] = pr["state"]
		var pos: Vector2i = pr["picked"][0]
		cell["alive"] = true
		cell["energy"] = s["tune"].immune_respawn_energy
		cell["respawn_round"] = -1
		ElmActions.enter_tile(s, cell, pos, effects)
		ElmGame.add_log(s, effects, "【免疫复活】%s 于 %s 复活（%s 能量）" % [
			ElmGame.cell_name(s, cell), str(pos), CWData.fmt(s["tune"].immune_respawn_energy)])


static func _aerobic(s: Dictionary, effects: Array) -> void:
	var immune: Array = ElmGame.living_cells(s, CWData.Faction.IMMUNE)
	if immune.is_empty():
		return
	var gain: int = s["tune"].aerobic_gain[s["immune_level"]]
	if s["tune"].aerobic_per_healthy > 0:
		# 挂钩健康组织：总供能 = 健康组织数 × 单格供能，可选按免疫细胞数均分
		var pool: int = ElmGame.count_tissue(s, CWData.Tissue.HEALTHY) \
			* s["tune"].aerobic_per_healthy / s["tune"].aerobic_healthy_div
		gain = (pool / immune.size()) if s["tune"].aerobic_split else pool
	gain = s["tune"].clamp_income(gain, s["tune"].aerobic_floor, s["tune"].aerobic_cap)
	for cell in immune:
		cell["energy"] += gain
	ElmGame.add_log(s, effects, "【有氧呼吸】所有免疫细胞 +%s 能量" % CWData.fmt(gain))


# ============ E 阶段 ============

## E 阶段全部内部、无 ask：一次做完（复刻 cw_world.e_phase）。
static func advance_e(s: Dictionary, effects: Array) -> void:
	_erosion(s, effects)
	_proliferate(s, effects)
	_anaerobic(s, effects)
	_solidify(s, effects)
	_decay(s)
	_clear_newborn(s)
	if s["winner"] < 0 and int(s["round_no"]) >= int(s["tune"].limit_round):
		_final_verdict(s, effects)
	# 无论胜负，E 阶段结束：下一回合（round_no+1）从 S 阶段重新开始
	if s["winner"] >= 0:
		s["pc"] = "DONE"
	else:
		s["round_no"] = int(s["round_no"]) + 1
		s["pc"] = "WORLD_S"
		s["phase_step"] = 0
		s["revive_idx"] = 0
		s["turn_index"] = 0
		s["act"] = null
		s["act_state"] = ""
		s["act_data"] = {}
		s["act_pid"] = -1
		s["action_guard"] = 0
		s["turn_open_pid"] = -1


## 【E-侵蚀】：全局掷一次，从所有被完全包围连通块的合法格中随机选（说明 #11）
## 刻意用**静默**掷骰：世界自动结算不是玩家行为（决策 ④，2026-08-27 定）。
static func _erosion(s: Dictionary, effects: Array) -> void:
	var eligible: Array[Vector2i] = []
	var healthy_pred := func(c: Vector2i) -> bool:
		return s["tiles"][c]["tissue"] == CWData.Tissue.HEALTHY
	for block in ElmGame.blocks_of(s, healthy_pred):
		var touches_edge := false
		for c in block:
			if CWData.is_edge(c):
				touches_edge = true
				break
		if touches_edge:
			continue  # 与棋盘外缘连接 → 未被完全包围
		for c in block:
			if not ElmGame.cells_at(s, c, CWData.Faction.IMMUNE).is_empty():
				continue  # 免疫细胞所在格无法被侵蚀
			var near_cancer := false
			for n in CWData.neighbors(c):
				if ElmGame.is_cancerous(s, n):
					near_cancer = true
					break
			if near_cancer:
				eligible.append(c)
	if eligible.is_empty():
		return
	var rr: Dictionary = ElmGame._randi_range(s["rng_state"], 1, 3)
	s["rng_state"] = rr["state"]
	var count: int = 1 if rr["value"] <= 2 else 2  # 2/3→1 格，1/3→2 格
	var pr: Dictionary = ElmGame._pick_random(s["rng_state"], eligible, count)
	s["rng_state"] = pr["state"]
	for c in pr["picked"]:
		var t: Dictionary = s["tiles"][c]
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
		ElmGame.add_log(s, effects, "【侵蚀】%s 转为癌组织" % str(c))


## 【E-增生】癌组织向外扩散（团队提案，旋钮默认关闭）。
## 先统一掷骰收集、再统一转化 —— 保证「同时结算」，避免转化顺序影响后续格的相邻数。
static func _proliferate(s: Dictionary, effects: Array) -> void:
	var rate: int = s["tune"].proliferate_per_adjacent
	if rate <= 0:
		return
	var converts: Array[Vector2i] = []
	var coords: Array = s["tiles"].keys()
	coords.sort()  # 固定遍历顺序，保证同种子可复现
	for c in coords:
		if s["tiles"][c]["tissue"] != CWData.Tissue.HEALTHY:
			continue
		if not ElmGame.cells_at(s, c, CWData.Faction.IMMUNE).is_empty():
			continue  # 与【侵蚀】一致：免疫细胞所在格不被转化
		var adj := 0
		for n in CWData.neighbors(c):
			if ElmGame.is_cancerous(s, n):
				adj += 1
		if adj > 0:
			var rr: Dictionary = ElmGame._randi_range(s["rng_state"], 1, 1000)
			s["rng_state"] = rr["state"]
			if rr["value"] <= rate * adj:
				converts.append(c)
	for c in converts:
		var t: Dictionary = s["tiles"][c]
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
	if not converts.is_empty():
		ElmGame.add_log(s, effects, "【增生】%d 格健康组织被癌组织侵占" % converts.size())


## 【E-无氧呼吸】：每块供能 =（癌×0.2 + 固化×0.5），块内癌细胞均分，向下取整到 0.1（说明 #10）
static func _anaerobic(s: Dictionary, effects: Array) -> void:
	var cancer_pred := func(c: Vector2i) -> bool:
		return ElmGame.is_cancerous(s, c)
	for block in ElmGame.blocks_of(s, cancer_pred):
		var pool := 0
		var members := {}
		for c in block:
			members[c] = true
			if s["tiles"][c]["tissue"] == CWData.Tissue.SOLID:
				pool += s["tune"].anaerobic_per_solid
			else:
				pool += s["tune"].anaerobic_per_cancer
		var here: Array = []
		for cell in ElmGame.living_cells(s, CWData.Faction.CANCER):
			if members.has(cell["pos"]):
				here.append(cell)
		if here.is_empty():
			continue
		var gain: int = (pool / here.size()) if s["tune"].anaerobic_split else pool
		gain = s["tune"].clamp_income(gain, s["tune"].anaerobic_floor, s["tune"].anaerobic_cap)
		for cell in here:
			cell["energy"] += gain
		ElmGame.add_log(s, effects, "【无氧呼吸】连通块（%d 格）内 %d 个癌细胞各 +%s 能量" % [
			block.size(), here.size(), CWData.fmt(gain)])


## 【E-固化】：有癌细胞停留的（非新生）癌组织，按格 +1 计数（说明 #22）
static func _solidify(s: Dictionary, effects: Array) -> void:
	var counted := {}
	for cell in ElmGame.living_cells(s, CWData.Faction.CANCER):
		var c: Vector2i = cell["pos"]
		if counted.has(c):
			continue
		counted[c] = true
		var t: Dictionary = s["tiles"][c]
		if t["tissue"] != CWData.Tissue.CANCER or t["newborn"]:
			continue
		t["solid"] += 1
		# 停留者中有固着型 → 该点为「固着点」，永不自然衰减（说明 #16）
		for occupant in ElmGame.cells_at(s, c, CWData.Faction.CANCER):
			if occupant["ctype"] == CWData.CancerType.SESSILE:
				t["sticky"] += 1
				break
		if t["solid"] >= s["tune"].solidify_threshold:
			t["tissue"] = CWData.Tissue.SOLID
			ElmGame.add_log(s, effects, "【固化】%s 转为固化癌组织" % str(c))


## 固化衰减：计数>0 且无癌细胞停留的癌组织 -1；固着点不衰减
static func _decay(s: Dictionary) -> void:
	for c in s["tiles"].keys():
		var t: Dictionary = s["tiles"][c]
		if t["tissue"] != CWData.Tissue.CANCER or t["solid"] <= 0:
			continue
		if ElmGame.cells_at(s, c, CWData.Faction.CANCER).is_empty() and t["solid"] > t["sticky"]:
			t["solid"] -= 1


static func _clear_newborn(s: Dictionary) -> void:
	for t in s["tiles"].values():
		t["newborn"] = false


## 回合上限终局：癌性组织达到门槛 → 癌症胜利，否则免疫胜利
static func _final_verdict(s: Dictionary, effects: Array) -> void:
	var cancerous: int = ElmGame.count_tissue(s, CWData.Tissue.CANCER) \
		+ ElmGame.count_tissue(s, CWData.Tissue.SOLID)
	var limit: int = s["tune"].limit_cancerous
	if cancerous >= limit:
		s["winner"] = CWData.Faction.CANCER
		s["win_kind"] = "limit_cancer"
		s["win_reason"] = "%d 回合到：癌性组织 %d ≥ %d，癌症胜利" % [
			s["tune"].limit_round, cancerous, limit]
	else:
		s["winner"] = CWData.Faction.IMMUNE
		s["win_kind"] = "limit_immune"
		s["win_reason"] = "%d 回合到：癌性组织 %d < %d，免疫胜利" % [
			s["tune"].limit_round, cancerous, limit]
