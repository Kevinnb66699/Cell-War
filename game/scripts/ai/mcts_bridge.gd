## mcts_bridge.gd —— 独立蒙特卡洛树搜索桥：第三档「树搜索」AI，不对标尺动手
##
## 与 `CWMonteCarloBridge`（扁平 MC，当前平衡标尺）**并列、互不继承**：
##   · 扁平 MC 每个顶层候选各跑几条独立 playout、取平均 —— 无中间记忆、单步 argmax；
##   · 本桥维护一棵 UCT 树，把算力**聚焦**到被反复证明更好的分支上，越挖越深。
## 2026-09-07 新增，目标是「比专家档更强的第三档」人机 AI。标尺（浅层 MC 互搏）
## 与所有以它为基准的平衡表一律不碰：新桥是纯增量。
##
## 只接管 kind == "action" 且选项 >1 的顶层询问（分支最宽、最值得花算力的决策）；
## 其余（落子/复活/卡牌中途选择/hand 类）全部回落到启发式（CWHeuristicBridge 是基类）。
##
## 确定性三重保证（与扁平 MC 同一些约定）：
##   ① 全程跑在**独立副本**（CWGame+restore）上，主 game 一行不动、不写日志；
##   ② 树内每条边的落点状态是确定的：进一条边前 `image.rng.seed = hash([父路径种子, 动作号])`，
##      于是「从根沿同一串动作走」永远回到同一状态 —— 重访节点可靠、无需转置表；
##   ③ 只有 rollout 尾巴用「快照 rng 状态 + 迭代号」派生的种子（复用扁平 MC 的
##      `_playout_seed`），让同一分支在多次迭代里有随机纵深，但不偷看任何真实骰子。
## 同种子同局面必然同答案。
##
## 线程化：推演放进 `Thread`（较强 AI 人机对局才开），主线程只提交 + await。
## 开不开线程，评估代码是同一条、结果逐位一致（无头测试/平衡模拟不开，绕圈验证跑得干净）。
class_name CWMCTSBridge
extends CWHeuristicBridge

## 树搜索预算：总迭代次数（每迭代 = 一次 选择→扩展→rollout→回传）。别与扁平 MC 的
## `rollouts` 混：那是「每个候选各跑几条」；这里是「整棵树共几条」，花在最有希望的分支上。
var iterations := 100
## 树内从根往下的最大深度（决策点计数）。到点不再深入，就地估值收束。
var horizon := 12
## UCB 探索系数 C。越大越爱逛没探过的分支，越小越死磕当前看起来最好的那条。
var ucb_c := 1.0
## 单次决策允许实际推进的模拟 step 总数上限；0 = 不设上限（只靠 iterations 截）。
var max_sim_steps := 0
## 给基准和诊断读的上一次决策统计（深拷贝，外部改写不了记录）。
var _last_stats: Dictionary = {}
var last_stats: Dictionary:
	get:
		return _last_stats.duplicate(true)
## 关闸 = 整座桥退化为启发式。留给将来的 UI 强度开关（本版未接线，字段先备好）。
var enabled := true
## 推演是否放副线程。只有真对局的较强 AI 才开（CWMatch 装配时拨）；默认关。
var use_threading := false


func set_version(v: String) -> void:
	super.set_version(v)   ## MCTS 不动「v1/v2」的那两条杆（分化/惜命），版本修饰全由基类处理


func version_tag() -> String:
	return "%s-mcts" % AI_VERSION


func ask(req: Dictionary) -> int:
	if not enabled or req["kind"] != "action" or req["options"].size() <= 1:
		return await super.ask(req)
	return await _mcts_pick(req)


