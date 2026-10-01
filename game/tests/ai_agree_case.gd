## ai_agree_case.gd —— 「AI 对拍模式默认关、线上行为一行不变」的共用用例（换内核 P3）
##
## headless_test.gd 的 t_ai_agree_default_off 与录基线的一次性脚本**各 preload 同一份**：
## 基线是在加对拍模式**之前**的 GD 代码上录的（2026-10-01，提交 44d731d 的 heuristic_bridge / mech_*），
## 加了之后同一段代码在默认（关）状态下跑出来的局面哈希必须逐位相同。
## 混三档：启发式 / 意图（MechBridge）/ 搜索（MechBridge use_search + use_fit_eval）各占席位 —— t_ai_same_hash 只覆盖启发式 / MC / MCTS，
## 照不到意图与搜索两档，而对拍模式改的正是这两档的代码。
## 不碰 agree_rng.gd（录基线时它还不存在），没有 class_name。
extends RefCounted

const PLAYERS := 4
const SEED := 20261001
## 顶层问答步数封顶：搜索档一问几百毫秒，四人局 48 步约 5 秒；前 N 步只要有一步的决策变了，哈希立刻散开
const MAX_STEPS := 48


static func run_mixed() -> Dictionary:
	## mech_dist 的距离场缓存是跨局共享的静态量（键里没有组织状态）：同一进程里先跑过的局会留下一份，
	## 撞上同一个键就读到别人的场。清掉再跑，基线与测试才是同一个起点
	var dist: GDScript = load("res://scripts/ai/mech/mech_dist.gd")
	dist._ck = ""
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[PLAYERS], SEED)
	var heur := CWHeuristicBridge.new()
	heur.game = g
	var intent := MechBridge.new()
	intent.game = g
	var search := MechBridge.new()
	search.game = g
	search.use_search = true
	search.use_fit_eval = true
	MechBridge._fit_linear_on = false
	var seats: Array = [search, heur, intent, search]
	for pid: int in g.order:
		g.bridges[pid] = seats[pid % seats.size()]
	var steps := 0
	while steps < MAX_STEPS:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		await g.step(await g.ask(int(req["pid"]), req))
		steps += 1
	var out := { "steps": steps, "round_no": int(g.round_no), "hash": g.state_hash() }
	g.dispose()
	return out
