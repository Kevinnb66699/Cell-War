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
## ① **增生在侵蚀之前**，但增生这一轮**新造的格子不作侵蚀的来源**
##    （PRD 的「注」：新癌组织下一世界回合才参与结算；Kevin 2026-09-09 定的读法）。
##    所以 `_proliferate()` 把新格返回给 `_erosion()`，两者不再是单纯的先后关系。
##    「完全包围」仍按实时盘面算 —— 新格已经不是健康组织了，连通块本来就变了，不去还原。
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
	## 增生把它这一轮造出来的格子交给侵蚀，让侵蚀**不要拿它们当来源**（PRD 的「注」，Kevin 2026-09-09 定读法）
	_erosion(_proliferate())                 ## 2 【增生】→ 3 【侵蚀】
	if not game.tune.anaerobic_on_turn_end:
		_anaerobic()                         ## 4 【无氧呼吸】（默认走这里；`eturn=1` 改在各癌细胞回合末，见 settle_anaerobic_turn）
	_cancer_upkeep()                         ## 4.5 【代谢消耗】（PRD 之外，平衡候选③）
	await _resolve_camping()                 ## 4.9 骨样硬化标记格上的蹲守净化（排在固化之前，见 _resolve_camping）
	_solidify()                              ## 5 【固化】
	_ossify()                                ## 5 骨肉瘤【骨样硬化】标记到期（同属第 5 步，排在计数固化之后）
	_decay()                                 ## 6 固化计数衰减
	_mark_adhesion()                         ## 7 树突【E-组织黏连】（也是 E 类，排在紊乱返回之前）
	await game.world_fx.round_effects()      ## 7 其他 E 类效果：目前只有【紊乱】返回原位
	game.world_fx.tick_durations()           ## 8 世界事件倒计时/到期 + 「本世界回合」修饰过期
	_tick_necrosis()                         ## 8 「坏死」倒计时（同属第 8 步）
	_tick_chemo()                            ## 8 树突【I-趋化源】倒计时（同属第 8 步）
	_tick_chemo_track()                      ## 8 【免疫猎杀】的追踪趋化源倒计时（同属第 8 步）
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


