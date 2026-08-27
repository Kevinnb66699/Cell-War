## cw_tuning.gd —— 平衡旋钮：把「可能需要改动的数值」从规则常量里分离出来
##
## 默认值 = 规则原文（CWData 常量），所以 CWTuning.new() 就是「按规则跑」。
## 平衡测试时只改旋钮、不改引擎代码；旋钮定案后再回写规则文档与 CWData。
##
## 单位一律是「十分能量」（10 = 1.0 能量）。
class_name CWTuning
extends RefCounted

## 方案名（打印报告用）
var name := "规则原文"


## 当前推荐的平衡方案（2026-08-27 在 127 格棋盘上重新标定，尚未写回规则文档，待团队确认）。
## AI 互搏：4 人局癌胜率 ~53%、6 人局 ~50%、2 人局 ~36%，平均 12~13 世界回合。
## （对照：同棋盘下规则原文的收入公式只有 4 人 36% / 6 人 20%）
##
## 各项作用（详见 docs/平衡测试报告.md）：
##   ① 免疫【有氧呼吸】挂钩健康组织（0.05/格）、癌方【无氧呼吸】0.5 及固化 1.2/格
##      —— 双方收入都挂钩地盘，形成对等反馈
##   ② 两侧都按己方细胞数均分 —— 阵营总收入与人数无关，人数缩放问题因此消失
##   ③ 新增【E-增生】：健康组织按 相邻癌性组织数×4% 的概率被侵占
##   ④ **低保 + 封顶**：①的挂钩会让领先方收入涨、落后方收入跌，双向加速形成雪球；
##      低保防崩盘、封顶防雪球，两个一起用才稳。实测拆掉任意一个都会崩：
##      去封顶 → 4 人 82%／6 人 100%，对局塌到 7 回合；去低保 → 6 人 96%。
##      封顶必须不对称：转化一格地盘癌方只要 0.5、免疫要 1.0，
##      所以免疫的上限约为癌方的 1.4~2 倍才是等吞吐量。
static func recommended() -> CWTuning:
	var t := CWTuning.new()
	t.name = "推荐方案"
	# 免疫供能 = 健康组织数 × 0.1 ÷ 2 = 0.05/格。
	# 棋盘从 61 扩到 127 格后，原来的 0.1/格意味着开局 12.0 总供能，免疫直接顶到封顶、
	# 「收入挂钩地盘」的反馈全程失效，所以这里用分母把每格供能减半。
	t.aerobic_per_healthy = 1
	t.aerobic_healthy_div = 2
	t.aerobic_split = true
	t.anaerobic_per_cancer = 5      # 0.5/格
	t.anaerobic_per_solid = 12      # 1.2/格
	t.proliferate_per_adjacent = 40 # 增生 4%/相邻癌性组织
	t.anaerobic_floor = 12          # 癌方低保 1.2
	t.anaerobic_cap = 35            # 癌方封顶 3.5
	# 免疫低保 1.9 而不是 2.0：6 人局的免疫每细胞供能 = 120 ÷ 2 ÷ 3 = 2.0，
	# 低保定在 2.0 会从第 1 回合就把它钉死，收入再也不随地盘萎缩 → 6 人局癌方只有 39%。
	# 降到 1.9 就重新打开了衰减空间，6 人局回到 50%，而 4 人局（开局 3.0，很晚才触底）几乎不受影响。
	t.aerobic_floor = 19
	t.aerobic_cap = 35              # 只在 2 人局生效（独苗免疫细胞独享全部供能）
	return t


# ---- 收入 ----
var aerobic_gain: Array = CWData.AEROBIC_GAIN.duplicate()   # 免疫【有氧呼吸】按等级
var anaerobic_per_cancer := CWData.ANAEROBIC_PER_CANCER      # 每癌组织供能
var anaerobic_per_solid := CWData.ANAEROBIC_PER_SOLID        # 每固化癌组织供能
## 无氧呼吸是否按连通块内癌细胞数均分（关掉=每个癌细胞独享全额，大幅提升多细胞癌方收入）
var anaerobic_split := true

