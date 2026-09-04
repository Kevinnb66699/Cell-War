## cw_world.gd —— 世界回合的 S/E 阶段结算
##
## 阶段顺序**逐条照抄 PRD「世界回合」那一节**，改动前先回去核对，别凭印象调：
##
## S 阶段：世界事件 → 特殊组织产出 → 血管传送 → 免疫【复活】→ 癌细胞【复活】
##        → 免疫【有氧呼吸】→ 其他 S 类
## E 阶段：【微环境压迫】→【增生】→【侵蚀】→【无氧呼吸】→【固化】→ 固化计数衰减
##        → 其他 E 类 → 更新持续状态（「坏死」到期）→ 移除「新生」
##        → 世界事件到期（紊乱返回、持续效果倒计时）→ **胜利条件检查**
##
## 两个容易踩的点：
## ① **增生在侵蚀之前**。增生会把健康组织变成癌组织，从而改变「完全包围」的判定结果，
##    顺序反了侵蚀的选格就不一样。
## ② **两个胜利条件都是 E 类**，在 E 阶段最后一步统一判。
##    2026-08-28 之前免疫胜利是净化后立即判（I 类）、癌症胜利是 S 阶段开头判，PRD 已推翻。
class_name CWWorld
extends RefCounted

var game: CWGame


## S 阶段的**自动结算部分**（世界事件 → 特殊组织产出 → 血管传送）。
## 两处【复活】要玩家选落点，交给流程状态机；有氧呼吸在复活全部结算完之后调。
## 是协程：产出收取和血管落地都可能抽到要中途选择的事件卡（await 链见 cw_card_fx 头注）。
func round_start() -> void:
	game.log_msg("━━━━ 第 %d 世界回合 ━━━━" % game.round_no)
	_reset_round_flags()
	await game.world_fx.on_round_start()
	if CWData.is_world_event_round(game.round_no):
		await game.world_fx.trigger()
	await _tissue_production()
	await _vessel_teleport()


func aerobic() -> void:
	_aerobic()


## 严格按 PRD「E 阶段」的十步走。2026-08-31 校正了第 7~9 步的先后（口径 #86）：
## 此前 `world_fx.round_end()`（紊乱返回 + 事件到期）整体排在 `_clear_newborn()` 之后，
## 于是紊乱返回时【定殖】造出的癌组织会多背一个世界回合的「新生」。
func e_phase() -> void:
	_pressure()                              ## 1 【微环境压迫】
	_proliferate()                           ## 2 【增生】
	_erosion()                               ## 3 【侵蚀】
	_anaerobic()                             ## 4 【无氧呼吸】
	_cancer_upkeep()                         ## 4.5 【代谢消耗】（PRD 之外，平衡候选③）
	_solidify()                              ## 5 【固化】
	_decay()                                 ## 6 固化计数衰减
	await game.world_fx.round_effects()      ## 7 其他 E 类效果：目前只有【紊乱】返回原位
	game.world_fx.tick_durations()           ## 8 世界事件倒计时/到期 + 「本世界回合」修饰过期
	_tick_necrosis()                         ## 8 「坏死」倒计时（同属第 8 步）
	_tick_chemo()                            ## 8 树突【I-趋化源】倒计时（同属第 8 步）
	_clear_newborn()                         ## 9 移除「新生」
	_cap_energy()                            ## 9.5 能量上限（PRD 之外，见口径 #92）
	## 10 胜利条件检查。免疫先判：PRD 的列举顺序如此，
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
		c["toxin_used"] = 0            ## T【细胞毒素】3 次/世界回合
		c["antibody_used"] = 0         ## B【抗体】每世界回合上限（旋钮，默认不限）
		c["metastasis_used"] = false   ## 黑色素瘤【早期血行转移】1 次/世界回合
		c["jump_used"] = 0             ## 小细胞肺癌【转移】每世界回合上限（旋钮，默认不限）
		c["fx_round"] = {}             ## 永久技能「每世界回合第一次」的闸门


## 代谢核心/骨髓产出；产出瞬间站在其上的细胞立即收取（说明 #9）
func _tissue_production() -> void:
	if game.event_stacks("营养缺乏") > 0:
		game.log_msg("【营养缺乏】本回合特殊组织不产出")
		return
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
				await game.actions.collect_special(here[0], c)


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
		await game.actions.enter_tile(cell, b)
		await game.world_fx.on_vessel_pass(cell)
	for cell in cb:
		game.log_msg("【血管】%s 传送至 %s" % [game.cell_name(cell), str(a)])
		await game.actions.enter_tile(cell, a)
		await game.world_fx.on_vessel_pass(cell)