## 【S-复活】癌症，可自愿放弃（说明 #21）。
##
## PRD（Kevin 2026-09-09 给的定稿措辞）：「每个癌细胞可以在**没有被免疫细胞占据的
## 固化癌组织 1 环内**、**无细胞占据的癌性组织**复活，获得 2 能量，
## 随后**该固化癌组织**转为癌组织」。
##
## 拆成引擎能查的三句：
##   · **依托**：任何**不被免疫细胞占据**的固化癌组织（空着的、或队友站着的，都算）；
##   · **落点**：该依托格 1 环内、无细胞占据的癌性组织。1 环**含中心格**（通用规则 2），
##     所以「直接落在空着的固化格上」只是这条规则的特例，不再是单独一条路；
##   · **代价**：降级的是**依托格**，不是落点。
##
## **被免疫占着的固化格什么都不给**：免疫踩着固化格堵复活位是有意的战术
## （Kevin 2026-08-31 裁定「这不算 bug，请保留」）。PRD 定稿把这句写进了正文。
##
## 没有可用落点时返回空数组，流程状态机会跳过这个玩家 —— **但会先说明为什么**，见 _report_no_revive。
##
## 顺带一提：**不影响【E-免疫胜利】**（CWGame.check_immune_win）——
## 那边判的是「有没有能用于复活的固化癌组织」，用的是同一套「不被免疫占据」的口径。
func revive_options_cancer(pid: int) -> Array:
	var cell: Dictionary = game.cell_of(pid)
	## 流程状态机对**每个席位**都问一遍（_ask_each），免疫席位也会走到这里：死了的免疫细胞归上一段
	## revive_immune 管，这里必须直接放过 —— 否则它会被报成「场上没有固化癌组织」（队友 2026-09-03 截图），
	## 而且场上有空固化格时还会被当成癌细胞问「复活于固化格」。
	if cell["alive"] or cell["faction"] != CWData.Faction.CANCER:
		return []
	var spots := {}                       ## 落点 -> 作为依托、要被碎掉的那个固化格
	var by_immune: Array[Vector2i] = []   ## 被免疫占着：整格作废
	var usable: Array[Vector2i] = []      ## 能当依托的固化格（用于「为什么复活不了」的说明）
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] != CWData.Tissue.SOLID:
			continue
		var here: Array = game.cells_at(c)
		if not here.is_empty() and here[0]["faction"] != CWData.Faction.CANCER:
			by_immune.append(c)
			continue
		usable.append(c)
		## 1 环 = 中心格 + 六个邻格（通用规则 2「含中心格」）。
		## 不调 CWData.ring(c, 1) 是因为它要遍历全部 127 格算距离，这里每个固化格都要跑一遍。
		var around: Array[Vector2i] = [c]
		around.append_array(CWData.neighbors(c))
		for n in around:
			if game.is_cancerous(n) and game.cells_at(n).is_empty():
				## 一个落点可能同时落在好几个固化格的 1 环里。**依托取坐标最小的那个**：
				## 让玩家再选一次「碎哪一格」会给复活多加一问，收益远不抵这一步的打扰；
				## 取最小值也让结果不依赖 tiles 的遍历顺序（同种子可复现）。
				## ⚠ 落点自己就是空固化格时，`c == n` 一定是候选之一，但**不保证被选中**——
				## 旁边坐标更小的固化格会顶替它，于是碎的是旁边那格、人站在仍然是固化的落点上。
				## 这对癌方反而更划算，PRD 没有排除，就按同一条最小值规则走，不另开一问。
				if not spots.has(n) or c < spots[n]:
					spots[n] = c
	if spots.is_empty():
		by_immune.sort()
		usable.sort()
		_report_no_revive(pid, cell, by_immune, usable)
		return []
	var keys: Array = spots.keys()
	keys.sort()        ## 固定候选顺序，保证同种子可复现
	var options: Array = [{ "label": "放弃本回合复活", "data": { "skip": true } }]
	for c in keys:
		var anchor: Vector2i = spots[c]
		if anchor == c:
			options.append({ "label": "复活于 %s" % str(c), "data": { "to": c, "anchor": anchor } })
		else:
			options.append({ "label": "复活于 %s（碎掉固化癌组织 %s）" % [str(c), str(anchor)],
				"data": { "to": c, "anchor": anchor } })
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
func _report_no_revive(pid: int, cell: Dictionary, by_immune: Array[Vector2i],
		usable: Array[Vector2i]) -> void:
	if game.sim_quiet:
		return          ## 蒙特卡洛推演里没人看，也别去广播
	var who: String = game.player(pid)["name"]
	if by_immune.is_empty() and usable.is_empty():
		game.log_msg("【复活】%s 无法复活：场上没有固化癌组织" % who)
		game.announce("%s 无法复活：没有固化癌组织" % who, cell["pos"], true)
		return
	## 固化格是有的，只是没有一格开得出落点。**两种处境分开说** ——「被免疫踩着」要去把免疫赶走，
	## 「能用但一圈没空位」要去把它周围腾出来，混成一句话玩家读不出该干什么。
	var parts: PackedStringArray = []
	if not by_immune.is_empty():
		var who_on: PackedStringArray = []
		for c in by_immune:
			who_on.append("%s 被 %s 占据" % [str(c), game.cell_name(game.cells_at(c)[0])])
		parts.append("被免疫占着的（%s）" % "；".join(who_on))
	if not usable.is_empty():
		var spots: PackedStringArray = []
		for c in usable:
			spots.append(str(c))
		parts.append("能用的（%s）1 环内没有空的癌性组织" % ", ".join(spots))
	game.log_msg("【复活】%s 无法复活：%s" % [who, "；".join(parts)])
	## 提示挂在**被堵的那一格**上，玩家一眼能看到是哪儿出的问题
	var at: Vector2i = by_immune[0] if not by_immune.is_empty() else usable[0]
	game.announce("%s 无法复活：固化癌组织都用不上" % who, at, true)



func revive_cancer(pid: int, data: Dictionary) -> void:
	var cell: Dictionary = game.cell_of(pid)
	if data.get("skip", false):
		game.log_msg("%s 放弃复活" % game.player(pid)["name"])
		return
	var pos: Vector2i = data["to"]
	## 复活获得 2.0 能量，随后**作为依托的那一格**固化癌组织降级为癌组织（计数清零，说明 #22）。
	## 降级的是 anchor 而不是落点 —— 落在依托格自己身上时两者才是同一格（1 环含中心格）。
	## `get` 的兜底留给读旧存档：2026-09-09 之前「直接落在空固化格上」那条选项不带 anchor。
	var anchor: Vector2i = data.get("anchor", pos)
	CWTissue.crack_to_cancer(game.tile(anchor))
	cell["alive"] = true
	cell["energy"] = CWData.REVIVE_ENERGY
	## 【癌症干性】：复活能量提高（分期），本世界回合**前两次**向癌性组织的移动免费。
	## 2026-09-07 卡面改动：复活能量 2.5/3/3.5 → 3/4/5，免费次数从「1 次（20 回合起 2 次）」
	## 统一成 2 次（15 回合制之下没有第 20 回合了）。免费额度挂成 round 时钟的修饰条目，计费在 _move_cost_mod
	if game.has_skill(cell, "癌症干性"):
		cell["energy"] = CWData.STEMNESS_ENERGY[CWCardData.cancer_phase(game.round_no)]
		var freebies := 2
		game.add_mod(cell, "癌症干性", freebies, "round")
		game.log_msg("　【癌症干性】复活能量提高至 %s，本世界回合 %d 次向癌性组织移动免费" % [
			CWData.fmt(cell["energy"]), freebies])
	await game.actions.enter_tile(cell, pos)
	if anchor == pos:
		game.log_msg("【复活】%s 复活于 %s（%s 能量），该格降级为癌组织" % [
			game.cell_name(cell), str(pos), CWData.fmt(cell["energy"])])
	else:
		game.log_msg("【复活】%s 复活于 %s（%s 能量），依托的固化癌组织 %s 降级为癌组织" % [
			game.cell_name(cell), str(pos), CWData.fmt(cell["energy"]), str(anchor)])


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
	game.announce("%s 无法复活：骨髓不可用" % who, at, true)


