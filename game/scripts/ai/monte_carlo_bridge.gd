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
## 单次决策允许实际推进的模拟 step() 总数；0 = 沿用旧版，不设总上限。
## 这是工作量而不是墙钟：同一状态、同一预算在快慢机器上会评估同一批 rollout。
var max_sim_steps := 0
var _last_stats: Dictionary = {}
## 给基准和诊断读的上一次决策统计。返回深拷贝，外部不能改写桥的记录。
var last_stats: Dictionary:
	get:
		return _last_stats.duplicate(true)
## 关闸 = 整座桥退化为启发式。给 CWUIBridge 当「AI 强度」开关用：
## 它继承本类，人机对局里由对局配置面板拨这一位。
var enabled := true
## v2 估值罚死亡（CWEval._death_cost）。set_version("v1") 会关掉它 —— 和分化/惜命一起退回 v1，供交叉验证用。
var death_cost := true
## 推演里的陪练**不**惜命（分化仍随机）：把「陪练惜命」和「估值罚死亡」对 MC 强度的影响分开量。
var sim_no_lifecare := false
var _tag := AI_VERSION


## 版本串 = 基础版本 + 可选修饰，修饰只给 AI 升级的交叉验证用（balance_scan aiver=）：
##   "v2-nodc"     估值不罚死亡（陪练照旧 v2）
##   "v2-simnolc"  陪练不惜命（估值照旧罚死亡）
## 2026-09-02 v2 交叉验证发现 v2 癌在 6 人局比 v1 弱，就是用这两个开关归因的。
func set_version(v: String) -> void:
	super.set_version(v)
	var parts: PackedStringArray = v.split("-")
	death_cost = parts[0] != "v1" and not ("nodc" in parts)
	sim_no_lifecare = "simnolc" in parts
	_tag = v


func version_tag() -> String:
	return _tag


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
	sim.fixed_lineup = fixed_lineup   ## 陪练跟本桥同版本：v1 的推演里跑的是 v1 的启发式
	sim.lifecare = lifecare and not sim_no_lifecare
	var saved_bridges := game.bridges
	var sim_bridges := {}
	for p in saved_bridges:
		sim_bridges[p] = sim
	game.bridges = sim_bridges
	game.sim_quiet = true

	var best := 0
	var best_score := -(1 << 60)
	var stats := {
		"candidates": options.size(), "candidates_probed": 0, "snapshots": 1,
		"restores": 0, "rollouts": 0, "sim_steps": 0,
		"max_sim_steps": max_sim_steps, "budget_exhausted": false,
	}
	for i in options.size():
		if _budget_exhausted(stats):
			break
		if not _worth_probing(pid, options[i]["data"]):
			continue
		stats["candidates_probed"] += 1
		var total := 0
		for r in rollouts:
			if _budget_exhausted(stats):
				break
			game.rng.seed = _playout_seed(snap["rng"], r)
			await game.step(i)
			stats["sim_steps"] += 1
			stats["rollouts"] += 1
			var plies := 0
			while plies < horizon and not game.is_over() and not _budget_exhausted(stats):
				var rq: Dictionary = await game.pending()
				if rq.is_empty():
					break
				var idx: int = await sim.ask(rq)
				await game.step(idx)
				plies += 1
				stats["sim_steps"] += 1
			total += CWEval.score(game, my_faction, death_cost)
			game.restore(snap)
			stats["restores"] += 1
		if total > best_score:
			best_score = total
			best = i

	stats["budget_exhausted"] = _budget_exhausted(stats)
	_last_stats = stats
	game.sim_quiet = false
	game.bridges = saved_bridges
	sim.game = null   ## 断环：sim 持 game、game.bridges 持本桥，留着会漏
	return best


func _budget_exhausted(stats: Dictionary) -> bool:
	return max_sim_steps > 0 and int(stats["sim_steps"]) >= max_sim_steps


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