## 【有氧呼吸】改为与健康组织数量挂钩（团队 2026-08-26 提案「削正常组织获取能量的方式」）。
## >0 时启用：免疫方总供能 = 健康组织数 × 本值，再按 aerobic_split 决定是否均分；
## =0 时用规则原文的固定值 aerobic_gain。
##
## 为什么重要：规则原文里癌方收入挂钩地盘、免疫收入不挂钩任何东西，
## 于是「免疫净化 → 癌方变穷 → 更打不过」是单向正反馈，癌方没有对等手段。
## 挂钩之后癌方扩张同样会削减免疫收入，两边的反馈才对称。
var aerobic_per_healthy := 0
## 免疫供能的分母：总供能 = 健康组织数 × aerobic_per_healthy ÷ 本值。
## 为什么需要：per_healthy 的最小步进是 0.1/格，在 61 格棋盘上够用，
## 但棋盘扩到 127 格后「0.1/格」意味着开局 12.0 总供能——最小步进太粗，
## 一档就能把收入翻倍。用分母把有效步进降到 0.05/格、0.033/格 …… 便于细调。
var aerobic_healthy_div := 1
## 有氧呼吸是否按免疫细胞数均分（与无氧呼吸的除法对称）。
## 两边都均分时，双方阵营总收入都与人数无关 → 人数缩放问题从根上消失。
var aerobic_split := true

# ---- 收入低保与封顶（Kevin 2026-08-26 提出「低保」，封顶是配套的另一半）----
## 收入挂钩地盘会形成雪球：领先方地盘涨、收入涨，落后方地盘跌、收入跌，双向加速。
## 低保防止落后方直接崩盘，封顶防止领先方滚雪球——两个一起用才是稳定器。
## 单位十分能量，每细胞每回合；0 = 不启用。
var anaerobic_floor := 0
var anaerobic_cap := 0
var aerobic_floor := 0
var aerobic_cap := 0


## 把每细胞收入钳制在低保与封顶之间
func clamp_income(gain: int, floor_v: int, cap_v: int) -> int:
	var out := gain
	if floor_v > 0:
		out = maxi(out, floor_v)
	if cap_v > 0:
		out = mini(out, cap_v)
	return out

# ---- 初始能量 ----
var init_energy_immune := CWData.INIT_ENERGY
var init_energy_cancer := CWData.INIT_ENERGY

## 初始癌组织格数。规则原文固定 7 格、不随人数变化——但棋盘也固定 61 格，
## 于是 6 人局的 3 个免疫细胞每回合能净化 6~9 格，一个回合就能抹平整个癌区。
var init_cancer_tiles := CWData.INIT_CANCER_TILES

# ---- 免疫行动费用 ----
var immune_move_healthy: Array = CWData.IMMUNE_MOVE_HEALTHY.duplicate()
var immune_move_cancerous: Array = CWData.IMMUNE_MOVE_CANCEROUS.duplicate()

# ---- 攻击 ----
var attack_dmg_success := CWData.ATTACK_DMG_SUCCESS
var attack_dmg_crit := CWData.ATTACK_DMG_CRIT
## 攻击失败（1/3「被癌细胞反弹」）时，免疫细胞受到的能量损失。
## 规则原文为 0：癌方没有任何伤害手段 → 免疫细胞不可能死亡（见说明 #23）。
var counter_dmg_on_fail := 0

# ---- 固化 ----
var solidify_threshold := CWData.SOLIDIFY_THRESHOLD

# ---- 胜负条件（2026-08-26 团队定案，上限 20 为暂定值，需要实测比较 20 与 15）----
var limit_round := CWData.LIMIT_ROUND
var limit_cancerous := CWData.LIMIT_CANCEROUS
## 癌方即时胜利门槛（癌组织 + 2×固化）。规则原文 41 = ⌈2/3×61⌉。
## 注意：这个门槛如果太低，对局会在回合上限之前就结束，使上限规则形同虚设。
var cancer_win_weighted := CWData.CANCER_WIN_WEIGHTED

# ---- 原发灶：每个癌症玩家的出生格开局即为固化癌组织 ----
var solid_at_cancer_spawn := CWData.SOLID_AT_CANCER_SPAWN

# ---- 免疫死亡与复活 ----
## 罚停回合数；设为 -1 表示免疫细胞死亡后不再复活（规则原文语义）
var immune_respawn_delay := CWData.IMMUNE_RESPAWN_DELAY
var immune_respawn_energy := CWData.IMMUNE_RESPAWN_ENERGY

# ---- 【E-增生】癌组织向外扩散（规则原文没有这条，团队 2026-08-26 提案）----
## 每个与癌性组织相邻的健康组织，按「相邻癌性组织数 × 本值」的概率转为癌组织。
## 单位千分率（100 = 每个相邻癌性组织贡献 10%），0 = 关闭 = 规则原文。
## 规则原文里癌组织只能靠【定殖】【侵蚀】【基质重塑】扩张，全都依赖癌细胞存活；
## 本机制让地盘能脱离癌细胞自行生长，用于打破「癌细胞一死就彻底崩盘」的负反馈。
var proliferate_per_adjacent := 0
