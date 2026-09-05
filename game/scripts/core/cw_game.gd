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
## 树突状细胞【I-趋化源】：{} = 场上没有；否则 { at: Vector2i, left: 剩余世界回合, by: 建立者 pid }。
## **进快照与哈希**（它改变后续所有移动的价钱）。同一时刻仅一个，见 CWActions 的 chemo 选项。
var chemo := {}
var cancer_win_streak := 0  # 癌方加权占地连续达标的回合末次数（见 tune.cancer_win_hold_rounds）；进快照与哈希
var rng := RandomNumberGenerator.new()
var bridges := {}          # player_id -> CWBridge
var logs: PackedStringArray = []
## 与 logs 平行的两列（联机视角用）：这一行只对哪个席位可见（-1 = 公开），以及给其他席位看的公开替身。
## 目前唯一的秘密行是「谁抽到了哪张牌」（cw_cards.draw）——别人只该看到「抽到 1 张卡」。
var log_secret: PackedInt32Array = []
var log_public: PackedStringArray = []
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
var cost: CWCost
var damage: CWDamage


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
	cost = CWCost.new()
	damage = CWDamage.new()
	for m in [setup, world, turn, actions, cards, card_fx, world_fx, cost, damage]:
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
				## 一次行动就是一次结算：卡牌把能量顶到 15 以上，到这里就削回去
				cap_energy()
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
					cap_energy()      ## S 阶段这一次结算完，溢出的不留
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
	## 【E-无氧呼吸】2026-09-05 起在癌细胞自己的回合末结算（旋钮 anaerobic_on_turn_end）；
	## 排在 end_turn 之前，让「结束回合（能量 X）」那行日志写的是进账后的数
	if tune.anaerobic_on_turn_end and cell["faction"] == CWData.Faction.CANCER and cell["alive"]:
		world.settle_anaerobic_turn(cell)
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
	return CWStateCodec.snapshot(self)


func restore(snap: Dictionary) -> void:
	CWStateCodec.restore(self, snap)


func dispose() -> void:
	for m in [setup, world, turn, actions, cards, card_fx, world_fx, cost, damage]:
		if m != null:
			m.game = null
	setup = null
	world = null
	turn = null
	actions = null
	cards = null
	card_fx = null
	world_fx = null
	cost = null
	damage = null
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


## 【溢出】把所有存活细胞的能量削到上限（PRD 2026-09-01：「能量最高储存量为 15，
## 超出则溢出消失」，数值修正结算顺序第 9 阶段）。
##
## **为什么封存量而不是封流量。** 此前封的是【无氧呼吸】每回合的进账（10.0），
## 但进账可以跨回合囤着：2026-08-31 的试玩里，免疫把癌组织压到 3 格、局面看着已经赢了，
## 黑色素瘤下一回合掏出攒了几轮的 25.5 能量一口气占了 63 格，直接越过胜利线。
##
## **为什么在「结算末」削而不是每次 += 都削。** PRD 明写「结算时先将能量增减相互抵消，
## 再算溢出值」—— 一次结算里既有进账又有扣减时，要先抵消完再看溢出，
## 否则中途那个高点会被白白削掉（例：【无氧呼吸】先给基础值、再给【GLUT1高表达】加成，
## 中间削一刀就把加成吃了）。所以调用点是**三个结算边界**，见 CWWorld.e_phase、
## CWGame.advance（S 阶段末）与 CWGame.step（每次行动结算后）。
func cap_energy() -> void:
	var cap: int = tune.energy_cap
	if cap <= 0:
		return
	for cell in living_cells():
		if cell["energy"] <= cap:
			continue
		log_msg("【溢出】%s 能量 %s → %s" % [
			cell_name(cell), CWData.fmt(cell["energy"]), CWData.fmt(cap)])
		cell["energy"] = cap


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
##         "round"=世界回合结束（CWWorldFx.tick_durations 清）/ ""=只等次数用尽
## **同名多条同时生效**：一次符合条件的结算里所有同名条目一起触发、各扣一次
## （两张「下一次损失 -1.5」= 同一个下一次上减 3.0，不排队——定案 #57）。
func add_mod(cell: Dictionary, mod_name: String, uses: int, until: String,
		data: Dictionary = {}) -> void:
	cell["play_n"] += 1   ## 盖上打出先后的戳（与 equip_seq 同一把尺，见 cw_setup 细胞结构）
	cell["mods"].append({ "name": mod_name, "uses": uses, "until": until,
		"seq": cell["play_n"], "data": data })


