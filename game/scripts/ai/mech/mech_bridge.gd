## mech_bridge.gd —— 意图 AI 桥：action 用意图规划器选迁移，其余回落启发式
##
## 第一版意图级 AI：把 MechIntent（生成候选 → 评估「做完后的地图能量」→ 选最好）
## 接进 CWBridge。只接管 action 顶层询问：癌方用癌方 scorer、免疫方用免疫方 scorer，
## 卡牌 / 中途询问 / 开局 / 复活等一律回落启发式（super.ask）。
##
## 确定性：best_by 对并列取第一个最大值；evaluate_path 快照→试走→读数→回滚，
## rng 状态随快照复原 —— 同种子同配置同决策，可复现。
##
## ⚠ scorer 是**品味**不是规则：权重先全 1，等强度对局（mech_strength.gd）标定。
## ⚠ 免疫侧 metrics 尚不如癌侧完整（缺压迫/免疫视角杠杆），强度对局会暴露。
class_name MechBridge
extends CWHeuristicBridge

## **true = 用数据拟合位置估值（MechValue.position_eval，2026-09-20 估值体检产物）**
## 代替旧手拍 scorer；AI 档名 "mev"（mech 桥 + 拟合估值）。旧行为（false）不变。
var use_fit_eval := false
## true 且 use_fit_eval：用线性版 position_eval_linear（对照「log 阻尼坑癌」实验，档名 "mel"）。
var fit_linear := false
static var _fit_linear_on := false
## true = action 用意图级 alpha-beta（depth=SEARCH_DEPTH，叶=拟合估值），否则旧贪心 best_by。
var use_search := false
## 计划缓存（pid → {round, actions, i}）：同细胞同回合只搜一次，后续询问执行
## 叶模拟时的既定序列（见 search_best 的 plan 捕获）。回合更替自动作废。
var _plan := {}
## 计划视野：只承诺前 2 手（搜索手+1 手续走）。2026-09-20 实测教训：整回合缓存
## 把搜索覆盖从「每手一搜」降到「一回合一搜」，续走启发式的弱势被放大——
## 自对弈癌胜率 54%→33%（再叠威胁 v2 一度 4%）。2 手足以断「等值格振荡」，
## 之后重搜恢复覆盖。 Steps: 振荡的周期是 1 手（A→B→A），2 手承诺即断。
## 参数扫描注入口(0=用默认): 云上网格搜索用。已部署调优值: topk=6/hz=1
## (2026-09-20 云扫描13配置x48局 + 大样本确认432局55.6% vs 默认44.5%)。
static var TOPK_OVERRIDE := 0
static var HORIZON_OVERRIDE := 0
static var W_THREAT := 15.0
static var THREAT_REACH := 60
const PLAN_HORIZON := 1
const SEARCH_DEPTH := 2
## 线程化：true 时整棵搜索树（search_best / best_by）抛给副线程，主线程只出帧等结果。
## 和 MC / MCTS 同一前提：image 全用同步启发式桥 → 协程零真挂起，worker 可整体跑到底。
## 默认关；`use_threading=true` 时结果与同步路径逐位一致（除 `_fit_linear_on` 走 cfg 快照）。
var use_threading := false


