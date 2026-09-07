## monte_carlo_bridge.gd —— 扁平蒙特卡洛桥：逐个候选行动「试走 → 粗跑几步 → 估值」，挑最好的
##
## 只接管 kind == "action" 的顶层询问 —— 那是分支最宽、最值得花算力的决策；
## 落子/复活等低频询问以及所有中途选择沿用启发式（CWHeuristicBridge 是基类）。
## 「action」询问只会出现在 pending 边界上（run_game 就是在那里问的），
## 那一刻没有悬着的协程，快照是安全的 —— 这正是流程状态机设计时要的能力。
##
## 推演改成 **离线程 + 独立副本**（2026-09-XX，修「较强 AI 卡前端」）：
##   主桥只做三件事 ——
##   ① 在 pending 边界上抓一份快照（那时没有悬着的协程）；
##   ② 把快照 + 候选 + 参数交给一个**独立的 CWGame 副本**
##      （`new()→init()→restore()`，全部引擎模块纯 RefCounted、不碰场景树），
##      在副本里跑全部 rollout，主 `game` 一行都不动；
##   ③ 等结果，把最佳下标答回去。
## 副本是纯数据，因此可以交给 `Thread` 在副线程跑 —— 主线程只提交 + await，
## 不再被连续算力整段堵住。开不开线程，评估本身是**同一份代码**、结果逐位一致。
##
## 确定性：推演用的随机流由快照里的 rng 状态**派生**（见 _playout_seed），
## 候选之间共用同一条流，同一候选的多条 playout 各用一条。
## 同种子同局面必然同答案。**推演不能用真实的 rng 状态**：那会让 AI 提前看到
## 自己这一步的真骰子（2026-09-01 前的旧行为）。
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

## 是否把推演放进副线程。只有真对局的较强 AI 才开（CWMatch 装配时拨）。
## 无头测试 / 平衡模拟里开线程没意义（每次决策多付一次线程开销，且绕圈验证跑不干净），
## 默认关；`use_threading=true` 时结果与同步路径逐位一致。
var use_threading := false


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
	var cfg := {
		"rollouts": rollouts, "horizon": horizon, "max_sim_steps": max_sim_steps,
		"pid": pid, "my_faction": my_faction,
		"fixed_lineup": fixed_lineup,
		"lifecare": lifecare, "death_cost": death_cost, "sim_no_lifecare": sim_no_lifecare,
	}
	var res: Dictionary
	if use_threading:
		res = await _threaded_eval(snap, options, cfg)
	else:
		res = await _eval_sync(snap, options, cfg)
	_last_stats = res.get("stats", {})
	return int(res.get("best", 0))


## 同步路径：在调用方协程里建副本、跑评估、（不碰主 game）。给无头测试 / 平衡模拟用。
func _eval_sync(snap: Dictionary, options: Array, cfg: Dictionary) -> Dictionary:
	var copy := _build_image_static(snap, cfg)
	var res: Dictionary = await _evaluate_on(copy, options, cfg)
	copy.dispose()
	return res


## 副线程路径：提交一个静态入口（绝不捕获主桥实例），主线程只在释放点让帧。
func _threaded_eval(snap: Dictionary, options: Array, cfg: Dictionary) -> Dictionary:
	## 主线程要用主循环的 process_frame 让帧（桥不是 Node、game 是 RefCounted）。
	## 真对局与无头 SceneTree 脚本都是 SceneTree；拿不到就退回同步路径，绝不忙等。
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		push_warning("CWMonteCarloBridge._threaded_eval: 拿不到 SceneTree，退回同步路径")
		return await _eval_sync(snap, options, cfg)
	var holder := { "result": {} }
	var box := RefCounted.new()   ## 仅作 Thread 入参的一个稳定对象；worker 不读写它
	var t := Thread.new()
	## 静态入口 + bind：Thread 只拿到数据与 holder，接触不到主 game / UI / 场景树。
	t.start(cw_mc_thread_entry.bind(holder, snap, options, cfg, box))
	while not _result_ready(holder):
		await tree.process_frame   ## 主线程出帧等结果，不被算力堵死
	t.wait_to_finish()
	return holder["result"]


func _result_ready(holder: Dictionary) -> bool:
	return not holder["result"].is_empty()


## 线程真正的入口：这个静态函数在线程上建独立对局、跑评估、写 holder。
static func cw_mc_thread_entry(holder: Dictionary, snap: Dictionary, options: Array, cfg: Dictionary, _box: RefCounted) -> void:
	var copy := _build_image_static(snap, cfg)
	var res: Dictionary = await _evaluate_on(copy, options, cfg)
	holder["result"] = res
	copy.dispose()


