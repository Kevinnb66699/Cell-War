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
## 世界事件状态（CWWorldFx 管理，结算点用 event_stacks() 查询）。
## pool = 尚未抽过的事件名（定案 #42 同局不可重复）；active = 生效中的效果条目
## {name, left, stacks, data}；double_next = 【双重触发】待兑现的标记。整体进快照与哈希。
var events := { "pool": [], "active": [], "double_next": false }
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
## 推演静音：蒙特卡洛桥「快照→试走→回滚」期间置 true——那些「未来」没有真的发生，
## 日志既不落 logs 也不广播。不进快照：它描述的是谁在看，不是对局状态。
var sim_quiet := false

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
var card_fx: CWCardFx
var world_fx: CWWorldFx


## faction_list：按行动顺序排列的阵营数组（如 CWData.FACTION_ORDER[4]）
func init(faction_list: Array, seed_value: int) -> void:
	rng.seed = seed_value
	setup = CWSetup.new()
	world = CWWorld.new()
	turn = CWTurn.new()
	actions = CWActions.new()
	cards = CWCards.new()
	card_fx = CWCardFx.new()
	world_fx = CWWorldFx.new()
	for m in [setup, world, turn, actions, cards, card_fx, world_fx]:
		m.game = self
	events["pool"] = CWWorldFx.EVENTS.duplicate()
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
		var req: Dictionary = await pending()
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
## 三个约定（2026-08-29 随「需中途选择」的卡牌批修订）：
##   ① pending() 返回「轮到谁、要做什么决定、有哪些选项」，空表示对局已结束。
##      它和 step() 都是协程，但**只在两种情况下真正挂起**：表现层要演出（掷骰动画），
##      或结算中途经 game.ask 追问且作答的是人类桥。同步桥（AI/测试）下 await
##      立即完成，快照→落子→回滚的评估循环依旧零挂起。
##   ② 行动的**入口**仍然全是顶层选项 —— AI 选行动时看到的就是原子行动。
##      少数卡在结算里的后续决定（趋化募集的走位、代谢耦联的数额…）经 game.ask
##      追问，「可以不做」的询问下标 0 恒为停止/放弃，基类桥答 0 天然安全。
##   ③ 流程位置仍是**数据**（flow）：挂起只发生在等人类作答的那一瞬，
##      快照永远取在 pending 边界上，那时没有悬着的协程。

## 当前待决策的询问；空字典 = 对局已结束。
func pending() -> Dictionary:
	if _pending.is_empty():
		await advance()
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
			await world.revive_immune(pid, data["to"])
			flow["i"] += 1
		"revive":
			await world.revive_cancer(pid, data)
			flow["i"] += 1
		"action":
			var cell: Dictionary = cell_of(pid)
			if data["act"] == "end":
				_end_turn(pid, cell)
			else:
				await actions.execute(cell, data)
				flow["acts"] += 1
	await advance()


## 推进到下一个需要决策的地方。这一路上不掷骰、不演出；
## 唯一可能挂起的是自动结算连锁里的中途询问（人类桥作答时），见 pending() 头注。
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
				await world.round_start()
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
				await world.e_phase()
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
		"events": events.duplicate(true),
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
	events = snap["events"].duplicate(true)
	rng.state = snap["rng"]


func dispose() -> void:
	for m in [setup, world, turn, actions, cards, card_fx, world_fx]:
		if m != null:
			m.game = null
	setup = null
	world = null
	turn = null
	actions = null
	cards = null
	card_fx = null
	world_fx = null
	for b in bridges.values():
		b.game = null
	bridges.clear()


# ---- 询问桥（引擎↔玩家的唯一交互通道）----
## req = {kind, prompt, options:[{label, data}], (tag)}，返回所选下标（已钳位）。
## 除了流程状态机的顶层询问，卡牌结算的**中途选择**也从这里走
## （kind：free_move / pick_cell / pick_tile / pick，tag=卡名；见 cw_card_fx 头注）。
## 中止对局时固定答 0 —— 所以「可以不做」的询问把停止/放弃放在下标 0。
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


## 名为 name 的世界事件当前叠了几层（0 = 未生效）。所有结算点都走这里；
## 卡牌的**全局**修饰（基质稳定/TGF-β/TNF 冻结格）也塞进 events["active"]，
## 被同一批挂接点认出（对照 5.1 #26 的框架承诺，2026-08-29 兑现）。
func event_stacks(name: String) -> int:
	for e in events["active"]:
		if e["name"] == name:
			return e["stacks"]
	return 0