## 【S-复活】癌症：落点是**未被细胞占据**的固化癌组织；可自愿放弃（说明 #21）。
## 没有可用落点时返回空数组，流程状态机会跳过这个玩家 —— **但会先说明为什么**，见 _report_no_revive。
func revive_options_cancer(pid: int) -> Array:
	var cell: Dictionary = game.cell_of(pid)
	## 流程状态机对**每个席位**都问一遍（_ask_each），免疫席位也会走到这里：死了的免疫细胞归上一段
	## revive_immune 管，这里必须直接放过 —— 否则它会被报成「场上没有固化癌组织」（队友 2026-09-03 截图），
	## 而且场上有空固化格时还会被当成癌细胞问「复活于固化格」。
	if cell["alive"] or cell["faction"] != CWData.Faction.CANCER:
		return []
	var candidates: Array[Vector2i] = []
	var taken: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] != CWData.Tissue.SOLID:
			continue
		if game.cells_at(c).is_empty():
			candidates.append(c)
		else:
			taken.append(c)     ## 有细胞站着的固化格：不是落点，但要说清楚是被谁占了
	if candidates.is_empty():
		taken.sort()
		_report_no_revive(pid, cell, taken)
		return []
	candidates.sort()   ## 固定候选顺序，保证同种子可复现
	var options: Array = [{ "label": "放弃本回合复活", "data": { "skip": true } }]
	for c in candidates:
		options.append({ "label": "复活于 %s" % str(c), "data": { "to": c } })
	return options


## 复活不了的时候，得让癌方知道**为什么**。
##
## 此前这里只是返回空数组，流程状态机静默跳过 —— 癌方玩家看到的就是
## 「我死了，然后就没有然后了」，队友 2026-08-31 报的正是这个（口径 #93）。
## 免疫站在固化癌组织上把复活位堵死是**有意的战术**（Kevin 裁定「这不算 bug，请保留」），
## 但**被堵住这件事必须说出来**，否则玩家读不出这是战术，只会读成程序坏了。
##
## 每个世界回合每人只会走到这里一次（`_ask_each` 沿 flow["i"] 单向推进），所以不会刷屏。
## 只写日志 + 一句通报，**不碰任何状态**，同种子可复现不受影响。
func _report_no_revive(pid: int, cell: Dictionary, taken: Array[Vector2i]) -> void:
	if game.sim_quiet:
		return          ## 蒙特卡洛推演里没人看，也别去广播
	var who: String = game.player(pid)["name"]
	if taken.is_empty():
		game.log_msg("【复活】%s 无法复活：场上没有固化癌组织" % who)
		game.announce("%s 无法复活：没有固化癌组织" % who, cell["pos"])
		return
	var parts: PackedStringArray = []
	for c in taken:
		parts.append("%s 被 %s 占据" % [str(c), game.cell_name(game.cells_at(c)[0])])
	game.log_msg("【复活】%s 无法复活：固化癌组织都有人站着（%s）" % [who, "；".join(parts)])
	## 提示挂在**被占的那一格**上，玩家一眼能看到是哪儿被堵了
	game.announce("%s 无法复活：固化癌组织被占据" % who, taken[0])



func revive_cancer(pid: int, data: Dictionary) -> void:
	var cell: Dictionary = game.cell_of(pid)
	if data.get("skip", false):
		game.log_msg("%s 放弃复活" % game.player(pid)["name"])
		return
	var pos: Vector2i = data["to"]
	## 复活获得 2.0 能量，随后该固化癌组织降级为癌组织（计数清零，说明 #22）
	var t: Dictionary = game.tile(pos)
	CWTissue.crack_to_cancer(t)
	cell["alive"] = true
	cell["energy"] = CWData.REVIVE_ENERGY
	## 【癌症干性】：复活能量提高（分期），本世界回合 1 次（20 回合起 2 次）
	## 向癌性组织的移动免费——免费额度挂成 round 时钟的修饰条目，计费在 _move_cost_mod
	if game.has_skill(cell, "癌症干性"):
		cell["energy"] = CWData.STEMNESS_ENERGY[CWCardData.cancer_phase(game.round_no)]
		var freebies := 2 if game.round_no >= 20 else 1
		game.add_mod(cell, "癌症干性", freebies, "round")
		game.log_msg("　【癌症干性】复活能量提高至 %s，本世界回合 %d 次向癌性组织移动免费" % [
			CWData.fmt(cell["energy"]), freebies])
	await game.actions.enter_tile(cell, pos)
	game.log_msg("【复活】%s 复活于 %s（%s 能量），该格降级为癌组织" % [
		game.cell_name(cell), str(pos), CWData.fmt(cell["energy"])])


