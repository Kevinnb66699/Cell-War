## cw_game.gd —— 对局状态 + 通用工具 + 主循环 + 胜负判定
##
## 流程逻辑拆分在 cw_setup / cw_world / cw_turn / cw_actions / cw_cards，
## 各模块持 game 强引用互调；对局结束后必须调 game.dispose() 断开循环引用。
## 所有随机数必须走 game.rng（确定性回放/联机的前提，测试会抓违规）。
class_name CWGame
extends RefCounted

signal log_line(text: String)

# ---- 状态 ----
var tiles := {}            # Vector2i -> 组织格字典（见 cw_setup._make_tile）
var cells: Array = []      # 细胞字典数组，含死亡细胞（alive=false）
var players: Array = []    # {id, name, faction, cell_id}
var order: Array = []      # 行动顺序（player id 列表）
var round_no := 1          # 当前世界回合（从 1 起）
var memory := 0            # 免疫方抗原记忆（阵营共享）
var immune_level := 0      # 0..3 = I/II/III/X，只升不降
var differentiated: Array = []   # 已被分化占用的免疫种类（每种全阵营限一个）
var winner := -1           # -1 未分胜负；否则 CWData.Faction
var win_reason := ""
var win_kind := ""         # immune_clear / cancer_weighted / limit_cancer / limit_immune（统计用）
var rng := RandomNumberGenerator.new()
var bridges := {}          # player_id -> CWBridge
var logs: PackedStringArray = []
var tune := CWTuning.new() # 平衡旋钮；默认即规则原文，init() 之前可整体替换

# ---- 模块 ----
var setup: CWSetup
var world: CWWorld
var turn: CWTurn
var actions: CWActions
var cards: CWCards


## faction_list：按行动顺序排列的阵营数组（如 CWData.FACTION_ORDER[4]）
func init(faction_list: Array, seed_value: int) -> void:
	rng.seed = seed_value
	setup = CWSetup.new()
	world = CWWorld.new()
	turn = CWTurn.new()
	actions = CWActions.new()
	cards = CWCards.new()
	for m in [setup, world, turn, actions, cards]:
		m.game = self
	var immune_i := 0
	var cancer_i := 0
	for i in faction_list.size():
		var f: int = faction_list[i]
		var seq := ""
		if f == CWData.Faction.IMMUNE:
			seq = char(65 + immune_i)  # A/B/C
			immune_i += 1
		else:
			seq = char(65 + cancer_i)
			cancer_i += 1
		var pname := ("免疫" if f == CWData.Faction.IMMUNE else "癌症") + seq
		players.append({ "id": i, "name": pname, "faction": f, "cell_id": i })
		order.append(i)


## 跑完整局，返回胜方阵营。调用方负责在之后 dispose()。
func run_game() -> int:
	await setup.run()
	while winner < 0:
		await world.s_phase()
		if winner >= 0:
			break
		await turn.run_all()
		if winner >= 0:
			break
		world.e_phase()
		if winner >= 0:
			break
		round_no += 1
	log_msg("=== 对局结束：%s ===" % win_reason)
	return winner


func dispose() -> void:
	for m in [setup, world, turn, actions, cards]:
		if m != null:
			m.game = null
	setup = null
	world = null
	turn = null
	actions = null
	cards = null
	for b in bridges.values():
		b.game = null
	bridges.clear()


# ---- 询问桥（引擎↔玩家的唯一交互通道）----
## req = {kind, prompt, options:[{label, data}]}，返回所选下标（已钳位）。
func ask(pid: int, req: Dictionary) -> int:
	req["pid"] = pid
	var b: CWBridge = bridges.get(pid)
	var idx := 0
	if b != null:
		idx = await b.ask(req)
	return clampi(idx, 0, req["options"].size() - 1)


# ---- 查询工具 ----
func tile(c: Vector2i) -> Dictionary:
	return tiles[c]


func player(pid: int) -> Dictionary:
	return players[pid]


func cell_of(pid: int) -> Dictionary:
	return cells[players[pid]["cell_id"]]


