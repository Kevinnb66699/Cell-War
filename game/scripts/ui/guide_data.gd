## guide_data.gd —— 新手引导剧本数据（纯静态、无状态）
##
## 设计目标：把「一步一步教新手熟悉机制」这件事写成**数据**，UI 与桥只负责
## 照着演。引导不硬锁对局：剧本里每个需要玩家操作的步骤都只提供提示与可选演示，
## 玩家做错就继续提示，绝不拦住引擎。
##
## 剧本按「关卡 + 步骤」组织。关卡是主题块（关卡 1: 认识棋盘/目标；关卡 2: 落子/移动/
## 净化；关卡 3: 攻击/判定；关卡 4: 抽卡/手牌/分化；关卡 5: 世界回合/收尾/自由游玩）。
## 每一关的步骤绝大多数是「展示型」（只需要玩家点继续），少数是「操作型」
## （由 CWGuideBridge 在等玩家作答时喂提示）。
##
## steps() 是纯函数：数字一律现读 CWData / CWTuning 默认值，不在这里写第二份。
class_name CWGuideData
extends RefCounted

## 引导剧本有几关
const CHAPTER_COUNT := 6

## 每关在 CWCodex 里对应的章节目录下标（详见 cw_codex.chapters()）。
## 通过这个挂钩，玩家在引导面板里点「翻到知识之书」能直达正在学的内容。
const CODEX_PAGE := [0, 4, 5, 6, 3, 8]

## 关卡名（也用于进度显示）
static func chapter_titles() -> Array[String]:
	return [
		"认识棋盘",
		"落子与移动",
		"攻击与判定",
		"抽卡与手牌",
		"世界回合",
		"细胞图鉴",
	]

## 关卡一句概括（新手引导目录页用）
static func chapter_subtitles() -> Array[String]:
	return [
		"先看懂目标、棋盘和地形。",
		"学会落子、迁移，以及把癌组织净化回健康。",
		"看懂骰子、攻击成功与失败，学习进攻节奏。",
		"学会抽卡、读卡、打开/弃置手牌，了解分化入口。",
		"看懂一整个世界回合，然后自由开始你的第一局。",
		"九种细胞一页看懂：谁是谁、怎么用、怕什么。",
	]

## 关卡图标：00/01/02/03/04（UI 画步骤进度用）
static func chapter_step_count(chapter: int) -> int:
	return steps(chapter).size()

## 返回某一关的步骤数组。
## 每步字段：
##   t  标题（短，面板标题栏用）
##   b  正文行（已折好的一行一元素，10px 字体固定 15px 行高）
##   flag 可选：本步骤需要在棋盘/界面高亮哪块视觉（guide.gd 按名字找）
##   act 可选：等玩家操作时交给 CWGuideBridge 的提示键，也是它的 STEPS 索引
static func steps(chapter: int) -> Array:
	match chapter:
		0: return _chapter_intro()
		1: return _chapter_placement()
		2: return _chapter_attack()
		3: return _chapter_cards()
		4: return _chapter_world()
		5: return _chapter_cells()
		_: return []


static func total_steps() -> int:
	var n := 0
	for i in CHAPTER_COUNT:
		n += steps(i).size()
	return n


