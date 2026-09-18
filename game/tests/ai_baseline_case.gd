## ai_baseline_case.gd —— 护栏⑦ t_ai_same_hash 的共用用例表与跑法（口径二 · 批 1 步 6+8）
##
## headless_test.gd 与 record_ai_baseline.gd **各 preload 同一份**：录基线和比基线必须逐字是同一段代码，
## 否则「与改动前逐位相同」测的是两套东西。没有 class_name（同 guide_watch.gd 的理由：不用先 --import，也能热更）。
##
## 装配照抄 match.gd:_wire_bridge 的三档，但一个界面节点都不碰：human_pids 为空 ⇒ CWUIBridge.ask 全走 AI 那条，
## _ask_human 根本进不去。批 1 把 bridge.game = game 换成 attach_engine 之后这里仍写 b.game = g ——
## attach_engine 做的就是这一件事，两边都成立，基线才录得出来。
extends RefCounted

## 三档 AI × 两种人数 = 6 个用例。name 就是基线 JSON 里的键
const CASES := [
	{ "name": "heur4", "players": 4, "seed": 20260919, "level": 0 },
	{ "name": "heur6", "players": 6, "seed": 20260919, "level": 0 },
	{ "name": "mc4", "players": 4, "seed": 20260919, "level": 1 },
	{ "name": "mc6", "players": 6, "seed": 20260919, "level": 1 },
	{ "name": "mcts4", "players": 4, "seed": 20260919, "level": 2 },
	{ "name": "mcts6", "players": 6, "seed": 20260919, "level": 2 },
]

## 步数封顶：MCTS 六人局跑到终局要几分钟，套件受不了。**固定步数一样钉得住标尺** ——
## 前 N 步只要有一步的决策变了，state_hash 立刻散开。改这个数就得重录基线（基线里记着它，t_ai_same_hash 会比）
const MAX_STEPS := 400


static func make_bridge(g: CWGame, level: int) -> CWBridge:
	var b := CWUIBridge.new()
	b.hotseat = false
	b.human_pids = []                      ## 全 AI：不会走 _ask_human，一个界面节点都不需要
	b.enabled = level == 1                 ## 「较强」= 扁平蒙特卡洛（CWUIBridge 的基类本体），也是平衡标尺
	b.max_sim_steps = 192 if level == 1 else 0
	b.use_threading = false                ## 线程只影响墙钟不影响结果；关掉免得基线抖
	b.delay_ms = 0
	b.mcts = null
	if level == 2:
		var tree_ai := CWMCTSBridge.new()
		tree_ai.game = g
		tree_ai.iterations = CWMatch.MCTS_ITERATIONS
		tree_ai.horizon = CWMatch.MCTS_HORIZON
		tree_ai.max_sim_steps = CWMatch.MCTS_MAX_STEPS
		tree_ai.use_threading = false
		tree_ai.delay_ms = 0
		b.mcts = tree_ai
	b.game = g
	return b


## 跑一个用例，返回 {winner, round_no, steps, hash}
static func run_case(case: Dictionary) -> Dictionary:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[int(case["players"])], int(case["seed"]))
	var b := make_bridge(g, int(case["level"]))
	for pid in g.order:
		g.bridges[pid] = b
	var steps := 0
	while steps < MAX_STEPS:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		await g.step(await b.ask(req))
		steps += 1
	var out := { "winner": int(g.winner), "round_no": int(g.round_no),
		"steps": steps, "hash": g.state_hash() }
	g.dispose()
	return out
