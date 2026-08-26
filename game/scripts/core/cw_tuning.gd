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


## 当前推荐的平衡方案（2026-08-26 模拟得出，尚未写回规则文档，待团队确认）。
## AI 互搏 60 局 × 各人数：4 人局癌胜率 50%，6 人局 46%（规则原文为 0% / 0%）。
## 四项改动，缺一不可——详见 docs/平衡测试报告.md：
##   ① 免疫【有氧呼吸】改为挂钩健康组织（0.1/格，按免疫细胞数均分）
##   ② 癌方【无氧呼吸】提到 0.5/格、固化 1.2/格
##   ③ 新增【E-增生】：健康组织按 相邻癌性组织数×4% 的概率被侵占
##   ④ ①②的「均分」让双方阵营总收入都与人数无关，人数缩放问题因此消失
static func recommended() -> CWTuning:
	var t := CWTuning.new()
	t.name = "推荐方案"
	t.aerobic_per_healthy = 1
	t.aerobic_split = true
	t.anaerobic_per_cancer = 5
	t.anaerobic_per_solid = 12
	t.proliferate_per_adjacent = 40
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
## 有氧呼吸是否按免疫细胞数均分（与无氧呼吸的除法对称）。
## 两边都均分时，双方阵营总收入都与人数无关 → 人数缩放问题从根上消失。
var aerobic_split := true

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

# ---- 【E-增生】癌组织向外扩散（规则原文没有这条，团队 2026-08-26 提案）----
## 每个与癌性组织相邻的健康组织，按「相邻癌性组织数 × 本值」的概率转为癌组织。
## 单位千分率（100 = 每个相邻癌性组织贡献 10%），0 = 关闭 = 规则原文。
## 规则原文里癌组织只能靠【定殖】【侵蚀】【基质重塑】扩张，全都依赖癌细胞存活；
## 本机制让地盘能脱离癌细胞自行生长，用于打破「癌细胞一死就彻底崩盘」的负反馈。
var proliferate_per_adjacent := 0