func revive_immune(pid: int, pos: Vector2i) -> void:
	var cell: Dictionary = game.cell_of(pid)
	cell["alive"] = true
	cell["energy"] = game.tune.immune_respawn_energy
	cell["respawn_round"] = -1
	await game.actions.enter_tile(cell, pos)
	game.log_msg("【免疫复活】%s 于骨髓 %s 复活（%s 能量）" % [
		game.cell_name(cell), str(pos), CWData.fmt(game.tune.immune_respawn_energy)])


## 【S-有氧呼吸】能量 = **(抗原记忆等级 − 1) × 0.5 + 基数**（团队 09-04 定公式、Kevin 09-05 定写法；
## 基数按人数分档 四人 2.0 / 六人 1.8，见 CWData.aerobic_level_base）。immune_level 0 起，故代码是 base + level × step。
## 每个免疫细胞各拿这么多，不按细胞数均分（PRD 如此；均分是 CWTuning.split_income() 的实验档）。
##
## 盘面口径（健康 - 坏死）现在只用来写日志了 —— 但**照旧要数**：
## 旧公式仍能靠 `abase=0` 跑回来（09-04 之前的扫描数据都是那套），日志两边共用同一组数字。
## 「坏死」格在旧公式里要扣掉：它虽然是健康组织，但不为免疫供能。
## 盘面上的健康格数与其中的坏死格数（盘面式有氧基准和日志用）
func _healthy_counts() -> Vector2i:
	var healthy := 0
	var necrotic := 0
	for t in game.tiles.values():
		if t["tissue"] != CWData.Tissue.HEALTHY:
			continue
		healthy += 1
		if t["necrosis"] > 0:
			necrotic += 1
	return Vector2i(healthy, necrotic)


## 场上挂着几份【TGF-β释放】（卡牌挂的全局修饰，下一次有氧结算消耗）
func _tgf_stacks() -> int:
	var n := 0
	for e in game.events["active"]:
		if e["name"] == "TGF-β释放":
			n += int(e["stacks"])
	return n


## 【有氧呼吸】这一次**每份**多少：基准 → 夹钳 → 均分 → 【TGF-β释放】逐份 -20%。
## **只算不结算**（不消耗 TGF-β、不写日志）：右栏「预计收入」和 _aerobic 共用这一份算式 ——
## 界面抄第二份必然漂（pressure_at 同款纪律，2026-09-06 Kevin 要能量旁边显示预计收入时拆出来的）。
## with_tgf=false 只给 _aerobic 写「减免前 → 减免后」那行日志用。
func aerobic_share(with_tgf := true) -> int:
	var hn := _healthy_counts()
	## 低保/封顶夹在**基准**上、再均分 —— 顺序反过来的话 2.0 的低保会把 2.5÷3=0.8 顶回 2.0，
	## 均分等于没开（2026-09-05 t_batch2_rules 当场抓到；此前 split 是关着的所以从没暴露）。
	## aerobic_split=false 时两种顺序逐位相同，09-04 之前的数据不受影响。
	var gain := game.tune.clamp_income(_aerobic_base(hn.x, hn.y),
		game.tune.aerobic_floor, game.tune.aerobic_cap)
	if game.tune.aerobic_split:
		gain = _split_aerobic(gain, game.living_cells(CWData.Faction.IMMUNE).size())
	if with_tgf:
		for i in _tgf_stacks():
			gain = gain * 8 / 10   ## 整数除法 = 向下取整到十分位（逐份 ×80%，定案 #63）
	return gain


## 【代谢适应】/【自分泌生存信号】的「每次结算有氧呼吸时额外获得」——在每份之外加，不吃 TGF-β 的 -20%（口径 #69）
func _aerobic_bonus(cell: Dictionary) -> int:
	var bonus := 0
	if game.has_skill(cell, "代谢适应"):
		bonus += CWData.AEROBIC_ADAPT
	if game.has_skill(cell, "自分泌生存信号"):
		bonus += CWData.AEROBIC_AUTOCRINE
	return bonus