## 【S-复活】免疫：玩家可选**任一骨髓中无细胞占据的健康组织**，初始 1.0 能量（PRD）。
##
## 落点只有 6 个骨髓格，所以这是个**真实的稀缺资源** —— 骨髓被癌化或被占满时
## 免疫细胞就复活不了，只能继续等。旧版是「全场随机健康格 + 2.0 能量」，
## 那既没有骨髓这个抓手，也让复活变成了免费换阵地。
func revive_options_immune(pid: int) -> Array:
	var cell: Dictionary = game.cell_of(pid)
	if cell["faction"] != CWData.Faction.IMMUNE:
		return []          ## 癌席位归下一段 revive_cancer 管（与上面对称，别靠 respawn_round 恰好是 -1 撞对）
	if cell["alive"] or cell["respawn_round"] < 0 			or game.round_no < cell["respawn_round"]:
		return []          ## 还没到复活回合 —— 不是「被挡住」，没什么可解释的
	var options: Array = []
	var cancerous: Array[Vector2i] = []
	var taken: Array[Vector2i] = []
	for c in CWData.MARROWS:
		if game.tile(c)["tissue"] != CWData.Tissue.HEALTHY:
			cancerous.append(c)          ## 被癌化：净化掉才能用
		elif not game.cells_at(c).is_empty():
			taken.append(c)              ## 有人站着：等它走开
		else:
			options.append({ "label": "复活于骨髓 %s" % str(c), "data": { "to": c } })
	if options.is_empty():
		_report_no_revive_immune(cell, cancerous, taken)
	return options


## 免疫复活不了时说清楚**为什么**，和癌方那条（_report_no_revive）对称。
##
## 此前这里只有一句「无可用骨髓（健康且无细胞占据），无法复活」——话是说了，
## 但玩家看不出该去救哪一格：六个骨髓里哪些被癌化了、哪些只是站了人，
## 这两种情况的应对完全不同（前者要净化，后者只要等或挪开）。
##
## 只写日志 + 一句通报，**不碰任何状态**；sim_quiet 时整体跳过。
func _report_no_revive_immune(cell: Dictionary, cancerous: Array[Vector2i],
		taken: Array[Vector2i]) -> void:
	if game.sim_quiet:
		return
	var who: String = game.cell_name(cell)
	var parts: PackedStringArray = []
	if not cancerous.is_empty():
		var cs: PackedStringArray = []
		for c in cancerous:
			cs.append(str(c))
		parts.append("被癌化 %s" % " ".join(cs))
	if not taken.is_empty():
		var ts: PackedStringArray = []
		for c in taken:
			ts.append("%s 被 %s 占据" % [str(c), game.cell_name(game.cells_at(c)[0])])
		parts.append("有人站着（%s）" % "；".join(ts))
	game.log_msg("【免疫复活】%s 无法复活：六个骨髓%s" % [who, "，".join(parts)])
	## 提示挂在第一格被挡的骨髓上，玩家一眼知道该往哪儿使劲
	var at: Vector2i = cancerous[0] if not cancerous.is_empty() else taken[0]
	game.announce("%s 无法复活：骨髓不可用" % who, at)


func revive_immune(pid: int, pos: Vector2i) -> void:
	var cell: Dictionary = game.cell_of(pid)
	cell["alive"] = true
	cell["energy"] = game.tune.immune_respawn_energy
	cell["respawn_round"] = -1
	await game.actions.enter_tile(cell, pos)
	game.log_msg("【免疫复活】%s 于骨髓 %s 复活（%s 能量）" % [
		game.cell_name(cell), str(pos), CWData.fmt(game.tune.immune_respawn_energy)])


