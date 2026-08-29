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
enum CancerType { MELANOMA, SIGNET, OSTEO, SCLC }  # 黑色素瘤 / 印戒 / 骨肉瘤 / 小细胞肺癌

# ---- 棋盘（2026-08-27 团队定案：半径 4 / 61 格 → 半径 6 / 127 格）----
const BOARD_RADIUS := 6                  # 半径 6 蜂窝 = 1 + 3×6×7 = 127 格
const TOTAL_TILES := 127
const INIT_CANCER_TILES := 15            # PRD：15 初始癌组织 + 112 健康 = 127

# ---- 胜负 ----
# 2026-08-28：全部回到 PRD 原值。此前 20/85/64 是 2026-08-26 依据平衡测试定的暂行值，
# PRD 这一版已明确写死，团队决定「按 PRD 实现，差异不再讨论」。
# 两个胜利条件现在**都是 E 类**，在 E 阶段最后统一判定（见 CWWorld.e_phase）。
const CANCER_WIN_WEIGHTED := 64          # 癌+2×固化 ≥ ⌈1/2×127⌉ 时癌症即胜
const LIMIT_ROUND := 30                  # 终局世界回合数
const LIMIT_CANCEROUS := 42              # 终局判定线 ⌊1/3×127⌋

# ---- 原发灶（2026-08-26 团队定案）----
# 每个癌症玩家的出生格开局即为固化癌组织，给癌方一次复活容错，
# 破解「复活需固化组织、固化需停留 2 回合、停留就被打死」的死循环。
const SOLID_AT_CANCER_SPAWN := true

# ---- 免疫死亡与复活（2026-08-26 团队定案）----
# 免疫细胞可被杀死，但罚停若干回合后在随机健康组织复活（无限次）。
# 注意：造成免疫死亡的手段尚未定案（反弹反击可被免疫主动规避，见开发日志），
# 所以这套机制目前基本不会触发——等癌方主动伤害手段定下来才会真正生效。
# PRD 没有罚停条款：死亡的免疫细胞在**下一个** S 阶段结算【复活】。
# 死于第 N 回合的玩家阶段 → 第 N+1 回合 S 阶段复活，天然就缺席了一整轮。
const IMMUNE_RESPAWN_DELAY := 0
const IMMUNE_RESPAWN_ENERGY := 10        # PRD：复活初始 1.0 能量（癌细胞是 2.0，见 REVIVE_ENERGY）

# ---- 能量与费用（十分能量）----
const INIT_ENERGY := 30                  # 初始 3.0
# PRD【I-免疫记忆】：III 级「迁移到癌性组织的耗能降为 0.7」；X 级「迁移耗能均改为 0.5」。
# 健康组织那一档 PRD 从头到尾都是 0.5，没有等级加成。
const IMMUNE_MOVE_HEALTHY := [5, 5, 5, 5]     # 迁移→健康，按等级 I/II/III/X
const IMMUNE_MOVE_CANCEROUS := [10, 10, 7, 5] # 迁移→癌性，按等级
# PRD【S-有氧呼吸】：能量 = (健康组织格数 − 坏死格数) ÷ 总格数 × 3，四舍五入到十分位。
# 每个免疫细胞各得这么多，**不按免疫细胞数均分**。等级加成（II 级 4、III 级 3）已从 PRD 删除。
const AEROBIC_MULT := 30                      # 十分能量，即公式里的「×3」
const LEVEL_MIN_MEMORY := [0, 6, 16, 31]      # I/II/III/X 记忆门槛（PRD：III = 16~30，X = 31+）
const DRAW_MAX_PER_TURN := 3             # 【基因表达】每个行动回合最多 3 次（双方同）
# 手牌上限。**PRD 没有这一条**，是团队 2026-08-28 为了界面能一眼读懂而定的
# （右侧竖条里手牌数画成 8 个方块，满与不满一眼可见）。
# 满 8 张时【基因表达】的抽卡选项直接不出现；踩到骨髓也不发卡，卡留在骨髓里下次再拿。
const HAND_MAX := 8
const IMMUNE_DRAW_COST := 5
const CANCER_DRAW_COST := 10
const CANCER_MOVE_CANCEROUS := 2
const CANCER_MOVE_HEALTHY := 5

