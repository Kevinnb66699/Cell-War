## cw_card_data.gd —— 卡牌的**身份**：卡名、类别、各池权重
##
## **本文件由 tools 从 PRD 生成，不要手改** —— 改了下次重生成就没了。
## PRD 改卡池时重跑生成脚本。**效果不在这里**：这一版只解决「抽到的是哪张卡」，
## 66 张卡的效果是另一个量级的工作，见 docs/PRD差异对照.md 第五节。
##
## 两套池的结构不一样（PRD 卡牌设定）：
##   免疫 —— 按抗原记忆等级切池，`immune[等级]` 是它在该池的权重，0 = 不在该池
##   癌症 —— 不分等级，永远一个池，但**按世界回合分三期**（1—9 / 10—19 / 20—30），
##            `cancer[期]` 是该期的权重
class_name CWCardData
extends RefCounted

enum Kind { EVENT, INSTANT, PERMANENT }   ## 事件 / 即时技能 / 永久技能

const KIND_NAMES := {
	Kind.EVENT: "事件", Kind.INSTANT: "即时", Kind.PERMANENT: "永久",
}

## 卡名 → { kind, immune: [I, II, III, X], cancer: [前期, 中期, 后期] }
const CARDS := {
	"BCL-2抗凋亡": { "kind": Kind.PERMANENT, "immune": [0,0,0,0], "cancer": [2,3,3] },
	"CXCR3趋化": { "kind": Kind.INSTANT, "immune": [0,4,0,0], "cancer": [0,0,0] },
	"DNA损伤修复": { "kind": Kind.INSTANT, "immune": [0,0,0,0], "cancer": [2,3,4] },
	"GLUT1高表达": { "kind": Kind.PERMANENT, "immune": [0,0,0,0], "cancer": [4,3,2] },
	"IFN-γ释放": { "kind": Kind.EVENT, "immune": [0,0,3,0], "cancer": [0,0,0] },
	"IFN-γ高峰": { "kind": Kind.INSTANT, "immune": [0,0,0,3], "cancer": [0,0,0] },
	"I型干扰素": { "kind": Kind.EVENT, "immune": [3,0,0,0], "cancer": [0,0,0] },
	"LFA-1黏附": { "kind": Kind.PERMANENT, "immune": [0,3,0,0], "cancer": [0,0,0] },
	"PD-L1表达": { "kind": Kind.INSTANT, "immune": [0,0,0,0], "cancer": [2,3,4] },
	"RAS持续激活": { "kind": Kind.PERMANENT, "immune": [0,0,0,0], "cancer": [4,3,2] },
	"TGF-β释放": { "kind": Kind.EVENT, "immune": [0,0,0,0], "cancer": [1,2,4] },
	"TNF-α局部炎症": { "kind": Kind.INSTANT, "immune": [0,3,0,0], "cancer": [0,0,0] },
	"上皮—间质转化": { "kind": Kind.INSTANT, "immune": [0,0,0,0], "cancer": [5,4,3] },
	"乳酸酸化": { "kind": Kind.INSTANT, "immune": [0,0,0,0], "cancer": [2,3,4] },
	"交叉呈递": { "kind": Kind.INSTANT, "immune": [0,0,3,0], "cancer": [0,0,0] },
	"代谢耦联": { "kind": Kind.INSTANT, "immune": [0,0,2,2], "cancer": [3,3,2] },
	"代谢适应": { "kind": Kind.PERMANENT, "immune": [3,0,0,0], "cancer": [0,0,0] },
	"克隆增殖": { "kind": Kind.EVENT, "immune": [0,0,0,0], "cancer": [5,4,3] },
	"克隆扩增": { "kind": Kind.EVENT, "immune": [0,0,3,2], "cancer": [0,0,0] },
	"免疫增援": { "kind": Kind.INSTANT, "immune": [0,1,2,3], "cancer": [0,0,0] },
	"免疫监视": { "kind": Kind.PERMANENT, "immune": [0,0,0,3], "cancer": [0,0,0] },
	"免疫突触成熟": { "kind": Kind.PERMANENT, "immune": [0,0,3,0], "cancer": [0,0,0] },
	"免疫记忆库": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"免疫风暴": { "kind": Kind.EVENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"全身免疫动员": { "kind": Kind.EVENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"全身性免疫清除": { "kind": Kind.EVENT, "immune": [0,0,0,1], "cancer": [0,0,0] },
	"吞噬体成熟": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"基因组不稳定": { "kind": Kind.EVENT, "immune": [0,0,0,0], "cancer": [3,3,3] },
	"基质硬化": { "kind": Kind.INSTANT, "immune": [0,0,0,0], "cancer": [2,4,5] },
	"基质稳定": { "kind": Kind.EVENT, "immune": [0,0,0,0], "cancer": [1,3,2] },
	"基质重塑": { "kind": Kind.INSTANT, "immune": [0,0,0,3], "cancer": [0,0,0] },
	"基质降解": { "kind": Kind.INSTANT, "immune": [0,2,2,2], "cancer": [0,0,0] },
	"局部吞噬": { "kind": Kind.EVENT, "immune": [2,0,0,0], "cancer": [0,0,0] },
	"急性炎症反应": { "kind": Kind.EVENT, "immune": [4,0,0,0], "cancer": [0,0,0] },
	"抗体亲和力成熟": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"抗体依赖细胞毒作用": { "kind": Kind.INSTANT, "immune": [0,0,3,0], "cancer": [0,0,0] },
	"抗原呈递增强": { "kind": Kind.EVENT, "immune": [0,3,2,0], "cancer": [0,0,0] },
	"抗原呈递强化": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"抗原摄取": { "kind": Kind.EVENT, "immune": [3,0,0,0], "cancer": [0,0,0] },
	"放疗": { "kind": Kind.INSTANT, "immune": [0,0,0,1], "cancer": [0,0,0] },
	"效应细胞浸润": { "kind": Kind.EVENT, "immune": [0,0,2,0], "cancer": [0,0,0] },
	"效应记忆形成": { "kind": Kind.PERMANENT, "immune": [0,3,0,0], "cancer": [0,0,0] },
	"模式识别增强": { "kind": Kind.PERMANENT, "immune": [3,0,0,0], "cancer": [0,0,0] },
	"溶酶体强化": { "kind": Kind.INSTANT, "immune": [0,0,3,0], "cancer": [0,0,0] },
	"炎症性趋化": { "kind": Kind.INSTANT, "immune": [0,0,4,0], "cancer": [0,0,0] },
	"炎症趋化": { "kind": Kind.INSTANT, "immune": [4,0,0,0], "cancer": [0,0,0] },
	"炎症风暴": { "kind": Kind.EVENT, "immune": [0,0,2,0], "cancer": [0,0,0] },
	"癌症干性": { "kind": Kind.PERMANENT, "immune": [0,0,0,0], "cancer": [1,2,4] },
	"穿孔素-颗粒酶": { "kind": Kind.INSTANT, "immune": [0,0,4,0], "cancer": [0,0,0] },
	"糖酵解爆发": { "kind": Kind.EVENT, "immune": [0,0,0,0], "cancer": [3,4,5] },
	"组织巡航": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"组织浸润": { "kind": Kind.PERMANENT, "immune": [0,0,3,0], "cancer": [0,0,0] },
	"组织驻留": { "kind": Kind.PERMANENT, "immune": [3,0,0,0], "cancer": [0,0,0] },
	"细胞因子网络": { "kind": Kind.PERMANENT, "immune": [0,0,2,2], "cancer": [0,0,0] },
	"细胞毒性增强": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"细胞膜修复": { "kind": Kind.INSTANT, "immune": [4,2,0,0], "cancer": [0,0,0] },
	"缺氧适应": { "kind": Kind.INSTANT, "immune": [0,3,0,3], "cancer": [0,0,0] },
	"耗竭抵抗": { "kind": Kind.PERMANENT, "immune": [0,0,0,2], "cancer": [0,0,0] },
	"肿瘤细胞募集": { "kind": Kind.INSTANT, "immune": [0,0,0,0], "cancer": [3,3,3] },
	"肿瘤血管生成": { "kind": Kind.EVENT, "immune": [0,0,0,0], "cancer": [3,3,2] },
	"自分泌生存信号": { "kind": Kind.PERMANENT, "immune": [0,2,0,0], "cancer": [0,0,0] },
	"补体级联": { "kind": Kind.INSTANT, "immune": [0,4,4,3], "cancer": [0,0,0] },
	"补体调理": { "kind": Kind.INSTANT, "immune": [4,2,0,0], "cancer": [0,0,0] },
	"趋化募集": { "kind": Kind.EVENT, "immune": [4,3,0,0], "cancer": [0,0,0] },
	"骨髓动员": { "kind": Kind.EVENT, "immune": [0,3,0,0], "cancer": [0,0,0] },
	"高亲和力克隆": { "kind": Kind.INSTANT, "immune": [0,0,0,4], "cancer": [0,0,0] },
}


## 癌症卡池的分期：第 1—9 回合 = 前期，10—19 = 中期，20—30 = 后期。
static func cancer_phase(round_no: int) -> int:
	if round_no < 10:
		return 0
	return 1 if round_no < 20 else 2


## 某一方此刻的候选池：返回 [{ name, weight }]，权重 > 0 的才在里面。
## **顺序固定**（卡名字典序）—— 权重抽取要同种子可复现。
static func pool_of(faction: int, immune_level: int, round_no: int) -> Array:
	var out: Array = []
	var phase := cancer_phase(round_no)
	for name in CARDS:
		var c: Dictionary = CARDS[name]
		var w: int = c["immune"][immune_level] if faction == CWData.Faction.IMMUNE \
			else c["cancer"][phase]
		if w > 0:
			out.append({ "name": name, "weight": w })
	return out
