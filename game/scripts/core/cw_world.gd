## cw_world.gd —— 世界回合的 S/E 阶段结算
##
## 阶段顺序**逐条照抄 PRD「世界回合」那一节**，改动前先回去核对，别凭印象调：
##
## S 阶段：世界事件 → 特殊组织产出 → 血管传送 → 免疫【复活】→ 癌细胞【复活】
##        → 免疫【有氧呼吸】→ 其他 S 类
## E 阶段：【微环境压迫】→【增生】→【侵蚀】→【无氧呼吸】→【固化】→ 固化计数衰减
##        → 其他 E 类 → 更新持续状态（「坏死」到期）→ 移除「新生」→ **胜利条件检查**
##
## 两个容易踩的点：
## ① **增生在侵蚀之前**。增生会把健康组织变成癌组织，从而改变「完全包围」的判定结果，
##    顺序反了侵蚀的选格就不一样。
## ② **两个胜利条件都是 E 类**，在 E 阶段最后一步统一判。
##    2026-08-28 之前免疫胜利是净化后立即判（I 类）、癌症胜利是 S 阶段开头判，PRD 已推翻。
class_name CWWorld
extends RefCounted

var game: CWGame


## S 阶段的**无决策部分**（世界事件 → 特殊组织产出 → 血管传送）。
## 两处【复活】要玩家选落点，交给流程状态机；有氧呼吸在复活全部结算完之后调。
func round_start() -> void:
	game.log_msg("━━━━ 第 %d 世界回合 ━━━━" % game.round_no)
	_reset_round_flags()
	if CWData.is_world_event_round(game.round_no):
		game.log_msg("【世界事件】本回合应触发（内容未定义，暂跳过）")  # 说明 #1
	_tissue_production()
	_vessel_teleport()


func aerobic() -> void:
	_aerobic()


func e_phase() -> void:
	_pressure()
	_proliferate()
	_erosion()
	_anaerobic()
	_solidify()
	_decay()
	_tick_necrosis()   ## 「更新持续时间类状态」——目前只有「坏死」
	_clear_newborn()
	## 胜利条件检查（E 阶段第 10 步）。免疫先判：PRD 的列举顺序如此，
	## 而且两边同时满足时「癌细胞已全灭」比「占地达标」更靠后发生，判给免疫更符合直觉。
	game.check_immune_win()
	game.check_cancer_win()
	if game.winner < 0 and game.round_no >= game.tune.limit_round:
		_final_verdict()


# ---- S 阶段 ----

func _reset_round_flags() -> void:
	for c in game.cells:
		c["armor_used"] = false        ## 印戒【囊性护甲】每世界回合减免 1 次
		c["mutate_used"] = false       ## 【突变】每世界回合 1 次
		c["antibody_used"] = 0         ## B【抗体】2 次/世界回合
		c["toxin_used"] = 0            ## T【细胞毒素】3 次/世界回合
		c["metastasis_used"] = false   ## 黑色素瘤【早期血行转移】1 次/世界回合


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


## 【S-复活】癌症：落点是**未被细胞占据**的固化癌组织；可自愿放弃（说明 #21）。
## 没有可用落点时返回空数组，流程状态机会跳过这个玩家。
func revive_options_cancer(pid: int) -> Array:
	var cell: Dictionary = game.cell_of(pid)
	if cell["alive"]:
		return []
	var candidates: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] == CWData.Tissue.SOLID \
				and game.cells_at(c).is_empty():
			candidates.append(c)
	if candidates.is_empty():
		return []
	candidates.sort()   ## 固定候选顺序，保证同种子可复现
	var options: Array = [{ "label": "放弃本回合复活", "data": { "skip": true } }]
	for c in candidates:
		options.append({ "label": "复活于 %s" % str(c), "data": { "to": c } })
	return options


