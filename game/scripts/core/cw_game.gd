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
# 中途放弃这一局（返回主菜单）。置位后引擎的各个循环会在下一个检查点收摊，
# 让卡在「等玩家作答」上的那次询问能安全地一路展开回来 ——
# 直接 dispose() 的话，展开途中会碰到已经置空的模块。
var aborted := false
# 下面两个纯粹是给界面看的：「现在是哪个阶段、轮到谁」本来只存在于控制流里，
# 界面问不出来。不参与 state_hash，也不影响任何结算。
var phase := ""            # 开局布置 / 世界回合 S / 玩家回合 / 世界回合 E
var current_pid := -1      # 正在行动的玩家；非玩家回合时为 -1
var win_reason := ""
var win_kind := ""         # immune_clear / cancer_weighted / limit_cancer / limit_immune（统计用）
var rng := RandomNumberGenerator.new()
var bridges := {}          # player_id -> CWBridge
var logs: PackedStringArray = []
var tune := CWTuning.new() # 平衡旋钮；默认即规则原文，init() 之前可整体替换

## 流程游标。**对局推进到哪一步是数据，不是调用栈。**
## stage 见 advance() 的 match；i 是玩家游标（order 的下标）。
var flow := { "stage": "init", "i": 0, "acts": 0 }
var _pending := {}         ## 当前待决策的询问；空 = 不需要任何人做决定
## 推进到这个阶段的**开头**就停下，不执行它。给测试和工具用（"" = 不停）。
## 例：想要「刚落完子、世界回合还没开始」的局面，就设成 "round_start"。
var stop_at := ""

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
##
## 这里只是个薄壳：真正的推进在 advance() / step()。
## 保留它是因为 AI 互搏、平衡模拟、测试都只想要「跑完一局」这一件事。
func run_game() -> int:
	while true:
		var req := pending()
		if req.is_empty():
			break
		var idx: int = await ask(req["pid"], req)
		if aborted:
			break
		await step(idx)
	log_msg("=== 对局结束：%s ===" % win_reason)
	return winner


# ---- 流程状态机 ----
##
## **为什么不写成一个从头跑到尾的循环。** 那样「现在推进到哪儿」这件事就存在
## 调用栈里（哪个函数、循环跑到第几个玩家），而调用栈是没法快照的。
## AI 要评估「我走这一步会怎样」，需要的是：快照 → 落一步 → 继续跑几步 → 回滚，
## 反复几千次。所以流程位置必须是**数据**（flow），推进必须是**函数调用**（step）。
##
## 三个约定：
##   ① pending() 是同步的，返回「轮到谁、要做什么决定、有哪些选项」，空表示对局已结束
##   ② step() 只在**表现层要求演出**时才会挂起（掷骰动画）。同步的桥用它零成本
##   ③ 所有决定都是顶层选项 —— execute() 内部不再发问，一个行动就是一个原子

## 当前待决策的询问；空字典 = 对局已结束。**同步，可以随便调。**
func pending() -> Dictionary:
	if _pending.is_empty():
		advance()
	return _pending


func is_over() -> bool:
	return winner >= 0 or aborted


## 对当前 pending() 作答，并推进到下一个决策点。
## choice 是选项下标（会被钳位）。**可能 await —— 只因为掷骰要演出。**
func step(choice: int) -> void:
	if _pending.is_empty():
		return
	var req := _pending
	_pending = {}
	var opts: Array = req["options"]
	var idx: int = clampi(choice, 0, opts.size() - 1)
	var data: Dictionary = opts[idx]["data"]
	var pid: int = req["pid"]
	match req["kind"]:
		"setup_place":
			setup.place(pid, data["to"])
			flow["i"] += 1
		"immune_revive":
			world.revive_immune(pid, data["to"])
			flow["i"] += 1
		"revive":
			world.revive_cancer(pid, data)
			flow["i"] += 1
		"action":
			var cell: Dictionary = cell_of(pid)
			if data["act"] == "end":
				_end_turn(pid, cell)
			else:
				await actions.execute(cell, data)
				flow["acts"] += 1
	advance()


