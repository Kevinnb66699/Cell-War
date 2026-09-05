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
static func chapters() -> Array:
	var tune := CWTuning.new()
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
			{ "t": "癌方怎么赢", "b": [
				"让「癌组织 + 2 × 固化癌组织」的加权占地达到 %d，" % tune.cancer_win_weighted,
				"E 阶段结算时立即获胜。",
			] },
			{ "t": "回合打满怎么办", "b": [
				"最多 %d 个世界回合。" % CWData.LIMIT_ROUND,
				"到点后癌性组织达到 %d 格判癌方胜，否则免疫胜。" % CWData.LIMIT_CANCEROUS,
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
				"红色，癌方的地盘。癌细胞停留会积累「固化计数」，",
				"攒满 %s 后变成固化癌组织。" % CWData.fmt(tune.solidify_threshold),
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
			{ "t": "初始与上限", "b": [
				"免疫细胞开局 %s 能量，癌细胞开局 %s 能量；" % [CWData.fmt(CWData.INIT_ENERGY), CWData.fmt(CWData.INIT_ENERGY_CANCER)],
				"每格账户最多存 %s，溢出会消失。" % CWData.fmt(CWData.ENERGY_CAP_PER_ROUND),
			] },
			{ "t": "免疫的收入", "b": [
				"每个世界回合 S 阶段【有氧呼吸】：按全盘健康组织占比 ×3 结算，",
				"每个免疫细胞各拿一份，且有 %s 低保。" % CWData.fmt(CWData.AEROBIC_FLOOR),
			] },
			{ "t": "癌方的收入", "b": [
				"每个世界回合 E 阶段【无氧呼吸】：按所处癌组织连通块的供能，",
				"块内癌细胞均分。癌组织铺得越开，进账越多。",
			] },
			{ "t": "常用费用", "b": [
				"免疫迁移健康 %s / 癌性按等级；" % CWData.fmt(CWData.IMMUNE_MOVE_HEALTHY[0]),
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
			{ "t": "玩家回合", "b": [
				"按行动顺序轮流行动，每个人可以连续行动多次，",
				"直到自己按下「结束回合」。右侧竖条标明回合数与轮到谁。",
			] },
			{ "t": "E 阶段", "b": [
				"癌方结算【无氧呼吸】，随后微环境压迫、增生、侵蚀、",
				"固化与衰减依次发生，最后统一判定胜负。",
			] },
			{ "t": "回合计数", "b": [
				"世界事件只在第 3、6、10、15、20、25、30 回合触发。",
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
				"免疫每净化一格 +1 抗原记忆。记忆积累到 16 升 III 级、",
				"31 升 X 级，免疫迁移到癌组织的费用随等级下降。",
			] },
		] },
		{ "title": "攻击与判定", "entries": [
			{ "t": "怎么发起攻击", "b": [
				"免疫迁移时，目标格上站着癌细胞就是一次攻击。",
				"骰子会落在那一格上方演一遍，结算说明由引擎给出。",
			] },
			{ "t": "d6 判定", "b": [
				"1-2 失败（自身 -%s 被反弹）；" % CWData.fmt(CWData.COUNTER_DMG_ON_FAIL),
				"3-5 成功（目标 -%s）；6 大成功（目标 -%s）。" % [CWData.fmt(CWData.ATTACK_DMG_SUCCESS), CWData.fmt(CWData.ATTACK_DMG_CRIT)],
			] },
			{ "t": "标记翻倍", "b": [
				"树突细胞给相邻癌细胞挂【标记】，带标记的目标受到的下一次",
				"伤害翻倍，随后消耗一层标记。",
			] },
			{ "t": "攻击次数", "b": [
				"每个行动回合最多攻击 %d 次，" % CWData.ATTACK_MAX_PER_TURN,
				"用完后攻击选项从行动栏消失，普通迁移不受影响。",
			] },
		] },
		{ "title": "免疫分化", "entries": [
			{ "t": "分化规则", "b": [
				"免疫等级升到 III 后可以分化，每个细胞一辈子一次，",
				"每种分化全阵营限一个。分化免费。",
			] },
			{ "t": "B 细胞", "b": [
				"【抗体】：范围内与健康组织邻接的癌细胞各受 %s 伤害；" % CWData.fmt(CWData.ANTIBODY_DAMAGE),
				"没有目标时改为转化癌组织。",
			] },
			{ "t": "T 细胞", "b": [
				"【细胞毒素】把相邻癌组织转健康并留下坏死；",
				"【裂解】破除相邻的固化癌组织。主攻手。",
			] },
			{ "t": "巨噬细胞", "b": [
				"【吞噬】：每次净化恢复 %s 能量。续航型，适合反复净化。" % CWData.fmt(CWData.MACRO_HEAL_PURIFY),
			] },
			{ "t": "树突状细胞", "b": [
				"给相邻癌细胞挂【标记】，让队友的攻击翻倍。",
				"辅助型，配一个输出收益很高。",
			] },
		] },
		{ "title": "四种癌细胞", "entries": [
			{ "t": "恶性黑色素瘤", "b": [
				"【早期血行转移】从血管传送到任意空地并扩散癌组织，",
				"每世界回合一次。机动性极强。",
			] },
			{ "t": "印戒细胞癌", "b": [
				"【黏液破裂】耗尽能量自爆、范围转化癌组织；",
				"【囊性护甲】每回合减免一次伤害。肉盾型。",
			] },
			{ "t": "骨肉瘤", "b": [
				"【骨样硬化】固化计数 +%s，" % CWData.fmt(CWData.SOLIDIFY_STEP + CWData.SOLIDIFY_STEP / 2),
				"蹲守更快成型；站在固化组织上受伤只剩 %d%%。阵地型。" % CWData.OSTEO_BARRIER_PERCENT,
			] },
			{ "t": "小细胞肺癌", "b": [
				"【转移】向某方向跃进 5 格；【瓦伯格】无氧呼吸 %d%%；" % CWData.WARBURG_PERCENT,
				"移动至健康组织还有折扣。爆发型。",
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
				"免疫续航型分化：【吞噬】每次净化回 %s 能量，" % CWData.fmt(CWData.MACRO_HEAL_PURIFY),
				"配合反复净化能一直走下去，适合清扫大片癌组织。",
			] },
			{ "t": "树突状细胞", "b": [
				"免疫辅助型分化：给相邻癌细胞挂【标记】，",
				"带标记的目标下一次受到的伤害翻倍。配输出收益极高。",
			] },
			{ "t": "恶性黑色素瘤", "b": [
				"癌方游击手：【早期血行转移】花 %s 能量，每世界回合一次，" % CWData.fmt(CWData.MELANOMA_HOMING_COST),
				"从血管传送到任意空地并扩散癌组织。盯紧血管口。",
			] },
			{ "t": "印戒细胞癌", "b": [
				"癌方肉盾：【黏液破裂】耗尽能量自爆、范围转化最多 %d 格癌组织；" % CWData.MUCUS_MAX_CONVERT,
				"【囊性护甲】每回合减免一次伤害。别让它扎进健康区。",
			] },
			{ "t": "骨肉瘤", "b": [
				"癌方阵地：【骨样硬化】固化计数 +%s，" % CWData.fmt(CWData.SOLIDIFY_STEP + CWData.SOLIDIFY_STEP / 2),
				"蹲守更快成型；站在固化组织上受伤只剩 %d%%。" % CWData.OSTEO_BARRIER_PERCENT,
				"用 T 细胞【裂解】拆壳最稳。",
			] },
			{ "t": "小细胞肺癌", "b": [
				"癌方爆发：【转移】向某方向跃进 5 格；【瓦伯格】无氧呼吸 %d%%；" % CWData.WARBURG_PERCENT,
				"移动至健康组织仅 %s。贴脸就能打乱免疫阵型。" % CWData.fmt(CWData.SCLC_MOVE_HEALTHY),
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
				"在第 3、6、10、15、20、25、30 回合从池中随机抽取，",
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
				"免疫多净化、癌方多定殖，把健康组织占比 / 癌组织连通块做大，",
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
