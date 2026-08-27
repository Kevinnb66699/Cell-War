## cw_world.gd —— 世界回合的 S/E 阶段结算
##
## S 阶段（回合开始）：癌症胜利判定 → 世界事件（占位）→ 特殊组织产出 → 血管传送
##                  → 癌细胞【复活】→ 免疫【有氧呼吸】
## E 阶段（回合结束）：【侵蚀】→【无氧呼吸】→【固化】→ 固化衰减 → 清除「新生」
##                  → 第 30 回合终局判定
class_name CWWorld
extends RefCounted

var game: CWGame


func s_phase() -> void:
	game.log_msg("━━━━ 第 %d 世界回合 ━━━━" % game.round_no)
	_reset_round_flags()
	game.check_cancer_s_win()  # S 类胜利判定放在最开头（说明 #27）
	if game.winner >= 0:
		return
	if CWData.is_world_event_round(game.round_no):
		game.log_msg("【世界事件】本回合应触发（内容未定义，暂跳过）")  # 说明 #1
	_tissue_production()
	_vessel_teleport()
	await _revive()
	_immune_respawn()
	_aerobic()
	game.check_immune_win()  # 复活全部失败时可能立即满足免疫胜利


func e_phase() -> void:
	_erosion()
	_proliferate()
	_anaerobic()
	_solidify()
	_decay()
	_clear_newborn()
	if game.winner < 0 and game.round_no >= game.tune.limit_round:
		_final_verdict()


# ---- S 阶段 ----

func _reset_round_flags() -> void:
	for c in game.cells:
		c["escape_used"] = false
		c["invasive_used"] = 0
		c["remodel_used"] = false
		c["mutate_used"] = false
		c["unstable_used"] = false
		c["antibody_used"] = 0


## 代谢核心/骨髓产出；产出瞬间站在其上的细胞立即收取（说明 #9）
func _tissue_production() -> void:
	for c in game.tiles.keys():
		var t: Dictionary = game.tiles[c]
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
			var here: Array = game.cells_at(c)
			if not here.is_empty():
				game.actions.collect_special(here[0], c)


## 血管传送：强制；两端互换；若会导致敌对同格则整体取消（说明 #13）
func _vessel_teleport() -> void:
	var a: Vector2i = CWData.VESSELS[0]
	var b: Vector2i = CWData.VESSELS[1]
	var ca: Array = game.cells_at(a)
	var cb: Array = game.cells_at(b)
	if ca.is_empty() and cb.is_empty():
		return
	if not ca.is_empty() and not cb.is_empty() \
			and ca[0]["faction"] != cb[0]["faction"]:
		game.log_msg("【血管】两端阵营敌对，传送取消")
		return
	for cell in ca:
		game.log_msg("【血管】%s 传送至 %s" % [game.cell_name(cell), str(b)])
		game.actions.enter_tile(cell, b)
	for cell in cb:
		game.log_msg("【血管】%s 传送至 %s" % [game.cell_name(cell), str(a)])
		game.actions.enter_tile(cell, a)


## 【S-复活】：死亡癌细胞按行动顺序依次结算；可自愿放弃（说明 #21）
func _revive() -> void:
	for pid in game.order:
		if game.player(pid)["faction"] != CWData.Faction.CANCER:
			continue
		var cell: Dictionary = game.cell_of(pid)
		if cell["alive"]:
			continue
		var candidates: Array[Vector2i] = []
		for c in game.tiles.keys():
			if game.tiles[c]["tissue"] == CWData.Tissue.SOLID \
					and game.cells_at(c, CWData.Faction.IMMUNE).is_empty():
				candidates.append(c)
		if candidates.is_empty():
			game.log_msg("%s 无可用固化癌组织，无法复活" % game.player(pid)["name"])
			continue
		var options: Array = [{ "label": "放弃本回合复活", "data": { "skip": true } }]
		for c in candidates:
			options.append({ "label": "复活于 %s" % str(c), "data": { "to": c } })
		var idx: int = await game.ask(pid, {
			"kind": "revive", "prompt": "%s 选择复活位置" % game.player(pid)["name"],
			"options": options,
		})
		var data: Dictionary = options[idx]["data"]
		if data.get("skip", false):
			game.log_msg("%s 放弃复活" % game.player(pid)["name"])
			continue
		var pos: Vector2i = data["to"]
		# 复活获得 2.0 能量，随后该固化癌组织降级为癌组织（计数清零，说明 #22）
		var t: Dictionary = game.tile(pos)
		t["tissue"] = CWData.Tissue.CANCER
		t["solid"] = 0
		t["sticky"] = 0
		cell["alive"] = true
		cell["energy"] = CWData.REVIVE_ENERGY
		game.actions.enter_tile(cell, pos)
		game.log_msg("【复活】%s 复活于 %s（2.0 能量），该格降级为癌组织" % [
			game.cell_name(cell), str(pos)])


