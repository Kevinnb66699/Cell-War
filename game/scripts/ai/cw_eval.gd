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
## 癌组织上固化计数每一点的分量（快固化=快据点，给部分学分）
const SOLID_TICK := 30
## 抗原记忆一点 / 免疫等级一级的分量（升级解锁分化、换更强的卡池）
const MEMORY := 25
const LEVEL := 150
## 手牌一张 / 已装备一张的分量（期货与永久被动）
const CARD := 12
const EQUIP := 40
## 免疫细胞离最近癌性组织每远 1 格给癌方的加分（战线：人不到场，地就收不回）
const FAR := 8


## 从 faction 视角给局面打分。先算「癌方优势」，免疫视角取负 —— 两个视角零和，
## 蒙特卡洛给任何一方用都不必换公式。
static func score(g: CWGame, faction: int) -> int:
	var adv := 0
	if g.winner >= 0:
		adv = WIN if g.winner == CWData.Faction.CANCER else -WIN
		return adv if faction == CWData.Faction.CANCER else -adv
	## 地盘：与胜利判据同一口径（癌 1 / 固化 2），另给固化进度部分学分
	for c in g.tiles.keys():
		var t: Dictionary = g.tiles[c]
		if t["tissue"] == CWData.Tissue.CANCER:
			adv += TILE + t["solid"] * SOLID_TICK
		elif t["tissue"] == CWData.Tissue.SOLID:
			adv += TILE * 2
	## 物质：存活细胞的能量与手牌/装备；免疫细胞另按离战线的距离罚分
	for cell in g.cells:
		if not cell["alive"]:
			continue
		var worth: int = cell["energy"] + cell["hand"].size() * CARD \
			+ cell["equipped"].size() * EQUIP
		if cell["faction"] == CWData.Faction.CANCER:
			adv += worth
		else:
			adv -= worth
			adv += mini(_dist_to_cancerous(g, cell["pos"]), 6) * FAR
	## 免疫科技（记忆与等级不属于哪个细胞，单独算）
	adv -= g.memory * MEMORY + g.immune_level * LEVEL
	return adv if faction == CWData.Faction.CANCER else -adv


static func _dist_to_cancerous(g: CWGame, from: Vector2i) -> int:
	var best := 99
	for c in g.tiles.keys():
		if g.is_cancerous(c):
			best = mini(best, CWData.hex_dist(from, c))
	return best