## 推进到下一个需要决策的地方。全程同步 —— 这一路上不掷骰、不演出。
func advance() -> void:
	while _pending.is_empty() and not is_over() and flow["stage"] != stop_at:
		match flow["stage"]:
			"init":
				setup.begin()
				_goto("setup_place")
			"setup_place":
				if not _ask_each("setup_place", func(pid: int) -> Array:
					return setup.place_options(pid)):
					setup.finish()
					_goto("round_start")
			"round_start":
				world.round_start()
				_goto("revive_immune")
			"revive_immune":
				if not _ask_each("immune_revive", func(pid: int) -> Array:
					return world.revive_options_immune(pid)):
					_goto("revive_cancer")
			"revive_cancer":
				if not _ask_each("revive", func(pid: int) -> Array:
					return world.revive_options_cancer(pid)):
					world.aerobic()
					_goto("turn")
			"turn":
				_advance_turn()
			"e_phase":
				phase = "世界回合 E"
				world.e_phase()
				if is_over():
					return
				round_no += 1
				_goto("round_start")
			_:
				return


func _goto(stage: String) -> void:
	flow["stage"] = stage
	flow["i"] = 0
	phase = PHASE_NAMES.get(stage, phase)


## 按行动顺序逐个玩家问一遍。返回 true 表示「已经问出去了，等作答」，
## false 表示「这一轮所有人都问完了」。落子、两处复活共用这套游标。
func _ask_each(kind: String, options_of: Callable) -> bool:
	while flow["i"] < order.size():
		var pid: int = order[flow["i"]]
		var opts: Array = options_of.call(pid)
		if opts.is_empty():
			flow["i"] += 1
			continue
		_pending = {
			"kind": kind, "pid": pid, "options": opts,
			"prompt": "%s：%s" % [player(pid)["name"], PROMPTS.get(kind, "请选择")],
		}
		return true
	return false


## 玩家回合：同一个人可以连续行动，直到「结束回合」/ 死亡 / 没得选。
func _advance_turn() -> void:
	while flow["i"] < order.size():
		var pid: int = order[flow["i"]]
		var cell: Dictionary = cell_of(pid)
		if not cell["alive"]:
			log_msg("（%s 已死亡，跳过回合）" % player(pid)["name"])
			_next_player()
			continue
		if current_pid != pid:
			turn.begin_turn(pid, cell)
			current_pid = pid
			flow["acts"] = 0
		var opts: Array = actions.build_options(cell)
		## 只剩「结束回合」，或者行动次数撞上护栏 → 直接收摊，不必问
		if opts.size() <= 1 or flow["acts"] >= CWTurn.MAX_ACTIONS_PER_TURN:
			_end_turn(pid, cell)
			continue
		_pending = {
			"kind": "action", "pid": pid, "options": opts, "prompt": "选择行动",
		}
		return
	_goto("e_phase")


func _end_turn(pid: int, cell: Dictionary) -> void:
	turn.end_turn(pid, cell)
	_next_player()


func _next_player() -> void:
	flow["i"] += 1
	current_pid = -1


const PHASE_NAMES := {
	"setup_place": "开局布置", "round_start": "世界回合 S",
	"revive_immune": "世界回合 S", "revive_cancer": "世界回合 S",
	"turn": "玩家回合", "e_phase": "世界回合 E",
}
const PROMPTS := {
	"setup_place": "选择初始位置", "immune_revive": "选择复活位置",
	"revive": "选择复活位置",
}


# ---- 快照 / 回滚 ----
## 给 AI 推演用：snapshot() 拿一份完整状态，restore() 原样放回去。
##
## **随机数发生器的 state 也在里面** —— 少了它，同一步走两遍会掷出不同的骰子，
## 整个推演就没有意义了（猫靴说的「随机种子是状态的一部分」，这里是它的落点）。
##
## 实测深拷贝一次约 0.16 ms。真要跑上万次推演的话，这个成本是主要开销，
## 届时应该换成「落子 / 悔子」（make-unmake）而不是整份复制 —— 但那要先有回滚日志。
func snapshot() -> Dictionary:
	return {
		"tiles": tiles.duplicate(true),
		"cells": cells.duplicate(true),
		"players": players.duplicate(true),
		"differentiated": differentiated.duplicate(),
		"flow": flow.duplicate(),
		"pending": _pending.duplicate(true),
		"round_no": round_no, "memory": memory, "immune_level": immune_level,
		"winner": winner, "win_reason": win_reason, "win_kind": win_kind,
		"current_pid": current_pid, "phase": phase,
		"rng": rng.state,
	}


