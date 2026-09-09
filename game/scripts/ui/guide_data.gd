## guide_data.gd —— 16 关新手引导剧本数据（纯静态、无状态）
##
## 教程只描述现行规则，不复制规则计算。所有数字从 CWData / CWTuning 读取；
## 每步正文最多两行，细节交给高亮、悬停详情和知识之书。
class_name CWGuideData
extends RefCounted

const CHAPTER_COUNT := 16

## 每关对应的 CWCodex 章节下标。
const CODEX_PAGE := [4, 4, 5, 3, 3, 1, 1, 9, 2, 6, 7, 3, 10, 6, 0, 12]


static func chapter_titles() -> Array[String]:
	return [
		"苏醒", "病灶", "第一次接触", "时间开始流动",
		"另一种生命", "建立据点", "组织里的基础设施", "基因表达",
		"免疫记忆", "分化", "癌症并不只有一种", "肿瘤微环境",
		"世界并不稳定", "终末免疫", "怎样真正赢下一局", "毕业战",
	]


static func chapter_subtitles() -> Array[String]:
	return [
		"落子、迁移与能量。", "净化癌组织，攒抗原记忆。",
		"第一次向癌细胞出手。", "世界回合的 S 与 E。",
		"换癌方视角看扩张。", "固化与复活据点。",
		"三种特殊组织。", "卡牌与手牌。",
		"记忆、等级与卡池。", "四种免疫分化方向。",
		"四种真实癌症。", "压迫、增生、侵蚀、坏死。",
		"全场规则突变。", "X 级与效应应答。",
		"真正的胜利条件。", "自由对局开始。",
	]


static func chapter_step_count(chapter: int) -> int:
	return steps(chapter).size()


## 字段：t 标题；b 正文；flag 高亮目标；act 动作提示；watch 真实状态完成键。
static func steps(chapter: int) -> Array:
	match chapter:
		0: return _stage_awaken()
		1: return _stage_lesion()
		2: return _stage_contact()
		3: return _stage_time()
		4: return _stage_cancer_life()
		5: return _stage_stronghold()
		6: return _stage_infrastructure()
		7: return _stage_genes()
		8: return _stage_memory()
		9: return _stage_differentiate()
		10: return _stage_cancer_types()
		11: return _stage_microenvironment()
		12: return _stage_events()
		13: return _stage_effector()
		14: return _stage_victory()
		15: return _stage_graduation()
		_: return []


static func total_steps() -> int:
	var total := 0
	for chapter in CHAPTER_COUNT:
		total += steps(chapter).size()
	return total


static func _stage_awaken() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "欢迎来到细胞战争", "flag": "board", "b": [
			"你执免疫方，AI 执癌方。", "做错不惩罚——跟着高亮走就好。"] },
		{ "t": "第一步：落子", "flag": "place", "act": "place", "watch": "placed", "b": [
			"开局轮流把细胞放上棋盘。", "点一个高亮的健康组织。"] },
		{ "t": "能量就是生命", "flag": "energy", "b": [
			"行动花能量，归零即死。", "开局免疫 %s、癌方 %s。" % [
				CWData.fmt(tune.init_energy_immune), CWData.fmt(tune.init_energy_cancer)]] },
		{ "t": "第二步：迁移", "flag": "move", "act": "move", "watch": "moved", "b": [
			"点「迁移」再点相邻一格。", "健康组织 %s、癌组织 %s。" % [
				CWData.fmt(tune.immune_move_healthy[0]), CWData.fmt(tune.immune_move_cancerous[0])]] },
		{ "t": "别忘了结束回合", "flag": "end", "act": "end", "b": [
			"一人可连续行动多次。", "点右侧「结束回合」交棒。"] },
	]


static func _stage_lesion() -> Array:
	return [
		{ "t": "进癌组织＝净化", "flag": "purify", "b": [
			"免疫走进癌组织，立即净化回健康。", "悬停格子看迁移费用。"] },
		{ "t": "抗原记忆", "flag": "", "b": [
			"每净化一格 +1 抗原记忆。", "记忆攒够，免疫升级。"] },
	]


static func _stage_contact() -> Array:
	var tune := CWTuning.new()
	var limit := ["攻击次数不限，只受能量约束。"]
	if tune.attack_max_per_turn > 0:
		limit = ["每行动回合最多攻击 %d 次。" % tune.attack_max_per_turn,
			"用完按钮变灰，迁移不受影响。"]
	return [
		{ "t": "走进癌细胞＝攻击", "flag": "attack", "act": "attack", "b": [
			"迁向站有癌细胞的一格就是攻击。", "骰子会落在目标格旁。"] },
		{ "t": "看懂骰子", "flag": "d6", "b": [
			"1-2 失败弹回并自伤 %s。" % CWData.fmt(tune.counter_dmg_on_fail),
			"3-5 成功 -%s、6 大成功 -%s。" % [
				CWData.fmt(tune.attack_dmg_success), CWData.fmt(tune.attack_dmg_crit)]] },
		{ "t": "攻击次数", "flag": "attack_limit", "b": limit },
	]


static func _stage_time() -> Array:
	return [
		{ "t": "S → 行动 → E", "flag": "round", "b": [
			"世界回合先 S 结算、再轮流行动、末了 E。", "右栏顶部看进度。"] },
		{ "t": "有氧呼吸", "flag": "energy", "b": [
			"S 阶段每个免疫细胞拿一份能量。", "等级越高拿得越多。"] },
		{ "t": "E 阶段", "flag": "round", "b": [
			"压迫、增生、侵蚀、固化都在 E。", "结束回合前想一遍。"] },
	]