# ---- 癌细胞种类专属（PRD 癌细胞种类）----
# 恶性黑色素瘤
const MELANOMA_HOMING_COST := 10         # 【早期血行转移】1.0 能量，每世界回合 1 次
const PSEUDOPOD_COST := 2                # 【伪足穿透】目标健康组织邻接 ≥2 格癌性组织时，移动费 0.2
const PSEUDOPOD_MIN_ADJ := 2
# 印戒细胞癌
const MUCUS_MIN_ENERGY := 20             # 【黏液破裂】至少 2.0 能量才能发动
const MUCUS_RADIUS := 2                  # 自身所在格及周围 2 格
const MUCUS_MAX_CONVERT := 8             # 其中随机最多 8 格立即转为癌组织
const MUCUS_IMMUNE_LOSS := 20            # 范围内免疫细胞损失 2.0
const ARMOR_REDUCTION := 5               # 【囊性护甲】受到的能量损失 -0.5，每世界回合 1 次
# 骨肉瘤：【骨样硬化】见 SOLIDIFY_STEP 的用法；【刚性屏障】是攻击合法性限制，无数值
# 小细胞肺癌
const SCLC_MOVE_HEALTHY := 3             # 【极简胞浆】移动至健康组织永久 0.3
const METASTASIS_COST := 10              # 【转移】1.0 能量
const METASTASIS_RANGE := 5              # 向某方向跃进 5 格
const WARBURG_PERCENT := 110             # 【瓦伯格超速糖酵解】无氧呼吸 110%，向上取整到十分位
const MUTATE_COST := 5
const MUTATE_EXTRA_LOSS := 10            # 突变第 3 种结果再扣 1.0（效果扣减，可致死）
const ANTIBODY_COST := 10
const ANTIBODY_DAMAGE := 10
const ANTIBODY_MAX_PER_ROUND := 2        # PRD：B 细胞每世界回合最多 2 次
const TOXIN_COST := 10
const TOXIN_MAX_PER_ROUND := 3           # PRD：T 细胞每世界回合最多 3 次
const LYSE_COST := 10
const REVIVE_ENERGY := 20                # 复活获得 2.0
const ATTACK_DMG_SUCCESS := 10
const ATTACK_DMG_CRIT := 20
const MACRO_HEAL_PURIFY := 3             # 巨噬【吞噬】：每次净化回 0.3
# 攻击那一档 PRD 是 ⌈受击方损失能量 ÷ 2⌉，随伤害变化，不是常数 —— 见 CWGame.immune_hit

# ---- 无氧呼吸 / 固化 ----
const ANAEROBIC_PER_CANCER := 4          # 每癌组织供能 0.4
const ANAEROBIC_PER_SOLID := 10          # 每固化癌组织供能 1.0

# 固化计数也用「十分」整数存（10 = 1 点）。PRD 里它不再是整数：
# 衰减 −0.5、骨肉瘤【骨样硬化】+1.5、癌症卡【基质硬化】+1/+1.5/+2。
const SOLIDIFY_THRESHOLD := 30           # 计数达 3.0 → 固化癌组织
const SOLIDIFY_STEP := 10                # 癌细胞停留：+1.0
const SOLIDIFY_DECAY := 5                # 无癌细胞停留：每世界回合 −0.5
const SOLIDIFY_ACCEL_AT := 20            # 【固化加速】：从 <2.0 涨到 ≥2.0 立即转化（定案 W4）

# ---- 场景事件（PRD 场景事件）----
# 【E-微环境压迫】：相邻癌性组织 > 2 格时，免疫细胞损失（相邻数 − 2）× 0.5。
# 这是癌方**第一个稳定的伤害来源** —— 在此之前免疫细胞几乎不可能死（旧说明 #23）。
# 【E-增生】：没有免疫细胞的健康组织，按「相邻癌性组织数 × 4%」的概率转为癌组织。
# 这条原本是团队 2026-08-26 的提案（引擎里做成了默认关闭的旋钮），PRD 已正式采纳。
const PROLIFERATE_PER_ADJ := 40          # 千分率：每个相邻癌性组织贡献 4%

