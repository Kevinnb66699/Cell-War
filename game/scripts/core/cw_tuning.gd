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


## 2026-08-28：PRD 把 2026-08-27 那套推荐方案的**方向**吸收进了规则原文
## （免疫收入挂钩健康组织、癌方无氧呼吸提高、【E-增生】正式入规），但数值另定，
## 而且**只有癌方按己方细胞数均分、免疫方不均分**。默认值现在就是 PRD，所以
## `CWTuning.new()` = 按 PRD 跑，旧的 recommended() 已被 PRD 取代、删除。
##
## 下面这个预设保留的是 PRD **没有**解决的那一项：人数缩放。
## 《平衡测试报告》问题 #29 的根因是「癌方阵营总收入与人数无关，免疫方随人数线性增长」，
## 修法是两边都按己方细胞数均分。PRD 的公式结构和 #29 完全一样，
## 用开局盘面算阵营总收入是 2 人 2.6:6.0 / 4 人 5.2:6.0 / 6 人 7.8:6.0。
## 想验证这一条时用本预设跑 balance_sim 对照。
static func split_income() -> CWTuning:
	var t := CWTuning.new()
	t.name = "PRD + 免疫收入均分"
	t.aerobic_split = true
	return t


# ---- 收入 ----
var anaerobic_per_cancer := CWData.ANAEROBIC_PER_CANCER      # 每癌组织供能
var anaerobic_per_solid := CWData.ANAEROBIC_PER_SOLID        # 每固化癌组织供能
## 无氧呼吸是否按连通块内癌细胞数均分（关掉=每个癌细胞独享全额，大幅提升多细胞癌方收入）
var anaerobic_split := true

## 【S-有氧呼吸】公式里的乘数：每个免疫细胞得 (健康 - 坏死) ÷ 总格数 × 本值 ÷ 10。
var aerobic_mult := CWData.AEROBIC_MULT
## 有氧呼吸是否再按免疫细胞数均分。
## **PRD 是不均分的**，所以默认 false；true 时两边阵营总收入都与人数无关
## （《平衡测试报告》#29 的修法，见 split_income()）。
var aerobic_split := false

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

## 初始癌组织格数。**-1 = 按人数取**（`CWData.init_cancer_tiles`，现值 4 人 15 / 6 人 21）。
## 只有平衡测试要把所有人数钉成同一个数时才设具体值 —— 那是扫这条杠杆的唯一办法，
## 因为按人数分档的表本身就是被扫的对象。
var init_cancer_tiles := -1

# ---- 免疫行动费用 ----
var immune_move_healthy: Array = CWData.IMMUNE_MOVE_HEALTHY.duplicate()
var immune_move_cancerous: Array = CWData.IMMUNE_MOVE_CANCEROUS.duplicate()

# ---- 癌方移动费用 = 占地单价 ----
## 癌细胞每移动到一格健康组织就【定殖】一格，所以「移动费」就是「占地单价」。
## 《平衡方案_PRD版》第二节①认定的根因（转化比 4.6:1）全部落在这四个数上，
## 但它们此前是写死的常量、扫不了 —— 免疫那边一直有旋钮，这里补齐对称。
## 2026-08-31 口径 #82 已把 CWData 那三个默认值抬上去了（1.2 / 0.7 / 0.5），
## 所以这里的默认值**不再等于 PRD**，等于「引擎现值」。要跑 PRD 原样得显式传 PRD 的数。
var cancer_move_cancerous := CWData.CANCER_MOVE_CANCEROUS
var cancer_move_healthy := CWData.CANCER_MOVE_HEALTHY
## 小细胞肺癌【极简胞浆】：移动至健康组织**永久**走这个折后价
var sclc_move_healthy := CWData.SCLC_MOVE_HEALTHY
## 黑色素瘤【伪足穿透】：目标邻接 ≥2 格癌性组织时走这个折后价，**无次数限制**
var pseudopod_cost := CWData.PSEUDOPOD_COST

# ---- 攻击 ----
var attack_dmg_success := CWData.ATTACK_DMG_SUCCESS
var attack_dmg_crit := CWData.ATTACK_DMG_CRIT
## 攻击失败（1/3「被癌细胞反弹」）时，攻击者自身的能量损失。
## 2026-08-31 补齐到 PRD 值 0.5（口径 #84）；此前写死 0，是 61 格旧规则留下的。
## 留成旋钮是因为它直接决定「进攻型免疫打法的风险」，是重跑平衡时要扫的一档。
var counter_dmg_on_fail := CWData.COUNTER_DMG_ON_FAIL

# ---- 固化 ----
var solidify_threshold := CWData.SOLIDIFY_THRESHOLD

# ---- 胜负条件（PRD 原值：30 回合 / 加权 64 / 终局线 42）----
var limit_round := CWData.LIMIT_ROUND
var limit_cancerous := CWData.LIMIT_CANCEROUS
## 癌方即时胜利门槛（癌组织 + 2×固化）。规则原文 41 = ⌈2/3×61⌉。
## 注意：这个门槛如果太低，对局会在回合上限之前就结束，使上限规则形同虚设。
var cancer_win_weighted := CWData.CANCER_WIN_WEIGHTED

# ---- 原发灶：每个癌症玩家的出生格开局即为固化癌组织 ----
var solid_at_cancer_spawn := CWData.SOLID_AT_CANCER_SPAWN

# ---- 免疫死亡与复活 ----
## 额外罚停回合数；PRD 为 0（下一个 S 阶段即复活）。设为 -1 表示死后不再复活。
var immune_respawn_delay := CWData.IMMUNE_RESPAWN_DELAY
var immune_respawn_energy := CWData.IMMUNE_RESPAWN_ENERGY

# ---- 【E-增生】癌组织向外扩散（规则原文没有这条，团队 2026-08-26 提案）----
## 每个与癌性组织相邻的健康组织，按「相邻癌性组织数 × 本值」的概率转为癌组织。
## 单位千分率（40 = 每个相邻癌性组织贡献 4% = PRD 值），0 = 关闭。
## 作用是让地盘能脱离癌细胞自行生长，打破「癌细胞一死就彻底崩盘」的负反馈。
var proliferate_per_adjacent := CWData.PROLIFERATE_PER_ADJ