func living_cells(faction: int = -1) -> Array:
	var out: Array = []
	for c in cells:
		if c["alive"] and (faction < 0 or c["faction"] == faction):
			out.append(c)
	return out


func cells_at(pos: Vector2i, faction: int = -1) -> Array:
	var out: Array = []
	for c in cells:
		if c["alive"] and c["pos"] == pos and (faction < 0 or c["faction"] == faction):
			out.append(c)
	return out


func is_cancerous(c: Vector2i) -> bool:
	var t: int = tiles[c]["tissue"]
	return t == CWData.Tissue.CANCER or t == CWData.Tissue.SOLID


func count_tissue(tissue: int) -> int:
	var n := 0
	for t in tiles.values():
		if t["tissue"] == tissue:
			n += 1
	return n


## 组织连通块：返回 Array[Array[Vector2i]]，pred 决定哪些格属于同类
func blocks_of(pred: Callable) -> Array:
	var seen := {}
	var out: Array = []
	for c in tiles.keys():
		if seen.has(c) or not pred.call(c):
			continue
		var block: Array[Vector2i] = []
		var queue: Array[Vector2i] = [c]
		seen[c] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			block.append(cur)
			for n in CWData.neighbors(cur):
				if not seen.has(n) and pred.call(n):
					seen[n] = true
					queue.append(n)
		out.append(block)
	return out


# ---- 随机 ----
func roll_d6() -> int:
	return rng.randi_range(1, 6)


func roll_d3() -> int:
	return rng.randi_range(1, 3)


## 从数组中均匀随机取 n 个（不重复）
func pick_random(arr: Array, n: int) -> Array:
	var pool := arr.duplicate()
	var out: Array = []
	while out.size() < n and not pool.is_empty():
		out.append(pool.pop_at(rng.randi_range(0, pool.size() - 1)))
	return out


# ---- 能量 / 伤害 / 死亡 ----
## 支付技能费用：不能使能量降至 0（规则总则），失败返回 false
func pay(cell: Dictionary, cost: int) -> bool:
	if cell["energy"] <= cost:
		return false
	cell["energy"] -= cost
	return true


func can_pay(cell: Dictionary, cost: int) -> bool:
	return cell["energy"] > cost


## 免疫来源的能量损失结算（攻击/抗体共用）：
## 顺序 = 基础 → 标记×2（消耗）→ 免疫逃逸-0.5（每世界回合一次）（说明 #19）
func immune_hit(target: Dictionary, base: int, attacker: Dictionary) -> int:
	var dmg := base
	if target["marked"]:
		dmg *= 2
		target["marked"] = false
		log_msg("　【标记】生效，伤害翻倍")
	if target["ctype"] == CWData.CancerType.ESCAPE and not target["escape_used"]:
		dmg = maxi(dmg - CWData.ESCAPE_REDUCTION, 0)
		target["escape_used"] = true
		log_msg("　【免疫逃逸】减免 0.5")
	target["energy"] -= dmg
	log_msg("　%s 损失 %s 能量（余 %s）" % [
		cell_name(target), CWData.fmt(dmg), CWData.fmt(maxi(target["energy"], 0))])
	if attacker["faction"] == CWData.Faction.IMMUNE \
			and attacker["itype"] == CWData.ImmuneType.MACRO and dmg > 0:
		attacker["energy"] += CWData.MACRO_HEAL_ATTACK
		log_msg("　巨噬【吞噬】恢复 0.5 能量")
	if target["energy"] <= 0:
		kill(target)
	update_marks()
	return dmg


func kill(cell: Dictionary) -> void:
	cell["energy"] = 0
	cell["alive"] = false
	if cell["faction"] == CWData.Faction.CANCER:
		log_msg("☠ %s 死亡" % cell_name(cell))
		check_immune_win()
		return
	# 免疫细胞：罚停若干回合后在随机健康组织复活（2026-08-26 团队定案）
	# 死于第 N 回合 → 缺席第 N+1 回合 → 第 N+2 回合开局复活（delay=1 时）
	var delay: int = tune.immune_respawn_delay
	if delay < 0:
		cell["respawn_round"] = -1
		log_msg("☠ %s 死亡（不再复活）" % cell_name(cell))
		return
	cell["respawn_round"] = round_no + 1 + delay
	log_msg("☠ %s 死亡，罚停至第 %d 世界回合" % [cell_name(cell), cell["respawn_round"]])