static func _stage_cancer_life() -> Array:
	return [
		{ "t": "癌方扩张＝定殖", "flag": "cancer_grow", "b": [
			"癌细胞走进健康组织即转癌。", "这叫【定殖】。"] },
		{ "t": "无氧呼吸", "flag": "cancer_grow", "b": [
			"E 阶段按连通块给癌方供能。", "块越大能量越足。"] },
	]


static func _stage_stronghold() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "固化计数", "flag": "cancer_grow", "b": [
			"癌细胞停在癌组织上，E 时固化 +1。",
			"到 %s 变固化癌组织。" % CWData.fmt(tune.solidify_threshold)] },
		{ "t": "复活据点", "flag": "", "b": [
			"固化癌组织净化不掉。", "也是癌细胞复活点。"] },
	]


static func _stage_infrastructure() -> Array:
	return [
		{ "t": "三种特殊组织", "flag": "special", "b": [
			"核心存能量、骨髓发卡、血管传送。", "悬停任一格看详情。"] },
		{ "t": "归属会变", "flag": "special", "b": [
			"特殊组织也会被定殖。", "谁控制就为谁产资源。"] },
	]


static func _stage_genes() -> Array:
	return [
		{ "t": "抽卡", "flag": "draw", "act": "draw", "b": [
			"「基因表达」花 %s 抽一张。" % CWData.fmt(CWData.IMMUNE_DRAW_COST),
			"每回合最多 %d 次。" % CWData.DRAW_MAX_PER_TURN] },
		{ "t": "三类卡", "flag": "card_kinds", "b": [
			"事件立即结算、技能进手牌。", "永久技能装上一直生效。"] },
		{ "t": "读卡与打出", "flag": "hand_card", "b": [
			"悬停手牌看效果原文。", "双击打出、右键双击弃置。"] },
		{ "t": "手牌上限", "flag": "hand_limit", "b": [
			"最多持 %d 张，超了要弃。" % CWData.HAND_MAX, "骨髓发的卡记得去收。"] },
	]


static func _stage_memory() -> Array:
	return [
		{ "t": "记忆与等级", "flag": "", "b": [
			"净化攒记忆：%d 升 II、%d 升 III、%d 升 X。" % [
				CWData.LEVEL_MIN_MEMORY[1], CWData.LEVEL_MIN_MEMORY[2], CWData.LEVEL_MIN_MEMORY[3]],
			"升级换更强的卡池。"] },
		{ "t": "等级收益", "flag": "differentiate", "b": [
			"III 级起迁癌组织打折。", "还解锁「分化」。"] },
	]


static func _stage_differentiate() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "何时分化", "flag": "differentiate", "b": [
			"%s 解锁、免费、一局一次。" % CWData.LEVEL_NAMES[tune.differentiate_min_level],
			"全阵营每种限一个。"] },
		{ "t": "四个方向", "flag": "differentiate", "b": [
			"B / T / 巨噬 / 树突各有所长。", "图鉴里查技能原文。"] },
	]


static func _stage_cancer_types() -> Array:
	return [
		{ "t": "四种真实癌症", "flag": "", "b": [
			"黑色素瘤会转移、印戒会自爆。", "骨肉瘤会硬化、小细胞跑得快。"] },
		{ "t": "对位思路", "flag": "", "b": [
			"悬停癌细胞看种类与能量。", "知识之书查全部技能。"] },
	]


static func _stage_microenvironment() -> Array:
	return [
		{ "t": "微环境压迫", "flag": "immune_defend", "b": [
			"身边癌组织太多，回合末掉能量。", "悬停格子看预计损失。"] },
		{ "t": "增生与侵蚀", "flag": "round", "b": [
			"癌组织向邻居增生。", "被包住的健康块会被侵蚀。"] },
		{ "t": "坏死", "flag": "", "b": [
			"有些效果把格子变坏死。", "坏死不给有氧供能。"] },
	]


static func _stage_events() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "世界事件", "flag": "world_event", "b": [
			"第 %s 回合全场变规则。" % CWCodex.event_rounds_text(tune.limit_round),
			"左侧事件列随时查。"] },
	]


static func _stage_effector() -> Array:
	return [
		{ "t": "X 级与效应记忆", "flag": "differentiate", "b": [
			"X 级后记忆改攒效应记忆。", "攒 %d 份可发动效应应答。" % CWData.EFFECTOR_COST] },
		{ "t": "效应应答", "flag": "", "b": [
			"每个分化方向一种终极手段。", "一局一次、足以翻盘。"] },
	]


static func _stage_victory() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "免疫怎么赢", "flag": "round", "b": [
			"杀光癌细胞还不够。", "还要清掉可复活的固化据点。"] },
		{ "t": "癌症怎么赢", "flag": "round", "b": [
			"加权占地至少 %d，连 %d 个回合末达标。" % [
				tune.cancer_win_weighted, tune.cancer_win_hold_rounds], "第一次达标只响警报。"] },
		{ "t": "回合上限", "flag": "round", "b": [
			"%d 回合没分胜负按占地判定。" % tune.limit_round,
			"癌性组织至少 %d 格癌胜。" % tune.limit_cancerous] },
	]


static func _stage_graduation() -> Array:
	return [
		{ "t": "你出师了", "flag": "graduated", "b": [
			"接下来是自由对局。", "知识之书随时查规则。"] },
	]


static func act_of(chapter: int, step: int) -> String:
	var chapter_steps: Array = steps(chapter)
	if step < 0 or step >= chapter_steps.size():
		return ""
	return str(chapter_steps[step].get("act", ""))


## placed / moved 只观察真实局面；空串表示讲解型步骤。
static func watch_of(chapter: int, step: int) -> String:
	var chapter_steps: Array = steps(chapter)
	if step < 0 or step >= chapter_steps.size():
		return ""
	return str(chapter_steps[step].get("watch", ""))
