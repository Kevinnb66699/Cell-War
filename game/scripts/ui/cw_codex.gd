## cw_codex.gd —— 知识之书：机制图鉴（主菜单 / 暂停菜单可达的一页式翻阅面板）
##
## 定位是「图鉴」，不是「规则书」：规则速查页（CWRulesPage）管「怎么赢 / 回合 /
## 判定」那一张硬数字总览，这里管「每个东西是什么、怎么用」，把新手引导每一课的
## 要点沉淀成随时能回看的条目。两者可以同时存在，不互相替代。
##
## 数字一律现读 CWData / CWTuning 默认值，不写第二份 —— 调平衡旋钮后本页自动跟上
## （和 CWRulesPage.sections() 是同一条纪律）。行文只解释机制，不复制 PRD 原文。
##
## 交互：左右箭头 / 方向键 / 滚轮翻页（一章一页），页内装不下时滚轮先滚页内、
## 到顶底再翻章；Esc 或右键关闭。内容 chapters() 是纯函数，无头测试直接核对。
##
## 正文渲染沿用规则速查页的做法：10px 点阵字、固定 15px 行高、预先手工折行，
## 不做运行时自动换行测量 —— 点阵字非整数行高会糊，测量又依赖字体排版细节，
## 固定行高最简单也最稳。chapters() 里每行的 b 就是折好的一行。
class_name CWCodex
extends Control

const W := 580
const H := 470
const PAD := 20
const HEADER_H := 52
const FOOTER_H := 34
const LINE := 15
const TITLE_LINE := 24
const GAP := 8

var _page := 0
var _scroll := 0.0
var _max_scroll := 0.0
var _body: Control
var _content: Control
var _title: Label
var _page_label: Label
var _prev: Label
var _next: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func open() -> void:
	_ensure_built()
	open_to(0)


## 直接翻到指定章（引导面板「翻到知识之书」用）。页码会被钳到合法范围。
func open_to(page: int) -> void:
	_ensure_built()
	visible = true
	_page = clampi(page, 0, chapters().size() - 1)
	_scroll = 0.0
	_rebuild_page()


## 兜底：程序化建出来的实例在 _ready 之前就可能被 open/open_to 调用，
## 这里保证控件树先建好（已建过就是空操作）。
func _ensure_built() -> void:
	if _title == null:
		_build()


## 由 CWMainMenu / CWPauseMenu 路由（覆盖层统一走菜单路由）
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		visible = false
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("ui_down"):
		get_viewport().set_input_as_handled()
		_next_page()
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_up"):
		get_viewport().set_input_as_handled()
		_prev_page()