## ---- 第一关：认识棋盘 ----
static func _chapter_intro() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "欢迎来到细胞战争", "flag": "", "b": [
			"这一套新手引导会带你走完一整局基础流程。",
			"我会像教练一样陪伴你：一边讲一边让你亲手操作。",
			"想随时退出时，点面板左下角「跳过引导」即可。",
		] },
		{ "t": "这一局的目标", "flag": "", "b": [
			"你扮演免疫方，AI 扮演癌方。",
			"免疫要清剿所有癌细胞，并且没有可供复活的固化癌组织。",
			"癌方要把癌组织铺开，让加权占地达到 %d。" % tune.cancer_win_weighted,
		] },
		{ "t": "认识棋盘", "flag": "board", "b": [
			"六边形棋盘共 %d 格。" % CWData.TOTAL_TILES,
			"青绿色是健康组织，红色是癌组织。",
			"悬停任意格稍候，会弹出那一格的地形详情。",
		] },
		{ "t": "三种特殊组织", "flag": "special", "b": [
			"代谢核心：健康时每 %d 个世界回合存 %s 能量（最多 %s），踩上去当场收走。" % [
				CWData.CORE_HEALTHY_PERIOD, CWData.fmt(CWData.CORE_HEALTHY_GAIN), CWData.fmt(CWData.CORE_STORE_MAX)],
			"骨髓：踩上去拿卡，也是免疫复活的锚点。",
			"血管：S 阶段把站在上面的细胞传到另一端；黑色素瘤在血管上还能【血行转移】。",
		] },
		{ "t": "看完这页就动手", "flag": "", "b": [
			"接下来我会带你把第一个免疫细胞放到棋盘上。",
			"不用紧张，做错也不会有惩罚。",
		] },
	]


## ---- 第二关：落子与移动 ----
static func _chapter_placement() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "第一步：落子", "flag": "place", "act": "place", "b": [
			"开局要轮流把细胞放到棋盘上。",
			"点一个高亮的健康组织，把免疫细胞放下去。",
			"我建议选在紧邻癌区外侧的健康组织上，方便下一步进攻。",
		] },
		{ "t": "能量就是生命", "flag": "energy", "b": [
			"右侧竖条显示你当前的能量。开局免疫 %s、癌方 %s。" % [
				CWData.fmt(tune.init_energy_immune), CWData.fmt(tune.init_energy_cancer)],
			"行动要花能量；支付不能让能量降到 0，归零就死亡。",
		] },
		{ "t": "第二步：迁移", "flag": "move", "act": "move", "b": [
			"轮到你时，点底部「迁移」按钮，再点一个高亮的相邻健康组织。",
			"走进癌组织会自动【净化】，并让免疫 +1 抗原记忆。",
		] },
		{ "t": "净化与记忆", "flag": "purify", "b": [
			"净化把癌组织变回健康组织，这是免疫争夺地盘的基本方式。",
			"每净化一格 +1 抗原记忆；记忆到 %d 升 II 级、%d 升 III 级、%d 升 X 级。" % [
				CWData.LEVEL_MIN_MEMORY[1], CWData.LEVEL_MIN_MEMORY[2], CWData.LEVEL_MIN_MEMORY[3]],
		] },
		{ "t": "别忘了结束回合", "flag": "end", "act": "end", "b": [
			"一个人可以连续行动多次，直到点右侧「结束回合」（或空格）。",
		] },
	]


## ---- 第三关：攻击与判定 ----
static func _chapter_attack() -> Array:
	var tune := CWTuning.new()
	var fail := "1-2 失败：免疫被弹回原格"
	if tune.counter_dmg_on_fail > 0:
		fail += "，并损失 %s 能量" % CWData.fmt(tune.counter_dmg_on_fail)
	fail += "。"
	var limit: Array = ["攻击次数不限，只受能量约束。"]
	if tune.attack_max_per_turn > 0:
		limit = ["每个免疫细胞每行动回合最多攻击 %d 次。" % tune.attack_max_per_turn,
			"用完攻击选项会从行动栏消失，普通迁移不受影响。"]
	return [
		{ "t": "怎么发起攻击", "flag": "attack", "act": "attack", "b": [
			"免疫走进站有癌细胞的一格就是一次攻击。",
			"骰子会落在目标格上方演一遍；结算说明由引擎给出。",
		] },
		{ "t": "看懂骰子", "flag": "d6", "b": [
			fail,
			"3-5 成功：目标失去 %s 能量。" % CWData.fmt(tune.attack_dmg_success),
			"6 大成功：目标失去 %s 能量。" % CWData.fmt(tune.attack_dmg_crit),
		] },
		{ "t": "攻击次数", "flag": "attack_limit", "b": limit },
		{ "t": "失败也会发生", "flag": "", "b": [
			"进攻不是稳赢：失败会丢能量、又站回原位。",
			"学会在能量充裕、角度占优时出手。",
		] },
		{ "t": "进攻节奏", "flag": "", "b": [
			"清剿癌细胞前先想：它踩在什么组织上？旁边有没有友军/地形加成？",
			"用净化扩张地盘，用攻击拔除威胁，两者交替。",
		] },
	]