## 某个免疫细胞下一次 S 阶段预计拿到多少（右栏能量旁的「+x.x」）：站在坏死格 = 整份不拿、连技能加成也没有；
## 否则 = 每份 + 永久技能的额外获得。口径与 _aerobic 逐位一致 —— 回归拿它和真结算的差额对。
func aerobic_income(cell: Dictionary) -> int:
	return necrosis_cut(cell, aerobic_share() + _aerobic_bonus(cell))


## 站在坏死组织上就打折（Kevin 2026-09-07：由「一份不给」改成 80%）。**整份一起打**——
## 技能的「额外获得」也在这一份里（那句的前提是「这次结算发生了」，折扣是对这次结算整体的）。
## **四舍五入**到十分位（PRD 通用规则 1）—— PRD 只说「减半」，没写取整方式，
## 所以归总则管。**与 TGF-β 的 ×80% 不同口径**：那条卡面明写「向下取整」。
func necrosis_cut(cell: Dictionary, gain: int) -> int:
	if game.tile(cell["pos"])["necrosis"] <= 0:
		return gain
	return CWData.round_tenth(gain * game.tune.necrosis_aerobic_pct, 100)


func _aerobic() -> void:
	var immune: Array = game.living_cells(CWData.Faction.IMMUNE)
	if immune.is_empty():
		return
	var gain := aerobic_share()
	## 【TGF-β释放】：下一次有氧结算每份 -20%（逐份 ×80% 向下取整，定案 #63），
	## 结算完消耗——条目挂在全局容器里，left=2 保证能活到下一个 S 阶段。减免本身已算在 aerobic_share 里
	var tgf := _tgf_stacks()
	if tgf > 0:
		var kept: Array = []
		for e in game.events["active"]:
			if e["name"] != "TGF-β释放":
				kept.append(e)
		game.events["active"] = kept
		game.log_msg("【TGF-β释放】有氧呼吸 %s → %s（%d 份 -20%%，已消耗）" % [
			CWData.fmt(aerobic_share(false)), CWData.fmt(gain), tgf])
	for cell in immune:
		## 【代谢适应】/【自分泌生存信号】的「额外获得」在基准收入之外加，
		## 不吃 TGF-β 的 -20%（那句管的是有氧结算本身的所得，口径 #69）
		var bonus := _aerobic_bonus(cell)
		## 「坏死」：站在坏死格上整份打折（Kevin 2026-09-07 由「一份不给」改成 80%）。
		## **和右栏「预计收入」同一条路**（aerobic_income → necrosis_cut），界面不会和结算对不上
		var got := necrosis_cut(cell, gain + bonus)
		cell["energy"] += got
		if bonus > 0:
			game.log_msg("　%s 的永久技能额外 +%s 能量" % [game.cell_name(cell), CWData.fmt(bonus)])
		if got != gain + bonus:
			game.log_msg("　%s 站在坏死组织上，有氧呼吸打 %d 折后只拿 %s" % [
				game.cell_name(cell), game.tune.necrosis_aerobic_pct / 10, CWData.fmt(got)])
	var hn := _healthy_counts()
	var why := "抗原记忆 %s 级" % CWData.LEVEL_NAMES[game.immune_level] \
		if game.tune.aerobic_level_base != 0 else "健康 %d - 坏死 %d" % [hn.x, hn.y]
	game.log_msg("【有氧呼吸】所有免疫细胞 +%s 能量（%s）" % [CWData.fmt(gain), why])


## 均分：n ≤ ref 每人全额；n > ref 把 ref 份总额均分，四舍五入到十分位（(2p+n)/(2n) 的整数写法，同 _split_share）。
## ref = 0 退化成纯「÷ n」。**纯函数**，测试直接核对。
func _split_aerobic(per_cell: int, n: int) -> int:
	var ref: int = game.tune.aerobic_split_ref
	if n <= 0:
		return per_cell
	if ref <= 0:
		return (2 * per_cell + n) / (2 * n)
	if n <= ref:
		return per_cell
	return (2 * per_cell * ref + n) / (2 * n)


## 一份【有氧呼吸】的基准收入（均分与夹钳在调用处套）。
##
## 现行是等级式：`base + 等级 × step`，与盘面无关 —— 换掉盘面式的理由见 CWData.AEROBIC_LEVEL_BASE。
## `aerobic_level_base <= 0` 退回盘面式，那条**必须逐位不变**，否则 09-04 之前的扫描数据全作废。
func _aerobic_base(healthy: int, necrotic: int) -> int:
	## -1 = 按人数取（四人 2.0 / 六人 1.8）；>0 = 整体覆盖；0 = 退回旧盘面式
	var base: int = game.tune.aerobic_level_base
	if base < 0:
		base = CWData.aerobic_level_base(game.order.size())
	if base > 0:
		## (等级系数 − 1) × step + base（PRD 2026-09-09 云端版，由平方式改回线性）。
		## immune_level 是 0 起，正好就是「等级系数 − 1」：I 0 / II 1 / III 2 / X 3 → 2.0 / 3.5 / 5.0 / 6.5
		return base + game.tune.aerobic_level_step * game.immune_level
	# 四舍五入到十分位（PRD 通用规则 1）；算式只有 CWData.round_tenth 一份
	var num: int = (healthy - necrotic) * game.tune.aerobic_mult_at(game.round_no)
	return CWData.round_tenth(num, CWData.TOTAL_TILES)