## 只消耗**一条**同名修饰，多条时取**最早打出**的那条（seq 最小）。
##
## 和 spend_mods（同名一次全消耗，定案 #57）是**两条并存的口径**，别互相改：
## 减伤类走 #57（两张「下一次 -1.5」= 这一次减 3.0），而【PD-L1表达】按团队
## 2026-09-01 的裁定走这条 —— 判定已经是失败也照样消耗，但一次攻击只吃掉一层，
## 剩下的留给下一次攻击。返回是否真的消耗掉了一条。
##
## 用下标而不是 Array.erase：mods 里两条同名条目的字典内容可能完全一样，
## 按值删会删错那条（seq 不同但先被匹配到的是另一条）。
func spend_one_mod(cell: Dictionary, mod_name: String) -> bool:
	var pick := -1
	for i in cell["mods"].size():
		var m: Dictionary = cell["mods"][i]
		if m["name"] != mod_name:
			continue
		if pick < 0 or int(m.get("seq", 0)) < int(cell["mods"][pick].get("seq", 0)):
			pick = i
	if pick < 0:
		return false
	var e: Dictionary = cell["mods"][pick]
	e["uses"] -= 1
	if e["uses"] <= 0:
		cell["mods"].remove_at(pick)
	return true


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
## 存的是**用了几次**而不是 true：多数闸门只要「是不是第一次」，
## 但【组织驻留】这类「前 N 次」要数得出来（CWCost.GATE_USES）。
## 返回值语义不变 —— 仍然是「这一次是不是第一次」。
func first_this_turn(cell: Dictionary, key: String) -> bool:
	var n: int = cell["fx_turn"].get(key, 0)
	cell["fx_turn"][key] = n + 1
	return n == 0


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
	if solid_frozen(pos):
		log_msg("　【TNF-α局部炎症】%s 本世界回合无法增加固化计数" % str(pos))
		return
	var t: Dictionary = tile(pos)
	var before: int = t["solid"]
	t["solid"] = before + amount
	var accel: bool = event_stacks("固化加速") > 0 \
		and before < CWData.SOLIDIFY_ACCEL_AT and t["solid"] >= CWData.SOLIDIFY_ACCEL_AT
	if t["solid"] < tune.solidify_threshold and not accel:
		return
	CWTissue.to_solid(t)
	log_msg("【固化】%s 转为固化癌组织%s" % [str(pos),
		"（固化加速）" if t["solid"] < tune.solidify_threshold else ""])


## 这一格本世界回合被【TNF-α局部炎症】冻住了吗（冻结格记在全局条目的 data 里，
## left=1 随回合末自动解冻）。**纯查询，不改任何状态。**
##
## 抽成一份是因为它有两个读者：`raise_solid()` 结算时拦，
## 卡【基质硬化】**选目标时**也要拦。少了后者就会出现团队 2026-09-05 报的那个形状 ——
## 选项照给、卡照吃、计数不动，玩家只看见「用了没反应」。
func solid_frozen(pos: Vector2i) -> bool:
	for e in events["active"]:
		if e["name"] == "TNF-α局部炎症" and e["data"].has(pos):
			return true
	return false


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


## 【E-侵蚀】过场广播。去重规则同 announce（热座共用一个 UI 桥时只演一次）。
## 不 await：过场自己会走完，不该卡住 E 阶段的后续步骤。
func erosion_fx(at: Vector2i, dir: int) -> void:
	var shown: Array = []
	for b in bridges.values():
		if b == null or shown.has(b):
			continue
		shown.append(b)
		b.show_erosion(at, dir)


## 全局通报（不挂格子）：每个桥对象只通报一次，同 announce
func notice(text: String) -> void:
	var shown: Array = []
	for b in bridges.values():
		if b == null or shown.has(b):
			continue
		shown.append(b)
		b.show_notice(text)


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
## 2026-08-30 起只是 CWDamage 的**薄壳**：建一个 DamageEvent 交给管线，
## 返回目标**实际失去**的能量（DamageResult.actual）。所有减免、标记、护甲、
## 死亡替代与伤后触发都住在 cw_damage.gd 里，这里不再自己算。
##
## attack=false 表示这次损失**不是「攻击」**（卡牌伤害等）：树突【各司其职】减半与
## 巨噬【吞噬】吸血都不触发——PRD 那两条明写"攻击"。
func immune_hit(target: Dictionary, base: int, attacker: Dictionary, attack: bool = true,
		add: int = 0) -> int:
	var tags: Array = [CWDamage.Tag.IMMUNE]
	if attack:
		tags.append(CWDamage.Tag.ATTACK)
	var ev := damage.event(attacker, target, base,
		CWDamage.Kind.ATTACK if attack else CWDamage.Kind.CARD,
		tags, "攻击" if attack else "技能", add)
	return damage.submit([ev])[0]["actual"]


