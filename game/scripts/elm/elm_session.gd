## elm_session.gd —— 运行时会话：以 Elm 状态机为核心的对局门面
##
## 旧 `CWGame`（可变状态 + 过程式结算 + 自持桥）在 Elm 化后的**对等替代**：项目里所有
## 「跑对局」的地方（平衡模拟 / dump / UI 场景）统一改用本会话，不再 new CWGame。
##
## 职责：
##   · 持有 state（单一来源）+ 每玩家决策桥（多桥，pid -> bridge）
##   · 驱动：step()/run_full() 读 state 决定发 step/decision msg，喂 ElmGame.update
##   · 查询：对齐旧 CWGame 的只读查询（tile/player/cell_of/living_cells/...），全读 state 快照
##   · 演出：roll_show 收集进演出队列 + 可挂 on_roll 回调（表现层异步播，逻辑不等）
##
## 桥接口：`ask(state, req) -> int`（吃 state 快照 + req，纯函数决策，见 elm_heuristic.gd）。
## 铁律不变：本会话**不修改 state**（state 只被 ElmGame.update 产出）；不发 game 引用给桥。
class_name ElmSession
extends RefCounted

var state: Dictionary = {}
var chain: Array = []          # state 链（每 step 一个，悔棋/回放/差分的基础）
var rolls: Array = []          # 演出队列（roll_show effects，UI 异步播）
var bridges: Dictionary = {}   # pid -> bridge（ask(state, req) -> idx）
var steps := 0

## 表现层回调（可空）：roll_show / log / ask 各自通知，用于 UI 订阅、演出、日志面板。
var on_roll: Callable = Callable()
var on_log: Callable = Callable()
var on_ask: Callable = Callable()


## 建立一局：faction_list 行动顺序、seed、tune（null=规则原文 CWTuning）。
## bridge_factory：Callable，无参返回一个桥对象；默认启发式 AI 桥（全部玩家）。
func init_game(faction_list: Array, seed_value: int, tune = null,
		bridge_factory: Callable = Callable()) -> void:
	state = ElmGame.make_initial_state(seed_value, faction_list,
		tune if tune != null else CWTuning.new())
	chain = [state]
	rolls = []
	bridges = {}
	steps = 0
	for pid in state["order"]:
		var b: RefCounted
		if bridge_factory.is_valid():
			b = bridge_factory.call()
		else:
			b = ElmHeuristicBridge.new()
		bridges[pid] = b


## 推进一步（一次 update）：停在 ask 就向对应玩家桥要决策，否则发 step。
## 返回 r = ElmGame.update 的 { "state", "effects" }（已把 effects 分流到队列/回调）。
func step() -> Dictionary:
	var msg: Dictionary
	if state["pending"] != null:
		var req: Dictionary = state["pending"]["req"]
		var b = bridges.get(state["pending"]["pid"])
		var idx := 0
		if b != null:
			idx = b.ask(state, req)
		msg = { "kind": "decision", "idx": clampi(idx, 0, req["options"].size() - 1) }
	else:
		msg = { "kind": "step" }
	var before_logs: int = state["logs"].size()
	var r := ElmGame.update(state, msg)
	state = r["state"]
	chain.append(state)
	for fx in r["effects"]:
		match fx["kind"]:
			"roll_show":
				rolls.append(fx)
				if on_roll.is_valid():
					# 演出通知（不等）：表现层异步播，逻辑继续
					on_roll.call(fx)
			"log":
				pass  # 实时日志统一走下面的增量 diff（含直接写 state 无 effect 的，单一来源）
			"ask":
				if on_ask.is_valid():
					on_ask.call(fx)
	# 兜底：有些 add_log 直接写 state.logs 没产 effect（如 gain_memory 的升级日志），
	# 用增量 diff 保证 UI 不漏任何一条。
	if on_log.is_valid():
		for i in range(before_logs, state["logs"].size()):
			on_log.call(state["logs"][i])
	steps += 1
	return r


## 推到 DONE 或撞 max_steps 护栏（防死循环），返回终局摘要。
func run_full(max_steps := 30000) -> Dictionary:
	while String(state["pc"]) != "DONE" and steps < max_steps:
		step()
	return result()


## 终局/当前摘要：结果字段对齐旧 CWGame（winner/win_kind/win_reason/round_no/logs）。
func result() -> Dictionary:
	return {
		"state": state, "chain": chain, "steps": steps,
		"winner": state["winner"], "win_kind": state["win_kind"],
		"win_reason": state["win_reason"], "round_no": state["round_no"],
		"logs": state["logs"], "rolls": rolls,
	}


# ============ 只读查询（对齐旧 CWGame，全读 state 快照）============

func tile(c: Vector2i) -> Dictionary: return state["tiles"][c]
func player(pid: int) -> Dictionary: return state["players"][pid]
func cell_of(pid: int) -> Dictionary: return state["cells"][state["players"][pid]["cell_id"]]
func living_cells(faction: int = -1) -> Array: return ElmGame.living_cells(state, faction)
func cells_at(pos: Vector2i, faction: int = -1) -> Array:
	return ElmGame.cells_at(state, pos, faction)
func is_cancerous(c: Vector2i) -> bool: return ElmGame.is_cancerous(state, c)
func count_tissue(tissue: int) -> int: return ElmGame.count_tissue(state, tissue)
func blocks_of(pred: Callable) -> Array: return ElmGame.blocks_of(state, pred)
func cell_name(c: Dictionary) -> String: return ElmGame.cell_name(state, c)
func state_hash() -> String: return ElmGame.state_hash(state)


# ---- 标量快照（旧 CWGame 同名字段）----

var round_no: int:
	get: return state["round_no"]
var memory: int:
	get: return state["memory"]
var immune_level: int:
	get: return state["immune_level"]
var winner: int:
	get: return state["winner"]
var win_kind: String:
	get: return state["win_kind"]
var win_reason: String:
	get: return state["win_reason"]
var pc: String:
	get: return state["pc"]
var pending: Dictionary:
	get: return state["pending"]
var logs: Array:
	get: return state["logs"]   # 日志单一来源 = state.logs（含直接写 state 无 effect 的）
var cells: Array:
	get: return state["cells"]
var players: Array:
	get: return state["players"]
var order: Array:
	get: return state["order"]
var tiles: Dictionary:
	get: return state["tiles"]
var tune: Dictionary:
	get: return state["tune"]


## 断开引用（桥不持 game，主要清掉会话自身的 state 引用；保持旧 dispose() 调用习惯）。
func dispose() -> void:
	bridges.clear()
	chain = []
	state = {}