func restore(snap: Dictionary) -> void:
	tiles = snap["tiles"].duplicate(true)
	cells = snap["cells"].duplicate(true)
	players = snap["players"].duplicate(true)
	differentiated = snap["differentiated"].duplicate()
	flow = snap["flow"].duplicate()
	_pending = snap["pending"].duplicate(true)
	round_no = snap["round_no"]
	memory = snap["memory"]
	immune_level = snap["immune_level"]
	winner = snap["winner"]
	win_reason = snap["win_reason"]
	win_kind = snap["win_kind"]
	current_pid = snap["current_pid"]
	phase = snap["phase"]
	rng.state = snap["rng"]


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
	if aborted:
		return 0
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
## 静默掷骰：不触发任何演出。世界自动结算这类随机用它。
func roll_d6() -> int:
	return rng.randi_range(1, 6)


func roll_d3() -> int:
	return rng.randi_range(1, 3)


## 带演出的掷骰：引擎在这里等动画播完，再继续结算。
##
## 和 roll_d6/roll_d3 消耗的是同一个 rng、同样一次 randi_range，
## 所以两者可以随时互换而不影响同种子可复现 ——
## **「某个随机要不要演动画」是纯表现层决定，不碰规则**。
## reason 显示在骰子旁边（"攻击" / "突变" …）。无头运行时基类桥立即返回。
## pid = 掷骰的那个玩家，表现层用它决定骰子的阵营色。
## 广播给**所有**桥，而不是只给 pid 那一个 —— AI 掷的骰，旁观的人类也得看见。
## 同一个桥对象注册给多个玩家时（热座共用一个 UI）按对象去重，只演一次。
func roll_shown(sides: int, reason: String, pid: int, at: Vector2i) -> int:
	var v := rng.randi_range(1, sides)
	var shown: Array = []
	for b in bridges.values():
		if b == null or shown.has(b):
			continue
		shown.append(b)
		await b.show_roll(reason, v, sides, pid, at)
	return v


## 把一句话通报广播给所有桥。去重规则同 roll_shown（热座共用一个 UI 桥时只报一次）。
## 不 await：提示自己会淡掉，不该卡住结算。
func announce(text: String, at: Vector2i) -> void:
	var shown: Array = []
	for b in bridges.values():
		if b == null or shown.has(b):
			continue
		shown.append(b)
		b.show_result(text, at)


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


## PRD「通用结算规则 · 能量损失计算顺序」：
##   ① 基础能量损失 → ② 固定数值增加 → ③ 倍增效果 → ④ 倍减效果 → ⑤ 固定数值减免
##
## **全项目扣能量都要走这里。** 卡池上来之后，各种 ±N / ×2 / 减伤都是往这五步里塞参数，
## 谁也不许在别处自己算一遍 —— 顺序错了结果就不一样（先减免再倍增能差一倍）。
## 倍减用整数除法，正好等于 PRD 反复强调的「向下取整到十分位」（能量本来就是十分整数）。
static func settle_loss(base: int, add: int, mult: int, div: int, cut: int) -> int:
	var v: int = (base + add) * mult / div
	return maxi(v - cut, 0)


## 免疫来源的能量损失（普通攻击 / B 细胞【抗体】共用）。
##
## 落到五步管线上的分别是：
##   ③ 倍增 —— 树突【I-标记】×2（消耗掉）
##   ④ 倍减 —— 树突【I-各司其职】自己攻击只造成 1/2
##   ⑤ 减免 —— 印戒【囊性护甲】−0.5，每世界回合一次
func immune_hit(target: Dictionary, base: int, attacker: Dictionary) -> int:
	var mult := 1
	var div := 1
	var cut := 0
	if target["marked"]:
		mult *= 2
		target["marked"] = false
		log_msg("　【标记】生效，伤害翻倍")
	if attacker["faction"] == CWData.Faction.IMMUNE \
			and attacker["itype"] == CWData.ImmuneType.DENDRITIC:
		div *= 2
		log_msg("　【各司其职】树突状细胞只造成 1/2 伤害")
	if target["ctype"] == CWData.CancerType.SIGNET and not target["armor_used"]:
		cut += CWData.ARMOR_REDUCTION
		target["armor_used"] = true
		log_msg("　【囊性护甲】减免 0.5")
	var dmg := settle_loss(base, 0, mult, div, cut)
	_lose_energy(target, dmg)
	## 巨噬【吞噬】：攻击造成能量损失后恢复 ⌈受击方损失 ÷ 2⌉。
	## PRD 这里的取整符号外面没写「到十分位」，所以按**整数能量**向上取整 ——
	## 1.0 伤害回 1.0、2.0 伤害也回 1.0，比旧版固定 0.5 明显强。
	if attacker["faction"] == CWData.Faction.IMMUNE \
			and attacker["itype"] == CWData.ImmuneType.MACRO and dmg > 0:
		var heal: int = int(ceil(dmg / 2.0 / 10.0)) * 10
		attacker["energy"] += heal
		log_msg("　巨噬【吞噬】恢复 %s 能量" % CWData.fmt(heal))
	if dmg > 0:
		_after_damage(target)
	return dmg