## 往修饰器容器里挂一个全局条目（卡牌的全局修饰用；世界事件走 world_fx.trigger）。
## left 按世界回合倒计时，回合末 -1、归零移除 —— 与世界事件同一套时钟。
func install_event(ev_name: String, left: int, data: Dictionary = {}) -> void:
	events["active"].append({ "name": ev_name, "left": left, "stacks": 1, "data": data })


# ---- 卡牌修饰：挂在细胞上的那部分（全局的用上面的 install_event）----
## 条目 {name, uses, until, data}：
##   uses  还能触发几次，每次触发 -1，归零移除
##   until 过期时钟——"turn"=持有者行动回合结束（CWTurn.end_turn 清）/
##         "round"=世界回合结束（CWWorldFx.round_end 清）/ ""=只等次数用尽
## **同名多条同时生效**：一次符合条件的结算里所有同名条目一起触发、各扣一次
## （两张「下一次损失 -1.5」= 同一个下一次上减 3.0，不排队——定案 #57）。
func add_mod(cell: Dictionary, mod_name: String, uses: int, until: String,
		data: Dictionary = {}) -> void:
	cell["play_n"] += 1   ## 盖上打出先后的戳（与 equip_seq 同一把尺，见 cw_setup 细胞结构）
	cell["mods"].append({ "name": mod_name, "uses": uses, "until": until,
		"seq": cell["play_n"], "data": data })


func mods_of(cell: Dictionary, mod_name: String) -> Array:
	var out: Array = []
	for m in cell["mods"]:
		if m["name"] == mod_name:
			out.append(m)
	return out


## 触发一次：所有同名条目各扣一次，返回触发的条目数（0 = 没有这个修饰）
func spend_mods(cell: Dictionary, mod_name: String) -> int:
	var fired := 0
	var kept: Array = []
	for m in cell["mods"]:
		if m["name"] == mod_name:
			fired += 1
			m["uses"] -= 1
			if m["uses"] <= 0:
				continue
		kept.append(m)
	if fired > 0:
		cell["mods"] = kept
	return fired


## 清掉某个时钟到期的条目（"turn" / "round"）
func clear_mods(cell: Dictionary, until: String) -> void:
	var kept: Array = []
	for m in cell["mods"]:
		if m["until"] != until:
			kept.append(m)
	cell["mods"] = kept


# ---- 永久技能（装备在 cell["equipped"]，打出即装备、死亡不掉、同名限一张）----

func has_skill(cell: Dictionary, skill: String) -> bool:
	return skill in cell["equipped"]


## 「每个行动回合第一次」的闸门：第一次调用返回 true 并记账（begin_turn 清）。
## 报价这类只读场合**别调它**——直接查 cell["fx_turn"].has(key)，免得把闸门白白烧掉。
func first_this_turn(cell: Dictionary, key: String) -> bool:
	if cell["fx_turn"].has(key):
		return false
	cell["fx_turn"][key] = true
	return true


## 「每世界回合第一次」的闸门（S 阶段 _reset_round_flags 清）
func first_this_round(cell: Dictionary, key: String) -> bool:
	if cell["fx_round"].has(key):
		return false
	cell["fx_round"][key] = true
	return true


## 固化计数的**增加**一律走这里（【E-固化】与卡【基质硬化】共用）：
## 达到 3.0 即转固化；【固化加速】生效时，从 2.0 以下涨到 ≥2.0 也立即转化
## （定案 W4——只认「涨过线」，事件触发时已 ≥2.0 的格不追溯）。
func raise_solid(pos: Vector2i, amount: int) -> void:
	## 【TNF-α局部炎症】冻住的癌组织本世界回合不能增加固化计数
	## （冻结格记在全局条目的 data 里，left=1 随回合末自动解冻）
	for e in events["active"]:
		if e["name"] == "TNF-α局部炎症" and e["data"].has(pos):
			log_msg("　【TNF-α局部炎症】%s 本世界回合无法增加固化计数" % str(pos))
			return
	var t: Dictionary = tile(pos)
	var before: int = t["solid"]
	t["solid"] = before + amount
	var accel: bool = event_stacks("固化加速") > 0 \
		and before < CWData.SOLIDIFY_ACCEL_AT and t["solid"] >= CWData.SOLIDIFY_ACCEL_AT
	if t["solid"] < tune.solidify_threshold and not accel:
		return
	t["tissue"] = CWData.Tissue.SOLID
	log_msg("【固化】%s 转为固化癌组织%s" % [str(pos),
		"（固化加速）" if t["solid"] < tune.solidify_threshold else ""])