func revive_cancer(pid: int, data: Dictionary) -> void:
	var cell: Dictionary = game.cell_of(pid)
	if data.get("skip", false):
		game.log_msg("%s 放弃复活" % game.player(pid)["name"])
		return
	var pos: Vector2i = data["to"]
	## 复活获得 2.0 能量，随后该固化癌组织降级为癌组织（计数清零，说明 #22）
	var t: Dictionary = game.tile(pos)
	t["tissue"] = CWData.Tissue.CANCER
	t["solid"] = 0
	cell["alive"] = true
	cell["energy"] = CWData.REVIVE_ENERGY
	game.actions.enter_tile(cell, pos)
	game.log_msg("【复活】%s 复活于 %s（2.0 能量），该格降级为癌组织" % [
		game.cell_name(cell), str(pos)])


## 【S-复活】免疫：玩家可选**任一骨髓中无细胞占据的健康组织**，初始 1.0 能量（PRD）。
##
## 落点只有 6 个骨髓格，所以这是个**真实的稀缺资源** —— 骨髓被癌化或被占满时
## 免疫细胞就复活不了，只能继续等。旧版是「全场随机健康格 + 2.0 能量」，
## 那既没有骨髓这个抓手，也让复活变成了免费换阵地。
func revive_options_immune(pid: int) -> Array:
	var cell: Dictionary = game.cell_of(pid)
	if cell["alive"] or cell["respawn_round"] < 0 \
			or game.round_no < cell["respawn_round"]:
		return []
	var options: Array = []
	for c in CWData.MARROWS:
		if game.tile(c)["tissue"] == CWData.Tissue.HEALTHY \
				and game.cells_at(c).is_empty():
			options.append({ "label": "复活于骨髓 %s" % str(c), "data": { "to": c } })
	if options.is_empty():
		game.log_msg("%s 无可用骨髓（健康且无细胞占据），无法复活" % game.cell_name(cell))
	return options


func revive_immune(pid: int, pos: Vector2i) -> void:
	var cell: Dictionary = game.cell_of(pid)
	cell["alive"] = true
	cell["energy"] = game.tune.immune_respawn_energy
	cell["respawn_round"] = -1
	game.actions.enter_tile(cell, pos)
	game.log_msg("【免疫复活】%s 于骨髓 %s 复活（%s 能量）" % [
		game.cell_name(cell), str(pos), CWData.fmt(game.tune.immune_respawn_energy)])


## 【S-有氧呼吸】能量 =（健康组织格数 − 坏死格数）÷ 总格数 × 3，**四舍五入到十分位**。
## 每个免疫细胞各拿这么多，不按细胞数均分（PRD 如此；均分是 CWTuning.split_income() 的实验档）。
##
## 「坏死」格要扣掉：它虽然是健康组织，但不为免疫供能。
func _aerobic() -> void:
	var immune: Array = game.living_cells(CWData.Faction.IMMUNE)
	if immune.is_empty():
		return
	var healthy := 0
	var necrotic := 0
	for t in game.tiles.values():
		if t["tissue"] != CWData.Tissue.HEALTHY:
			continue
		healthy += 1
		if t["necrosis"] > 0:
			necrotic += 1
	# 四舍五入到十分位：分子先 ×10 再加半个分母，整数除法即得（全程整数，无浮点）
	var num: int = (healthy - necrotic) * game.tune.aerobic_mult
	var den: int = CWData.TOTAL_TILES
	var gain: int = (num + den / 2) / den
	if game.tune.aerobic_split:
		gain = gain / immune.size()
	gain = game.tune.clamp_income(gain, game.tune.aerobic_floor, game.tune.aerobic_cap)
	for cell in immune:
		cell["energy"] += gain
	game.log_msg("【有氧呼吸】所有免疫细胞 +%s 能量（健康 %d - 坏死 %d）" % [
		CWData.fmt(gain), healthy, necrotic])


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
	if not converts.is_empty():
		game.log_msg("【增生】%d 格健康组织被癌组织侵占" % converts.size())