## 【S-有氧呼吸】能量 =（健康组织格数 - 坏死格数）÷ 总格数 × 3，**四舍五入到十分位**。
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
	var num: int = (healthy - necrotic) * game.tune.aerobic_mult_at(game.round_no)
	var den: int = CWData.TOTAL_TILES
	var gain: int = (num + den / 2) / den
	if game.tune.aerobic_split:
		gain = gain / immune.size()
	gain = game.tune.clamp_income(gain, game.tune.aerobic_floor, game.tune.aerobic_cap)
	## 【TGF-β释放】：下一次有氧结算每份 -20%（逐份 ×80% 向下取整，定案 #63），
	## 结算完消耗——条目挂在全局容器里，left=2 保证能活到下一个 S 阶段
	var tgf := 0
	var kept: Array = []
	for e in game.events["active"]:
		if e["name"] == "TGF-β释放":
			tgf += e["stacks"]
		else:
			kept.append(e)
	if tgf > 0:
		game.events["active"] = kept
		var before := gain
		for i in tgf:
			gain = gain * 8 / 10   ## 整数除法 = 向下取整到十分位
		game.log_msg("【TGF-β释放】有氧呼吸 %s → %s（%d 份 -20%%，已消耗）" % [
			CWData.fmt(before), CWData.fmt(gain), tgf])
	for cell in immune:
		cell["energy"] += gain
		## 【代谢适应】/【自分泌生存信号】的「额外获得」在基准收入之外加，
		## 不吃 TGF-β 的 -20%（那句管的是有氧结算本身的所得，口径 #69）
		var bonus := 0
		if game.has_skill(cell, "代谢适应"):
			bonus += CWData.AEROBIC_ADAPT
		if game.has_skill(cell, "自分泌生存信号"):
			bonus += CWData.AEROBIC_AUTOCRINE
		if bonus > 0:
			cell["energy"] += bonus
			game.log_msg("　%s 的永久技能额外 +%s 能量" % [game.cell_name(cell), CWData.fmt(bonus)])
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
			if _watched(c):
				continue  # 【免疫监视】守护范围内不能被侵蚀
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
		CWTissue.to_cancer(game.tile(c), true)
		game.log_msg("【侵蚀】%s 转为癌组织" % str(c))


## 【E-增生】癌组织向外扩散：与癌性组织相邻的健康组织按概率被转化（PRD 已入规，概率见 CWTuning）
## 先统一掷骰收集、再统一转化 —— 保证「同时结算」，避免转化顺序影响后续格的相邻数。
func _proliferate() -> void:
	if game.event_stacks("增殖抑制") > 0:
		game.log_msg("【增殖抑制】本回合组织无法增生")
		return
	var rate: int = game.tune.proliferate_per_adjacent
	for i in game.event_stacks("异常增殖"):
		rate *= 2   ## 【异常增殖】增生概率翻倍（叠加时按层数连乘）
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
		if _watched(c):
			continue  # 【免疫监视】守护范围内不做增生判定（不掷骰，rng 消耗随之变少）
		var adj := 0
		for n in CWData.neighbors(c):
			if game.is_cancerous(n):
				adj += 1
		if adj > 0 and game.rng.randi_range(1, 1000) <= rate * adj:
			converts.append(c)
	for c in converts:
		CWTissue.to_cancer(game.tile(c), true)
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
		pool = _sqrt_pool(pool)
		var here: Array = []
		for cell in game.living_cells(CWData.Faction.CANCER):
			if members.has(cell["pos"]):
				here.append(cell)
		if here.is_empty():
			continue
		var gain := _split_share(pool, here.size())
		for cell in here:
			## 小细胞肺癌【瓦伯格超速糖酵解】：110% 原产出，**向上取整到十分位**
			if cell["ctype"] == CWData.CancerType.SCLC:
				cell["energy"] += int(ceil(gain * CWData.WARBURG_PERCENT / 100.0))
			else:
				cell["energy"] += gain
			var glut := _glut_bonus(cell)
			if glut > 0:
				cell["energy"] += glut
				game.log_msg("　【GLUT1高表达】%s 额外 +%s 能量" % [
					game.cell_name(cell), CWData.fmt(glut)])
		game.log_msg("【无氧呼吸】连通块（%d 格）内 %d 个癌细胞各 +%s 能量" % [
			block.size(), here.size(), CWData.fmt(gain)])