## 坏死格数。**坏死不是第四种组织** —— Tissue 只有 健康/癌/固化 三种，
## 坏死是叠在格子上的倒计时（tile["necrosis"]），所以不能用 count_tissue 数，
## 结算屏上也只能写成叠加项、不能和前三个并列去凑 127。
func count_necrosis() -> int:
	var n := 0
	for t in tiles.values():
		if t["necrosis"] > 0:
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


## 印戒【囊性护甲】：**每世界回合第一次能量损失 -0.5**（团队 2026-08-30 定案 B，口径 #76）。
##
## 卡面原来写「受到的能量损失」，实现也就只挂在 immune_hit 上，于是世界事件
## （【免疫抑制因子】对全体癌细胞的 0.5）那一路完全绕过了护甲 —— 2026-08-30 审查发现。
## 新卡面**不再限定来源**，所以两条伤害管线都要来这里取减免，别再各写一份。
##
## 唯一没盖到的是【突变】第 3 面的自扣（cell["energy"] -= …，不走管线）——
## 那条按口径 #68 的精神算「自己扣自己」，不是「受到损失」。⏳ 待团队确认。
func armor_cut(target: Dictionary) -> int:
	if target["ctype"] != CWData.CancerType.SIGNET or target["armor_used"]:
		return 0
	target["armor_used"] = true
	log_msg("　【囊性护甲】减免 %s" % CWData.fmt(CWData.ARMOR_REDUCTION))
	return CWData.ARMOR_REDUCTION


## 免疫来源的能量损失（普通攻击 / B 细胞【抗体】/ 免疫卡牌共用）。
##
## attack=false 表示这次损失**不是「攻击」**（卡牌伤害等）：树突【各司其职】减半与
## 巨噬【吞噬】吸血都不触发——PRD 那两条明写"攻击"；而【标记】×2 管的是"损失"，
## 任何来源都生效。【囊性护甲】同理，且**跨管线**生效（走 armor_cut，见那里的注释）。
##
## 落到五步管线上的分别是：
##   ② 固定增加 —— 攻击类修饰卡的「额外造成 X」（add 参数，标记翻倍会连它一起翻——管线顺序如此）
##   ③ 倍增 —— 树突【I-标记】×2（消耗掉）
##   ④ 倍减 —— 树突【I-各司其职】自己攻击只造成 1/2
##   ⑤ 减免 —— 印戒【囊性护甲】-0.5，每世界回合一次；癌卡【DNA损伤修复】挡事件/技能伤害
func immune_hit(target: Dictionary, base: int, attacker: Dictionary, attack: bool = true,
		add: int = 0) -> int:
	var mult := 1
	var div := 1
	var cut := 0
	if target["marked"]:
		mult *= 2
		target["mark_left"] -= 1
		if target["mark_left"] <= 0:
			target["marked"] = false
			log_msg("　【标记】生效，伤害翻倍")
		else:
			## 呈递强化树突施加的双份标记：翻倍两次才移除
			log_msg("　【标记】生效，伤害翻倍（还可触发 %d 次）" % target["mark_left"])
	if attack and attacker["faction"] == CWData.Faction.IMMUNE \
			and attacker["itype"] == CWData.ImmuneType.DENDRITIC:
		div *= 2
		log_msg("　【各司其职】树突状细胞只造成 1/2 伤害")
	cut += armor_cut(target)
	## 【DNA损伤修复】只挡免疫方【事件】/【技能】的损失，普通攻击是【PD-L1表达】的领地
	## （定案 #62）。数值按结算当刻的分期取（定案 #64）。
	if not attack:
		var repaired := spend_mods(target, "DNA损伤修复")
		if repaired > 0:
			var tier: int = [10, 15, 20][CWCardData.cancer_phase(round_no)] * repaired
			cut += tier
			log_msg("　【DNA损伤修复】减免 %s" % CWData.fmt(tier))
	var dmg := settle_loss(base, add, mult, div, cut)
	_lose_energy(target, dmg)
	## 巨噬【吞噬】：攻击造成能量损失后恢复 ⌈受击方损失 ÷ 2⌉。
	## PRD 这里的取整符号外面没写「到十分位」，所以按**整数能量**向上取整 ——
	## 1.0 伤害回 1.0、2.0 伤害也回 1.0，比旧版固定 0.5 明显强。
	if attack and attacker["faction"] == CWData.Faction.IMMUNE \
			and attacker["itype"] == CWData.ImmuneType.MACRO and dmg > 0:
		var heal: int = int(ceil(dmg / 2.0 / 10.0)) * 10
		attacker["energy"] += heal
		log_msg("　巨噬【吞噬】恢复 %s 能量" % CWData.fmt(heal))
	if dmg > 0:
		_after_damage(target)
	return dmg