func _mcts_pick(req: Dictionary) -> int:
	var pid: int = req["pid"]
	var snap := game.snapshot()
	var cfg := {
		"pid": pid, "my_faction": game.player(pid)["faction"],
		"iterations": iterations, "horizon": horizon, "ucb": ucb_c,
		"max_sim_steps": max_sim_steps,
		"fixed_lineup": fixed_lineup, "lifecare": lifecare,
		"death_cost": true, "sim_no_lifecare": false,
	}
	var res: Dictionary
	if use_threading:
		res = await _threaded_eval(snap, req["options"], cfg)
	else:
		res = await _eval_sync(snap, req["options"], cfg)
	_last_stats = res.get("stats", {})
	return int(res.get("best", 0))


func _eval_sync(snap: Dictionary, options: Array, cfg: Dictionary) -> Dictionary:
	var copy := CWMonteCarloBridge._build_image_static(snap, cfg)
	var res: Dictionary = await _tree_search(copy, options, cfg)
	copy.dispose()
	return res


func _threaded_eval(snap: Dictionary, options: Array, cfg: Dictionary) -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		push_warning("CWMCTSBridge._threaded_eval: 拿不到 SceneTree，退回同步路径")
		return await _eval_sync(snap, options, cfg)
	var holder := { "result": {} }
	var box := RefCounted.new()
	var t := Thread.new()
	t.start(cw_mcts_thread_entry.bind(holder, snap, options, cfg, box))
	while not holder["result"]:
		await tree.process_frame
	t.wait_to_finish()
	return holder["result"]


## 树的主入口（线程上也跑这条）：仅在独立副本上操作。
static func cw_mcts_thread_entry(holder: Dictionary, snap: Dictionary, options: Array, cfg: Dictionary, _box: RefCounted) -> void:
	var copy := CWMonteCarloBridge._build_image_static(snap, cfg)
	var res: Dictionary = await _tree_search(copy, options, cfg)
	holder["result"] = res
	copy.dispose()


## 一棵树的节点 = 一个「动作决策点」的统计槽。
## 不存整份快照 —— 状态由「从根沿同一串动作重走」确定性地重现（见文件头②），省内存。
class _Node:
	extends RefCounted
	var path_seed := 0      ## 决定本节点所有子边种子；由父边种子 + 动作号派生
	var vis := 0            ## 经过本节点的迭代数
	var val := 0            ## 见过的 CWEval 得分之和（UCT 用均值）
	var opts: Array = []    ## 本决策点所有选项（与 children 并行）
	var children: Array = []   ## opts 并行：未扩展的槽为 null