## ---- 第四关：抽卡与手牌 ----
static func _chapter_cards() -> Array:
	var tune := CWTuning.new()
	return [
		{ "t": "抽卡入口", "flag": "draw", "act": "draw", "b": [
			"点底部「基因表达」花 %s 抽一张卡。" % CWData.fmt(CWData.IMMUNE_DRAW_COST),
			"抽到的卡会从你的细胞身上飞进左下角手牌抽屉。",
		] },
		{ "t": "三类卡牌", "flag": "card_kinds", "b": [
			"【事件】：抽到立刻结算并弃置，不进手牌。",
			"【技能】：进手牌，打出一张就没一张。",
			"【永久技能】：打出即装备在细胞上，死亡也不掉。",
		] },
		{ "t": "读一张卡", "flag": "hand_card", "b": [
			"悬停手牌会抬高；左键点牌可以打出/选目标，右键进入弃置确认。",
			"打牌也消耗一次行动，所以要判断时机。",
		] },
		{ "t": "手牌上限", "flag": "hand_limit", "b": [
			"每个细胞最多持有 %d 张牌，超了要弃到 %d 张。" % [CWData.HAND_MAX, CWData.HAND_MAX],
			"骨髓每 %d 个世界回合还会发一张卡，别忘了去收。" % CWData.MARROW_HEALTHY_PERIOD,
		] },
		{ "t": "分化预览", "flag": "differentiate", "b": [
			"免疫等级升到 %s 后可以免费分化（B/T/巨噬/树突）。" % CWData.LEVEL_NAMES[tune.differentiate_min_level],
			"每种分化全阵营限一个，尽量配齐阵容。",
		] },
	]


## ---- 第五关：世界回合与收尾 ----
static func _chapter_world() -> Array:
	var tune := CWTuning.new()
	## 无氧呼吸写在它实际发生的那一段（eturn=1：各癌细胞回合末；0：E 阶段）
	var turn := "玩家回合：按行动顺序轮流行动"
	var e := "E 阶段："
	if tune.anaerobic_on_turn_end:
		turn += "；癌细胞结束回合时结算【无氧呼吸】。"
	else:
		turn += "。"
		e += "癌方结算【无氧呼吸】、"
	e += "微环境压迫、增生、侵蚀、固化，最后判胜负。"
	return [
		{ "t": "一个世界回合", "flag": "round", "b": [
			"S 阶段：世界事件、特殊组织产出、血管传送，然后复活，免疫拿【有氧呼吸】。",
			turn,
			e,
		] },
		{ "t": "癌方如何成长", "flag": "cancer_grow", "b": [
			"癌细胞每走进健康组织就【定殖】一格（花 %s 能量）。" % CWData.fmt(tune.cancer_move_healthy),
			"癌细胞停在癌组织上会积累固化计数，固化后更像要塞。",
		] },
		{ "t": "免疫如何防守", "flag": "immune_defend", "b": [
			"净化癌组织、清理固化、攻击癌细胞，三件事一起做。",
			"别让自己的免疫细胞陷在癌区深处（微环境压迫会扣能量）。",
		] },
		{ "t": "世界事件", "flag": "world_event", "b": [
			"第 %s 世界回合会触发世界事件。" % CWCodex.event_rounds_text(tune.limit_round),
			"事件可能同时影响两边，注意右上角/日志的通报。",
		] },
		{ "t": "你出师了", "flag": "graduated", "b": [
			"基础你都会了！可以继续自由游玩这一局。",
			"回主菜单后，记得用「知识之书」随时查图鉴、看速查。",
		] },
	]


