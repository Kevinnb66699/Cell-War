## cw_world_fx.gd —— 世界事件：抽取与结算 + 持续效果的修饰器容器
##
## 触发回合见 CWData.is_world_event_round（3/6/10/15/20/25/30 世界回合）。
## 抽取按团队定案 #42：**等权随机、同局不可重复** —— game.events["pool"] 抽一个少一个。
##
## 修饰器容器 = game.events["active"]，条目 {name, left, stacks, data}：
##   - left   还能存活的世界回合数（含本回合）。回合末 −1，归零移除。
##            「本回合」类事件也占条目（left=1），查询口径统一。
##   - stacks 叠加层数。正常 1；【双重触发】加倍下一个事件时按**三档**（定案 #49 修订版）：
##            持续·数量类 stacks=2（强度×2）；持续·开关类 left=4（一份强度接力 2+2）；
##            本回合类 left=2（连续两个回合各完整生效一遍，见 on_round_start 的重演）。
##   - data   事件私有簿记（紊乱=原位 / 营养输送=已领 / 迁移激活=已用），
##            键一律用 cell["id"]，随快照深拷贝、进 state_hash。
##
## 各结算点读事件一律走 game.event_stacks(名字)。**卡牌的修饰效果（对照 5.1 #26）
## 将来也往 active 里塞条目即可复用全部挂接点** —— 这是先做世界事件的原因。
## 事件可以共存：第 3 回合起手、被【双重触发】拉到 4 回合的事件会撞上第 6 回合的
## 新事件——容器是列表、各结算点独立查询，共存与叠加天然支持（#26 的卡牌修饰同理）。
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
## 细胞毒/免疫伪装/迁移激活是纯开关，叠两次开不出第二份 → 一份强度接力持续 4 回合。
const STACKABLE := {
	"营养输送": true, "异常增殖": true, "代谢加速": true, "抗原变异": true,
	"抗原暴露": true, "基质阻隔": true, "信号放大": true,
}


## 每个世界回合开头都调（不限触发回合）：清理按回合刷新的簿记，
## 并让被【双重触发】加倍的本回合类事件在第二个回合完整重演一遍
func on_round_start() -> void:
	for e in game.events["active"]:
		if e["name"] == "迁移激活":
			e["data"].clear()   ## 「回合开始时，首次移动费用为 0」——每回合重置
		elif not DURATION.has(e["name"]):
			## 本回合类事件只有被【双重触发】加倍（left=2）才能活过回合末——
			## 开关半句继续挂着，失去/弃牌/清空/传送这类一次性部分再来一遍
			game.log_msg("【双重触发】【%s】第二回合再次生效" % e["name"])
			_resolve(e)


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
		if not DURATION.has(name):
			left = 2   ## 本回合类：连续两个回合各完整生效一遍
			game.log_msg("【双重触发】【%s】连续两个回合各完整生效一遍" % name)
		elif STACKABLE.has(name):
			stacks = 2
			game.log_msg("【双重触发】【%s】两份同时生效（数值翻倍）" % name)
		else:
			left = 4   ## 开关类：一份强度接力 2+2 回合
			game.log_msg("【双重触发】【%s】改为持续 4 回合" % name)
	var entry := { "name": name, "left": left, "stacks": stacks, "data": {} }
	## 【双重触发】的效果全在 double_next 标记里，挂进 active 反而会在回合末
	## 打出一句误导人的「效果结束」——它不挂，其余事件（含「本回合」类）都挂
	if name != "双重触发":
		game.events["active"].append(entry)
	game.log_msg("【世界事件】抽到【%s】%s" % [
		name, "（持续 %d 回合）" % left if left > 1 else ""])
	_resolve(entry)


