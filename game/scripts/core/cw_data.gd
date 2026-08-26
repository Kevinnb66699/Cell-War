## cw_data.gd —— 全局静态数据：棋盘布局、特殊组织位置、数值常量、种类/等级表
##
## 重要约定：所有能量数值用「十分能量」整数表示（3.0 能量 = 30），
## 避免浮点误差，保证回放/联机确定性（见 docs/规则电子化说明.md #10）。
## 特殊组织位置是临时布局（说明 #3），换地图只需改本文件常量。
class_name CWData
extends RefCounted

enum Tissue { HEALTHY, CANCER, SOLID }          # 健康 / 癌组织 / 固化癌组织
enum Special { NONE, CORE, MARROW, VESSEL }     # 无 / 代谢核心 / 骨髓 / 血管
enum Faction { IMMUNE, CANCER }                 # 免疫方 / 癌症方
enum ImmuneType { BASIC, B_CELL, T_CELL, MACRO, DENDRITIC }
enum CancerType { BLAST, INVASIVE, REMODEL, ESCAPE, UNSTABLE, SESSILE }

# ---- 棋盘 ----
const BOARD_RADIUS := 4                  # 半径 4 蜂窝 = 61 格
const TOTAL_TILES := 61
const INIT_CANCER_TILES := 7

# ---- 胜负 ----
# 2026-08-26 团队定案：回合上限 30→20（暂定，不行再降到 15），终局门槛 1/3→1/2。
# 原因：原规则下对局平均 9~10 回合就结束，30 回合从未触发；而 1/3 的门槛对癌方过于友好，
# 缩短上限后癌方"熬到时间到"会白捡胜利。详见 docs/平衡测试报告.md
const CANCER_WIN_WEIGHTED := 41          # 癌+2×固化 ≥ ⌈2/3×61⌉ 时癌症即胜（S 类判定）
const LIMIT_ROUND := 20                  # 终局世界回合数
const LIMIT_CANCEROUS := 31              # 终局判定线 ⌈1/2×61⌉

# ---- 原发灶（2026-08-26 团队定案）----
# 每个癌症玩家的出生格开局即为固化癌组织，给癌方一次复活容错，
# 破解「复活需固化组织、固化需停留 2 回合、停留就被打死」的死循环。
const SOLID_AT_CANCER_SPAWN := true

# ---- 免疫死亡与复活（2026-08-26 团队定案）----
# 免疫细胞可被杀死，但罚停若干回合后在随机健康组织复活（无限次）。
# 注意：造成免疫死亡的手段尚未定案（反弹反击可被免疫主动规避，见开发日志），
# 所以这套机制目前基本不会触发——等癌方主动伤害手段定下来才会真正生效。
const IMMUNE_RESPAWN_DELAY := 1          # 罚停回合数：死于第 N 回合 → 缺席 N+1 → N+2 复活
const IMMUNE_RESPAWN_ENERGY := 20        # 复活获得 2.0 能量（与癌细胞【复活】一致）

# ---- 能量与费用（十分能量）----
const INIT_ENERGY := 30                  # 初始 3.0
const IMMUNE_MOVE_HEALTHY := [5, 5, 5, 4]     # 迁移→健康，按等级 I/II/III/X
const IMMUNE_MOVE_CANCEROUS := [10, 10, 5, 4] # 迁移→癌性，按等级
const AEROBIC_GAIN := [30, 40, 30, 30]        # 有氧呼吸，按等级（III 回落到 3 为规则原文，见说明 #6）
const LEVEL_MIN_MEMORY := [0, 6, 16, 30]      # I/II/III/X 记忆门槛（30 归 X，见说明 #7）
const IMMUNE_DRAW_COST := 5
const CANCER_DRAW_COST := 10
const CANCER_MOVE_CANCEROUS := 2
const CANCER_MOVE_HEALTHY := 5
const INVASIVE_DISCOUNT := 2             # 侵袭型前 2 次进健康组织 -0.2
const MUTATE_COST := 5
const MUTATE_EXTRA_LOSS := 10            # 突变第 3 种结果再扣 1.0（效果扣减，可致死）
const ANTIBODY_COST := 10
const ANTIBODY_DAMAGE := 10
const ANTIBODY_MAX_PER_ROUND := 3
const TOXIN_COST := 10
const LYSE_COST := 10
const REMODEL_COST := 10
const REVIVE_ENERGY := 20                # 复活获得 2.0
const ATTACK_DMG_SUCCESS := 10
const ATTACK_DMG_CRIT := 20
const ESCAPE_REDUCTION := 5              # 免疫逃逸：每世界回合首次受免疫伤害 -0.5
const MACRO_HEAL_PURIFY := 2             # 巨噬【吞噬】：净化回 0.2
const MACRO_HEAL_ATTACK := 5             # 巨噬【吞噬】：攻击造成伤害回 0.5