## 癌症来源的能量损失（【E-微环境压迫】、印戒【黏液破裂】、将来的癌症卡）。
## 走同一条管线；目前癌方还没有倍增/倍减手段，所以只有基础值。
func cancer_hit(target: Dictionary, base: int, reason: String) -> int:
	var dmg := settle_loss(base, 0, 1, 1, 0)
	log_msg("【%s】%s 损失 %s 能量（余 %s）" % [
		reason, cell_name(target), CWData.fmt(dmg), CWData.fmt(maxi(target["energy"] - dmg, 0))])
	_lose_energy(target, dmg, false)
	if dmg > 0:
		_after_damage(target)
	return dmg


func _lose_energy(cell: Dictionary, dmg: int, verbose: bool = true) -> void:
	cell["energy"] -= dmg
	if verbose:
		log_msg("　%s 损失 %s 能量（余 %s）" % [
			cell_name(cell), CWData.fmt(dmg), CWData.fmt(maxi(cell["energy"], 0))])


func _after_damage(cell: Dictionary) -> void:
	if cell["energy"] <= 0:
		kill(cell)
	update_marks()


func kill(cell: Dictionary) -> void:
	cell["energy"] = 0
	cell["alive"] = false
	if cell["faction"] == CWData.Faction.CANCER:
		log_msg("☠ %s 死亡" % cell_name(cell))
		return
	# 免疫细胞：下一个 S 阶段在骨髓复活（PRD 没有额外罚停，delay 默认 0）。
	# 死于第 N 回合的玩家阶段 → 第 N+1 回合 S 阶段复活，天然缺席一整轮。
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
## 【E-免疫胜利】场上无活体癌细胞，且不存在可用于【复活】的固化癌组织。
##
## **只在 E 阶段最后判**（PRD 世界回合 E 第 10 步）。2026-08-28 之前是 I 类、
## 净化后立即判，PRD 已推翻 —— 意味着癌方在被清场后仍有完整的一轮反应窗口。
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


## 【E-癌症胜利】癌组织 + 2×固化 ≥ ⌈1/2×127⌉ = 64。同样只在 E 阶段最后判。
func check_cancer_win() -> void:
	if winner >= 0:
		return
	var w := count_tissue(CWData.Tissue.CANCER) + 2 * count_tissue(CWData.Tissue.SOLID)
	if w >= tune.cancer_win_weighted:
		winner = CWData.Faction.CANCER
		win_kind = "cancer_weighted"
		win_reason = "癌症胜利：加权占地 %d >= %d" % [w, tune.cancer_win_weighted]


# ---- 日志 / 调试 ----
func log_msg(msg: String) -> void:
	logs.append(msg)
	log_line.emit(msg)


func cell_name(c: Dictionary) -> String:
	var tname: String
	if c["faction"] == CWData.Faction.IMMUNE:
		tname = CWData.IMMUNE_TYPE_NAMES[c["itype"]]
	else:
		tname = CWData.CANCER_TYPE_NAMES[c["ctype"]]   ## 「恶性黑色素瘤」自带癌义，别再拼「癌细胞」
	return "%s(%s)" % [players[c["pid"]]["name"], tname]


## 全状态哈希：确定性测试与未来联机对局校验用
func state_hash() -> String:
	var parts: PackedStringArray = []
	parts.append("r%d m%d lv%d w%d" % [round_no, memory, immune_level, winner])
	var coords := tiles.keys()
	coords.sort()
	for c in coords:
		var t: Dictionary = tiles[c]
		parts.append("%s:%d,%d,%d,%d,%d,%d,%d,%d" % [str(c), t["tissue"], t["solid"],
			t["necrosis"], 1 if t["newborn"] else 0, 1 if t["mucus"] else 0,
			t["store"], t["cards"], t["prod"]])
	for cell in cells:
		parts.append("c%d:%d,%s,%d,%d,%d,%d,%d|%s|%s" % [cell["id"], cell["faction"],
			str(cell["pos"]), cell["energy"], 1 if cell["alive"] else 0,
			cell["itype"], cell["ctype"], cell["respawn_round"],
			",".join(cell["hand"]), ",".join(cell["equipped"])])
	return "\n".join(parts).sha256_text()