const PRESSURE_FREE_ADJ := 2             # 前 2 格不造成损失
const PRESSURE_PER_ADJ := 5              # 超出部分每格 0.5

# 「坏死」：该格不为免疫【有氧呼吸】供能，但可以被【定殖】。按格记「还剩几个世界回合」。
const NECROSIS_TOXIN := 2                # T 细胞【细胞毒素】造成：两轮完整世界回合
const NECROSIS_RADIO := 5                # 免疫卡【放疗】造成：五轮
const RADIO_REGION := 15                 # 【放疗】区域：含起点的随机连通 15 格
const CHEMOTAX_STEP_COST := 2            # 【炎症性趋化】每步基准 0.2（再过移动费修正）

# ---- 特殊组织（2026-08-27 团队定案，轴坐标，中心 (0,0)）----
# 布局：**半径 3** 那一环的 6 个「角」上，代谢核心与骨髓**交替**排布（各 3 个）；
#      骨髓再在外缘（半径 6）的「边中格」补 3 个；左右两个最远角 (±6,0) 一对血管。
#      每个 120° 扇区正好分到 1 核心 + 1 内圈骨髓 + 1 外圈骨髓。
#
# 内圈为什么是半径 3 而不是 4：半径 4 时中心留出的空地有 37 格，团队认为太空旷；
# 收到半径 3 后空地缩到 19 格。实测半径 3 也是双方细胞踩到率最均衡的一圈
# （癌 36% / 免 36%，半径 4 是 35% / 29%），所以这一挪不偏袒任何一方。
#
# 外圈骨髓为什么补在「边中格」而不是边角：要保住内圈的 **3 重旋转对称**（转 120° 完全重合），
# 新增点必须是「转 120° 后落回自身」的一组。外缘满足条件的只有两类——6 个角和 6 个边中格，
# 而 6 个角分成的两组轨道**各被一个血管占了**，所以只剩边中格可选。
#
# 中央格原本也是骨髓，2026-08-27 移除——它与「初始癌组织必须包含中央格 + 癌组织不得与
# 特殊组织重合」这两条规则直接冲突（说明 #34），且会让癌方从第 0 回合白拿一个骨髓。
#
# 可视化参考：docs/地图布局_127格.svg（由 tools/render_map.py 从本文件生成，改坐标后重跑脚本）
const CORES: Array[Vector2i] = [Vector2i(0, -3), Vector2i(3, 0), Vector2i(-3, 3)]
const MARROWS: Array[Vector2i] = [
	Vector2i(3, -3), Vector2i(0, 3), Vector2i(-3, 0),      # 内圈：与核心交替
	Vector2i(6, -3), Vector2i(-3, 6), Vector2i(-3, -3),    # 外圈：外缘边中格
]
const VESSELS: Array[Vector2i] = [Vector2i(6, 0), Vector2i(-6, 0)]
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
## PRD 把原来 6 种设定型癌细胞换成了 4 种真实癌症，同一种每局最多出现 1 个 ——
## 所以**种类同时也是癌方的玩家身份**，棋盘上四张脸各不相同。
const CANCER_TYPE_NAMES := {
	CancerType.MELANOMA: "恶性黑色素瘤", CancerType.SIGNET: "印戒细胞癌",
	CancerType.OSTEO: "骨肉瘤", CancerType.SCLC: "小细胞肺癌",
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
	# PRD：第 3、6、10、15、20、25、30 世界回合，**到 30 为止**（30 也是终局回合）
	return r in [3, 6, 10, 15, 20, 25, 30]


## 十分能量 → 显示字符串（如 15 → "1.5"）
static func fmt(e: int) -> String:
	return "%d.%d" % [e / 10, abs(e) % 10]