# ---- E 阶段 ----

## 【E-侵蚀】：全局掷一次，从所有被完全包围连通块的合法格中随机选（说明 #11）
##
## `fresh` = **本回合【增生】刚造出来的癌组织**。PRD 的「注」：「【增生】与【侵蚀】创造的
## 新癌组织在下一世界回合才能参与结算【增生】与【侵蚀】」。Kevin 2026-09-09 定的读法是
## **只把新格排除在「来源」之外** —— 也就是只影响下面那道「与癌性组织相邻」的判定，
## 「完全包围」仍按**实时盘面**算（新格已经不是健康组织了，连通块的形状本来就变了，不去还原）。
##
## 增生与侵蚀**各自内部**早就是快照式的（先选完再转），这里补的是**两者之间**那一道：
## 从前增生跑在侵蚀之前、侵蚀读转化后的盘面，于是增生这一轮新造的格子当场就能当侵蚀的来源。
func _erosion(fresh: Array[Vector2i] = []) -> void:
	## 转成集合查表：eligible 的内层循环是 O(格数 × 6)，用 Array.has 会退化
	var fresh_set := {}
	for c: Vector2i in fresh:
		fresh_set[c] = true
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
				## 本回合增生刚造的格子不算「来源」——它要到下一世界回合才参与侵蚀结算
				if game.is_cancerous(n) and not fresh_set.has(n):
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
	## 2/3 概率取 x、1/3 概率取 y（PRD 2026-09-07 是 2/3；旋钮 erosion_tiles 可扫回 1/2）
	var count: int = int(game.tune.erosion_tiles.x if game.roll_d3() <= 2 else game.tune.erosion_tiles.y)
	var picked: Array = game.pick_random(eligible, count)
	## 过场方向要在**转化之前**全部算完：同一批里两格相邻时，
	## 先转的那格会变成后转那格的「来源」，方向就不再是「侵蚀从哪来」了。
	var from := {}
	for c: Vector2i in picked:
		from[c] = _erosion_dir(c)
	for c: Vector2i in picked:
		CWTissue.to_cancer(game.tile(c), true)
		game.log_msg("【侵蚀】%s 转为癌组织" % str(c))
		game.erosion_fx(c, int(from[c]))


## 侵蚀 / 增生是从哪一侧漫过来的（过场方向）：`CWData.DIRS` 的下标，取不到癌性邻居返回 -1。
##
## **刻意不掷骰**，哪怕有好几个癌性邻居也只按 DIRS 的固定顺序取第一个：
## 这只是演出用的方向，走 rng 会多消耗随机数，
## 同种子复现和此前所有平衡扫描数据当场作废（口径同 _erosion 里那句「静默掷骰」）。
func _erosion_dir(c: Vector2i) -> int:
	for i in CWData.DIRS.size():
		var n: Vector2i = c + CWData.DIRS[i]
		if CWData.is_on_board(n) and game.is_cancerous(n):
			return i
	return -1