## 免疫细胞罚停期满后，在**随机**健康组织复活（2026-08-26 团队定案）
## 随机选位是为了避免"自选复活点"变成免费传送——那样换阵地反而成了收益。
func _immune_respawn() -> void:
	for cell in game.cells:
		if cell["alive"] or cell["faction"] != CWData.Faction.IMMUNE:
			continue
		if cell["respawn_round"] < 0 or game.round_no < cell["respawn_round"]:
			continue
		var healthy: Array[Vector2i] = []
		for c in game.tiles.keys():
			if game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY:
				healthy.append(c)
		if healthy.is_empty():
			game.log_msg("%s 无健康组织可复活，继续等待" % game.cell_name(cell))
			continue
		healthy.sort()  # 固定候选顺序，保证同种子可复现
		var pos: Vector2i = game.pick_random(healthy, 1)[0]
		cell["alive"] = true
		cell["energy"] = game.tune.immune_respawn_energy
		cell["respawn_round"] = -1
		game.actions.enter_tile(cell, pos)
		game.log_msg("【免疫复活】%s 于 %s 复活（%s 能量）" % [
			game.cell_name(cell), str(pos), CWData.fmt(game.tune.immune_respawn_energy)])


func _aerobic() -> void:
	var immune: Array = game.living_cells(CWData.Faction.IMMUNE)
	if immune.is_empty():
		return
	var gain: int = game.tune.aerobic_gain[game.immune_level]
	if game.tune.aerobic_per_healthy > 0:
		# 挂钩健康组织：总供能 = 健康组织数 × 单格供能，可选按免疫细胞数均分
		var pool: int = game.count_tissue(CWData.Tissue.HEALTHY) 			* game.tune.aerobic_per_healthy / game.tune.aerobic_healthy_div
		gain = (pool / immune.size()) if game.tune.aerobic_split else pool
	gain = game.tune.clamp_income(gain, game.tune.aerobic_floor, game.tune.aerobic_cap)
	for cell in immune:
		cell["energy"] += gain
	game.log_msg("【有氧呼吸】所有免疫细胞 +%s 能量" % CWData.fmt(gain))


# ---- E 阶段 ----

## 【E-侵蚀】：全局掷一次，从所有被完全包围连通块的合法格中随机选（说明 #11）
func _erosion() -> void:
	var eligible: Array[Vector2i] = []
	var healthy_pred := func(c: Vector2i) -> bool:
		return game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY
	for block in game.blocks_of(healthy_pred):
		var touches_edge := false
		for c in block:
			if CWData.is_edge(c):
				touches_edge = true
				break
		if touches_edge:
			continue  # 与棋盘外缘连接 → 未被完全包围
		for c in block:
			if not game.cells_at(c, CWData.Faction.IMMUNE).is_empty():
				continue  # 免疫细胞所在格无法被侵蚀
			var near_cancer := false
			for n in CWData.neighbors(c):
				if game.is_cancerous(n):
					near_cancer = true
					break
			if near_cancer:
				eligible.append(c)
	if eligible.is_empty():
		return
	# 这里刻意用**静默**掷骰：侵蚀是世界自动结算，不是玩家自己掷的，
	# 一局要掷 7 次左右，每次都演会拖节奏（决策 ④，2026-08-27 定）。
	# 若团队改主意要演，把这行换成 `await game.roll_shown(3, "侵蚀")` 即可 ——
	# rng 消耗完全一样，平衡数据和同种子复现都不受影响，但 _erosion() 及其调用链要改成 async。
	var count: int = 1 if game.roll_d3() <= 2 else 2  # 2/3→1 格，1/3→2 格
	for c in game.pick_random(eligible, count):
		var t: Dictionary = game.tile(c)
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
		game.log_msg("【侵蚀】%s 转为癌组织" % str(c))