## 癌症来源**或世界事件等中立来源**的能量损失（微环境压迫、黏液破裂、癌症卡、
## 事件的「失去 X 能量」）。同样只是 CWDamage 的薄壳。
## skill=true 表示来源是**癌细胞的技能**（含癌方即时卡）——【缺氧适应】挡这一类
## 加上【微环境压迫】；世界事件与反弹不算（口径 #62）。
func cancer_hit(target: Dictionary, base: int, reason: String, skill: bool = false) -> int:
	var ev := damage.event({}, target, base,
		CWDamage.Kind.CELL_SKILL if skill else CWDamage.Kind.WORLD,
		[CWDamage.Tag.CANCER], reason)
	return damage.submit([ev])[0]["actual"]


## 范围伤害：**一批事件同时提交**（设计 §5.5）。
##
## 必须走这两个入口，不要自己 for 循环逐个调 immune_hit/cancer_hit ——
## 那样会边遍历边扣能量、边死人、边刷新标记，**数组顺序就会改变结果**。
## 批量提交先在同一份批前状态上把每个目标算完，再统一扣、统一判死、统一抛触发。
func immune_hit_area(targets: Array, base: int, attacker: Dictionary,
		ability: String = "技能", attack: bool = false) -> Array:
	var tags: Array = [CWDamage.Tag.IMMUNE, CWDamage.Tag.AREA]
	if attack:
		tags.append(CWDamage.Tag.ATTACK)
	## 批次号**取一次**给全体目标——写在循环里的话，同一次范围伤害会被声明成
	## 多个不同批次（2026-08-31 队友审查问题 2）
	var group := damage.next_group()
	var events: Array = []
	for t in targets:
		events.append(damage.event(attacker, t, base,
			CWDamage.Kind.ATTACK if attack else CWDamage.Kind.CARD,
			tags, ability, 0, group))
	return damage.submit(events)


func cancer_hit_area(targets: Array, base: int, reason: String, skill: bool = false) -> Array:
	var group := damage.next_group()
	var events: Array = []
	for t in targets:
		events.append(damage.event({}, t, base,
			CWDamage.Kind.CELL_SKILL if skill else CWDamage.Kind.WORLD,
			[CWDamage.Tag.CANCER, CWDamage.Tag.AREA], reason, 0, group))
	return damage.submit(events)


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


## 【I-标记】的光环刷新：**任意时间**站在树突旁边的癌细胞都该带着标记（2026-09-04 新 PRD）。
##
## 旧写法只在「分化出树突」和「有人移动」之后刷一次，于是标记被伤害消耗掉之后
## 即使还贴着树突也不会再回来 —— 新 PRD 的「同一回合一癌细胞可多次获得标记」要的正是那次回补。
## 所以改成**每次可能改变邻接或消耗标记的结算之后都刷一遍**（移动、伤害、复活、卡牌位移）。
## 幂等：已经带着标记的跳过，`maxi` 也保证【抗原呈递强化】的 2 层不会被降级，
## 因此重复调用不会把层数堆到天上。

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
	if w < tune.cancer_win_weighted:
		if cancer_win_streak > 0:
			log_msg("癌方加权占地回落到 %d < %d，胜利计数归零" % [w, tune.cancer_win_weighted])
		cancer_win_streak = 0
		return
	cancer_win_streak += 1
	if cancer_win_streak < tune.cancer_win_hold_rounds:
		## 达标但还没坐满：只拉响警报，给免疫方一个完整的回应回合（团队 2026-09-01 提案 B）。
		## hold_rounds = 1（定案 B 之前的旧规则）时永远走不到这里 —— 第一次达标就判胜。
		log_msg("★ 警报：癌方加权占地 %d >= %d（连续第 %d/%d 个回合末），下回合末仍达标即获胜" % [
			w, tune.cancer_win_weighted, cancer_win_streak, tune.cancer_win_hold_rounds])
		return
	winner = CWData.Faction.CANCER
	win_kind = "cancer_weighted"
	win_reason = "癌症胜利：加权占地 %d >= %d" % [w, tune.cancer_win_weighted]


# ---- 日志 / 调试 ----
## secret_pid >= 0 表示这行只有该席位能看原文，其他席位看 public_msg（联机视角；本地对局照常全显）。
func log_msg(msg: String, secret_pid: int = -1, public_msg: String = "") -> void:
	if sim_quiet:
		return
	logs.append(msg)
	log_secret.append(secret_pid)
	log_public.append(msg if secret_pid < 0 else public_msg)
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
	return CWStateCodec.state_hash(self)
