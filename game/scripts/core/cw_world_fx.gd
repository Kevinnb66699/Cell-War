## cw_world_fx.gd —— 世界事件：抽取与结算 + 持续效果的修饰器容器
##
## 触发回合见 CWData.is_world_event_round（3/6/10/15/20/25/30 世界回合）。
## 抽取按团队定案 #42：**等权随机、同局不可重复** —— game.events["pool"] 抽一个少一个。
##
## 修饰器容器 = game.events["active"]，条目 {name, left, stacks, data}：
##   - left   还能存活的世界回合数（含本回合）。回合末 −1，归零移除。
##            「本回合」类事件也占条目（left=1），查询口径统一。
##   - stacks 叠加层数。正常 1；【双重触发】使下一个事件加倍：可叠事件 stacks=2，
##            纯开关类叠不出第二份 → left 改 3（定案 W7，可叠清单见 STACKABLE）。
##   - data   事件私有簿记（紊乱=原位 / 营养输送=已领 / 迁移激活=已用），
##            键一律用 cell["id"]，随快照深拷贝、进 state_hash。
##
## 各结算点读事件一律走 game.event_stacks(名字)。**卡牌的修饰效果（对照 5.1 #26）
## 将来也往 active 里塞条目即可复用全部挂接点** —— 这是先做世界事件的原因。
## 当前世界事件之间永不同场（触发间隔 ≥3 > 最长持续 3），叠加语义是给 #26 预留的。
##
## 所有事件都无需玩家决策：整个模块同步结算，不碰流程状态机。
class_name CWWorldFx
extends RefCounted

var game: CWGame

## 18 个事件，按 PRD「世界事件」节的出场顺序
const EVENTS: Array = [
	"营养输送", "异常增殖", "代谢加速", "紊乱", "细胞毒", "免疫伪装",
	"抗原变异", "抗原丢失", "抗原暴露", "固化加速", "增殖抑制", "免疫抑制因子",
	"营养缺乏", "双重触发", "细胞应激", "基质阻隔", "迁移激活", "信号放大",
]

## 持续 2 回合的事件；其余为「本回合」（回合末撤销）
const DURATION := {
	"营养输送": true, "异常增殖": true, "代谢加速": true, "细胞毒": true,
	"免疫伪装": true, "抗原变异": true, "抗原暴露": true, "基质阻隔": true,
	"迁移激活": true, "信号放大": true,
}

## 【双重触发】下「可叠两次」的持续事件（数值类，效果按 stacks 倍乘/倍发）。
## 细胞毒/免疫伪装/迁移激活是纯开关，叠两次无第二份效果 → 改为持续 3 回合（定案 W7）。
const STACKABLE := {
	"营养输送": true, "异常增殖": true, "代谢加速": true, "抗原变异": true,
	"抗原暴露": true, "基质阻隔": true, "信号放大": true,
}


## 每个世界回合开头都调（不限触发回合）：清理按回合刷新的簿记
func on_round_start() -> void:
	for e in game.events["active"]:
		if e["name"] == "迁移激活":
			e["data"].clear()   ## 「回合开始时，首次移动费用为 0」——每回合重置


## 触发回合：抽一个事件并结算。由 CWWorld.round_start 调用，位于特殊组织产出之前。
func trigger() -> void:
	var pool: Array = game.events["pool"]
	if pool.is_empty():
		game.log_msg("【世界事件】事件池已空，本回合无事件")   # 18 事件 7 次触发，正常到不了
		return
	var name: String = pool.pop_at(game.rng.randi_range(0, pool.size() - 1))
	var stacks := 1
	var left: int = 2 if DURATION.has(name) else 1
	if game.events["double_next"]:
		game.events["double_next"] = false
		if DURATION.has(name) and not STACKABLE.has(name):
			left = 3
			game.log_msg("【双重触发】【%s】无法叠加 → 改为持续 3 回合" % name)
		else:
			stacks = 2
			game.log_msg("【双重触发】【%s】触发两次" % name)
	var entry := { "name": name, "left": left, "stacks": stacks, "data": {} }
	## 【双重触发】的效果全在 double_next 标记里，挂进 active 反而会在回合末
	## 打出一句误导人的「效果结束」——它不挂，其余事件（含「本回合」类）都挂
	if name != "双重触发":
		game.events["active"].append(entry)
	game.log_msg("【世界事件】抽到【%s】%s" % [
		name, "（持续 %d 回合）" % left if left > 1 else ""])
	_resolve(entry)


## 回合末：先做到期事件的收尾（紊乱返回），再倒计时并移除
func round_end() -> void:
	var kept: Array = []
	for e in game.events["active"]:
		e["left"] -= 1
		if e["left"] > 0:
			kept.append(e)
			continue
		if e["name"] == "紊乱":
			_chaos_return(e)
		game.log_msg("【世界事件】【%s】效果结束" % e["name"])
	game.events["active"] = kept


