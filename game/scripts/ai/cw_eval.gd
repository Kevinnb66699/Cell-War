## cw_eval.gd —— 静态估值：给定局面，从某一阵营视角打一个分（越高越好）
##
## 只给 AI 用（蒙特卡洛截断 playout 的末端评分），**不是规则**：
## 权重是 AI 的品味，改它不影响任何结算的合法性，所以也不放 cw_tuning
## （那里的旋钮是平衡实验用的规则数值）。
##
## 设计原则：项要少、每项都讲得出为什么。蒙特卡洛会把粗糙处抹平，
## 估值只要方向对——别把赢面算成输面。量纲折算成十分能量（1 分 ≈ 0.1 能量）。
class_name CWEval
extends RefCounted

## 终局压倒一切：任何物质优势都不该和「已经赢了」讨价还价
const WIN := 1000000

## 一格癌组织的分量。癌方胜利判「癌 1 + 固化 2 的加权占地 ≥ 阈值」，
## 占地同时是癌方收入来源 —— 这项是全局主导项，权重系数与胜利判据同口径。
const TILE := 100
## 癌组织上固化计数每一点的分量（进度学分）。
##
## ⚠ **必须小到让「修完固化」是净赚**（2026-09-04 修）：
## 一格癌组织 = `TILE`(100) + 进度 × SOLID_TICK；修成之后 = `TILE * 2`(200)。
## 满进度的学分总和**不能超过 100**，否则修完的那一刻估值反而下跌。
## 旧值 30 意味着进度满格值 600 —— 于是「进度 1.0 的癌组织(400) 比修成的固化格(200) 还值钱」，
## **MC 会主动避免把据点修完**，到处留半成品。癌方因此几乎从不拥有复活据点，
## 一被清场就出局 —— 09-04 上午量到的「癌方前期一死就出局」有一半是这条造成的伪影。
##
## 所以**从不变量推出来**，别再写死：门槛一动（2026-09-09 由 2.0 改 3.0）
## 写死的值就会破坏这条不变量，而症状是「AI 变蠢」这种没人会立刻归因到这儿的事。
## 现在门槛 3.0 → 3（3×30=90 ≤ 100）；换回 2.0 会自动回到 5，正是此前手工定的值。
const SOLID_TICK := TILE / CWData.SOLIDIFY_THRESHOLD
## **第一个可复活据点**的额外分量（2026-09-04 加）。
##
## `CWGame.check_immune_win()` 的原文是「癌细胞全灭**且没有免疫未占据的固化癌组织**」——
## 也就是说**只要场上还有一格无人占据的固化癌组织，免疫的「清场胜」就直接被挡住**。
## 这是一条**胜负条件**级别的事实，而估值此前只把它当成「一格地盘 100 → 200」，
## 完全没有体现「它挡掉了对方的一整条胜路、并把癌方的死从永久损失变成可复活」。
## （后者本来只在 `_death_cost` 里体现：无据点 1500 / 有据点 800，差 700 ——
## 但那要等真的死了才算得到，MC 的 horizon 常常看不到。）
##
## 所以给「拥有第一个据点」一次性加分；第二个及以后不再加（边际价值小得多）。
const FIRST_BASE := 400
## 抗原记忆一点 / 免疫等级一级的分量（升级解锁分化、换更强的卡池）
const MEMORY := 25
const LEVEL := 150
## 手牌一张 / 已装备一张的分量（期货与永久被动）
const CARD := 12
const EQUIP := 40
## 免疫细胞离最近癌性组织每远 1 格给癌方的加分（战线：人不到场，地就收不回）
const FAR := 8
## 死亡不再免费（v2，2026-09-02 Kevin 定「让 AI 惜命」）。此前死细胞直接跳过：一个免疫细胞自杀式冲进压迫区，
## 估值里只损失账上那点能量，甚至还甩掉了「离战线远」的罚分 —— MC 免疫每局死 5~8 次、复活罚停旋钮
## 怎么扫都像全表最重的杠杆（第二张表 ④，MC +33~40），全是这一条的伪影。
## 免疫：复活前每缺席一个世界回合 ≈ 少 2~3 次净化 + 一轮收入，按 2.5 格计；复活落在骨髓还得走回战线，再加 1.5 格。
const DEAD_IMMUNE_TRIP := 150
const DEAD_IMMUNE_ROUND := 250
## 不再复活（immune_respawn_delay = -1）：永久少一个细胞
const DEAD_FOREVER := 2000
## 癌：复活要有固化据点，没有就是永久损失（也离免疫胜利只差把据点清掉）；有据点也要等 S 阶段、从据点重新出发。
const DEAD_CANCER := 800
const DEAD_CANCER_NO_BASE := 1500

## ---- 特征 × 权重（2026-09-07，为「用自对弈回归权重」铺路）----
##
## 估值的非终局部分本来就是一个**线性组合**，只是权重写死在上面那些 const 里。
## 拆成 `features()` × `WEIGHTS` 之后，「学一组更好的权重」就退化成一次回归，
## 不必动树搜索、不必引入任何运行时依赖。
##
## ⚠ **默认权重下 score() 的输出必须逐位不变**：扁平 MC 是平衡标尺，估值一动整套平衡表作废
## （t_eval_features 钉着这条）。学出来的权重要用，请另开评分器（CWLeafValue 那套），别改这里的默认值。
##
## 特征顺序固定，改动要同步 FEATURE_NAMES —— 导出的训练数据按这个顺序写列。
const FEATURE_NAMES: Array[String] = [
	"cancer_tiles", "solid_tiles", "solid_progress", "has_base",
	"cancer_energy", "cancer_hand", "cancer_equip",
	"immune_energy", "immune_hand", "immune_equip", "immune_far",
	"memory", "level",
]
## 与 FEATURE_NAMES 并行。**能量那两项的权重是 1**：估值的量纲就是十分能量（1 分 ≈ 0.1 能量），
## 此前它没有名字、直接写在 `worth` 里 —— 拆出来才回归得动。
const WEIGHTS: Array[int] = [
	TILE, TILE * 2, SOLID_TICK, FIRST_BASE,
	1, CARD, EQUIP,
	-1, -CARD, -EQUIP, FAR,
	-MEMORY, -LEVEL,
]