## ---- 第六关：细胞图鉴（展示型：九种细胞各一组速览） ----
static func _chapter_cells() -> Array:
	var tune := CWTuning.new()
	var macro := "巨噬细胞：攻击造成损失后回血一半"
	if tune.macro_heal_purify > 0:
		macro = "巨噬细胞：每次净化回 %s 能量、攻击后再回血一半" % CWData.fmt(tune.macro_heal_purify)
	macro += "，跟着大部队越打越富。"
	return [
		{ "t": "免疫主力", "flag": "", "b": [
			"免疫细胞是开局就有的基础细胞：能迁移、能净化、能攻击。",
			"净化癌组织 +1 抗原记忆，是免疫争夺地盘的基本方式。",
			"记住一句话：进癌组织=净化，进癌细胞=攻击。",
		] },
		{ "t": "分化阵容 ①", "flag": "differentiate", "b": [
			"B细胞：花 %s 能量放【抗体】，让邻接健康组织的癌细胞集体受伤。" % CWData.fmt(CWData.ANTIBODY_COST),
			"T细胞：花 %s 能量【细胞毒素】清癌、%s 能量【裂解】破固化。" % [CWData.fmt(CWData.TOXIN_COST), CWData.fmt(CWData.LYSE_COST)],
			"两者都要免疫等级 %s 解锁，全阵营各限一个。" % CWData.LEVEL_NAMES[tune.differentiate_min_level],
		] },
		{ "t": "分化阵容 ②", "flag": "", "b": [
			macro,
			"树突细胞：花 %s 能量建趋化源，免疫靠近少付 %d%%、癌方远离多付 %d%%。" % [
				CWData.fmt(CWData.CHEMO_COST), 100 - CWData.CHEMO_IMMUNE_PCT, CWData.CHEMO_CANCER_PCT - 100],
			"它还能给相邻癌细胞挂【标记】，让下一次受伤翻倍。",
		] },
		{ "t": "癌方 ①", "flag": "", "b": [
			"黑色素瘤：在血管上花 %s 能量跳任意健康格并扩散一片癌组织。" % CWData.fmt(CWData.MELANOMA_HOMING_COST),
			"印戒细胞：弃光全部能量自爆，把周围最多 %d 格拉成癌组织。" % CWData.MUCUS_MAX_CONVERT,
			"前者要拆机动，后者要防它贴脸自爆。",
		] },
		{ "t": "癌方 ②", "flag": "", "b": [
			"骨肉瘤：花 %s 标记脚下癌组织，%d 回合后直接固化；站在固化组织上受伤只剩 %d%%。" % [
				CWData.fmt(tune.osteo_ossify_cost), tune.osteo_ossify_rounds, CWData.OSTEO_BARRIER_PERCENT],
			"小细胞肺癌：移入健康格只花 %s，还能向某方向跃 %d 格。" % [
				CWData.fmt(tune.sclc_move_healthy), CWData.METASTASIS_RANGE],
			"速度与滚雪球兼备，别让它把地盘滚大。",
		] },
		{ "t": "图鉴速查", "flag": "", "b": [
			"九种细胞的完整技能都在「知识之书 → 细胞图鉴」里。",
			"对局中把鼠标悬停到右栏细胞或技能上，也能看技能原文。",
			"到这里，新手引导就全部完成啦——去自由游玩吧！",
		] },
	]


## 从「教程桥」视角：某个操作步骤要演示/提示的动作键。
## 返回空串表示这不是一个操作步骤。
static func act_of(chapter: int, step: int) -> String:
	var s: Array = steps(chapter)
	if step < 0 or step >= s.size():
		return ""
	return str(s[step].get("act", ""))