## 【E-增生】癌组织向外扩散：与癌性组织相邻的健康组织按概率被转化（PRD 已入规，概率见 CWTuning）
## 先统一掷骰收集、再统一转化 —— 保证「同时结算」，避免转化顺序影响后续格的相邻数。
## 返回**本回合新造出来的癌组织**，交给 `_erosion()` 当作「这一轮不算来源」的名单（见那边的注释）。
func _proliferate() -> Array[Vector2i]:
	var none: Array[Vector2i] = []
	if game.event_stacks("增殖抑制") > 0:
		game.log_msg("【增殖抑制】本回合组织无法增生")
		return none
	var rate: int = game.tune.proliferate_per_adjacent
	var per_solid: int = game.tune.proliferate_per_solid
	for i in game.event_stacks("异常增殖"):
		rate *= 2        ## 【异常增殖】增生概率翻倍（叠加时按层数连乘）
		per_solid *= 2   ## 两项一起翻，否则事件生效期间反而把固化的加成压扁了
	if rate <= 0 and per_solid <= 0:
		return none
	## PRD 2026-09-08 云端修订版：每个癌性组织的贡献 = 3% + 1% × **它所在连通块里的固化癌组织数**。
	## （此前是「块里有固化 → 一律 4%」，不随固化数增长。）
	##
	## 先把每格所属连通块的固化数一次性算出来 —— 每格各跑一遍洪水填充的话，
	## 一次增生要跑 127 遍。
	var solids_of := {}   ## 癌性格 -> 它那个连通块里的固化数
	if per_solid > 0:
		var cancerous_pred := func(c: Vector2i) -> bool:
			return game.is_cancerous(c)
		for block in game.blocks_of(cancerous_pred):
			var n_solid := 0
			for c: Vector2i in block:
				if game.tiles[c]["tissue"] == CWData.Tissue.SOLID:
					n_solid += 1
			if n_solid > 0:
				for c: Vector2i in block:
					solids_of[c] = n_solid
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
		## 概率是**逐个邻居累加**的（不是「邻居数 × 单一档位」）：
		## 同一格的几个癌性邻居可能分属不同连通块，各自的固化数不一样。
		var chance := 0
		for n in CWData.neighbors(c):
			if game.is_cancerous(n):
				chance += rate + per_solid * int(solids_of.get(n, 0))
		if chance > 0 and game.rng.randi_range(1, 1000) <= chance:
			converts.append(c)
	## 过场方向在转化**之前**取：这一批是同时结算的，先转的格不该成为后转格的「来源」（同 _erosion）
	var from := {}
	for c in converts:
		from[c] = _erosion_dir(c)
	for c in converts:
		CWTissue.to_cancer(game.tile(c), true)
		game.erosion_fx(c, int(from[c]))   ## 过场与【侵蚀】同一套：癌从哪一侧漫过来
	if not converts.is_empty():
		game.log_msg("【增生】%d 格健康组织被癌组织侵占" % converts.size())
	return converts


## 【E-无氧呼吸】：每块供能 = `c × √(块内癌格子数)`，块内癌细胞均分，
## **四舍五入到十分位**（团队 2026-08-28 定案 #43，与有氧一致；PRD 本身没写取整方式）
func _anaerobic() -> void:
	var cancer_pred := func(c: Vector2i) -> bool:
		return game.is_cancerous(c)
	for block in game.blocks_of(cancer_pred):
		var members := {}
		for c in block:
			members[c] = true
		var pool := _anaerobic_pool(block)
		var here: Array = []
		for cell in game.living_cells(CWData.Faction.CANCER):
			if members.has(cell["pos"]):
				here.append(cell)
		if here.is_empty():
			continue
		var gain := _split_share(pool, here.size())
		for cell in here:
			## 小细胞肺癌【瓦伯格超速糖酵解】：110% 原产出，**向上取整到十分位**
			if cell["ctype"] == CWData.CancerType.SCLC and game.type_ability_on(cell):
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
## 一个癌性连通块这一次供多少能（还没按块内癌细胞数均分）。
## E 阶段结算和卡【糖酵解爆发】共用 —— 口径只有这一份。
##
## **为什么从线性改成开方（团队 2026-09-04 定案）。** 旧式是线性求和：
## 块里每格癌组织 +0.4、每格固化 +1.0。分子随占地涨、分母是固定的玩家数，
## 于是「占得越多 → 越有钱 → 占得越快」是个**没有刹车的正反馈**；
## 而免疫旧式【有氧呼吸】= 健康格占比 × 系数，**随健康格下跌**。两条曲线方向相反，拉开就不可逆。
## 2026-09-05 的六人局智能体对局把这条拍实了：癌组织净增 +11/+8/+13/+20/+20，
## 三个癌细胞第 4~5 回合就顶到 15 能量上限**溢出浪费**，而免疫有氧从 2.9 掉到 1.6。
##
## 开方之后前期几乎不变、后期腰斩：24 格时 √24×2.0 ≈ 9.8（线性 9.6），
## 97 格时 √97×2.0 ≈ 19.7（线性 40.6 起）。换句话说**不动开局手感，只砍雪球**。
##
## ⚠ **固化格不再有双倍权重**：新公式只数格子（团队定的口径就是「连通块癌格子数」）。
## 固化的价值因此完全落在「不能被【净化】」上，不再兼带供能加成。
##
## **2026-09-07 Kevin 换成**：`块内普通癌组织数^0.3 × 2 + 全图固化数 × 1.0`（分母在 _split_share 里）。
## 两处要看清：① 指数项的底数**只数普通癌组织**，块里的固化不算进去；
## ② 固化按**全图**计数、线性加 —— 固化的价值从「给本块供能」变成「给全场供能」，
##    所以每个癌细胞的这一项都一样，谁的块小谁摊得多。
## `anaerobic_block_coef = 0` 退回 09-04 之前的线性求和，供对照档使用。
## 返回**十分能量的浮点数**（不在这里取整）：四舍五入只做一次，在 _split_share 里除完再做。
func _anaerobic_pool(block: Array) -> float:
	## -1 = 按人数取（四人 2.0 / 六人 2.8）；>0 = 整体覆盖；0 = 退回线性式
	var coef: int = game.tune.anaerobic_block_coef
	if coef < 0:
		coef = CWData.anaerobic_block_coef(game.order.size())
	if coef > 0:
		var plain := 0
		for c in block:
			if game.tiles[c]["tissue"] == CWData.Tissue.CANCER:
				plain += 1
		var solid: int = game.count_tissue(CWData.Tissue.SOLID)
		var exp_term := pow(float(plain), game.tune.anaerobic_block_exp / 100.0) if plain > 0 else 0.0
		return exp_term * float(coef) + float(solid * game.tune.anaerobic_solid_bonus)
	var pool := 0.0
	for c in block:
		pool += game.tune.anaerobic_per_solid \
			if game.tiles[c]["tissue"] == CWData.Tissue.SOLID \
			else game.tune.anaerobic_per_cancer
	return pool