## 右键关闭接在 gui_input：本层是 STOP，鼠标事件到不了菜单路由（同规则速查页）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			accept_event()
			visible = false
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			accept_event()
			_scroll_by(-40.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			accept_event()
			_scroll_by(40.0)


func _scroll_by(delta: float) -> void:
	if _max_scroll > 0.0:
		_scroll = clampf(_scroll + delta, 0.0, _max_scroll)
		_layout()
		return
	if delta < 0.0:
		_next_page()
	else:
		_prev_page()


func _prev_page() -> void:
	_page = maxi(_page - 1, 0)
	_scroll = 0.0
	_rebuild_page()


func _next_page() -> void:
	_page = mini(_page + 1, chapters().size() - 1)
	_scroll = 0.0
	_rebuild_page()


## 章节目录。纯函数：{ title, entries:[{t, b:[行...]}] }。数字现算、正文预折行。
## 会随旋钮变的句子（能量上限、有氧公式、无氧时机、反击、攻击上限、占地胜连续回合……）
## 按旋钮现值拼，关掉的机制整句消失 —— 和规则速查页同一条纪律：图鉴里不许出现和引擎不符的数
## （2026-09-05 按当日落地的九条规则逐条核对过，见开发日志）。点阵字库没有 √ ≥ − 这类符号，
## 公式一律写成汉字（「平方根」）和 ASCII 的 - / ×。
static func chapters() -> Array:
	var tune := CWTuning.new()
	var lv: Array = CWData.LEVEL_NAMES
	## 【S-有氧呼吸】现行等级式：基数 + 等级 × 步长（-1 = 基数按人数分档）；0 = 退回旧的盘面公式
	var aerobic: Array = []
	if tune.aerobic_level_base != 0:
		aerobic.append("每个世界回合 S 阶段【有氧呼吸】，每个免疫细胞各拿一份：")
		aerobic.append("（抗原记忆等级 - 1）× %s + 基数，等级 I/II/III/X 记 1/2/3/4。"
			% CWData.fmt(tune.aerobic_level_step))
		if tune.aerobic_level_base < 0:
			var parts: Array[String] = []
			var ns: Array = CWData.AEROBIC_LEVEL_BASE_BY_PLAYERS.keys()
			ns.sort()
			for n in ns:
				parts.append("%d 人局 %s" % [n, CWData.fmt(CWData.aerobic_level_base(n))])
			aerobic.append("基数按人数：" + "、".join(parts) + "。多净化、升等级，收入就涨。")
		else:
			aerobic.append("基数 %s。多净化、升等级，收入就涨。" % CWData.fmt(tune.aerobic_level_base))
	else:
		aerobic.append("每个世界回合 S 阶段【有氧呼吸】：按全盘健康组织占比 × %s 结算，"
			% CWData.fmt(tune.aerobic_mult))
		aerobic.append("每个免疫细胞各拿一份。")
	if tune.aerobic_floor > 0:
		aerobic.append("每人至少拿 %s（低保）。" % CWData.fmt(tune.aerobic_floor))
	## 【E-无氧呼吸】：开方公式（0 = 退回线性求和）；时机看 anaerobic_on_turn_end（各癌细胞回合末 / E 阶段）
	var when := "每个癌细胞在自己的行动回合末" if tune.anaerobic_on_turn_end else "每个世界回合 E 阶段"
	var split := "，块内癌细胞均分。" if tune.anaerobic_split else "。"
	var anaerobic: Array = [when + "结算【无氧呼吸】："]
	if tune.anaerobic_sqrt_coef > 0:
		anaerobic.append("%s × 所在癌组织连通块格数的平方根" % CWData.fmt(tune.anaerobic_sqrt_coef) + split)
		anaerobic.append("块越大进账越多，但两个癌细胞挤一块不如各占一块。")
	else:
		anaerobic.append("所在连通块每格癌组织 %s、每格固化 %s" % [
			CWData.fmt(tune.anaerobic_per_cancer), CWData.fmt(tune.anaerobic_per_solid)] + split)
		anaerobic.append("癌组织铺得越开，进账越多。")
	## 能量存量上限：0 = 不封（团队 2026-09-05 取消了 15.0 的封顶）
	var energy: Array = ["免疫细胞开局 %s 能量，癌细胞开局 %s 能量。" % [
		CWData.fmt(tune.init_energy_immune), CWData.fmt(tune.init_energy_cancer)]]
	if tune.energy_cap > 0:
		energy.append("每格账户最多存 %s，多出的部分在世界回合末消失。" % CWData.fmt(tune.energy_cap))
	else:
		energy.append("能量没有存量上限，攒多少都留得住。")
	## 癌方占地胜：达标后要不要连续几个回合末都达标（默认 2：首次达标只是警报）
	var cancer_win: Array = ["让「癌组织 + 2 × 固化癌组织」的加权占地达到 %d，" % tune.cancer_win_weighted]
	if tune.cancer_win_hold_rounds > 1:
		cancer_win.append("且连续 %d 个世界回合末都达标（首次达标只是警报）。" % tune.cancer_win_hold_rounds)
	else:
		cancer_win.append("E 阶段结算时立即获胜。")
	## 攻击判定里随旋钮出没的两句
	var fail_line := "1-2 失败：弹回原格（费用不退）"
	if tune.counter_dmg_on_fail > 0:
		fail_line += "，自身再 -%s" % CWData.fmt(tune.counter_dmg_on_fail)
	fail_line += "；"
	var atk_limit: Array = ["攻击次数不限，只受能量约束。"]
	if tune.attack_max_per_turn > 0:
		atk_limit = ["每个行动回合最多攻击 %d 次，" % tune.attack_max_per_turn,
			"用完后攻击选项从行动栏消失，普通迁移不受影响。"]
	## 玩家回合 / E 阶段：无氧呼吸写在它实际发生的那一段
	var turn_lines: Array = [
		"按行动顺序轮流行动，每个人可以连续行动多次，",
		"直到自己按下「结束回合」。右侧竖条标明回合数与轮到谁。"]
	var e_phase := "微环境压迫、增生、侵蚀、"
	if tune.anaerobic_on_turn_end:
		turn_lines.append("癌细胞按下「结束回合」那一刻，结算自己的【无氧呼吸】。")
	else:
		e_phase = "癌方结算【无氧呼吸】，随后" + e_phase
	## 分化细胞里随旋钮出没的句子
	var b_lines: Array = [
		"【抗体】：范围内与健康组织邻接的癌细胞各受 %s 伤害；" % CWData.fmt(CWData.ANTIBODY_DAMAGE),
		"没有目标时改为转化癌组织。"]
	if tune.antibody_halve:
		b_lines.append("同一世界回合内再放一次，伤害减半、再减半。")
	var t_lines: Array = [
		"【细胞毒素】把相邻癌组织转健康并留下坏死；",
		"【裂解】破除相邻的固化癌组织。主攻手。"]
	if tune.necrosis_no_aerobic:
		t_lines.append("站在坏死格上的免疫细胞那一回合拿不到有氧收入，放完毒记得走开。")
	var macro_line := "【吞噬】：攻击造成能量损失后，回复目标损失量的一半。"
	var macro_codex := "免疫续航型分化：【吞噬】攻击造成损失后回血一半，"
	if tune.macro_heal_purify > 0:
		macro_line = "【吞噬】：每次净化恢复 %s 能量，攻击造成损失后再回血一半。" % CWData.fmt(tune.macro_heal_purify)
		macro_codex = "免疫续航型分化：【吞噬】每次净化回 %s 能量、攻击后再回血一半，" % CWData.fmt(tune.macro_heal_purify)
	## 癌细胞里随旋钮出没的句子
	var mucus_tail := "；"
	if tune.mucus_move_surcharge > 0:
		mucus_tail = "，留下的黏液让免疫踏入时多付 %s；" % CWData.fmt(tune.mucus_move_surcharge)
	var jump_limit := ""
	if tune.metastasis_max_per_round > 0:
		jump_limit = "（每世界回合最多 %d 次）" % tune.metastasis_max_per_round
	var solid_rounds: int = tune.solidify_threshold / CWData.SOLIDIFY_STEP
	var ev_rounds := event_rounds_text(tune.limit_round)
	return [
		{ "title": "目标与胜负", "entries": [
			{ "t": "你要做什么", "b": [
				"免疫方与癌方轮流行动：免疫要清剿癌细胞、守住身体，",
				"癌方要扩张癌组织、挤占整片棋盘。每一格组织、每一点能量",
				"都在此消彼长。",
			] },
			{ "t": "免疫怎么赢", "b": [
				"把场上所有癌细胞消灭，并且没有可供癌方复活的固化癌组织，",
				"在世界回合 E 阶段结算时立即获胜。",
			] },
			{ "t": "癌方怎么赢", "b": cancer_win },
			{ "t": "回合打满怎么办", "b": [
				"最多 %d 个世界回合。" % tune.limit_round,
				"到点后癌性组织达到 %d 格判癌方胜，否则免疫胜。" % tune.limit_cancerous,
			] },
		] },
		{ "title": "棋盘与地形", "entries": [
			{ "t": "一块蜂窝棋盘", "b": [
				"半径 6 的六边形网格，共 %d 格。" % CWData.TOTAL_TILES,
				"细胞站在组织格上，一格最多一个细胞。",
				"悬停任意格稍候，会弹出那一格的地形详情。",
			] },
			{ "t": "健康组织", "b": [
				"青绿色，是双方争夺的本体。免疫走进癌组织会把它净化回健康，",
				"癌细胞走进健康组织会把它定殖成癌组织。",
			] },
			{ "t": "癌组织", "b": [
				"红色，癌方的地盘。癌细胞在上面蹲满 %d 个世界回合，" % solid_rounds,
				"这一格就变成固化癌组织。",
			] },
			{ "t": "固化癌组织", "b": [
				"更深一档的癌组织，是癌方复活据点、加权占地记 2 分。",
				"它不能被普通净化，得用 T 细胞的【裂解】破除。",
			] },
			{ "t": "三种特殊组织", "b": [
				"代谢核心储能量、骨髓储卡牌，踩上去当场收取；",
				"血管会把踩上去的细胞传送到另一根血管。",
				"它们的产出一格一格记，悬停就能看到储量。",
			] },
		] },
		{ "title": "能量与费用", "entries": [
			{ "t": "能量就是生命", "b": [
				"所有行动都要花能量，能量归零即死亡。",
				"支付费用不能让能量降到 0，总要留一点底。",
			] },
			{ "t": "初始与上限", "b": energy },
			{ "t": "免疫的收入", "b": aerobic },
			{ "t": "癌方的收入", "b": anaerobic },
			{ "t": "常用费用", "b": [
				"免疫迁移健康 %s / 癌性按等级；" % CWData.fmt(tune.immune_move_healthy[0]),
				"抽卡免疫 %s、癌方 %s；突变 %s；" % [CWData.fmt(CWData.IMMUNE_DRAW_COST), CWData.fmt(CWData.CANCER_DRAW_COST), CWData.fmt(CWData.MUTATE_COST)],
				"细胞毒素 %s、裂解 %s。行动栏按钮上都会标价。" % [CWData.fmt(CWData.TOXIN_COST), CWData.fmt(CWData.LYSE_COST)],
			] },
		] },
		{ "title": "一个世界回合", "entries": [
			{ "t": "S 阶段", "b": [
				"先按顺序结算世界事件、特殊组织产出、血管传送，",
				"再轮到复活（免疫在骨髓、癌方在固化组织），",
				"最后免疫结算【有氧呼吸】收入。",
			] },
			{ "t": "玩家回合", "b": turn_lines },
			{ "t": "E 阶段", "b": [
				e_phase,
				"固化与衰减依次发生，最后统一判定胜负。",
			] },
			{ "t": "回合计数", "b": [
				"世界事件只在第 %s 回合触发。" % ev_rounds,
				"越往后局势越不受控制，别把决战拖到太晚。",
			] },
		] },
		{ "title": "移动与净化", "entries": [
			{ "t": "免疫迁移", "b": [
				"点「迁移」再点高亮的相邻格。走进癌组织会自动【净化】",
				"并 +1 抗原记忆；走进有癌细胞的一格则触发攻击而不是净化。",
			] },
			{ "t": "癌方移动", "b": [
				"点「移动」再点相邻格。走进健康组织会【定殖】成癌组织，",
				"这就是癌方扩张地盘的基本方式。",
			] },
			{ "t": "一格一格走", "b": [
				"「迁移 / 移动」是切换式：走完一步仍停在选目标格上，",
				"可以连续走，右键或 Esc 结束。",
			] },
			{ "t": "净化与记忆", "b": [
				"免疫每净化一格 +1 抗原记忆。记忆到 %d 升 II 级、" % CWData.LEVEL_MIN_MEMORY[1],
				"%d 升 III 级、%d 升 X 级，迁入癌组织的费用随等级下降。" % [CWData.LEVEL_MIN_MEMORY[2], CWData.LEVEL_MIN_MEMORY[3]],
			] },
		] },
		{ "title": "攻击与判定", "entries": [
			{ "t": "怎么发起攻击", "b": [
				"免疫迁移时，目标格上站着癌细胞就是一次攻击。",
				"骰子会落在那一格上方演一遍，结算说明由引擎给出。",
			] },
			{ "t": "d6 判定", "b": [
				fail_line,
				"3-5 成功（目标 -%s）；6 大成功（目标 -%s）。" % [CWData.fmt(tune.attack_dmg_success), CWData.fmt(tune.attack_dmg_crit)],
			] },
			{ "t": "标记翻倍", "b": [
				"树突细胞给相邻癌细胞挂【标记】，带标记的目标受到的下一次",
				"伤害翻倍，随后消耗一层标记。",
			] },
			{ "t": "攻击次数", "b": atk_limit },
		] },
		{ "title": "免疫分化", "entries": [
			{ "t": "分化规则", "b": [
				"免疫等级升到 %s 后可以分化，每个细胞一辈子一次，" % lv[tune.differentiate_min_level],
				"每种分化全阵营限一个。分化免费。",
			] },
			{ "t": "B 细胞", "b": b_lines },
			{ "t": "T 细胞", "b": t_lines },
			{ "t": "巨噬细胞", "b": [
				macro_line,
				"续航型，越打越有钱，适合反复净化。",
			] },
			{ "t": "树突状细胞", "b": [
				"【趋化源】：花 %s 在任意格立源、持续 %d 回合，" % [CWData.fmt(CWData.CHEMO_COST), CWData.CHEMO_ROUNDS],
				"免疫朝它走的迁移费 ×%d%%，癌细胞背它走的移动费 ×%d%%。" % [CWData.CHEMO_IMMUNE_PCT, CWData.CHEMO_CANCER_PCT],
				"相邻癌细胞自动带【标记】，下一次受伤翻倍。自身不能攻击，纯辅助。",
			] },
		] },
		{ "title": "四种癌细胞", "entries": [
			{ "t": "恶性黑色素瘤", "b": [
				"【早期血行转移】从血管传送到任意空地并扩散癌组织，每世界回合一次；",
				"【伪足穿透】目标邻接 %d 格以上癌性组织时移动只花 %s。" % [CWData.PSEUDOPOD_MIN_ADJ, CWData.fmt(tune.pseudopod_cost)],
				"机动性极强。",
			] },
			{ "t": "印戒细胞癌", "b": [
				"【黏液破裂】耗尽能量自爆、范围转化癌组织" + mucus_tail,
				"【囊性护甲】每世界回合第一次能量损失减 %s。肉盾型。" % CWData.fmt(CWData.ARMOR_REDUCTION),
			] },
			{ "t": "骨肉瘤", "b": [
				"【骨样硬化】花 %s 标记脚下的癌组织，%d 个世界回合后直接固化；" % [CWData.fmt(tune.osteo_ossify_cost), tune.osteo_ossify_rounds],
				"免疫踏进标记格得蹲满一回合才能净化。站在固化组织上受伤只剩 %d%%。阵地型。" % CWData.OSTEO_BARRIER_PERCENT,
			] },
			{ "t": "小细胞肺癌", "b": [
				"【转移】向某方向跃进 %d 格" % CWData.METASTASIS_RANGE + jump_limit + "；【瓦伯格】无氧呼吸 %d%%；" % CWData.WARBURG_PERCENT,
				"移动至健康组织只花 %s。爆发型。" % CWData.fmt(tune.sclc_move_healthy),
			] },
		] },
		{ "title": "细胞图鉴", "entries": [
			{ "t": "原生免疫细胞", "b": [
				"免疫方的移动单位：走进癌组织自动【净化】并 +1 抗原记忆，",
				"走进站有癌细胞的格子则触发攻击。能量花完或血被打空就死亡。",
			] },
			{ "t": "B 细胞", "b": [
				"免疫输出型分化：【抗体】花 %s 能量，范围内邻接健康组织" % CWData.fmt(CWData.ANTIBODY_COST),
				"的癌细胞各受 %s 伤害；没有目标时改为转化癌组织。" % CWData.fmt(CWData.ANTIBODY_DAMAGE),
			] },
			{ "t": "T 细胞", "b": [
				"免疫攻坚型分化：【细胞毒素】花 %s 能量，把相邻癌组织转健康" % CWData.fmt(CWData.TOXIN_COST),
				"并留下坏死；【裂解】花 %s 能量破除固化癌组织。" % CWData.fmt(CWData.LYSE_COST),
				"克制骨肉瘤的骨壳，也能拆掉癌方的复活点。",
			] },
			{ "t": "巨噬细胞", "b": [
				macro_codex,
				"配合反复净化能一直走下去，适合清扫大片癌组织。",
			] },
			{ "t": "树突状细胞", "b": [
				"免疫辅助型分化：【趋化源】花 %s 立源，免疫朝它走打折、癌细胞背它走加价；" % CWData.fmt(CWData.CHEMO_COST),
				"相邻癌细胞自动带【标记】，下一次受伤翻倍。自身不能攻击。",
			] },
			{ "t": "恶性黑色素瘤", "b": [
				"癌方游击手：【早期血行转移】花 %s 能量，每世界回合一次，" % CWData.fmt(CWData.MELANOMA_HOMING_COST),
				"从血管传送到任意空地并扩散癌组织；【伪足穿透】贴着癌区走只花 %s。" % CWData.fmt(tune.pseudopod_cost),
				"盯紧血管口。",
			] },
			{ "t": "印戒细胞癌", "b": [
				"癌方肉盾：【黏液破裂】耗尽能量自爆、范围转化最多 %d 格癌组织" % CWData.MUCUS_MAX_CONVERT + mucus_tail,
				"【囊性护甲】每世界回合第一次能量损失减 %s。别让它扎进健康区。" % CWData.fmt(CWData.ARMOR_REDUCTION),
			] },
			{ "t": "骨肉瘤", "b": [
				"癌方阵地：【骨样硬化】花 %s 标记脚下癌组织，%d 回合后直接固化，" % [CWData.fmt(tune.osteo_ossify_cost), tune.osteo_ossify_rounds],
				"免疫踏进标记格得蹲一回合才能净化；站在固化组织上受伤只剩 %d%%。" % CWData.OSTEO_BARRIER_PERCENT,
				"用 T 细胞【裂解】拆壳最稳。",
			] },
			{ "t": "小细胞肺癌", "b": [
				"癌方爆发：【转移】向某方向跃进 %d 格" % CWData.METASTASIS_RANGE + jump_limit + "；【瓦伯格】无氧呼吸 %d%%；" % CWData.WARBURG_PERCENT,
				"移动至健康组织仅 %s。贴脸就能打乱免疫阵型。" % CWData.fmt(tune.sclc_move_healthy),
			] },
		] },

		{ "title": "卡牌", "entries": [
			{ "t": "三类卡", "b": [
				"事件卡抽到立即结算并弃置；技能卡进手牌（上限 %d 张）；" % CWData.HAND_MAX,
				"永久技能打出即装备，持续生效、死亡不掉。",
			] },
			{ "t": "怎么抽卡", "b": [
				"【基因表达】付费抽卡，每个行动回合最多 %d 次；" % CWData.DRAW_MAX_PER_TURN,
				"踩骨髓也能拿卡。免疫按记忆等级抽池，癌方按回合分期抽池。",
			] },
			{ "t": "怎么出牌", "b": [
				"轮到人类玩家时，点左下角手牌即可打出或弃置。",
				"带目标的卡会高亮可点格子；双击免确认直接打出。",
			] },
		] },
		{ "title": "世界事件", "entries": [
			{ "t": "十八个事件", "b": [
				"在第 %s 回合从池中随机抽取，" % ev_rounds,
				"同局不重复，每回合一个。效果可能持续一两个回合。",
			] },
			{ "t": "留意公告", "b": [
				"事件结算时骰子旁会弹出说明。持续效果会挂在右侧竖条",
				"与回合流程里，多看对局日志（L 键）。",
			] },
		] },
		{ "title": "界面与快捷键", "entries": [
			{ "t": "右侧竖条", "b": [
				"回合数、胜负进度、每位玩家的能量与手牌、免疫等级都在这里。",
				"悬停玩家行可查看其已装备的永久技能。",
			] },
			{ "t": "行动栏", "b": [
				"底部一排按钮，数字键 1-9 对应从左到右。",
				"按钮不消失、只变暗，位置和编号始终稳定。",
			] },
			{ "t": "常用按键", "b": [
				"空格 = 结束回合；L = 对局日志；Esc = 取消 / 打开暂停菜单；",
				"右键 = 取消选目标。主菜单里方向键 + 回车即可全程操作。",
			] },
			{ "t": "悬停与提示", "b": [
				"悬停格子看地形、悬停玩家行看装备、悬停按钮看费用。",
				"点不动的时候，界面上一般会直接告诉你为什么。",
			] },
		] },
		{ "title": "给新手的三个提醒", "entries": [
			{ "t": "先扩张收入", "b": [
				"免疫多净化攒记忆、升等级，癌方多定殖把连通块做大，",
				"收入才滚得起来。开局别只盯着一个细胞对砍。",
			] },
			{ "t": "守住复活点", "b": [
				"癌方的命根子是固化癌组织，免疫的命根子是骨髓。",
				"被对面占住复活位，往往比死一个细胞更伤。",
			] },
			{ "t": "能量别见底", "b": [
				"付钱不能降到 0，攒不出足够费用就会卡手。",
				"留一两步移动的余量，关键时刻才进退自如。",
			] },
		] },
	]


## 世界事件回合的清单文字（「3、6、10、15、20、25、30」），现算自 CWData.is_world_event_round，
## 图鉴与引导剧本共用，别在两处各写一份。
static func event_rounds_text(limit: int) -> String:
	var out: Array[String] = []
	for r in range(1, limit + 1):
		if CWData.is_world_event_round(r):
			out.append(str(r))
	return "、".join(out)

func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var screen := CWView.screen_size()
	var panel := Control.new()
	panel.position = Vector2((screen.x - W) / 2.0, (screen.y - H) / 2.0)
	panel.size = Vector2(W, H)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	var head := CWStyle.label("知识之书", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	head.position = Vector2(PAD, PAD - 4)
	panel.add_child(head)

	var src := CWStyle.label("把新手引导的每一课沉淀成图鉴 · 细则以规则原文为准",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	src.size = Vector2(W - PAD * 2, 14)
	src.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	src.position = Vector2(PAD, PAD + 12)
	panel.add_child(src)

	## 章标题行与页码（点阵字没有箭头，用 ASCII < > 做翻页按钮，同配置面板语汇）
	_title = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	_title.position = Vector2(PAD, PAD + HEADER_H - 24)
	panel.add_child(_title)

	_page_label = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_page_label.position = Vector2(W - PAD - 78, PAD + HEADER_H - 22)
	_page_label.size = Vector2(40, 14)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(_page_label)

	_prev = _clicky("<", Vector2(W - PAD - 40, PAD + HEADER_H - 24), _prev_page, panel)
	_next = _clicky(">", Vector2(W - PAD - 20, PAD + HEADER_H - 24), _next_page, panel)

	## 正文滚动区：clip 裁掉越界部分，_content 随 _scroll 上下移动
	_body = Control.new()
	_body.position = Vector2(PAD, PAD + HEADER_H)
	_body.size = Vector2(W - PAD * 2, H - PAD - HEADER_H - FOOTER_H)
	_body.clip_contents = true
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_body)

	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_content)

	var hint := CWStyle.label("ESC / 右键 返回 · ←→ 翻页 · 滚轮阅读",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.size = Vector2(W - PAD * 2, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(PAD, H - PAD - 10)
	panel.add_child(hint)


## 可点击文字（同 config_panel._clicky——覆盖层里收点击都要标记已处理）
func _clicky(text: String, at: Vector2, on_click: Callable, parent: Node = null) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	label.position = at
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	(parent if parent != null else self).add_child(label)
	return label


func _rebuild_page() -> void:
	for child in _content.get_children():
		child.queue_free()
	_title.text = ""
	_page_label.text = ""
	var all := chapters()
	if all.is_empty():
		return
	var ch: Dictionary = all[_page]
	_title.text = ch["title"]
	_page_label.text = "%d / %d" % [_page + 1, all.size()]
	_prev.add_theme_color_override("font_color",
		CWStyle.TEXT_HI if _page > 0 else CWStyle.TEXT_OFF)
	_next.add_theme_color_override("font_color",
		CWStyle.TEXT_HI if _page < all.size() - 1 else CWStyle.TEXT_OFF)

	var y := 0.0
	for entry in ch["entries"]:
		var t := CWStyle.label(entry["t"], CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		t.position = Vector2(0, y)
		_content.add_child(t)
		y += TITLE_LINE
		for line in entry["b"]:
			var l := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT)
			l.position = Vector2(0, y)
			l.size = Vector2(_body.size.x, LINE)
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_content.add_child(l)
			y += LINE
		y += GAP
		_content.add_child(_rule(y - GAP))
	_content.size = Vector2(_body.size.x, y)
	_scroll = 0.0
	_layout()


func _rule(at_y: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(CWStyle.LINE, 0.18)
	r.position = Vector2(0, at_y)
	r.size = Vector2(_body.size.x, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _layout() -> void:
	_content.position = Vector2(0, -_scroll)
	_max_scroll = maxf(_content.size.y - _body.size.y, 0.0)