## 回合末：紊乱先做本回合的返回（每个回合都是一个完整的传送-返回周期），
## 然后统一倒计时并移除到期事件
func round_end() -> void:
	var kept: Array = []
	for e in game.events["active"]:
		if e["name"] == "紊乱":
			_chaos_return(e)
			e["data"].clear()   ## 下一回合（若被加倍）重新记原位
		e["left"] -= 1
		if e["left"] > 0:
			kept.append(e)
			continue
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
## 定案 W2：落地算「进入」（走 enter_tile）；目的地不选血管格（已进 PRD）。
## 原位记在 entry["data"]，回合末 _chaos_return 返回后清空（每回合一个完整周期）。
func _chaos(entry: Dictionary) -> void:
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
		entry["data"][cell["id"]] = cell["pos"]
		var dest: Vector2i = dests[game.rng.randi_range(0, dests.size() - 1)]
		game.log_msg("【紊乱】%s 传送至 %s" % [game.cell_name(cell), str(dest)])
		game.actions.enter_tile(cell, dest)


## 回合末返回原位——团队定案（2026-08-29）**方案A「同时返回」**：
## 所有返回视为同时发生，先算清每个人的落点、再统一归位。返回者的原位互不相同，
## 因此**互不阻挡**；真挡得住人的只有回合中途复活/移动上来的未传送细胞。
## 死亡不返回；主动移动过的照样返回；原位组织已变按正常「进入」结算
## （免疫触发【净化】、癌症触发【定殖】——PRD 紊乱条目明写）。
## 原位被真占则留在传送后的位置；连它也被别的返回者归位占掉（连环挤占的极端情形）
## 才随机找一个合法空位落脚。
func _chaos_return(entry: Dictionary) -> void:
	var returners: Array = []
	var returning_ids := {}
	for cell in game.cells:
		if entry["data"].has(cell["id"]) and cell["alive"]:
			returners.append(cell)
			returning_ids[cell["id"]] = true
	if returners.is_empty():
		return
	## 占位表从「不返回的细胞」起算；返回者只和已落定的结果比
	var taken := {}
	for cell in game.living_cells():
		if not returning_ids.has(cell["id"]):
			taken[cell["pos"]] = true
	## 第一遍：纯计算落点（原位 → 留在原地 → 随机合法空位），谁也不真动
	var dest_of := {}
	for cell in returners:
		var origin: Vector2i = entry["data"][cell["id"]]
		var pick: Vector2i
		if cell["pos"] == origin or not taken.has(origin):
			pick = origin
		elif not taken.has(cell["pos"]):
			pick = cell["pos"]
			game.log_msg("【紊乱】%s 的原位 %s 已被占据，无法返回" % [
				game.cell_name(cell), str(origin)])
		else:
			pick = _chaos_fallback(cell, taken)
			game.log_msg("【紊乱】%s 的原位与当前位置都被占，落脚 %s" % [
				game.cell_name(cell), str(pick)])
		taken[pick] = true
		dest_of[cell["id"]] = pick
	## 第二遍：先把位置全部放定（棋盘瞬间回到一格一细胞），再逐个补「进入」结算
	var moved: Array = []
	for cell in returners:
		if cell["pos"] != dest_of[cell["id"]]:
			moved.append(cell)
			cell["pos"] = dest_of[cell["id"]]
	for cell in moved:
		var dest: Vector2i = dest_of[cell["id"]]
		if dest == entry["data"][cell["id"]]:
			game.log_msg("【紊乱】%s 返回原位 %s" % [game.cell_name(cell), str(dest)])
		game.actions.enter_tile(cell, dest)


## 连环挤占时的落脚点：与传送同一套合法目的地（己方组织、非血管），
## 再排除本轮已被占/被认领的格。找不到就留在原地（双占也认了——127 格实际到不了）。
func _chaos_fallback(cell: Dictionary, taken: Dictionary) -> Vector2i:
	var cands: Array = []
	for c in game.tiles.keys():
		var t: Dictionary = game.tiles[c]
		if t["special"] == CWData.Special.VESSEL or taken.has(c):
			continue
		if cell["faction"] == CWData.Faction.IMMUNE:
			if t["tissue"] != CWData.Tissue.HEALTHY:
				continue
		elif not game.is_cancerous(c):
			continue
		cands.append(c)
	if cands.is_empty():
		return cell["pos"]
	cands.sort()
	return cands[game.rng.randi_range(0, cands.size() - 1)]


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
