## guide_levels.gd —— 16 关教程的逐关局面声明（纯静态、无状态）
##
## 与 CWGuideData（剧本台词）分工：这里只回答「第 N 关开局长什么样」——
## 棋盘半径、癌组织 / 特殊组织坐标、场上细胞与能量、玩家视角阵营。
## 导演（CWGuideDirector）据此在真实 CWGame 上装配开局；正式规则一格不改：
## 1–15 关是「小棋盘 + 定制局面」，第 16 关直接走正式 127 格四人初始化。
##
## 坐标一律用六边形轴坐标 (q, r)，中心 (0, 0)（与 CWData.all_coords 同口径）。
## 每关未标注的组织默认健康、特殊状态为空、固化计数 0（方案 §二）。
##
## 各关细节（特殊组织 / 固化计数 / 记忆值 / 固定随机脚本等）随各自切片的
## RED 测试逐关补进 raw()；本文件永远是「数据」，装配行为在导演那边。
class_name CWGuideLevels

## 半径表（方案 §二：微型1 小型2 中型3 大型4 正式6；第 2–4 关同为 19 格）
const RADII := [1, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 6]

## 玩家操作癌症方的关（0 起）：第 5 关「另一种生命」
const CANCER_POV := [4]


static func count() -> int:
	return RADII.size()


## 第 level 关的实验区数（第 10/11/12 关四个、第 15 关三个，其余 1）
static func zones(level: int) -> int:
	if level == 9 or level == 10 or level == 11:
		return 4
	return 3 if level == 14 else 1


## 第 level 关（0 起）的棋盘半径
static func radius(level: int) -> int:
	return RADII[level]


## 第 level 关玩家操作的阵营
static func player_faction(level: int) -> int:
	return CWData.Faction.CANCER if CANCER_POV.has(level) else CWData.Faction.IMMUNE