## 池子按块内癌细胞数均分。**四舍五入只在这里做一次**（池子是浮点，见 _anaerobic_pool）：
## 先取整再除会取整两次，和 PRD 的「四舍五入到十分位」对不上。
func _split_share(pool: float, count: int) -> int:
	var gain: int = int(round(pool / float(count))) if game.tune.anaerobic_split else int(round(pool))
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


## 【E-无氧呼吸】改在**这个癌细胞自己的行动回合末**结算（旋钮 anaerobic_on_turn_end：2026-09-05 默认开，
## **2026-09-06 Kevin 改回 E 阶段统一结算、默认关**；这条路留作 `eturn=1` 对照档）。
## 口径就是 anaerobic_gain_for —— 它本来就是「某个癌细胞此刻的份额」（含瓦伯格与 GLUT1）。
## 分母 = 此刻块里有几个癌细胞：后面的人再挤进来也抬不了你的分母，这正是要修的那条不公平。
func settle_anaerobic_turn(cell: Dictionary) -> void:
	var gain := anaerobic_gain_for(cell)
	if gain <= 0:
		return
	cell["energy"] += gain
	game.log_msg("【无氧呼吸】%s 回合末 +%s 能量（现 %s）" % [
		game.cell_name(cell), CWData.fmt(gain), CWData.fmt(cell["energy"])])


## 骨肉瘤【骨样硬化】的标记到期：转为固化癌组织。
## **走 CWTissue.to_solid，不碰固化计数、阈值与【固化加速】那套** —— 这是另一条独立的路。
## 标记期间格子被净化过（tissue 已不是癌组织）就作废。tiles 按插入序遍历，不掷骰。
func _ossify() -> void:
	for c in game.tiles.keys():
		var t: Dictionary = game.tiles[c]
		var at: int = int(t.get("ossify_at", 0))
		if at <= 0 or game.round_no < at:
			continue
		if t["tissue"] != CWData.Tissue.CANCER:
			t["ossify_at"] = 0
			continue
		CWTissue.to_solid(t)
		game.log_msg("【骨样硬化】%s 转为固化癌组织" % str(c))


## 免疫细胞踏进【骨样硬化】标记格时不能立刻净化，得**在那儿站到世界回合结束**——
## 还站在原格、格子还是癌组织，就在这里把净化补上。
## 挪过窝（camp_pos 对不上）、或格子已经固化 / 被别人净化，标记就作废。
##
## 时机：2026-09-07 从「下一回合 S 阶段」挪到**本回合 E 阶段**（线上版 PRD 明写
## 「须停留在该格，世界回合结束时完成【净化】」）—— 蹲的是半个回合而不是一整轮，对免疫是利好。
## 排在 _ossify 之前：两边可能同一个 E 阶段到期，而 PRD 另有一句「标记期间该格被净化…标记作废」，
## 所以净化优先。
func _resolve_camping() -> void:
	for cell in game.living_cells(CWData.Faction.IMMUNE):
		if int(cell.get("camp_round", -1)) < 0:
			continue
		var at: Vector2i = cell["camp_pos"]
		cell["camp_round"] = -1
		if cell["pos"] != at or game.tile(at)["tissue"] != CWData.Tissue.CANCER:
			continue
		game.log_msg("　【骨样硬化】%s 在 %s 停留了一回合，完成【净化】" % [game.cell_name(cell), str(at)])
		await game.actions.purify_here(cell, at, -1)