func ask(req: Dictionary) -> int:
	## 【计划缓存快路径】2026-09-20 人机实测修复"无意义走动"：
	## v2 每问重搜且假设"本回合剩余由启发式打完"，但真实执行者是下一轮搜索，
	## 等值格之间互相追逐 → 来回抖。现在执行 = 叶评估时的模拟序列。
	var _pid := int(req.get("pid", -1))
	var _pc: Dictionary = _plan.get(_pid, {})
	if not _pc.is_empty():
		if int(_pc["round"]) == game.round_no:
			var _acts: Array = _pc["actions"]
			var _i: int = int(_pc["i"])
			var _hz: int = HORIZON_OVERRIDE if HORIZON_OVERRIDE > 0 else PLAN_HORIZON
			if _i < _acts.size() and _i < _hz:
				var _pidx := _find_plan_option(req, _acts[_i])
				if _pidx >= 0:
					_pc["i"] = _i + 1
					return _pidx
				## 计划内的 action 对不上 = 局面已分叉（模拟外的询问改了状态）→ 作废。
				## 非.action 询问（roll/pick 等）不作废，让启发式答，计划留着。
				if str(req.get("kind", "")) == "action":
					_plan.erase(_pid)
			else:
				_plan.erase(_pid)   ## 序列走完
		else:
			_plan.erase(_pid)       ## 回合已更替
	if req["kind"] == "action":
		var fac: int = game.player(req["pid"])["faction"]
		## ⚠ **评估只许在独立副本上跑，真 game 一行不动**（Kevin 2026-09-19：意图档「动画乱套或重复播放」）。
		## 第一版把 MechIntent 的「快照→试走→回滚」直接跑在真 game 上：每一次试走的 `g.step()` 都是真步——
		## 内核消费者把它推成 roll / result / fx / feed 条目、界面照演，回滚之后真的那一步又演一遍；
		## 日志与出牌列也被假动作污染。与 MC / MCTS 同一条路：从快照造一份 `sim_quiet` 的副本
		## （陪练全是同步启发式，零真挂起），确定性照旧（rng 随快照复原）。护栏 `t_mech_bridge_quiet`。
		## 【alpha-beta 分支同规矩】search_best / best_by 的整棵树也只跑 image，真局零污染。
		## 【线程化】image 全用同步启发式桥 → 协程零真挂起，评估就能整体抛给副线程
		## （use_threading=true 时），主线程只在 _threaded_pick 里出帧等结果 —— 和 MC / MCTS 同一套路。
		var cfg := {
			"pid": req["pid"], "my_faction": fac,
			"use_search": use_search, "use_fit_eval": use_fit_eval,
			"fit_linear": _fit_linear_on,
			"fixed_lineup": fixed_lineup, "lifecare": lifecare,
			"sim_no_lifecare": false, "depth": SEARCH_DEPTH, "top_k": 4,
		}
		var best: Dictionary
		if use_threading:
			best = await _threaded_pick(game.snapshot(), cfg)
		else:
			best = await _pick_sync(game.snapshot(), cfg)
		if use_search and best.has("plan"):
			## 缓存整回合执行序列（含第一手），本回合后续询问走快路径
			_plan[_pid] = { "round": game.round_no, "actions": best["plan"], "i": 0 }
			if not best["plan"].is_empty():
				var _pidx2 := _find_plan_option(req, best["plan"][0])
				if _pidx2 >= 0:
					_plan[_pid]["i"] = 1
					return _pidx2
			_plan.erase(_pid)   ## 空序列 / 首手对不上 → 回落启发式
		elif best.has("path") and best["path"].size() > 0:
			var idx := _find_move_option(req, best["path"][0])
			if idx >= 0:
				return idx
	return await super.ask(req)


## —— 同步 / 副线程挑选入口（2026-09-20 线程化，与 MC / MCTS 同一套路）——

## 同步路径：主线程协程里直接跑（无线程构建 / SceneTree 拿不到时退回这里）。
## image 全用同步启发式桥 → cw_mech_work 的协程零真挂起，await 一路到底。
func _pick_sync(snap: Dictionary, cfg: Dictionary) -> Dictionary:
	return await cw_mech_work(snap, cfg)


## 副线程路径：提交一个静态入口（绝不捕获主桥实例），主线程只在释放点出帧等结果。
func _threaded_pick(snap: Dictionary, cfg: Dictionary) -> Dictionary:
	## 与 MC / MCTS 相同的护栏：无线程构建 / 拿不到 SceneTree 时退回同步路径，绝不忙等。
	## （`threads` 这个 feature 标签只在带线程的构建上有；万一在此类构建上不识别 use_threading
	##  却起步线程且回调不同步，holder 永远填不上，while 就死等 → 干脆一开头就认一次。）
	if not OS.has_feature("threads"):
		return await _pick_sync(snap, cfg)
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		push_warning("MechBridge._threaded_pick: 拿不到 SceneTree，退回同步路径")
		return await _pick_sync(snap, cfg)
	var holder := { "result": {} }
	var box := RefCounted.new()   ## 仅作 Thread 入参的稳定对象；worker 不读写它
	var t := Thread.new()
	## 静态入口 + bind：Thread 只拿到快照数据与 cfg，接触不到主 game / UI / 场景树。
	t.start(cw_mech_thread_entry.bind(holder, snap, cfg, box))
	while holder["result"].is_empty():
		await tree.process_frame   ## 主线程出帧等结果，不被算力堵死
	t.wait_to_finish()
	return holder["result"]


## 副线程真正的入口：worker 建独立对局、跑评估、写 holder，全程碰不到主 game / UI / 场景树。
static func cw_mech_thread_entry(holder: Dictionary, snap: Dictionary, cfg: Dictionary, _box: RefCounted) -> void:
	var best: Dictionary = await cw_mech_work(snap, cfg)
	holder["result"] = best