## 从 faction 视角给局面打分。先算「癌方优势」，免疫视角取负 —— 两个视角零和，
## 蒙特卡洛给任何一方用都不必换公式。
## death_cost=false = v1 的估值（死细胞直接跳过），只给 AI 版本交叉验证用。
##
## **死亡项只进免疫视角**（v2 定稿，2026-09-02 夜交叉验证，对同一 v1 免疫、7 片 × 12 局）：
## | 癌方估值 | 6 人癌胜 | 4 人（168 局） |
## | v1（不计死亡） | 24 | 29 |
## | 计死亡（自己 800/1500、免疫 +400） | **19** | 31 |
## | 只去掉免疫死亡奖励 | 18 | 32 |
## | 不计任何死亡项 | **36** | 28 |
## 罚分没让 MC 癌少死（每局癌死亡 3.4 vs 3.6），只让它在 12 步视野里更偏向「不动」，6 人局直接弱掉 5~17 点；
## 陪练（v2 启发式、贴脸留 3.0）已经把它的未来算得够保守，再叠一层罚分是重复计价。
## 免疫那边相反：不复活等于「缺席」落在视野之外，不显式计价就会自杀式净化 —— 计了之后两档都比 v1 强（24→18 / 29→19）。
static func score(g: CWGame, faction: int, death_cost: bool = true) -> int:
	return score_with(g, faction, WEIGHTS, death_cost)


## 同 score()，但权重由外部给（长度须等于 FEATURE_NAMES）。回归出的权重靠这条上场，
## **不必也不该改上面那些默认 const**（那是平衡标尺的一部分）。
static func score_with(g: CWGame, faction: int, w: Array, death_cost: bool = true) -> int:
	if g.winner >= 0:
		var end_adv := WIN if g.winner == CWData.Faction.CANCER else -WIN
		return end_adv if faction == CWData.Faction.CANCER else -end_adv
	var f := features(g)
	var adv := 0
	for i in f.size():
		adv += f[i] * int(w[i])
	## 死亡项**不进线性部分**：它是条件式的（只在免疫视角计、且要看复活还差几回合），
	## 硬塞进特征向量会让回归去拟合一个它看不全的量。留在这里按老口径算。
	if death_cost and faction == CWData.Faction.IMMUNE:
		for cell in g.cells:
			if cell["alive"]:
				continue
			var cost := _death_cost(g, cell)
			adv += -cost if cell["faction"] == CWData.Faction.CANCER else cost
	return adv if faction == CWData.Faction.CANCER else -adv


## 局面的特征向量，**一律从「癌方优势」视角取**（免疫视角在 score_with 末尾整体取负）。
## 顺序与 FEATURE_NAMES 一一对应。纯函数，导出训练数据与打分共用这一份 —— 抄第二份必然漂。
static func features(g: CWGame) -> Array[int]:
	var cancer_tiles := 0
	var solid_tiles := 0
	var solid_progress := 0
	var has_base := false          ## 癌方有没有「无人占据的固化癌组织」= 挡得住清场胜
	for c in g.tiles.keys():
		var t: Dictionary = g.tiles[c]
		if t["tissue"] == CWData.Tissue.CANCER:
			cancer_tiles += 1
			solid_progress += int(t["solid"])
		elif t["tissue"] == CWData.Tissue.SOLID:
			solid_tiles += 1
			## 与 check_immune_win 同一口径：免疫站上去的据点不算「可复活」
			if g.cells_at(c, CWData.Faction.IMMUNE).is_empty():
				has_base = true
	var ce := 0
	var ch := 0
	var cq := 0
	var ie := 0
	var ih := 0
	var iq := 0
	var far := 0
	for cell in g.cells:
		if not cell["alive"]:
			continue
		if cell["faction"] == CWData.Faction.CANCER:
			ce += int(cell["energy"])
			ch += cell["hand"].size()
			cq += cell["equipped"].size()
		else:
			ie += int(cell["energy"])
			ih += cell["hand"].size()
			iq += cell["equipped"].size()
			far += mini(_dist_to_cancerous(g, cell["pos"]), 6)
	var out: Array[int] = [cancer_tiles, solid_tiles, solid_progress, 1 if has_base else 0,
		ce, ch, cq, ie, ih, iq, far, g.memory, g.immune_level]
	return out


## 一个死细胞此刻对己方值多少损失（正数）。免疫按「离复活还有几个世界回合」计，罚停旋钮自然进入估值；
## 癌按「有没有固化据点可复活」计。
static func _death_cost(g: CWGame, cell: Dictionary) -> int:
	if cell["faction"] == CWData.Faction.CANCER:
		return DEAD_CANCER if g.count_tissue(CWData.Tissue.SOLID) > 0 else DEAD_CANCER_NO_BASE
	var back: int = cell["respawn_round"]
	if back < 0:
		return DEAD_FOREVER
	return DEAD_IMMUNE_TRIP + DEAD_IMMUNE_ROUND * maxi(back - g.round_no, 1)


static func _dist_to_cancerous(g: CWGame, from: Vector2i) -> int:
	var best := 99
	for c in g.tiles.keys():
		if g.is_cancerous(c):
			best = mini(best, CWData.hex_dist(from, c))
	return best