## 第 level 关的开局局面声明。字段（全部可选，按关递增）：
##   radius       棋盘半径（RADII 的冗余副本，导演直接读）
##   formal       true = 第 16 关，走正式四人初始化，其余字段无效
##   cancer_tiles 癌组织坐标（其余默认健康）
##   tile_extras  逐格覆盖 {坐标: {字段: 值}}——固化计数 solid、特殊组织 special、
##                代谢核心储能 store（十分之一）、骨髓存卡 cards 等
##   cells        开局细胞 [{faction, pos, energy, itype?, ctype?}]
static func raw(level: int) -> Dictionary:
	match level:
		0:
			return {
				"radius": RADII[0],
				## 第 1 关「苏醒」：7 格全健康 + 一枚免疫细胞 (0,0) 3.0 能量，世界回合暂停
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
				],
			}
		2:
			return {
				"radius": RADII[2],
				## 第 3 关「第一次接触」：玩家 6.0、敌方癌细胞 (1,0) 3.0，目标格及其后方为癌组织
				"cancer_tiles": [Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, -1)],
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO, "energy": 60 },
					{ "faction": CWData.Faction.CANCER, "pos": Vector2i(1, 0), "energy": 30 },
				],
			}
		3:
			return {
				"radius": RADII[3],
				## 第 4 关「时间开始流动」：免疫 1.0（有氧呼吸就要补上）、远离玩家的癌组织两格
				"cancer_tiles": [Vector2i(-2, 0), Vector2i(-2, 1)],
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO, "energy": 10 },
				],
			}
		4:
			return {
				"radius": RADII[4],
				## 第 5 关「另一种生命」：癌症视角，中心 7 格癌组织连通块供无氧呼吸
				"cancer_tiles": [Vector2i.ZERO] + CWData.neighbors(Vector2i.ZERO),
				"cells": [
					{ "faction": CWData.Faction.CANCER, "pos": Vector2i.ZERO,
						"energy": CWData.INIT_ENERGY_CANCER },
				],
			}
		5:
			return {
				"radius": RADII[5],
				## 第 6 关「建立据点」：中心固化计数预设 1（E 阶段一到即固化），另有 3 格普通癌组织
				"cancer_tiles": [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1)],
				"tile_extras": {
					Vector2i.ZERO: { "solid": 1 },
				},
				"cells": [
					{ "faction": CWData.Faction.CANCER, "pos": Vector2i.ZERO,
						"energy": CWData.INIT_ENERGY_CANCER },
				],
			}
		6:
			return {
				"radius": RADII[6],
				## 第 7 关「组织里的基础设施」：核预存 2.0、髓预存 1 张、血管一对
				"tile_extras": {
					Vector2i(1, 0): { "special": CWData.Special.CORE, "store": 20 },
					Vector2i(-1, 1): { "special": CWData.Special.MARROW, "cards": 1 },
					Vector2i(0, -3): { "special": CWData.Special.VESSEL },
					Vector2i(0, 3): { "special": CWData.Special.VESSEL },
				},
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
				],
			}
		7:
			return {
				"radius": RADII[7],
				## 第 8 关「基因表达」：免疫 4.0，两格癌组织做卡牌测试目标
				"cancer_tiles": [Vector2i(1, 0), Vector2i(1, 1)],
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO, "energy": 40 },
				],
			}
		8:
			return {
				"radius": RADII[8],
				## 第 9 关「免疫记忆」：抗原记忆 8/10，两格易净化癌组织推到升级
				"memory": 8,
				"cancer_tiles": [Vector2i(1, 0), Vector2i(1, 1)],
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
				],
			}
		9:
			return {
				"radius": RADII[9],
				## 第 10 关「分化」：四个实验区（树突 / 巨噬 / B / T），局面字段在各区里
				"zones": [
					{   ## 10A 树突状细胞：玩家树突 + 盟友免疫 + 癌细胞同场
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO,
								"itype": CWData.ImmuneType.DENDRITIC },
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i(0, 1),
								"itype": CWData.ImmuneType.BASIC },
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(2, 0),
								"energy": 30 },
						],
					},
					{   ## 10B 巨噬细胞：玩家能量较低 + 连续 3 格癌组织待吞噬净化
						"cancer_tiles": [Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)],
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO,
								"itype": CWData.ImmuneType.MACRO, "energy": 10 },
						],
					},
					{   ## 10C B 细胞：边缘 3 个与健康组织接触的癌细胞
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO,
								"itype": CWData.ImmuneType.B_CELL },
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(4, 0),
								"energy": 30 },
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(4, -2),
								"energy": 30 },
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(4, -4),
								"energy": 30 },
						],
					},
					{   ## 10D T 细胞：普通癌组织若干 + 固化癌组织（上站癌细胞）
						"cancer_tiles": [Vector2i(1, 1), Vector2i(2, 0)],
						"tile_extras": {
							Vector2i(1, 0): { "tissue": CWData.Tissue.SOLID },
						},
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO,
								"itype": CWData.ImmuneType.T_CELL },
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(1, 0),
								"energy": 30 },
						],
					},
				],
			}
		15:
			return {
				"radius": RADII[15],
				## 第 16 关「毕业战」：正式 127 格四人初始化，教程只叠加建议 / 预测 / 解释
				"formal": true,
			}
		10:
			return {
				"radius": RADII[10],
				## 第 11 关「癌症并不只有一种」：四种癌细胞实验区（癌症视角）
				"zones": [
					{   ## 11A 恶性黑色素瘤：玩家站在血管上，练早期血行转移
						"tile_extras": {
							Vector2i(0, -3): { "special": CWData.Special.VESSEL },
							Vector2i(0, 3): { "special": CWData.Special.VESSEL },
						},
						"cells": [
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(0, -3),
								"ctype": CWData.CancerType.MELANOMA, "energy": 30 },
						],
					},
					{   ## 11B 印戒细胞癌：4.0 能量、周围一枚免疫细胞，练黏液破裂
						"cells": [
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i.ZERO,
								"ctype": CWData.CancerType.SIGNET, "energy": 40 },
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i(0, 1) },
						],
					},
					{   ## 11C 骨肉瘤：站在普通癌组织上，练骨样硬化
						"cancer_tiles": [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1)],
						"cells": [
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i.ZERO,
								"ctype": CWData.CancerType.OSTEO,
								"energy": CWData.INIT_ENERGY_CANCER },
						],
					},
					{   ## 11D 小细胞肺癌：练转移跃进与健康迁移 0.7
						"cancer_tiles": [Vector2i.ZERO],
						"cells": [
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i.ZERO,
								"ctype": CWData.CancerType.SCLC,
								"energy": CWData.INIT_ENERGY_CANCER },
						],
					},
				],
			}
		11:
			return {
				"radius": RADII[11],
				## 第 12 关「肿瘤微环境」：压迫 / 增生 / 侵蚀 / 坏死四个教学场景
				"zones": [
					{   ## 12A 微环境压迫：免疫细胞被 5 格癌性组织包围
						"cancer_tiles": [Vector2i(1, 0), Vector2i(1, -1), Vector2i(-1, 0),
							Vector2i(-1, 1), Vector2i(0, 1)],
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
						],
					},
					{   ## 12B 增生：健康组织 (1,0) 与 3 格癌组织相邻
						"cancer_tiles": [Vector2i(2, 0), Vector2i(2, -1), Vector2i(1, 1)],
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i(-1, 0) },
						],
					},
					{   ## 12C 侵蚀：健康孤岛 (2,0) 被癌组织完全封闭
						"cancer_tiles": CWData.neighbors(Vector2i(2, 0)),
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
						],
					},
					{   ## 坏死：免疫细胞站在坏死组织上（剩余 2 世界回合）
						"tile_extras": {
							Vector2i.ZERO: { "necrosis": 2 },
						},
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
						],
					},
				],
			}
		12:
			return {
				"radius": RADII[12],
				## 第 13 关「世界并不稳定」：停在第 3 世界回合（事件回合 3/6/10/14）
				"round": 3,
				"cancer_tiles": [Vector2i(1, 0)],
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
				],
			}
		13:
			return {
				"radius": RADII[13],
				## 第 14 关「终末免疫」：记忆 29/30（III 级），玩家已分化为 T 细胞
				"memory": 29,
				"cells": [
					{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO,
						"itype": CWData.ImmuneType.T_CELL },
				],
			}
		14:
			var coords15: Array = CWData.all_coords(RADII[14])
			## 15B 癌症胜利警报：33 格癌组织 + 28 格固化占满 61 格，加权 33+2×28=89/90
			var zone_b: Dictionary = {
				"cancer_tiles": [],
				"tile_extras": {},
				"cells": [
					{ "faction": CWData.Faction.CANCER, "pos": Vector2i.ZERO,
						"energy": CWData.INIT_ENERGY_CANCER },
				],
			}
			for i in coords15.size():
				if i < 28:
					zone_b["tile_extras"][coords15[i]] = { "tissue": CWData.Tissue.SOLID }
				else:
					zone_b["cancer_tiles"].append(coords15[i])
			return {
				"radius": RADII[14],
				## 第 15 关「怎样真正赢下一局」：三个残局
				"zones": [
					{   ## 15A 免疫胜利：最后一个癌细胞 + 一个固化据点
						"tile_extras": {
							Vector2i(2, 0): { "tissue": CWData.Tissue.SOLID },
						},
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
							{ "faction": CWData.Faction.CANCER, "pos": Vector2i(1, 0),
								"energy": 30 },
						],
					},
					zone_b,
					{   ## 15C 第 15 回合判定：直接进最终回合
						"round": 15,
						"cells": [
							{ "faction": CWData.Faction.IMMUNE, "pos": Vector2i.ZERO },
						],
					},
				],
			}
		_:
			## 其余关：只有半径先行（台词与半径已由 t_guide_data / t_guide_director 盯住），
			## 局面细节随各自切片的 RED 测试补齐
			return { "radius": RADII[level] }