## 核心工作：由快照建独立 image（纯启发式桥），跑 search_best / best_by，返回 best。
## 只依赖 snap 与 cfg，不碰外层 game / 场景树 → 主线程协程与副线程 work 都能 await 到同一结果。
static func cw_mech_work(snap: Dictionary, cfg: Dictionary) -> Dictionary:
	var image: CWGame = CWMonteCarloBridge._build_image_static(snap, {
		"fixed_lineup": bool(cfg.get("fixed_lineup", false)),
		"lifecare": bool(cfg.get("lifecare", false)),
		"sim_no_lifecare": bool(cfg.get("sim_no_lifecare", false)),
	})
	var pid: int = int(cfg["pid"])
	var fac: int = int(cfg["my_faction"])
	var intent := MechIntent.new()
	var best: Dictionary
	if bool(cfg["use_search"]):
		## 叶估值 = 拟合 E(s)，**按搜索方阵营翻号一次**（树内所有值统一搜索方视角，
		## 节点 max/min 由 _ab_line 按行动方阵营处理）——v1 按 metrics.faction 翻号
		## 会让 alpha/beta 跨节点量纲不一致，v2 修正。
		var my_fac: int = fac
		var lin: bool = bool(cfg.get("fit_linear", false))
		var leaf: Callable = func(m: Dictionary) -> float:
			var ev: float = MechValue.position_eval_linear(m) if lin else MechValue.position_eval(m)
			return ev if my_fac == CWData.Faction.IMMUNE else -ev
		best = await intent.search_best(image, pid, leaf, int(cfg["depth"]), int(cfg["top_k"]))
	else:
		var scorer: Callable
		if bool(cfg.get("use_fit_eval", false)):
			scorer = MechBridge._fit_score
		else:
			scorer = MechBridge._cancer_score if fac == CWData.Faction.CANCER \
				else MechBridge._immune_score
		best = await intent.best_by(image, pid, scorer)
	image.dispose()
	return best


## 癌方视角：地盘 + 供给 + 能量差，再叠局部与战略维度：
##   · 固化潜力：蹲在接近固化的癌格上加分（造复活点/永久地盘/全图供给加成）；
##   · 生存：行动细胞能量 < 2.0 时重罚（癌能量低=随时被免疫打死）；
##   · 免疫威胁：贴免疫（dist<3）罚分（别送死——癌细胞会被免疫迁入攻击）；
##   · 战略三维（2026-09-20）：击杀 / 压迫 / 封骨髓。癌方没有走过去攻击的对称机制，
##     减免疫能量靠【微环境压迫】——所以「追杀」= 让免疫被回合末压迫压死。
## ⚠ 实验记录：曾试「供给×剩余回合折现」→ 移动率升但胜率 27.5%→15%，已回退（30%）。
## ⚠ B+A 教训：只加维度不调权重没用——这次是「真有战略结果（击杀/封髓）才重权」。
## 权重是先验估计，待强度对局标定。

## 击杀一个免疫的重权：移除一个行动者、强制复活延迟/耗骨髓、封完骨髓则永久。
const W_KILL := 50.0
## 持续压迫每点（十分能量/回合的剥削）的权重——回合末转化为免疫能量损失。
const W_PRESSURE := 2.0
## 封一个骨髓复活点的权重——配合击杀才致命，单独是中等战略价值。
const W_MARROW := 15.0

static func _cancer_score(m: Dictionary) -> float:
	var s := float(m["win_progress"]) + float(m["cancer_supply"]) \
		+ float(m["cancer_energy"]) - float(m["immune_energy"])
	## 固化潜力：蹲在 1~2 回合内能固化的癌格上加分
	var sr: int = int(m.get("actor_solid_rounds", -1))
	if sr >= 0 and sr <= 2:
		s += float(3 - sr)
	## 生存：能量 < 2.0（十分位 20）危险，随缺口重罚
	var ae: int = int(m.get("actor_energy", 0))
	if ae < 20:
		s -= float(20 - ae) * 2.0
	## 免疫威胁 v2（2026-09-20）：能量距离（MechDist）替代六边形 dist——
	## 「贴免疫」≠「会被打」：真实威胁 = 免疫**走过来要多少能量**（地形癌化决定）
	## × 自己还有没有血扛（用户实测口径：送死由免疫能量/地图癌化/自己血量共决）。
	## reach < 6.0 能量才构成威胁；危险度随自身能量衰减（≥4.0 不躲）。
	## 权重先验（峰值 15 = 旧 (3-d)*5 的峰值），待强度对局标定。
	var reach: int = int(m.get("actor_immune_reach_cost", 9999))
	if reach < THREAT_REACH:
		var danger: float = 1.0 - float(reach) / float(THREAT_REACH)
		var hp_scale: float = clampf((40.0 - float(ae)) / 30.0, 0.0, 1.0)
		s -= danger * hp_scale * W_THREAT
	## 战略三维：击杀 / 压迫 / 封骨髓（真有结果才重权）
	s += float(m.get("immune_lethal_count", 0)) * W_KILL
	s += float(m.get("immune_pressure_total", 0)) * W_PRESSURE
	s += float(m.get("cancer_marrows", 0)) * W_MARROW
	return s