# ---- 无氧呼吸 / 固化 ----
const ANAEROBIC_PER_CANCER := 2          # 每癌组织供能 0.2
const ANAEROBIC_PER_SOLID := 5           # 每固化癌组织供能 0.5
const SOLIDIFY_THRESHOLD := 2            # 固化计数达 2 → 固化癌组织

# ---- 特殊组织（临时布局，轴坐标，中心 (0,0)；见说明 #3）----
const CORES: Array[Vector2i] = [Vector2i(2, 0), Vector2i(-2, 2), Vector2i(0, -2)]
const MARROWS: Array[Vector2i] = [
	Vector2i(0, 3), Vector2i(-3, 3), Vector2i(-3, 0), Vector2i(0, -3), Vector2i(3, -3),
]
const VESSELS: Array[Vector2i] = [Vector2i(4, -2), Vector2i(-4, 2)]
const CORE_STORE_MAX := 20               # 代谢核心存储上限 2.0
const CORE_HEALTHY_PERIOD := 2           # 健康：每 2 世界回合 +1.0
const CORE_HEALTHY_GAIN := 10
const CORE_CANCER_GAIN := 4              # 癌性：每世界回合 +0.4
const MARROW_STORE_MAX := 1              # 骨髓存储上限 1 张
const MARROW_HEALTHY_PERIOD := 3
const MARROW_CANCER_PERIOD := 2

# ---- 行动顺序（规则只定义 4/6 人；2 人为电子版测试扩展，见说明 #5）----
const FACTION_ORDER := {
	2: [Faction.IMMUNE, Faction.CANCER],
	4: [Faction.IMMUNE, Faction.CANCER, Faction.IMMUNE, Faction.CANCER],
	6: [Faction.IMMUNE, Faction.CANCER, Faction.CANCER,
		Faction.IMMUNE, Faction.IMMUNE, Faction.CANCER],
}

# ---- 名称表（日志/UI 用）----
const CANCER_TYPE_NAMES := {
	CancerType.BLAST: "自爆", CancerType.INVASIVE: "侵袭型", CancerType.REMODEL: "基质重塑型",
	CancerType.ESCAPE: "免疫逃逸型", CancerType.UNSTABLE: "基因不稳定型", CancerType.SESSILE: "固着型",
}
const IMMUNE_TYPE_NAMES := {
	ImmuneType.BASIC: "免疫细胞", ImmuneType.B_CELL: "B细胞", ImmuneType.T_CELL: "T细胞",
	ImmuneType.MACRO: "巨噬细胞", ImmuneType.DENDRITIC: "树突状细胞",
}
const LEVEL_NAMES := ["I", "II", "III", "X"]
const TISSUE_NAMES := { Tissue.HEALTHY: "健康组织", Tissue.CANCER: "癌组织", Tissue.SOLID: "固化癌组织" }

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]


static func is_on_board(c: Vector2i) -> bool:
	return abs(c.x) <= BOARD_RADIUS and abs(c.y) <= BOARD_RADIUS \
		and abs(c.x + c.y) <= BOARD_RADIUS


static func all_coords() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for q in range(-BOARD_RADIUS, BOARD_RADIUS + 1):
		for r in range(-BOARD_RADIUS, BOARD_RADIUS + 1):
			var c := Vector2i(q, r)
			if is_on_board(c):
				out.append(c)
	return out


static func neighbors(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in DIRS:
		var n: Vector2i = c + d
		if is_on_board(n):
			out.append(n)
	return out


static func hex_dist(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (abs(dq) + abs(dr) + abs(dq + dr)) / 2


static func is_edge(c: Vector2i) -> bool:
	# 棋盘外缘格：邻居不满 6 个
	return neighbors(c).size() < 6


static func special_of(c: Vector2i) -> Special:
	if c in CORES:
		return Special.CORE
	if c in MARROWS:
		return Special.MARROW
	if c in VESSELS:
		return Special.VESSEL
	return Special.NONE


static func is_world_event_round(r: int) -> bool:
	# 世界事件：第 3、6、10、15（后续 +5）个世界回合
	return r == 3 or r == 6 or r == 10 or (r >= 15 and (r - 15) % 5 == 0)


## 十分能量 → 显示字符串（如 15 → "1.5"）
static func fmt(e: int) -> String:
	return "%d.%d" % [e / 10, abs(e) % 10]