## 【E-增生】癌组织向外扩散：与癌性组织相邻的健康组织按概率被转化（团队提案，旋钮默认关闭）
## 先统一掷骰收集、再统一转化 —— 保证「同时结算」，避免转化顺序影响后续格的相邻数。
func _proliferate() -> void:
	var rate: int = game.tune.proliferate_per_adjacent
	if rate <= 0:
		return
	var converts: Array[Vector2i] = []
	var coords: Array = game.tiles.keys()
	coords.sort()  # 固定遍历顺序，保证同种子可复现
	for c in coords:
		if game.tiles[c]["tissue"] != CWData.Tissue.HEALTHY:
			continue
		if not game.cells_at(c, CWData.Faction.IMMUNE).is_empty():
			continue  # 与【侵蚀】一致：免疫细胞所在格不被转化
		var adj := 0
		for n in CWData.neighbors(c):
			if game.is_cancerous(n):
				adj += 1
		if adj > 0 and game.rng.randi_range(1, 1000) <= rate * adj:
			converts.append(c)
	for c in converts:
		var t: Dictionary = game.tile(c)
		t["tissue"] = CWData.Tissue.CANCER
		t["newborn"] = true
		t["solid"] = 0
		t["sticky"] = 0
	if not converts.is_empty():
		game.log_msg("【增生】%d 格健康组织被癌组织侵占" % converts.size())


## 【E-无氧呼吸】：每块供能 =（癌×0.2 + 固化×0.5），块内癌细胞均分，向下取整到 0.1（说明 #10）
func _anaerobic() -> void:
	var cancer_pred := func(c: Vector2i) -> bool:
		return game.is_cancerous(c)
	for block in game.blocks_of(cancer_pred):
		var pool := 0
		var members := {}
		for c in block:
			members[c] = true
			if game.tiles[c]["tissue"] == CWData.Tissue.SOLID:
				pool += game.tune.anaerobic_per_solid
			else:
				pool += game.tune.anaerobic_per_cancer
		var here: Array = []
		for cell in game.living_cells(CWData.Faction.CANCER):
			if members.has(cell["pos"]):
				here.append(cell)
		if here.is_empty():
			continue
		var gain: int = (pool / here.size()) if game.tune.anaerobic_split else pool
		gain = game.tune.clamp_income(gain, game.tune.anaerobic_floor, game.tune.anaerobic_cap)
		for cell in here:
			cell["energy"] += gain
		game.log_msg("【无氧呼吸】连通块（%d 格）内 %d 个癌细胞各 +%s 能量" % [
			block.size(), here.size(), CWData.fmt(gain)])


## 【E-固化】：有癌细胞停留的（非新生）癌组织，按格 +1 计数（说明 #22）
func _solidify() -> void:
	var counted := {}
	for cell in game.living_cells(CWData.Faction.CANCER):
		var c: Vector2i = cell["pos"]
		if counted.has(c):
			continue
		counted[c] = true
		var t: Dictionary = game.tile(c)
		if t["tissue"] != CWData.Tissue.CANCER or t["newborn"]:
			continue
		t["solid"] += 1
		# 停留者中有固着型 → 该点为「固着点」，永不自然衰减（说明 #16）
		for occupant in game.cells_at(c, CWData.Faction.CANCER):
			if occupant["ctype"] == CWData.CancerType.SESSILE:
				t["sticky"] += 1
				break
		if t["solid"] >= game.tune.solidify_threshold:
			t["tissue"] = CWData.Tissue.SOLID
			game.log_msg("【固化】%s 转为固化癌组织" % str(c))


## 固化衰减：计数>0 且无癌细胞停留的癌组织 -1；固着点不衰减
func _decay() -> void:
	for c in game.tiles.keys():
		var t: Dictionary = game.tiles[c]
		if t["tissue"] != CWData.Tissue.CANCER or t["solid"] <= 0:
			continue
		if game.cells_at(c, CWData.Faction.CANCER).is_empty() and t["solid"] > t["sticky"]:
			t["solid"] -= 1


func _clear_newborn() -> void:
	for t in game.tiles.values():
		t["newborn"] = false


## 回合上限终局：癌性组织达到门槛 → 癌症胜利，否则免疫胜利
func _final_verdict() -> void:
	var cancerous: int = game.count_tissue(CWData.Tissue.CANCER) \
		+ game.count_tissue(CWData.Tissue.SOLID)
	var limit: int = game.tune.limit_cancerous
	if cancerous >= limit:
		game.winner = CWData.Faction.CANCER
		game.win_kind = "limit_cancer"
		game.win_reason = "%d 回合到：癌性组织 %d ≥ %d，癌症胜利" % [
			game.tune.limit_round, cancerous, limit]
	else:
		game.winner = CWData.Faction.IMMUNE
		game.win_kind = "limit_immune"
		game.win_reason = "%d 回合到：癌性组织 %d < %d，免疫胜利" % [
			game.tune.limit_round, cancerous, limit]