## 免疫方视角：与癌方相反（-癌地盘 -癌供给）+ 免疫能量银行 + 记忆进度。权重先全 1。
static func _immune_score(m: Dictionary) -> float:
	return float(m["immune_energy"]) - float(m["cancer_energy"]) \
		- float(m["cancer_supply"]) - float(m["win_progress"]) \
		+ float(m["memory"])


## 零和拟合估值包装：免疫 +E，癌 −E（E 的 log-odds 定义见 MechValue.position_eval）。
## 【实锤实验】补回三个 actor 战术项（权重抄旧手拍基线，非新拍数）——验证
## "mev 贪心崩盘 = 局面估值缺走子战术项" 这一结论：若胜率回升则实锤。
## A/B 开关：fit_tactical=false 跑纯局面版（对照），true 跑补战术版。
@export var fit_tactical := true

static func _fit_score(m: Dictionary) -> float:
	var e: float = MechValue.position_eval_linear(m) if _fit_linear_on else MechValue.position_eval(m)
	return e if int(m.get("faction", 0)) == CWData.Faction.IMMUNE else -e
	## 【实锤记录 2026-09-20】曾试补三个 actor 战术项(solid_rounds/energy/min_dist, 旧权重×0.1/×1)：
	##   全量纲 免10-2→4-8、0.1x →5-7，均比纯局面版差 → "mev 贪心弱=缺战术项"假设被否。
	##   真因：走子要"动作导向"即时回报(净化/攻击+分)，局面估值是"状态导向"终局预测 ——
	##   状态估值只能当搜索叶(见 MechValue.position_eval 头注)，不能喂贪心。

## actor 战术项（与旧 _cancer_score 同权重×TACTICAL_SCALE）：走子价值 = 局面价值 + 本手战术
## TACTICAL_SCALE=0.1：旧项量级(±10)直接叠 log-odds(±几)会淹没局面估值（实测免疫 10-2→4-8 崩），
## 缩到 0.1 让战术只做"同局面下的次序微调"，不覆盖战略判断。
const TACTICAL_SCALE := 0.1

static func _tactical_bonus(m: Dictionary) -> float:
	var t := 0.0
	var sr: int = int(m.get("actor_solid_rounds", -1))
	if sr >= 0 and sr <= 2:
		t += float(3 - sr)
	var ae: int = int(m.get("actor_energy", 0))
	if ae < 20:
		t -= float(20 - ae) * 2.0
	var d: int = int(m.get("actor_min_immune_dist", 999))
	if d < 3:
		t -= float(3 - d) * 5.0
	return TACTICAL_SCALE * t


## 在当前询问里找与缓存动作匹配的选项（kind 一致 + 语义键匹配，容忍 cost 等漂移）。
func _find_plan_option(req: Dictionary, action: Dictionary) -> int:
	if str(req.get("kind", "")) != str(action.get("kind", "")):
		return -1
	var opts: Array = req.get("options", [])
	for i in opts.size():
		if _action_matches(opts[i]["data"], action["data"]):
			return i
	return -1


## 语义键匹配：act 必同；有 to/card/cid 的键逐一比对，其余（end/mutate/draw）act 同即命中。
static func _action_matches(d: Dictionary, want: Dictionary) -> bool:
	if str(d.get("act", "")) != str(want.get("act", "")):
		return false
	if want.has("to") and d.get("to", Vector2i(99999, 99999)) != want["to"]:
		return false
	if want.has("card") and str(d.get("card", "")) != str(want["card"]):
		return false
	if want.has("cid") and int(d.get("cid", -1)) != int(want["cid"]):
		return false
	return true


func _find_move_option(req: Dictionary, to: Vector2i) -> int:
	for i in req["options"].size():
		var d: Dictionary = req["options"][i]["data"]
		if d.get("act", "") == "move" and d.get("to", Vector2i(-999, -999)) == to:
			return i
	return -1