## 癌症来源**或世界事件等中立来源**的能量损失（微环境压迫、黏液破裂、癌症卡、
## 事件的「失去 X 能量」）。走同一条管线，不吃**攻防**修正（【标记】×2 与树突减半、
## 巨噬吸血只挂在 immune_hit），但吃受击方的护盾类修饰卡与【囊性护甲】（⑤ 固定减免）。
## skill=true 表示来源是**癌细胞的技能**（黏液破裂/乳酸酸化这类细胞技能与癌方即时卡）——
## 【缺氧适应】挡这一类**加上**微环境压迫（卡面重写后，见下）；世界事件、反弹不算（定案 #62）。
func cancer_hit(target: Dictionary, base: int, reason: String, skill: bool = false) -> int:
	var cut := armor_cut(target)
	var mem := spend_mods(target, "细胞膜修复")
	if mem > 0:
		cut += CWData.MEMBRANE_CUT * mem
		log_msg("　【细胞膜修复】减免 %s" % CWData.fmt(CWData.MEMBRANE_CUT * mem))
	var ifn := spend_mods(target, "I型干扰素")
	if ifn > 0:
		cut += CWData.IFN1_CUT * ifn
		log_msg("　【I型干扰素】减免 %s" % CWData.fmt(CWData.IFN1_CUT * ifn))
	## 【缺氧适应】挡「癌细胞技能」**或**【微环境压迫】（2026-08-30 卡面重写，口径 #62/#72）。
	## 压迫不是技能，所以要在 skill 之外单认一次 reason。
	if skill or reason == "微环境压迫":
		var hyp := spend_mods(target, "缺氧适应")
		if hyp > 0:
			cut += CWData.HYPOXIA_CUT * hyp
			log_msg("　【缺氧适应】减免 %s" % CWData.fmt(CWData.HYPOXIA_CUT * hyp))
	if has_skill(target, "耗竭抵抗"):
		if first_this_round(target, "耗竭抵抗"):
			cut += CWData.EXHAUST_FIRST_CUT
			log_msg("　【耗竭抵抗】本世界回合首次损失 -1.0")
		if reason == "微环境压迫":
			cut += CWData.EXHAUST_PRESSURE_CUT
			log_msg("　【耗竭抵抗】微环境压迫额外 -0.5")
	var dmg := settle_loss(base, 0, 1, 1, cut)
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
	## 【BCL-2抗凋亡】只救「受到的损失」——挂在这里而不是 kill() 里，
	## 黏液破裂的自毁、突变的自扣不经过这条路，救不了（口径 #68）
	if cell["energy"] <= 0 and has_skill(cell, "BCL-2抗凋亡"):
		var tier: int = CWData.BCL2_ENERGY[CWCardData.cancer_phase(round_no)]
		cell["energy"] = tier
		cell["equipped"].erase("BCL-2抗凋亡")
		log_msg("　【BCL-2抗凋亡】%s 免于死亡，能量改为 %s（本牌弃置，可重新抽取）" % [
			cell_name(cell), CWData.fmt(tier)])
		update_marks()
		return
	if cell["energy"] <= 0:
		kill(cell)
	update_marks()