## 核心评估：`image` 必须是一份自洽的独立 CWGame（由 _build_image_static 造）。
## 只依赖 image 与 cfg，绝不碰外层 game / 场景树；协程但零真挂起（树内桥全同步）。
static func _tree_search(image, options: Array, cfg: Dictionary) -> Dictionary:
	var my_faction: int = int(cfg["my_faction"])
	var iters: int = maxi(1, int(cfg["iterations"]))
	var horizon_n: int = int(cfg["horizon"])
	var ucb_cv: float = float(cfg.get("ucb", 1.0))
	var max_steps: int = int(cfg["max_sim_steps"])
	var root_seed: int = image.rng.state
	var root_snap: Dictionary = image.snapshot()

	var stats := {
		"candidates": options.size(), "candidates_probed": 0, "snapshots": 1,
		"restores": 0, "rollouts": 0, "sim_steps": 0,
		"max_sim_steps": max_steps, "budget_exhausted": false,
		"iterations": iters, "nodes": 0,
	}

	var root := _Node.new()
	root.path_seed = hash([root_seed, 0x6D63])   ## 与扁平 MC 的流错开，避免碰撞
	root.opts = options
	root.children.resize(options.size())

	for it in iters:
		if _budget_exhausted(stats, max_steps):
			break
		image.restore(root_snap)
		stats["restores"] += 1
		image.rng.seed = _playout_seed(root_seed, it)
		var node: _Node = root
		var backpath: Array = []    ## 本迭代经过的节点，用于回传 val/vis
		var ply := 0
		## —— 每个迭代：一路向下选，直到「首次扩展」或 horizon/终局。
		while ply < horizon_n and not image.is_over():
			var rq: Dictionary = await image.pending()
			if rq.is_empty():
				break
			## 真分支点才进树。落子/复活/卡牌中途选择分支窄，拿启发式贴着走，不占树。
			## 根动作 restore 后就是第一个 pending（kind=action），也会落进这里 —— 天然一致。
			if rq.get("kind", "") != "action" or rq["options"].size() <= 1:
				await image.step(await _sim(image, rq, cfg))
				stats["sim_steps"] += 1
				ply += 1
				continue
			## 一个分支点。若首次到访，先登记儿子槽（后续迭代复用）。
			if node.opts.is_empty():
				var got: Array = rq["options"]
				node.opts = got
				node.children.resize(got.size())
				stats["nodes"] += 1
			var a: int = _select_child(node, ucb_cv)
			var child: _Node = node.children[a]
			image.rng.seed = hash([node.path_seed, a])   ## ② 子状态确定
			await image.step(a)
			stats["sim_steps"] += 1
			backpath.append(node)
			if child == null:
				## 首次扩展：替这个动作开儿子节点，然后走出分支进入 rollout。
				child = _Node.new()
				child.path_seed = hash([node.path_seed, a])
				node.children[a] = child
				backpath.append(child)
				node = child
				break
			node = child
			stats["candidates_probed"] += 1
			ply += 1
		## 从当前（扩展后或走到头的）状态估一个分，一路回传给本迭代经过的节点。
		var score: int = CWEval.score(image, my_faction, bool(cfg["death_cost"]))
		for n in backpath:
			n.vis += 1
			n.val += score
		stats["rollouts"] += 1
		if _budget_exhausted(stats, max_steps):
			break

	## 从根的已访问动作里挑「平均估值最高」的下标返回。
	var best: int = 0
	var best_avg := -INF
	for i in options.size():
		var c: _Node = root.children[i]
		if c == null or c.vis == 0:
			continue
		var avg := float(c.val) / float(c.vis)
		if avg > best_avg:
			best_avg = avg
			best = i
	stats["budget_exhausted"] = _budget_exhausted(stats, max_steps)
	return { "best": best, "stats": stats }


## UCT 选择：挑「均值 + 探索项」最大的一项。没访问过的按正无穷处理 → 每个动作先试一次，
## 之后再按 UCB 权衡深挖 vs 开拓。纯公式、不掷骰，并列取小下标，保证确定性。
static func _select_child(node: _Node, ucb_cv: float) -> int:
	var best := -1
	var best_v := -INF
	var parent_vis: int = node.vis
	for i in node.children.size():
		var c: _Node = node.children[i]
		var v := INF
		if c != null and c.vis > 0:
			var avg := float(c.val) / float(c.vis)
			v = avg + ucb_cv * sqrt(maxf(log(float(parent_vis + 1.0)), 0.0) / float(c.vis))
		if v > best_v:
			best_v = v
			best = i
	return maxi(best, 0)


## rollout 尾巴（以及树内非分支询问）：从当前状态起，用纯启发式陪练走下一步。
## 与扁平 MC 同一只手（CWHeuristicBridge），保证「陪练怎么打」两边口径一致。
static func _sim(image, rq: Dictionary, cfg: Dictionary) -> int:
	var sim := CWHeuristicBridge.new()
	sim.game = image
	sim.fixed_lineup = bool(cfg.get("fixed_lineup", false))
	sim.lifecare = bool(cfg["lifecare"]) and not bool(cfg.get("sim_no_lifecare", false))
	return await sim.ask(rq)


static func _budget_exhausted(stats: Dictionary, max_steps: int) -> bool:
	return max_steps > 0 and int(stats["sim_steps"]) >= max_steps


## 推演随机流派生，直接复用扁平 MC 的同一约定（不偷看真骰子、迭代间去结构相关）。
static func _playout_seed(real_state: int, it: int) -> int:
	return hash([real_state, it])