# ---- 抗原记忆 / 免疫等级 ----
func gain_memory(n: int) -> void:
	memory += n
	var lv := immune_level
	while lv < 3 and memory >= CWData.LEVEL_MIN_MEMORY[lv + 1]:
		lv += 1
	if lv > immune_level:
		immune_level = lv
		log_msg("★ 免疫等级升至 %s 级" % CWData.LEVEL_NAMES[lv])


func reduce_memory(n: int) -> void:
	memory = maxi(memory - n, 0)  # 下限 0，等级不降（说明 #18）


# ---- 树突【标记】：光环式，相邻即获得；只增不减，消耗后若仍相邻会再次标记 ----
func update_marks() -> void:
	for c in living_cells(CWData.Faction.CANCER):
		if c["marked"]:
			continue
		for n in CWData.neighbors(c["pos"]):
			var found := false
			for ic in cells_at(n, CWData.Faction.IMMUNE):
				if ic["itype"] == CWData.ImmuneType.DENDRITIC:
					found = true
					break
			if found:
				c["marked"] = true
				break


# ---- 胜负 ----
## 【I-免疫胜利】场上无活体癌细胞，且不存在可用于复活的固化癌组织（未被免疫占据）
func check_immune_win() -> void:
	if winner >= 0 or not living_cells(CWData.Faction.CANCER).is_empty():
		return
	for c in tiles.keys():
		if tiles[c]["tissue"] == CWData.Tissue.SOLID \
				and cells_at(c, CWData.Faction.IMMUNE).is_empty():
			return  # 还有可复活据点
	winner = CWData.Faction.IMMUNE
	win_kind = "immune_clear"
	win_reason = "免疫胜利：癌细胞全灭且无可复活的固化癌组织"


## 【S-癌症胜利】癌组织 + 2×固化 ≥ 41（每世界回合 S 阶段开头判定）
func check_cancer_s_win() -> void:
	if winner >= 0:
		return
	var w := count_tissue(CWData.Tissue.CANCER) + 2 * count_tissue(CWData.Tissue.SOLID)
	if w >= tune.cancer_win_weighted:
		winner = CWData.Faction.CANCER
		win_kind = "cancer_weighted"
		win_reason = "癌症胜利：加权占地 %d ≥ %d" % [w, tune.cancer_win_weighted]


# ---- 日志 / 调试 ----
func log_msg(msg: String) -> void:
	logs.append(msg)
	log_line.emit(msg)


func cell_name(c: Dictionary) -> String:
	var tname: String
	if c["faction"] == CWData.Faction.IMMUNE:
		tname = CWData.IMMUNE_TYPE_NAMES[c["itype"]]
	else:
		tname = CWData.CANCER_TYPE_NAMES[c["ctype"]] + "癌细胞"
	return "%s(%s)" % [players[c["pid"]]["name"], tname]


## 全状态哈希：确定性测试与未来联机对局校验用
func state_hash() -> String:
	var parts: PackedStringArray = []
	parts.append("r%d m%d lv%d w%d" % [round_no, memory, immune_level, winner])
	var coords := tiles.keys()
	coords.sort()
	for c in coords:
		var t: Dictionary = tiles[c]
		parts.append("%s:%d,%d,%d,%d,%d,%d,%d" % [str(c), t["tissue"], t["solid"],
			t["sticky"], 1 if t["newborn"] else 0, t["store"], t["cards"], t["prod"]])
	for cell in cells:
		parts.append("c%d:%d,%s,%d,%d,%d,%d,%d" % [cell["id"], cell["faction"],
			str(cell["pos"]), cell["energy"], 1 if cell["alive"] else 0,
			cell["itype"], cell["ctype"], cell["respawn_round"]])
	return "\n".join(parts).sha256_text()