## 连通块供能均分到一个细胞：四舍五入到十分位（定案 #43）+ 收入夹钳。
## E 阶段结算和卡【糖酵解爆发】共用 —— 改口径只改这里。
## 【无氧呼吸】的**刹车**（Kevin 2026-09-02 提的候选，旋钮 `anaerobic_sqrt_coef`，默认 0 = 关）。
##
## **为什么要有它。** 现行是线性求和：连通块里每格癌组织 +0.4、每格固化 +1.0。
## 分子随占地涨、分母是固定的玩家数，于是「占得越多 → 越有钱 → 占得越快」是个**没有刹车的正反馈**；
## 而免疫的【有氧呼吸】= 健康格占比 × 系数，**随健康格下跌**。两条曲线方向相反，拉开就不可逆。
## 2026-09-05 的六人局智能体对局把这条拍实了：癌组织净增 +11/+8/+13/+20/+20，
## 三个癌细胞第 4~5 回合就顶到 15 能量上限**溢出浪费**，而免疫有氧从 2.9 掉到 1.6。
##
## 改成开方之后，前期几乎不变、后期腰斩：
## 24 格时 √24×2.0 ≈ 9.8（线性 9.6），97 格时 √101×2.0 ≈ 20.1（线性 40.6）。
## 换句话说**不动开局手感，只砍雪球**。
##
## 先把线性池折回「等效格数」再开方（而不是直接数格子），这样固化格的双倍权重不会丢。
func _sqrt_pool(pool: int) -> int:
	var coef: int = game.tune.anaerobic_sqrt_coef
	if coef <= 0 or pool <= 0:
		return pool
	var tiles := float(pool) / float(game.tune.anaerobic_per_cancer)
	return int(round(coef * sqrt(tiles)))


func _split_share(pool: int, count: int) -> int:
	## (2p+n)/(2n) 是整数版的「p/n 四舍五入」：.5 进位，和有氧那边的 round 口径一致
	var gain: int = ((2 * pool + count) / (2 * count)) if game.tune.anaerobic_split else pool
	return game.tune.clamp_income(gain, game.tune.anaerobic_floor, game.tune.anaerobic_cap)


## 【代谢消耗】（平衡候选③，PRD 之外）：每个癌细胞按**当前能量的百分比**自动损能。
## 团队 2026-09-01 定的三条口径，每条都有代价，别顺手改：
##   ① 扣在【无氧呼吸】**之后** —— 所以税的是「存款 + 这回合刚进的账」，不只是存款；
##   ② **不算伤害事件** —— 不走 CWDamage 管线，【缺氧适应】【囊性护甲】【耗竭抵抗】
##      一概挡不住，BCL-2 也不介入。它是「代谢开销」不是「谁打了谁」，
##      进管线会让一堆减伤牌凭空多出一层用途；
##   ③ 向下取整（整数除法）。
##
## ⚠ **它杀不死细胞**，这是数学性质不是防呆：按比例扣永远到不了 0，
## 而且能量低到 `energy * pct < 100` 时整除直接得 0（0.4 能量扣 20% = 0.08 → 0）。
## 正因为杀不死人，这里不需要死亡检查 —— 也就不必进伤害管线。
func _cancer_upkeep() -> void:
	var pct: int = game.tune.cancer_upkeep_pct
	if pct <= 0:
		return
	for cell in game.living_cells(CWData.Faction.CANCER):
		var lost: int = cell["energy"] * pct / 100
		if lost <= 0:
			continue
		cell["energy"] -= lost
		game.log_msg("【代谢消耗】%s 损失 %s 能量（余 %s）" % [
			game.cell_name(cell), CWData.fmt(lost), CWData.fmt(cell["energy"])])


## 单独算某个癌细胞**此刻**的无氧供给（卡【糖酵解爆发】用），口径与 _anaerobic 一致
func anaerobic_gain_for(target: Dictionary) -> int:
	var cancer_pred := func(c: Vector2i) -> bool:
		return game.is_cancerous(c)
	for block in game.blocks_of(cancer_pred):
		var members := {}
		var pool := 0
		for c in block:
			members[c] = true
			pool += game.tune.anaerobic_per_solid if game.tiles[c]["tissue"] == CWData.Tissue.SOLID \
				else game.tune.anaerobic_per_cancer
		if not members.has(target["pos"]):
			continue
		var count := 0
		for cell in game.living_cells(CWData.Faction.CANCER):
			if members.has(cell["pos"]):
				count += 1
		var gain := _split_share(pool, maxi(count, 1))
		## 小细胞肺癌【瓦伯格超速糖酵解】对这次结算同样生效
		if target["ctype"] == CWData.CancerType.SCLC:
			gain = int(ceil(gain * CWData.WARBURG_PERCENT / 100.0))
		## 【GLUT1高表达】「每次结算无氧呼吸」——糖酵解爆发的这次也算
		return gain + _glut_bonus(target)
	return 0


func _glut_bonus(cell: Dictionary) -> int:
	if game.has_skill(cell, "GLUT1高表达"):
		return CWData.GLUT1_BONUS[CWCardData.cancer_phase(game.round_no)]
	return 0