## 一次性部分的结算。持续类事件大多只是挂上（各结算点自己查 event_stacks）。
func _resolve(entry: Dictionary) -> void:
	var stacks: int = entry["stacks"]
	match entry["name"]:
		"紊乱":
			_chaos(entry)
		"增殖抑制":
			## 「无法增生」是持续查询（CWWorld._proliferate）；失去/弃牌逐份结算
			for i in stacks:
				for c in game.living_cells(CWData.Faction.IMMUNE):
					game.cancer_hit(c, 5, "增殖抑制")
				for c in game.living_cells(CWData.Faction.CANCER):
					_discard_random(c)
		"免疫抑制因子":
			## 净化加价与不给记忆是持续查询（enter_tile / lyse）；这里只做一次性部分
			for i in stacks:
				for c in game.living_cells(CWData.Faction.CANCER):
					game.cancer_hit(c, 5, "免疫抑制因子")
				for c in game.living_cells(CWData.Faction.IMMUNE):
					_discard_random(c)
		"营养缺乏":
			## 清空；「本回合不产出」由 CWWorld._tissue_production 查询后跳过
			for c in game.tiles.keys():
				var t: Dictionary = game.tiles[c]
				if t["special"] == CWData.Special.CORE or t["special"] == CWData.Special.MARROW:
					t["store"] = 0
					t["cards"] = 0
			game.log_msg("【营养缺乏】代谢核心与骨髓清空，本回合不产出")
		"双重触发":
			game.events["double_next"] = true
			game.log_msg("【双重触发】下一个世界事件将触发两次（若可能）")
		_:
			pass   ## 其余事件只是挂上，效果在各结算点生效


## 【紊乱】所有细胞随机传送至各自阵营组织内的随机位置。
## 定案 W2：落地算「进入」（走 enter_tile）；目的地不选血管格。
## 原位记在 entry["data"]，回合末 _chaos_return 返回。
func _chaos(entry: Dictionary) -> void:
	for i in entry["stacks"]:
		for cell in game.living_cells():
			var dests: Array = []
			for c in game.tiles.keys():
				var t: Dictionary = game.tiles[c]
				if t["special"] == CWData.Special.VESSEL:
					continue   ## 不选血管格：避免紧接着又被血管传送（定案 W2）
				if cell["faction"] == CWData.Faction.IMMUNE:
					if t["tissue"] != CWData.Tissue.HEALTHY:
						continue
				elif not game.is_cancerous(c):
					continue
				if not game.cells_at(c).is_empty():
					continue
				dests.append(c)
			if dests.is_empty():
				game.log_msg("【紊乱】%s 无可传送的己方组织，留在原地" % game.cell_name(cell))
				continue
			dests.sort()   ## 固定候选顺序，保证同种子可复现
			if not entry["data"].has(cell["id"]):
				entry["data"][cell["id"]] = cell["pos"]
			var dest: Vector2i = dests[game.rng.randi_range(0, dests.size() - 1)]
			game.log_msg("【紊乱】%s 传送至 %s" % [game.cell_name(cell), str(dest)])
			game.actions.enter_tile(cell, dest)


## 回合末返回原位。W2③ 尚未定案的部分按保守假设：死亡不返回；原位被占则留在原地；
## 原位组织已变时按正常「进入」结算（净化/定殖照常触发）。
func _chaos_return(entry: Dictionary) -> void:
	for cell in game.cells:
		if not entry["data"].has(cell["id"]) or not cell["alive"]:
			continue
		var origin: Vector2i = entry["data"][cell["id"]]
		if cell["pos"] == origin:
			continue
		if not game.cells_at(origin).is_empty():
			game.log_msg("【紊乱】%s 的原位 %s 已被占据，无法返回" % [
				game.cell_name(cell), str(origin)])
			continue
		game.log_msg("【紊乱】%s 返回原位 %s" % [game.cell_name(cell), str(origin)])
		game.actions.enter_tile(cell, origin)


## 【营养输送】的血管奖励：2 回合内每个细胞**首次**通过血管 +2.0 能量、抽 1 张
## （按 stacks 倍发）。由 CWWorld._vessel_teleport 在每次传送落地后调用。
func on_vessel_pass(cell: Dictionary) -> void:
	for e in game.events["active"]:
		if e["name"] != "营养输送":
			continue
		if e["data"].has(cell["id"]):
			return
		e["data"][cell["id"]] = true
		cell["energy"] += 20 * e["stacks"]
		game.log_msg("【营养输送】%s 首次通过血管 +%s 能量" % [
			game.cell_name(cell), CWData.fmt(20 * e["stacks"])])
		for i in e["stacks"]:
			game.cards.draw(cell, "营养输送")
		return


## 【迁移激活】：这个免疫细胞本回合的免费首移还没用掉？（CWActions 定价用）
func free_move_available(cell: Dictionary) -> bool:
	if cell["faction"] != CWData.Faction.IMMUNE:
		return false
	for e in game.events["active"]:
		if e["name"] == "迁移激活":
			return not e["data"].has(cell["id"])
	return false


## 移动执行时消耗免费首移。不管这一步实际付了多少：「首次移动」就是首次移动。
func consume_free_move(cell: Dictionary) -> void:
	if cell["faction"] != CWData.Faction.IMMUNE:
		return
	for e in game.events["active"]:
		if e["name"] == "迁移激活" and not e["data"].has(cell["id"]):
			e["data"][cell["id"]] = true
			return


## 事件的「弃 1 张牌」：随机弃（定案 W6，走 game.rng）。空手牌静默跳过。
func _discard_random(cell: Dictionary) -> void:
	if cell["hand"].is_empty():
		return
	var card: String = cell["hand"][game.rng.randi_range(0, cell["hand"].size() - 1)]
	cell["hand"].erase(card)
	game.log_msg("　%s 随机弃置【%s】（手牌余 %d）" % [
		game.cell_name(cell), card, cell["hand"].size()])