func kill(cell: Dictionary) -> void:
	cell["energy"] = 0
	cell["alive"] = false
	cell["mods"] = []   ## 「自身」的修饰随细胞死亡消散，复活是新生

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
	var bonus := event_stacks("抗原暴露")   ## 每**次**获得时 +1，不按点数（按 stacks 叠）
	if bonus > 0:
		log_msg("　【抗原暴露】抗原记忆额外 +%d" % bonus)
	memory += n + bonus
	var lv := immune_level
	while lv < 3 and memory >= CWData.LEVEL_MIN_MEMORY[lv + 1]:
		lv += 1
	if lv > immune_level:
		immune_level = lv
		log_msg("★ 免疫等级升至 %s 级" % CWData.LEVEL_NAMES[lv])


func reduce_memory(n: int) -> void:
	memory = maxi(memory - n, 0)  # 下限 0，等级不降（说明 #18）


# ---- 树突【标记】：光环式，相邻即获得；只增不减，消耗后若仍相邻会再次标记 ----

## 施加【标记】的唯一入口（光环 / 卡【交叉呈递】/ 技能【抗原呈递强化】共用）。
## by = 施加者：树突装备【抗原呈递强化】时，它施加的标记可触发 2 次翻倍再移除。
## 已有更多次数的标记不被弱化（maxi 取大）。
func apply_mark(target: Dictionary, by: Dictionary) -> void:
	target["marked"] = true
	var charges := 1
	if by["faction"] == CWData.Faction.IMMUNE and by["itype"] == CWData.ImmuneType.DENDRITIC \
			and has_skill(by, "抗原呈递强化"):
		charges = 2
	target["mark_left"] = maxi(target["mark_left"], charges)


func update_marks() -> void:
	for c in living_cells(CWData.Faction.CANCER):
		if c["marked"]:
			continue
		for n in CWData.neighbors(c["pos"]):
			var found := false
			for ic in cells_at(n, CWData.Faction.IMMUNE):
				if ic["itype"] == CWData.ImmuneType.DENDRITIC:
					apply_mark(c, ic)
					found = true
					break
			if found:
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
	if sim_quiet:
		return
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
		## **打出先后的戳必须进哈希**（2026-08-30 审查问题 2）：口径 #73 之后 seq /
		## equip_seq 是**规则相关数据**（移动费链按它排序）。两个数组各自的内部次序
		## 本来就被数组顺序捎带上了，但即时卡与永久技能**之间**的交错完全没进来 ——
		## 于是「先装组织巡航后打炎症趋化」和反过来算出同一个哈希，而两者移动费差 0.5。
		##
		## `cell["play_n"]` 本身**不进哈希**：它是只增不减的计数器，绝对值不影响任何
		## 结算（同一批条目无论从 3 还是从 5 往后发号，排出来的先后完全一样），
		## 有意义的只是相对先后，而那已经被各条目的 seq 记住了。把它塞进来反而会打破
		## 「挂上修饰 → 消耗掉 = 回到原状态」这条测试地基（t_card_mods ⑪）。
		var mods: PackedStringArray = []
		for m in cell["mods"]:
			mods.append("%s*%d%s@%d" % [m["name"], m["uses"], m["until"], m.get("seq", 0)])
		var eq: PackedStringArray = []
		for s in cell["equipped"]:
			eq.append("%s@%d" % [s, cell["equip_seq"].get(s, 0)])
		var ft: Array = cell["fx_turn"].keys()
		ft.sort()
		var fr: Array = cell["fx_round"].keys()
		fr.sort()
		parts.append("c%d:%d,%s,%d,%d,%d,%d,%d|%s|%s|%s|k%d.%d|%s|%s" % [
			cell["id"], cell["faction"],
			str(cell["pos"]), cell["energy"], 1 if cell["alive"] else 0,
			cell["itype"], cell["ctype"], cell["respawn_round"],
			",".join(cell["hand"]), ",".join(eq), ",".join(mods),
			1 if cell["marked"] else 0, cell["mark_left"], str(ft), str(fr)])
	var ev: PackedStringArray = []
	for e in events["active"]:
		var dk: Array = e["data"].keys()
		dk.sort()
		var dp: PackedStringArray = []
		for k in dk:
			dp.append("%s=%s" % [str(k), str(e["data"][k])])
		ev.append("%s:%d:%d:%s" % [e["name"], e["left"], e["stacks"], ";".join(dp)])
	parts.append("ev dn%d pool:%s | %s" % [1 if events["double_next"] else 0,
		",".join(events["pool"]), " ".join(ev)])
	return "\n".join(parts).sha256_text()