## 由快照建一份独立对局：全部状态来自 snap，全程不依赖外层 game。
static func _build_image_static(snap: Dictionary, cfg: Dictionary) -> CWGame:
	var faction_list: Array = []
	for pid in snap["order"]:
		faction_list.append(int(snap["players"][pid]["faction"]))
	var copy := CWGame.new()
	copy.init(faction_list, 0)      ## init 的种子会被 restore 里的 snap["rng"] 覆盖
	copy.tune.cancer_types = (snap.get("tune", {})).get("cancer_types", []).duplicate()
	copy.restore(snap)
	## 副本的 bridges：全部挂同一个纯启发式陪练；副本里没有 UI 桥，show_roll/notice 全静默。
	var sim := CWHeuristicBridge.new()
	sim.game = copy
	sim.fixed_lineup = bool(cfg.get("fixed_lineup", false))
	sim.lifecare = bool(cfg["lifecare"]) and not bool(cfg.get("sim_no_lifecare", false))
	for p in copy.order:
		copy.bridges[p] = sim
	copy.sim_quiet = true
	return copy


## 核心评估：逐候选 × 逐 rollout，快照→试走→粗跑→估值→回滚。
## **只依赖 `image`（一份完全自洽的 CWGame）与 cfg**，绝不碰外层 game / 场景树。
## 它本身是协程，但只在 image 的桥全为同步启发式时才会一路跑到底（零真挂起），
## 所以既能在主线程协程里直接 await，也能在副线程里 await 到同一结果。
static func _evaluate_on(image, options: Array, cfg: Dictionary) -> Dictionary:
	var my_faction: int = int(cfg["my_faction"])
	var max_steps: int = int(cfg["max_sim_steps"])
	var rollouts_n: int = int(cfg["rollouts"])
	var horizon_n: int = int(cfg["horizon"])
	var sim := CWHeuristicBridge.new()
	sim.game = image
	sim.fixed_lineup = bool(cfg.get("fixed_lineup", false))
	sim.lifecare = bool(cfg["lifecare"]) and not bool(cfg.get("sim_no_lifecare", false))
	var saved_bridges: Dictionary = image.bridges.duplicate()
	var sim_bridges := {}
	for p in saved_bridges:
		sim_bridges[p] = sim
	image.bridges = sim_bridges
	image.sim_quiet = true

	var best := 0
	var best_score := -(1 << 60)
	var stats := {
		"candidates": options.size(), "candidates_probed": 0, "snapshots": 1,
		"restores": 0, "rollouts": 0, "sim_steps": 0,
		"max_sim_steps": max_steps, "budget_exhausted": false,
	}
	for i in options.size():
		if _budget_exhausted(stats, max_steps):
			break
		if not _worth_probing(image, options[i]["data"]):
			continue
		stats["candidates_probed"] += 1
		var total := 0
		var snap: Dictionary = image.snapshot()
		for r in rollouts_n:
			if _budget_exhausted(stats, max_steps):
				break
			image.rng.seed = _playout_seed(snap["rng"], r)
			await image.step(i)
			stats["sim_steps"] += 1
			stats["rollouts"] += 1
			var plies := 0
			while plies < horizon_n and not image.is_over() and not _budget_exhausted(stats, max_steps):
				var rq: Dictionary = await image.pending()
				if rq.is_empty():
					break
				var idx: int = await sim.ask(rq)
				await image.step(idx)
				plies += 1
				stats["sim_steps"] += 1
			total += CWEval.score(image, my_faction, bool(cfg["death_cost"]))
			image.restore(snap)
			stats["restores"] += 1
		if total > best_score:
			best_score = total
			best = i

	stats["budget_exhausted"] = _budget_exhausted(stats, max_steps)
	image.sim_quiet = false
	image.bridges = saved_bridges
	sim.game = null   ## 断环：sim 持 image、image.bridges 持 sim
	return { "best": best, "stats": stats }


static func _budget_exhausted(stats: Dictionary, max_steps: int) -> bool:
	return max_steps > 0 and int(stats["sim_steps"]) >= max_steps


## 推演用的随机流：由「快照里的 rng 状态 + 第几条 playout」派生，**刻意不等于真实的 rng 状态**。
##
## 2026-09-01 之前这里直接沿用快照里的真状态（第 r 条先烧 r 个随机数去相关）。
## 那等于让 AI 先用**真骰子**把这一步玩一遍再决定：rollouts=1 时，候选行动的即时结果
## （攻击成败、大成功与否、抽到哪张卡）对它是精确已知的 —— 一个只有 AI 才有的信息优势。
## 派生之后它和人一样只能按概率抽样。同种子同局面仍然同答案（派生是确定性的），
## 候选之间仍共用同一条随机流。用 hash() 而不是算术偏移：rng 是 LCG，「状态 + 常数」
## 的两条流在头几个数上会有结构性相关。
static func _playout_seed(real_state: int, r: int) -> int:
	return hash([real_state, r])


## 弃置只在手牌满（抽卡选项已消失）时才值得占一个候选名额 ——
## 腾位换抽是它唯一的赢面，其余时候评它纯属烧算力
static func _worth_probing(image, d: Dictionary) -> bool:
	if d.get("act", "") != "discard":
		return true
	## 谁在评估这个候选（这一问问的就是他）——找到他的 cell 看手牌。
	for cell in image.cells:
		if cell["pid"] == image.current_pid:
			return cell["hand"].size() >= CWData.HAND_MAX
	return true
