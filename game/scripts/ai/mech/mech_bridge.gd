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
const SEARCH_DEPTH := 2


func ask(req: Dictionary) -> int:
	if req["kind"] == "action":
		var fac: int = game.player(req["pid"])["faction"]
		var intent := MechIntent.new()
		## ⚠ **评估只许在独立副本上跑，真 game 一行不动**（Kevin 2026-09-19：意图档「动画乱套或重复播放」）。
		## 第一版把 MechIntent 的「快照→试走→回滚」直接跑在真 game 上：每一次试走的 `g.step()` 都是真步——
		## 内核消费者把它推成 roll / result / fx / feed 条目、界面照演，回滚之后真的那一步又演一遍；
		## 日志与出牌列也被假动作污染。与 MC / MCTS 同一条路：从快照造一份 `sim_quiet` 的副本
		## （陪练全是同步启发式，零真挂起），确定性照旧（rng 随快照复原）。护栏 `t_mech_bridge_quiet`。
		## 【alpha-beta 分支同规矩】search_best 的整棵搜索树也只跑 image，真局零污染。
		var image: CWGame = CWMonteCarloBridge._build_image_static(game.snapshot(), {
			"fixed_lineup": fixed_lineup, "lifecare": lifecare, "sim_no_lifecare": false })
		var best: Dictionary
		if use_search:
			## 叶估值 = 拟合 E(s)，**按搜索方阵营翻号一次**（树内所有值统一搜索方视角，
			## 节点 max/min 由 _ab_line 按行动方阵营处理）——v1 按 metrics.faction 翻号
			## 会让 alpha/beta 跨节点量纲不一致，v2 修正。
			var my_fac: int = fac
			var leaf: Callable = func(m: Dictionary) -> float:
				var ev: float = MechValue.position_eval_linear(m) if _fit_linear_on else MechValue.position_eval(m)
				return ev if my_fac == CWData.Faction.IMMUNE else -ev
			best = await intent.search_best(image, req["pid"], leaf, SEARCH_DEPTH)
		else:
			var scorer: Callable = _pick_scorer(fac)
			best = await intent.best_by(image, req["pid"], scorer)
		image.dispose()
		## 只在「动过确实更好」时接管：best 为空路径（不动基线赢）→ 回落启发式
		if best.has("path") and best["path"].size() > 0:
			var idx := _find_move_option(req, best["path"][0])
			if idx >= 0:
				return idx
	return await super.ask(req)


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
	## 免疫威胁：dist < 3 罚分（免疫能迁入攻击）
	var d: int = int(m.get("actor_min_immune_dist", 999))
	if d < 3:
		s -= float(3 - d) * 5.0
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


## scorer 选择（实例方法：需要读 use_fit_eval）：拟合估值是零和 E（免疫 max / 癌 min），
## 两侧共用同一可调用（内部按阵营翻号）。
func _pick_scorer(fac: int) -> Callable:
	if use_fit_eval:
		return MechBridge._fit_score
	return MechBridge._cancer_score if fac == CWData.Faction.CANCER \
		else MechBridge._immune_score

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


func _find_move_option(req: Dictionary, to: Vector2i) -> int:
	for i in req["options"].size():
		var d: Dictionary = req["options"][i]["data"]
		if d.get("act", "") == "move" and d.get("to", Vector2i(-999, -999)) == to:
			return i
	return -1