## 树突【E-组织黏连】：被标记的癌细胞把标记传染给相邻 `CWData.ADHESION_RANGE` 格内的所有癌细胞。
##
## **本阶段造成的感染不会连锁**（PRD 明文）：所以先把「进入本阶段时就带标记的」抄一份，
## 再照着这份传染 —— 边传边读活数据的话，一条癌组织长链会被一次结算全部点亮。
## 传染同样走 `apply_mark`，因此照样受「同一回合只能获得一次标记」约束（PRD 上一条）。
## 场上没有活着的树突就不发生：这是树突的被动，人没了效果也没了（同 update_marks 的口径）。
func _mark_adhesion() -> void:
	var dendritic: Dictionary = {}
	for ic in game.living_cells(CWData.Faction.IMMUNE):
		if ic["itype"] == CWData.ImmuneType.DENDRITIC:
			dendritic = ic
			break
	if dendritic.is_empty():
		return
	var carriers: Array = []
	for c in game.living_cells(CWData.Faction.CANCER):
		if c["marked"]:
			carriers.append(c)
	if carriers.is_empty():
		return
	for target in game.living_cells(CWData.Faction.CANCER):
		if target["marked"]:
			continue
		for src in carriers:
			if CWData.hex_dist(target["pos"], src["pos"]) <= CWData.ADHESION_RANGE:
				game.apply_mark(target, dendritic)
				if target["marked"]:
					game.log_msg("　【组织黏连】%s 的标记传染给 %s"
						% [game.cell_name(src), game.cell_name(target)])
				break


## 【追踪趋化源】倒计时（与普通趋化源同一步）。
func _tick_chemo_track() -> void:
	if game.chemo_track.is_empty():
		return
	game.chemo_track["left"] = int(game.chemo_track["left"]) - 1
	if game.chemo_track["left"] > 0:
		return
	game.log_msg("【追踪趋化源】%s 的追踪趋化源消散" % str(game.chemo_track_at()))
	game.chemo_track = {}


## 单独算某个癌细胞**此刻**的无氧供给（卡【糖酵解爆发】用），口径与 _anaerobic 一致
func anaerobic_gain_for(target: Dictionary) -> int:
	var cancer_pred := func(c: Vector2i) -> bool:
		return game.is_cancerous(c)
	for block in game.blocks_of(cancer_pred):
		var members := {}
		for c in block:
			members[c] = true
		if not members.has(target["pos"]):
			continue
		var pool := _anaerobic_pool(block)
		var count := 0
		for cell in game.living_cells(CWData.Faction.CANCER):
			if members.has(cell["pos"]):
				count += 1
		var gain := _split_share(pool, maxi(count, 1))
		## 小细胞肺癌【瓦伯格超速糖酵解】对这次结算同样生效
		if target["ctype"] == CWData.CancerType.SCLC and game.type_ability_on(target):
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
## 每回合停留加多少。骨肉瘤旧版的 +1.5 已撤（2026-09-05）：阈值 2.0 之下 +1.0 与 +1.5
## 都是蹲 2 回合，一回合没省 —— 它的【骨样硬化】重做成了主动技能，见 _ossify()。
func _solidify_step(_c: Vector2i) -> int:
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


## 【E-微环境压迫】：每个免疫细胞受相邻组织的压迫，
## 损失 = max(0, 1/4 × (相邻癌组织 + 相邻固化癌组织 × 2 − 相邻健康组织))（PRD 2026-09-08）。
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
	## 只读 `tissue` 一个字段：坏死是叠在健康组织上的计数，Kevin 2026-09-08 确认坏死格照算健康
	## （所以这里**不能**图省事改用 is_cancerous —— 那会把健康组织的抵消项整个丢掉）。
	## `neighbors()` 已经裁掉出界方向，棋盘边缘的细胞天然少几个邻居，不必特判。
	var raw := 0
	for nb in CWData.neighbors(c):
		match int(game.tiles[nb]["tissue"]):
			CWData.Tissue.CANCER:
				raw += CWData.PRESSURE_CANCER_W
			CWData.Tissue.SOLID:
				raw += CWData.PRESSURE_SOLID_W
			CWData.Tissue.HEALTHY:
				raw += CWData.PRESSURE_HEALTHY_W
	## ×1/4 不是整数格（能量单位是十分之一），按 PRD 通用规则 1 四舍五入到十分位
	return CWData.round_tenth(maxi(raw, 0) * CWData.PRESSURE_MUL, CWData.PRESSURE_DIV)


## 回合末的【微环境压迫】会不会把这只细胞压死。**界面预警用**（Kevin 2026-09-08）。
##
## **不能拿 `energy < pressure_at()` 糊弄**：压迫走的是完整的伤害管线，
## 【缺氧适应】那面 −1.0 的盾、TGF-β 之类的减免都在里面。少算一层就会对着
## 一只死不了的细胞报警 —— 误报的预警比没有预警更糟。
##
## 判的是 `>=` 不是 `>`：结算把能量减到 **0 就算死**（`_resolve_deaths`），
## 不用减成负数。
func pressure_lethal(cell: Dictionary) -> bool:
	if not cell["alive"] or cell["faction"] != CWData.Faction.IMMUNE:
		return false        ## 压迫只落在免疫细胞身上
	var raw := pressure_at(cell["pos"])
	if raw <= 0:
		return false
	var loss: int = game.damage.preview_amount(cell, raw, CWDamage.Kind.WORLD,
		[CWDamage.Tag.CANCER], "微环境压迫")
	return loss >= cell["energy"]


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