## 【免疫监视】：装备者所在格及 3 格范围内的健康组织不做【增生】判定、不能被【侵蚀】。
## （PRD 写「自身相邻3格」，按 3 格范围读——⏳ 口径 #66 待团队确认）
func _watched(c: Vector2i) -> bool:
	for cell in game.living_cells(CWData.Faction.IMMUNE):
		if game.has_skill(cell, "免疫监视") \
				and CWData.hex_dist(c, cell["pos"]) <= CWData.WATCH_RANGE:
			return true
	return false


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
		## 「新生」保护是旋钮（2026-09-04 Kevin 拍板取消，默认 false）：关掉后当回合新铺的格子当回合就累计
		if t["tissue"] != CWData.Tissue.CANCER 				or (game.tune.newborn_protect and t["newborn"]):
			continue
		game.raise_solid(c, _solidify_step(c))   ## 门槛判定（含【固化加速】）在 raise_solid 里


## 【E-能量上限】E 阶段末的那一次结算，实体在 CWGame.cap_energy（还有另外两个结算点要用）。
func _cap_energy() -> void:
	game.cap_energy()


## 固化计数衰减：计数 > 0 且无癌细胞停留的**癌组织**，每世界回合 -0.5（PRD）
func _decay() -> void:
	if game.event_stacks("基质稳定") > 0:
		game.log_msg("【基质稳定】本世界回合固化计数不衰减")
		return
	for c in game.tiles.keys():
		var t: Dictionary = game.tiles[c]
		if t["tissue"] != CWData.Tissue.CANCER or t["solid"] <= 0:
			continue
		if game.cells_at(c, CWData.Faction.CANCER).is_empty():
			t["solid"] = maxi(t["solid"] - CWData.SOLIDIFY_DECAY, 0)


## 【E-微环境压迫】：每个免疫细胞受相邻癌性组织的压迫，
## 相邻数超过 2 格时损失（相邻数 - 2）× 0.5 能量。
##
## 这是 PRD 给癌方的**第一个稳定伤害来源**。在此之前免疫细胞几乎不可能死
## （旧说明 #23「免疫无死亡途径」），所以【复活】那一整套机制此前基本是空转的。
## 站在 `c` 的免疫细胞在本世界回合末会因【微环境压迫】损失多少能量（十分能量）。
##
## **纯查询，界面直接调它**（悬停格子详情框显示「本回合末压迫 −X」）。
## 抽出来的唯一理由：这条算式**只能有一份**。界面抄第二份必然漂，
## 而本项目 2026-09-01 已经因为「注释/测试与实现共享错误前提」栽过三次。
##
## ⚠ 它算的是**此刻**的盘面。癌方在免疫之后行动、会在免疫周围铺新格，
## 所以回合末的真实值只会**大于等于**这个数 —— 界面上要说清是「至少」。
func pressure_at(c: Vector2i) -> int:
	var adj := 0
	for nb in CWData.neighbors(c):
		if game.is_cancerous(nb):
			adj += 1
	return maxi(adj - CWData.PRESSURE_FREE_ADJ, 0) * CWData.PRESSURE_PER_ADJ


func _pressure() -> void:
	for cell in game.living_cells(CWData.Faction.IMMUNE):
		var loss := pressure_at(cell["pos"])
		if loss <= 0:
			continue
		## 压迫一律走 cancer_hit：【缺氧适应】重写后（2026-08-30）不再「免疫压迫」，
		## 而是在损失管线里减 1.0，和癌细胞技能同一面盾——不需要在这里特判了
		game.cancer_hit(cell, loss, "微环境压迫")


## 「坏死」倒计时。PRD E 阶段第 8 步「更新持续时间类状态，并移除已经结束的『坏死』等状态」。
## 按格记「还剩几个世界回合」，每个世界回合末 -1，归零即恢复。
## 树突【I-趋化源】的「持续 2 回合」：与坏死同一步倒计时，归零即消失。
## 建立的那个回合末算第一次减 —— 所以「持续 2 回合」= 建立当回合 + 下一个回合。
func _tick_chemo() -> void:
	if game.chemo.is_empty():
		return
	game.chemo["left"] = int(game.chemo["left"]) - 1
	if game.chemo["left"] <= 0:
		var at: Vector2i = game.chemo["at"]
		game.chemo = {}
		game.log_msg("【趋化源】%s 的趋化源消散" % str(at))


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