## 【E-无氧呼吸】：每块供能 =（癌×0.4 + 固化×1.0），块内癌细胞均分，
## **四舍五入到十分位**（团队 2026-08-28 定案 #43，与有氧一致；PRD 本身没写取整方式）
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
		## (2p+n)/(2n) 是整数版的「p/n 四舍五入」——.5 进位，和有氧那边的 round 口径一致
		var gain: int = ((2 * pool + here.size()) / (2 * here.size())) if game.tune.anaerobic_split else pool
		gain = game.tune.clamp_income(gain, game.tune.anaerobic_floor, game.tune.anaerobic_cap)
		for cell in here:
			## 小细胞肺癌【瓦伯格超速糖酵解】：110% 原产出，**向上取整到十分位**
			if cell["ctype"] == CWData.CancerType.SCLC:
				cell["energy"] += int(ceil(gain * CWData.WARBURG_PERCENT / 100.0))
			else:
				cell["energy"] += gain
		game.log_msg("【无氧呼吸】连通块（%d 格）内 %d 个癌细胞各 +%s 能量" % [
			block.size(), here.size(), CWData.fmt(gain)])


## 骨肉瘤【骨样硬化】：该细胞触发的【E-固化】结算计数为 +1.5。
## 同格只可能有一个细胞（PRD「一个组织内只能容纳一个细胞」），所以不存在叠加问题。
func _solidify_step(c: Vector2i) -> int:
	for occupant in game.cells_at(c, CWData.Faction.CANCER):
		if occupant["ctype"] == CWData.CancerType.OSTEO:
			return CWData.SOLIDIFY_STEP + CWData.SOLIDIFY_STEP / 2
	return CWData.SOLIDIFY_STEP


## 【E-固化】：有癌细胞停留的（非新生）癌组织，按格加计数（说明 #22）
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
		t["solid"] += _solidify_step(c)
		if t["solid"] >= game.tune.solidify_threshold:
			t["tissue"] = CWData.Tissue.SOLID
			game.log_msg("【固化】%s 转为固化癌组织" % str(c))


## 固化计数衰减：计数 > 0 且无癌细胞停留的**癌组织**，每世界回合 −0.5（PRD）
func _decay() -> void:
	for c in game.tiles.keys():
		var t: Dictionary = game.tiles[c]
		if t["tissue"] != CWData.Tissue.CANCER or t["solid"] <= 0:
			continue
		if game.cells_at(c, CWData.Faction.CANCER).is_empty():
			t["solid"] = maxi(t["solid"] - CWData.SOLIDIFY_DECAY, 0)


## 【E-微环境压迫】：每个免疫细胞受相邻癌性组织的压迫，
## 相邻数超过 2 格时损失（相邻数 − 2）× 0.5 能量。
##
## 这是 PRD 给癌方的**第一个稳定伤害来源**。在此之前免疫细胞几乎不可能死
## （旧说明 #23「免疫无死亡途径」），所以【复活】那一整套机制此前基本是空转的。
func _pressure() -> void:
	for cell in game.living_cells(CWData.Faction.IMMUNE):
		var adj := 0
		for nb in CWData.neighbors(cell["pos"]):
			if game.is_cancerous(nb):
				adj += 1
		if adj <= CWData.PRESSURE_FREE_ADJ:
			continue
		var loss: int = (adj - CWData.PRESSURE_FREE_ADJ) * CWData.PRESSURE_PER_ADJ
		game.cancer_hit(cell, loss, "微环境压迫")


## 「坏死」倒计时。PRD E 阶段第 8 步「更新持续时间类状态，并移除已经结束的『坏死』等状态」。
## 按格记「还剩几个世界回合」，每个世界回合末 −1，归零即恢复。
func _tick_necrosis() -> void:
	for t in game.tiles.values():
		if t["necrosis"] > 0:
			t["necrosis"] -= 1


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
		game.win_reason = "%d 回合到：癌性组织 %d >= %d，癌症胜利" % [
			game.tune.limit_round, cancerous, limit]
	else:
		game.winner = CWData.Faction.IMMUNE
		game.win_kind = "limit_immune"
		game.win_reason = "%d 回合到：癌性组织 %d < %d，免疫胜利" % [
			game.tune.limit_round, cancerous, limit]
