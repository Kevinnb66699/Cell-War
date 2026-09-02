## monte_carlo_bridge.gd —— 扁平蒙特卡洛桥：逐个候选行动「试走 → 粗跑几步 → 估值」，挑最好的
##
## 只接管 kind == "action" 的顶层询问 —— 那是分支最宽、最值得花算力的决策；
## 落子/复活等低频询问以及所有中途选择沿用启发式（CWHeuristicBridge 是基类）。
## 「action」询问只会出现在 pending 边界上（run_game 就是在那里问的），
## 那一刻没有悬着的协程，快照是安全的 —— 这正是流程状态机设计时要的能力。
##
## 评估期间把 game.bridges 整个换成一个同步启发式代打：中途询问、别家的回合
## 都由它即时应答，人类桥绝不会在推演里被问到；推演结束 restore + 换回，
## 主线状态零污染（t_rollout_isolation / t_ai_mc 验收这条）。
##
## 确定性：桥自己不引入随机数 —— 推演用的随机流由快照里的 rng 状态**派生**（见 _playout_seed），
## 候选之间共用同一条流，同一候选的多条 playout 各用一条。
## 同种子同局面必然同答案，观战/回放/联机口径与启发式桥一致。
## **推演不能用真实的 rng 状态**：那会让 AI 提前看到自己这一步的真骰子（2026-09-01 前的旧行为）。
class_name CWMonteCarloBridge
extends CWHeuristicBridge

## 每个候选行动跑几条截断 playout / 每条最多推进多少个决策点。
## 缺省值取「人机对战可接受的思考时间」量级；平衡模拟要快就调小 ——
## 或者直接用启发式桥（架构说明书：平衡用 AI 与对战用 AI 不必是同一个）。
var rollouts := 2
var horizon := 40
## 关闸 = 整座桥退化为启发式。给 CWUIBridge 当「AI 强度」开关用：
## 它继承本类，人机对局里由对局配置面板拨这一位。
var enabled := true


func ask(req: Dictionary) -> int:
	if not enabled or req["kind"] != "action" or req["options"].size() <= 1:
		return await super.ask(req)
	return await _mc_pick(req)


func _mc_pick(req: Dictionary) -> int:
	var pid: int = req["pid"]
	var my_faction: int = game.player(pid)["faction"]
	var options: Array = req["options"]
	var snap := game.snapshot()
	## 推演代打：一个实例应付所有 pid（ask 的 req 自带 pid），且绝无演出延迟
	var sim := CWHeuristicBridge.new()
	sim.game = game
	var saved_bridges := game.bridges
	var sim_bridges := {}
	for p in saved_bridges:
		sim_bridges[p] = sim
	game.bridges = sim_bridges
	game.sim_quiet = true

	var best := 0
	var best_score := -(1 << 60)
	for i in options.size():
		if not _worth_probing(pid, options[i]["data"]):
			continue
		var total := 0
		for r in rollouts:
			game.rng.seed = _playout_seed(snap["rng"], r)
			await game.step(i)
			var plies := 0
			while plies < horizon and not game.is_over():
				var rq: Dictionary = await game.pending()
				if rq.is_empty():
					break
				var idx: int = await sim.ask(rq)
				await game.step(idx)
				plies += 1
			total += CWEval.score(game, my_faction)
			game.restore(snap)
		if total > best_score:
			best_score = total
			best = i

	game.sim_quiet = false
	game.bridges = saved_bridges
	sim.game = null   ## 断环：sim 持 game、game.bridges 持本桥，留着会漏
	return best


## 推演用的随机流：由「快照里的 rng 状态 + 第几条 playout」派生，**刻意不等于真实的 rng 状态**。
##
## 2026-09-01 之前这里直接沿用快照里的真状态（第 r 条先烧 r 个随机数去相关）。
## 那等于让 AI 先用**真骰子**把这一步玩一遍再决定：rollouts=1 时，候选行动的即时结果
## （攻击成败、大成功与否、抽到哪张卡）对它是精确已知的 —— 一个只有 AI 才有的信息优势，
## 而且落在掷骰最多的免疫方身上（每回合 3 次攻击、抗体、抽卡），
## 是「MC 系统性高估免疫」（口径 #87）的一个具体来源。
## 派生之后它和人一样只能按概率抽样。同种子同局面仍然同答案（派生是确定性的），
## 候选之间仍共用同一条随机流（同 r 同种子）—— 比较候选时公用随机数能压方差，这点没变。
## 用 hash() 而不是算术偏移：rng 是 LCG，「状态 + 常数」的两条流在头几个数上会有结构性相关。
func _playout_seed(real_state: int, r: int) -> int:
	return hash([real_state, r])


## 弃置只在手牌满（抽卡选项已消失）时才值得占一个候选名额 ——
## 腾位换抽是它唯一的赢面，其余时候评它纯属烧算力
func _worth_probing(pid: int, d: Dictionary) -> bool:
	if d.get("act", "") != "discard":
		return true
	return game.cell_of(pid)["hand"].size() >= CWData.HAND_MAX
