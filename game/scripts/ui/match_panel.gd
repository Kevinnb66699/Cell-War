## match_panel.gd —— 右侧竖条：常驻信息全在这儿
##
## 尺寸全部照搬定稿的「右侧竖条 · 尺寸与字号」标注稿，**一个数都别改**：
## 面板 264×540，内边距 16，块间距 10，各块高度写死
## 52（回合）/ 56（胜负进度）/ 44×人数（玩家列表）/ 44（免疫等级）/ 52（结束回合，钉底）。
## 6 人局合计 530，只余 10px —— 这套高度是按最挤的情况配平的，
## 随手把哪一块调高一点，6 人局就会溢出。
##
## 为什么是右侧竖条而不是底部横条：见 [CWView] 的对局机位注释。
##
## 刷新方式和棋盘一致：每帧全量刷（refresh），只改 Label 的 text。
## Godot 的 Label.text 在没变化时会直接返回，所以代价接近零，
## 而画面不可能和状态对不上。节点结构只在第一次 refresh 时按人数建一遍。
class_name CWMatchPanel
extends Control

## 「结束回合」被按下（面板底部那个按钮，或空格）
signal end_turn_pressed
## 固定详情里停在某一条技能上：把它的 PRD 原文（CWCardInfo 的 { name, kind, lines }）
## 和详情框该贴的横坐标交出去，由 CWMatch 转给同一只 CWCardInfo。
## 离开时发空字典 —— 和行动栏那条悬停路径同一套约定
## anchor_y = 被悬停那一行的画布 y，详情框把框顶对齐到它（2026-09-07 之前没带 y，框被摆到窗口底部）；离开时发 -1
signal skill_hovered(rows: Dictionary, anchor_x: float, anchor_y: float)
signal played_card_pressed(rows: Dictionary, anchor_x: float, anchor_y: float)

const RECT := Rect2(696, 0, 264, 540)
const PAD := 16
const GAP := 10
const ROUND_H := 52
const SCORE_H := 56
const ROW_H := 44
const LEVEL_H := 44
const END_H := 52
## 升级进度条：贴免疫等级那一块的底边。**不许加高那一块**（见文件头），
## 所以它只能长在文字墨迹底下那道缝里 —— 38 起、4 高，块高 44，还留 2px 到下边。
##
## 第一版摆在 34，Kevin 一眼看出来「距离罗马数字太近了」：等级那个字是
## SIZE_BODY 20，行框到 y+35，34 等于**贴着它的下沿**。往下挪 4px 之后
## 字与条之间空出一行的呼吸。护栏钉的就是「条顶不高于等级字的行框底」——
## 那条关系比「34 还是 38」耐改（换字号时会自己跟着走）。
const BAR_DY := 38.0
const BAR_H := 4.0
## 「免疫等级」那四个字。数字要居中到它和记忆行之间，所以宽度得量它 ——
## 写成常量是为了**只有一处**：量的字和摆的字必须是同一串（见 _layout_level）
const LEVEL_CAPTION := "免疫等级"
## 数字离两边各留多少才不算贴脸。**只有护栏在用** —— 版面本身是居中算的，
## 这个数是「最挤的一档也得留出这么多」的下限（见 t_match_panel）
const LEVEL_GAP := 8.0

const W := 232          ## 内容宽 = 264 - 16×2
const ROW_PAD := 6      ## 玩家行自己的左右内边距
const ICON := 32

## 手牌用小方块表示（团队 2026-08-28 定）：**总是画满 CWData.HAND_MAX 格**，
## 持有的填成阵营色、其余只留描边 —— 满没满一眼可见，比一个数字直观。
## 永久技能则**没有上限**（X 级免疫池光永久技能就有 9 张），所以只能用数字，不能也方块化。
const PIP := 6            ## 方块边长
const PIP_GAP := 2
const INCOME_RESERVE := 30  ## 预计收入小字「+x.x」贴行右缘，预留的宽度（Kevin 2026-09-06：「能量往左、+ 多少放右边」）
const ENERGY_RESERVE := 52  ## 能量数字预留的宽度，右对齐到预计收入左边；「技 N」再右对齐到它左边
## 玩家名的裁剪宽度：原 110，给预计收入让位后 64。本地对局的「免疫A」52px 不受影响；
## 联机长昵称本来就要裁（2026-09-03 排版体检），只是裁得更早一点
const NAME_W := 64
## 技能详情框的宽度。固定态要放下「停在技能上看详情 · 再点该行取消固定」这行小字（10px×18 字 = 180）
const TIP_W := 200.0
## 本回合打出的历史小卡（队友 2026-09-06 的表现层）：16px 像素小卡 + 1px 边 = 18，放进 30px；
## 摆在行底那一行、手牌方块左边 —— 行首插 60px 会把玩家名推到能量数上（合并时改的摆法，见开发日志）。
## 叠放只露 2px（Kevin 2026-09-06 看放大图定的）：1px 不透明主色边框 + 1px 深色卡面，图标只画最上面那张 ——
## 原来叠 6px、边框半透明，底下每张的边框压在上一张的图标上，颜色太多有割裂感
const HISTORY_W := 30.0
const HISTORY_ICON := 18.0
const HISTORY_STEP := 2.0
## 抽到即结算的事件卡（Kevin 2026-09-07 拍板方案乙）：本世界回合内**所有人**抽到的，
## 横排在世界事件那一行的右侧、右缘对齐。和玩家行那排「自己打出的卡」分开摆，边色也不同
## （这里按抽到它的阵营：青 = 免疫、橙 = 癌方；那边是主色）—— 那正是这次要分开的两件事。
## 世界事件文字裁到小卡左边（方案乙认下的代价）；最多留 8 张，再多丢最旧的，全量记录在对局日志里。
const EVENT_STRIP_MAX := 8
const EVENT_STRIP_Y := 56.0    ## 小卡 20px 高，56+2..56+22 = 58..78，正好停在分数块（78）之上

## 玩家行里的种类图标。和棋盘上是同一批贴图，但棋盘那份要对齐脚底、这份是居中摆，
## 用途不同所以各留各的表（棋盘那份见 CWMatch.IMMUNE_ART / CANCER_ART）。
const IMMUNE_ICON := {
	CWData.ImmuneType.BASIC: preload("res://assets/art/cells/immune.png"),
	CWData.ImmuneType.B_CELL: preload("res://assets/art/cells/bcell.png"),
	CWData.ImmuneType.T_CELL: preload("res://assets/art/cells/tcell.png"),
	CWData.ImmuneType.MACRO: preload("res://assets/art/cells/macrophage.png"),
	CWData.ImmuneType.DENDRITIC: preload("res://assets/art/cells/dendritic.png"),
}
const CANCER_ICON := {
	CWData.CancerType.MELANOMA: preload("res://assets/art/cells/melanoma.png"),
	CWData.CancerType.SIGNET: preload("res://assets/art/cells/signet.png"),
	CWData.CancerType.OSTEO: preload("res://assets/art/cells/osteo.png"),
	CWData.CancerType.SCLC: preload("res://assets/art/cells/sclc.png"),
}

var _round: Label
var _phase: Label
## 进行中的世界事件（名字 + 剩余回合）。此前只有对局日志里能看到，玩家在盘面上根本不知道
## 【基质阻隔】还在（2026-09-02 Kevin：「有能量为什么走不进癌组织」的根源之一）。
## 没有事件时整行隐藏；放在回合块底部那 14px 的空档里，不动任何块高（见文件头「一个数都别改」）。
var _events: Label
var _event_strip: Control  ## 本世界回合抽到的事件卡（横排，右缘对齐）
var _event_hover := false      ## 鼠标停在事件行上
var _event_tip: Control        ## 事件行的悬浮详情（每个事件一句话效果 + 剩余回合）
var _event_tip_key := ""
var _weighted: Label
var _weighted_max: Label
var _weighted_caption: Label   ## 平时写「癌性加权」，警报期换成「★ 警报 1/2」
var _bar_fill: ColorRect
var _level: Label
var _memory: Label
var _lv_bar_bg: ColorRect    ## 升级进度条的槽（胜负那条叫 _bar_fill，别混）
var _lv_bar_fill: ColorRect  ## 已攒到的那一段
var _bg: Panel
var _end: PanelContainer
var _rows: Array = []      ## 每项 { bg, fac, history, icon, name, type, energy, pips, skills }
var _built := 0            ## 已按几人局建好（0 = 还没建）
var _history_round := -1    ## 当前回合号；换回合就清右侧历史
var _level_y := 0.0        ## 免疫等级那一块的顶边；测试靠它核对 6 人局没溢出
var _tip: Control = null   ## 技能详情框（悬停玩家行时列出已装备 + 即时修饰；**点一下固定**后列全套技能）
var _tip_pid := -1         ## 正悬停哪一行；-1 = 收起
var _tip_pinned := -1      ## 被点住固定的那一行；-1 = 没固定。固定后框不随鼠标收起、条目可悬停
var _tip_key := ""         ## 上次搭悬浮框用的键，没变不重搭
## 联机：房间视图里的席位表（下标 = pid）。AI 席 / 离线席在种类后面加个角标；本地对局留空
var net_seats: Array = []


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 面板要挡住底下的棋盘点击
	_chrome()


## 底板和「结束回合」按钮：都跟人数无关，所以和玩家列表分开建，
## 而且是**懒建**——程序化创建本面板时 _ready 要等到下一帧才跑，
## 而调用方（CWUIBridge）当帧就可能来调 show_end_turn()。
func _chrome() -> void:
	if _bg == null:
		_bg = Panel.new()
		## 只有左边一道描边（设计稿 border-left），所以不能用 set_border_width_all
		var box := CWStyle.box(0.45, CWStyle.PANEL)
		box.set_border_width_all(0)
		box.border_width_left = 2
		_bg.add_theme_stylebox_override("panel", box)
		_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_bg)
	if _end == null:
		_end = _build_end_button()
		_end.position = Vector2(PAD, RECT.size.y - PAD - END_H)
		_end.size = Vector2(W, END_H)
		_end.visible = false
		add_child(_end)


## 点面板外面 → 取消固定的细胞信息栏（Kevin 2026-09-07）。点在面板 / 详情框自己身上的鼠标事件
## 走不到这里（那两处都是 MOUSE_FILTER_STOP），所以能到这儿的就是「点了外面」。
## **不吃这一下**：它只是个信息框，玩家点棋盘多半是要走子或选目标，顺手收起就好，别把那一下也吞了
## —— 日志面板那边相反（它盖着大半个棋盘，点外面就是想关它）。
func _unhandled_input(event: InputEvent) -> void:
	if _tip_pinned < 0:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_tip_pinned = -1
	_tip_key = ""        ## 固定与否决定列什么，键作废、强制重搭
	skill_hovered.emit({}, 0.0, -1.0)   ## 连带收掉浮在旁边的那张卡面


func _unhandled_key_input(event: InputEvent) -> void:
	## 设计稿把空格标成「结束回合」的快捷键
	if _end != null and _end.visible and event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		end_turn_pressed.emit()


## 每帧调用。第一次会按人数把节点建出来，之后只改文字。
func refresh(game: CWGame) -> void:
	if game == null or game.players.is_empty():
		return
	if _built != game.players.size():
		_build(game.players.size())
	if _history_round != game.round_no:
		_history_round = game.round_no
		_clear_history()
	_round.text = "第 %d 回合" % game.round_no
	## 环境恶化（2026-09-11）：肿瘤分期直接改压迫/增生/侵蚀/固化门槛的数，玩家得看得见现在是第几期。
	## 世界事件关着时（现在的默认）不再写「已关闭」—— 一句永远不变的话占着位置，分期更有用。
	## 关掉时别再倒计时一个永远不会来的事件（Kevin 2026-09-08 的开关）
	var stage_name: String = CWData.STAGE_NAMES[game.tumor_stage()]
	if not game.tune.world_events_on:
		_phase.text = "%s · %s" % [game.phase, stage_name]
	else:
		var next_ev := _next_event_round(game.round_no)
		_phase.text = "%s · %s · 世界事件 第 %d 回合" % [game.phase, stage_name, next_ev] if next_ev > 0 \
			else "%s · %s · 世界事件已放完" % [game.phase, stage_name]
	_events.text = active_events_text(game)
	_events.visible = _events.text != ""
	_layout_event_row()
	_update_event_tip(game)

	var w := game.count_tissue(CWData.Tissue.CANCER) \
		+ 2 * game.count_tissue(CWData.Tissue.SOLID)
	var goal: int = game.tune.cancer_win_weighted
	_weighted.text = str(w)
	_weighted_max.text = " / %d" % goal
	## 定案 B（2026-09-01）：首次达标只拉警报。引擎的 cancer_win_streak > 0 就是「警报期」，
	## 界面只负责把它显示出来（架构约定 #10），不自己数。
	if game.cancer_win_streak > 0:
		_weighted_caption.text = "★ 警报 %d/%d" % [game.cancer_win_streak, game.tune.cancer_win_hold_rounds]
		_weighted_caption.add_theme_color_override("font_color", CWStyle.CANCER)
	else:
		_weighted_caption.text = "癌性加权"
		_weighted_caption.add_theme_color_override("font_color", CWStyle.TEXT_DIM)
	_bar_fill.size.x = W * clampf(float(w) / float(goal), 0.0, 1.0)

	for pid in game.players.size():
		_refresh_row(game, pid)
	_update_tip(game)

	_level.text = CWData.LEVEL_NAMES[game.immune_level]
	## 门槛**按人数分档**（四人 6/16/30、六人 10/20/30）——
	## 别读 CWData.LEVEL_MIN_MEMORY 那张常量表，那是六人档兼缺省（同 CWGame.gain_memory）
	var tiers: Array = CWData.level_min_memory(game.order.size())
	_memory.text = memory_text(game.memory, game.immune_level, tiers)
	_layout_level()      ## 记忆行的宽度变了，数字要重新居中（见 _layout_level）
	var p := level_progress(game.memory, game.immune_level, tiers)
	## X 级没有「下一级」，条整个收起来 —— 画一根永远满的条等于骗人
	_lv_bar_bg.visible = p >= 0.0
	_lv_bar_fill.visible = p >= 0.0
	_lv_bar_fill.size = Vector2(W * maxf(p, 0.0), BAR_H)


## 回到主菜单时清空：下一局人数可能不同，节点结构要按新人数重建。
func reset() -> void:
	_chrome()
	_end.visible = false
	for c in get_children():
		if c == _bg or c == _end:
			continue
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_built = 0
	_history_round = -1
	net_seats = []
	_tip = null       ## 悬浮框也在刚才那波清掉了，别留野引用
	_tip_pid = -1
	_tip_pinned = -1
	_tip_key = ""


func show_end_turn(on: bool) -> void:
	_chrome()
	_end.visible = on


## 引导提亮用（CWGuideSpotlight）：某块区域的屏幕矩形。"round" 回合 / 阶段 / 事件块，"row:<pid>" 玩家行，
## "pips:<pid>" 该行的手牌方块，"level" 免疫等级块，"end" 结束回合按钮。没建好 / 此刻不显示 → 零矩形（提亮就不画）
func rect_of(what: String) -> Rect2:
	if _built == 0:
		return Rect2()
	var at := global_position
	if what == "round":
		return Rect2(at + Vector2(PAD, PAD), Vector2(W, ROUND_H))
	if what == "level":
		return Rect2(at + Vector2(PAD, _level_y), Vector2(W, LEVEL_H))
	if what == "end":
		return _end.get_global_rect() if _end != null and _end.visible else Rect2()
	var parts := what.split(":")
	if parts.size() != 2:
		return Rect2()
	var pid := int(parts[1])
	if pid < 0 or pid >= _rows.size():
		return Rect2()
	if parts[0] == "row":
		return (_rows[pid]["bg"] as Control).get_global_rect()
	if parts[0] == "pips":
		var pips: Array = _rows[pid]["pips"]
		var r: Rect2 = (pips[0] as Control).get_global_rect()
		for p in pips:
			r = r.merge((p as Control).get_global_rect())
		return r
	return Rect2()


## 「下一次世界事件是第几回合」。判据仍然只有 CWData 一处，这里只做查找。
## **必须有上界**：2026-09-07 事件表改成 3/6/10/14 之后，14 回合以后没有下一次了，
## 原来那个无上界的 while 会在终局回合空转把游戏卡死（当天真踩到，测试跑不完）。
## 找不到就返回 0，调用方改口播「无」。
func _next_event_round(from: int) -> int:
	for r in range(maxi(from, 1), CWData.LIMIT_ROUND + 1):
		if CWData.is_world_event_round(r):
			return r
	return 0


func _refresh_row(game: CWGame, pid: int) -> void:
	var row: Dictionary = _rows[pid]
	var p: Dictionary = game.player(pid)
	var immune: bool = p["faction"] == CWData.Faction.IMMUNE
	var faction_color: Color = CWStyle.IMMUNE if immune else CWStyle.CANCER
	row["fac"].color = faction_color
	row["name"].text = p["name"]

	## 开局布置阶段是一个一个落子的：玩家已经建好，细胞还没有。
	## 这一行先只显示名字和阵营色，别去问一个还不存在的细胞。
	if pid >= game.cells.size():
		row["bg"].color = Color(faction_color, 0.0)
		row["name"].add_theme_color_override("font_color", CWStyle.TEXT_OFF)
		row["type"].text = "待落子"
		row["energy"].text = ""
		row["income"].text = ""
		_set_pips(row, 0, CWStyle.TEXT_OFF_DIM)
		row["skills"].text = ""
		row["icon"].visible = false
		return

	var cell: Dictionary = game.cell_of(pid)
	var dead: bool = not cell["alive"]
	var on: bool = game.current_pid == pid
	row["bg"].color = Color(faction_color, 0.10 if on else 0.0)
	row["name"].add_theme_color_override("font_color",
		CWStyle.TEXT_OFF if dead else (CWStyle.TEXT_HI if on else CWStyle.TEXT))
	## 种类名按阵营查表；死亡占位细胞（教程 fixture 的缺席方）种类为 -1，显示空串
	var tname := ""
	if immune:
		if cell["itype"] >= 0:
			tname = CWData.IMMUNE_TYPE_NAMES[cell["itype"]]
	elif cell["ctype"] >= 0:
		tname = CWData.CANCER_TYPE_NAMES[cell["ctype"]]
	row["type"].text = tname
	if pid < net_seats.size():
		var seat: Dictionary = net_seats[pid]
		if seat.get("kind", "") == "ai":
			row["type"].text += " · AI"
		elif seat.get("kind", "") == "human" and not seat.get("online", true):
			row["type"].text += " · 离线代打"
	row["energy"].text = CWData.fmt(maxi(cell["energy"], 0))
	row["energy"].add_theme_color_override("font_color",
		CWStyle.TEXT_OFF if dead else CWStyle.TEXT_HI)
	row["income"].text = "" if dead else income_text(game, cell)
	## 手牌方块：持有的填阵营色，其余留描边色
	_set_pips(row, cell["hand"].size(), CWStyle.TEXT_OFF if dead else faction_color)
	var n_skill: int = cell["equipped"].size()
	row["skills"].text = "技 %d" % n_skill
	row["skills"].add_theme_color_override("font_color",
		CWStyle.TEXT_HI if n_skill > 0 else CWStyle.TEXT_OFF)
	_fit_type_label(row)

	var icon: Sprite2D = row["icon"]
	var icon_ok: bool = cell["itype"] >= 0 if immune else cell["ctype"] >= 0
	icon.visible = icon_ok          ## 死亡占位（教程 fixture 缺席方）没有种类图标
	icon.modulate.a = 0.35 if dead else 1.0
	if icon_ok:
		icon.texture = IMMUNE_ICON[cell["itype"]] if immune else CANCER_ICON[cell["ctype"]]


# ============ 建节点（只跑一次）============

func _build(n: int) -> void:
	_chrome()
	for c in get_children():
		if c == _bg or c == _end:
			continue      ## 底板和结束回合按钮跟人数无关，留着
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_built = n
	_history_round = -1
	_tip = null
	_tip_pid = -1
	_tip_pinned = -1
	_tip_key = ""

	# ① 回合 / 阶段 / 进行中的世界事件
	_round = _put(CWStyle.label("", CWStyle.SIZE_BIG, CWStyle.TEXT_HI), PAD, PAD, W)
	_phase = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, PAD + 36, W)
	_events = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_HI), PAD, PAD + 50, W)
	## **先开裁切再定尺寸**（架构约定：不裁的 Label 最小宽 = 全文宽，会把 size 顶回去、省略号根本不生效）——
	## 2026-09-07 给事件卡让宽时才发现这条一直没开，同时挂三个世界事件时那行字本来会顶穿右缘
	_events.clip_text = true
	_events.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS   ## 同时挂着三个事件才会超宽；细节看悬浮详情
	_events.visible = false
	_events.mouse_filter = Control.MOUSE_FILTER_STOP   ## 要接悬停：悬浮框里有每个事件的一句话效果（Kevin 2026-09-02）
	_events.mouse_default_cursor_shape = Control.CURSOR_HELP
	_events.mouse_entered.connect(func() -> void: _event_hover = true)
	_events.mouse_exited.connect(func() -> void: _event_hover = false)
	## 事件卡横排：和世界事件文字共用这一行（Kevin 2026-09-07 方案乙）。容器按**摊开 8 张**的宽度定，
	## 收着时小卡右对齐贴在容器右缘 = 面板内容右缘
	var strip_w: float = EVENT_STRIP_MAX * (HISTORY_ICON + 2.0)
	_event_strip = Control.new()
	_event_strip.position = Vector2(PAD + W - strip_w, EVENT_STRIP_Y)
	_event_strip.size = Vector2(strip_w, HISTORY_ICON + 4.0)
	_event_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_event_strip.visible = false
	add_child(_event_strip)
	_event_tip = null
	_event_tip_key = ""

	# ② 胜负进度：一行标签 + 一条进度条
	var y := PAD + ROUND_H + GAP
	_weighted_caption = _put(CWStyle.label("癌性加权", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, y + 10, 100)
	_weighted_max = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		PAD, y + 10, W, HORIZONTAL_ALIGNMENT_RIGHT)
	_weighted = _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.CANCER),
		PAD, y, W - 36, HORIZONTAL_ALIGNMENT_RIGHT)
	var track := ColorRect.new()
	track.color = Color("0a0f16")
	track.position = Vector2(PAD, y + 28)
	track.size = Vector2(W, 8)
	add_child(track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = CWStyle.CANCER
	_bar_fill.position = Vector2(PAD, y + 28)
	_bar_fill.size = Vector2(0, 8)
	add_child(_bar_fill)

	# ③ 玩家列表
	y = PAD + ROUND_H + GAP + SCORE_H + GAP
	for i in n:
		_rows.append(_build_row(y + i * ROW_H, i))

	# ④ 免疫等级（上面一道分隔线）
	y += n * ROW_H + GAP
	_level_y = y
	var rule := ColorRect.new()
	rule.color = Color(CWStyle.LINE, 0.25)
	rule.position = Vector2(PAD, y)
	rule.size = Vector2(W, 1)
	add_child(rule)
	var lv_cap := CWStyle.label(LEVEL_CAPTION, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_put(lv_cap, PAD, y + 20, 80)
	## 等级数字**居中在「免疫等级」和记忆行之间那道缝里**（Kevin 2026-09-10 定）。
	##
	## 位置**只能在 refresh() 里现算**（`_layout_level`）：缝的右边缘跟着记忆行的长短走，
	## 而那串会变 ——「抗原记忆 0 / 6」和「抗原记忆 18 / 20」差着 15px，
	## X 级还会换成「效应记忆 25」。在这儿算死就等于又埋一个要人记得同步的常数
	## （issue #6 就是这么来的：原来数字右对齐到 `W - 92`，那 92 是照旧文案量的，
	## 记忆行一加「/ 下一档」就顶到数字上了）。
	##
	## 纵向按**基线**对齐而不是按行框：两个字号的行框虚高不一样（10px 的 ascent 11、
	## 20px 的 22），照行框顶对齐会差 3px，并排时一眼就看得出来。
	var lv_y: float = y + 20 + CWStyle.FONT.get_ascent(CWStyle.SIZE_LABEL) \
		- CWStyle.FONT.get_ascent(CWStyle.SIZE_BODY)
	_level = _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.IMMUNE),
		PAD, lv_y, 0, HORIZONTAL_ALIGNMENT_CENTER)
	_memory = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		PAD, y + 20, W, HORIZONTAL_ALIGNMENT_RIGHT)
	## 升级进度条（Kevin 2026-09-10：「方便玩家观察和计算」）。
	##
	## **摆在这一块的底边，而且只有 4px 高** —— 文件头那条「一个数都别改」是硬的：
	## 6 人局五块加起来 530，只余 10px，把哪一块调高一点就溢出。
	## 好在 44px 里文字的**墨迹**只到 y+31（点阵字的行框虚高 23px 而字形只有 10px），
	## y+34 起是空的，细条正好塞得进去，不占任何人的地方。
	_lv_bar_bg = ColorRect.new()
	_lv_bar_bg.color = Color(CWStyle.TEXT_OFF, 0.30)
	_lv_bar_bg.position = Vector2(PAD, y + BAR_DY)
	_lv_bar_bg.size = Vector2(W, BAR_H)
	_lv_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lv_bar_bg)
	_lv_bar_fill = ColorRect.new()
	_lv_bar_fill.color = CWStyle.IMMUNE
	_lv_bar_fill.position = _lv_bar_bg.position
	_lv_bar_fill.size = Vector2(0, BAR_H)
	_lv_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lv_bar_fill)

	## ⑤「结束回合」钉在底部（设计稿 margin-top:auto），在 _chrome() 里建


func _build_row(y: float, pid: int) -> Dictionary:
	var bg := ColorRect.new()
	bg.position = Vector2(PAD, y)
	bg.size = Vector2(W, ROW_H)
	bg.color = Color(0, 0, 0, 0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	## 悬停整行 → 浮出该玩家的已装备清单（设计稿：贴着「技 N」往左浮）。
	## 感应区做整行而不是只做「技 N」两个字：44px 的行才够格算命中目标。
	var hover := Control.new()
	hover.position = Vector2(PAD, y)
	hover.size = Vector2(W, ROW_H)
	hover.mouse_filter = Control.MOUSE_FILTER_PASS   ## 只感应悬停，不吃点击
	hover.mouse_entered.connect(func() -> void: _tip_pid = pid)
	hover.mouse_exited.connect(func() -> void:
		if _tip_pid == pid:
			_tip_pid = -1)
	## 点一下**固定**这一行的详情（2026-09-04 Kevin 要的）：不固定的话框会随鼠标一起消失，
	## 想读技能正文就永远够不着它。再点同一行取消，点别的行直接换过去。
	hover.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_tip_pinned = -1 if _tip_pinned == pid else pid
			_tip_key = ""      ## 固定与否决定列什么，键作废、强制重搭
			skill_hovered.emit({}, 0.0, -1.0))
	add_child(hover)

	var x: float = PAD + ROW_PAD
	var fac := ColorRect.new()            ## 阵营色条 4×30
	fac.position = Vector2(x, y + (ROW_H - 30) / 2.0)
	fac.size = Vector2(4, 30)
	add_child(fac)
	x += 4 + 8

	## 贴图有 16/24/32 三种尺寸，一律居中摆、不缩放 —— 非整数倍会糊。
	var icon := Sprite2D.new()
	icon.position = Vector2(x + ICON / 2.0, y + ROW_H / 2.0)
	add_child(icon)
	x += ICON + 8

	var nm := _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT), x, y + 4, NAME_W)
	## 联机昵称最长 12 字（20px 字 = 240px），不裁会压到同一行右对齐的能量数上；
	## 本地对局的「免疫A」只有 52px，不受影响（2026-09-03 排版体检）
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	## **先开裁切再定尺寸**（架构约定；不裁的 Label 最小宽 = 全文宽，会把这里的 110 顶开）——
	## 2026-09-07 Kevin 拍到「图标重叠」：联机局的「恶性黑色素瘤 · 离线代打」正是这么压到历史小卡底下的。
	## 实际宽度每帧由 _fit_type_label() 按小卡占了多少再收一次
	var ty := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	ty.clip_text = true
	ty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_put(ty, x, y + 26, 110)
	var right: float = PAD + W - ROW_PAD
	## 能量数右对齐到预计收入左边（顶行从右往左：+x.x → 能量 → 技 N，Kevin 2026-09-06 定的顺序）
	var en := _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI),
		x, y + 4, right - INCOME_RESERVE - x, HORIZONTAL_ALIGNMENT_RIGHT)
	## 手牌方块：右对齐贴到行的右缘，占行底那一行
	var pips: Array = []
	var total: float = CWData.HAND_MAX * (PIP + PIP_GAP) - PIP_GAP
	for k in CWData.HAND_MAX:
		var pip := ColorRect.new()
		pip.position = Vector2(right - total + k * (PIP + PIP_GAP), y + 30)
		pip.size = Vector2(PIP, PIP)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pip)
		pips.append(pip)
	## 历史小卡：种类小字最长 6 字（60px）到 x=134，方块从 right-total=180 起，中间 46px 放三张叠 6px 的小卡刚好；
	## 小卡 20px 高、贴行底（y+24..y+44），悬停抬 2px 仍在自己的框里
	var history := Control.new()
	history.position = Vector2(right - total - 4.0 - HISTORY_W, y + ROW_H - (HISTORY_ICON + 2.0) - 2.0)
	history.size = Vector2(HISTORY_W, HISTORY_ICON + 2.0 + 2.0)
	history.mouse_filter = Control.MOUSE_FILTER_IGNORE
	history.visible = false
	add_child(history)
	## 预计收入「+x.x」贴行右缘、能量数右边（Kevin 2026-09-06：每回合预计拿到的有氧 / 无氧呼吸，显示在能量边）
	var inc := _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		x, y + 10, right - x, HORIZONTAL_ALIGNMENT_RIGHT)
	## 「技 N」放**能量那一行**（团队 2026-08-28 选的右边那版），右对齐到能量左侧
	var sk := _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		x, y + 10, right - ENERGY_RESERVE - INCOME_RESERVE - x, HORIZONTAL_ALIGNMENT_RIGHT)
	return { "bg": bg, "fac": fac, "history": history, "icon": icon,
		"name": nm, "type": ty, "energy": en, "income": inc, "pips": pips, "skills": sk }


## 第二行只有这么宽：种类文字 → 历史小卡 → 手牌方块。小卡占了多少，种类就让多少
## （Kevin 2026-09-07：那一行会重叠）。没打过牌时种类一直铺到方块左边，不白让。
func _fit_type_label(row: Dictionary) -> void:
	var ty: Label = row["type"]
	var pips: Array = row["pips"]
	if pips.is_empty():
		return
	var limit: float = (pips[0] as Control).position.x - 4.0
	var history: Control = row.get("history", null)
	if history != null and is_instance_valid(history) and history.visible:
		var n: int = history.get_child_count()
		if n > 0:
			## 收着时最左那张的位置：容器右缘往左退「一张 + (n-1) 个 2px」
			var taken: float = (HISTORY_ICON + 2.0) + float(n - 1) * HISTORY_STEP
			limit = history.position.x + history.size.x - taken - 4.0
	ty.size.x = maxf(40.0, limit - ty.position.x)


# ============ 历史卡牌 ============

## 抽到即结算的事件卡：记进「回合数」那一栏（Kevin 2026-09-07 方案乙）。**不记在玩家行** ——
## 它不是谁「打出」的，按 PRD 抽到就结算、不进手牌，记在回合上比记在人身上更贴事实。
## 悬停摊开 / 点击看卡面复用玩家行那套（`_make_history_chip` / `_layout_history` 同一批函数）。
func note_event_card(game: CWGame, faction: int, card_name: String) -> void:
	if game == null or _event_strip == null or not is_instance_valid(_event_strip):
		return
	_sync_history_round(game)
	var rows: Dictionary = CWCardInfo.describe(card_name, faction, CWCardData.cancer_phase(game.round_no))
	var accent: Color = CWStyle.IMMUNE if faction == CWData.Faction.IMMUNE else CWStyle.CANCER
	_event_strip.add_child(_make_history_chip(rows, faction, card_name, accent))
	## 超出上限丢最旧的。**remove_child 之后再 queue_free**：只 queue_free 的话这一帧的 get_child_count 还算着它
	while _event_strip.get_child_count() > EVENT_STRIP_MAX:
		var oldest: Node = _event_strip.get_child(0)
		_event_strip.remove_child(oldest)
		oldest.queue_free()
	_event_strip.visible = true
	_layout_history(_event_strip)
	_layout_event_row()


## 世界事件文字与事件卡共用那一行：文字裁到小卡左边（方案乙认下的代价，同时挂三个世界事件时会裁得更早）。
## 摊开时小卡会盖住文字 —— 那是临时浮层，和玩家行摊开盖住种类小字同一个道理。
func _layout_event_row() -> void:
	if _events == null or _event_strip == null or not is_instance_valid(_event_strip):
		return
	var n: int = _event_strip.get_child_count()
	_event_strip.visible = n > 0
	if n == 0:
		_events.size.x = W          ## 没有小卡就占满整行，别白白扣掉留缝
		return
	var taken: float = (HISTORY_ICON + 2.0) + float(n - 1) * HISTORY_STEP
	_events.size.x = maxf(40.0, W - taken - 6.0)


## 本回合刚打出的卡，往对应玩家头像左边追加一个小卡片。
func note_played_card(game: CWGame, pid: int, faction: int, card_name: String) -> void:
	if game == null or pid < 0 or pid >= _rows.size():
		return
	_sync_history_round(game)
	var row: Dictionary = _rows[pid]
	if not row.has("history"):
		return
	var history: Control = row["history"]
	var rows: Dictionary = CWCardInfo.describe(card_name, faction, CWCardData.cancer_phase(game.round_no))   ## 带分期高亮
	var chip := _make_history_chip(rows, faction, card_name)   ## 主色边：和上面按阵营染色的事件卡区分开
	history.visible = true
	history.add_child(chip)
	_layout_history(history)
	_fit_type_label(row)   ## 小卡多一张，种类就再让一点（Kevin 2026-09-07）


func _sync_history_round(game: CWGame) -> void:
	if game == null:
		return
	if _history_round == game.round_no:
		return
	_history_round = game.round_no
	_clear_history()


func _clear_history() -> void:
	if _event_strip != null and is_instance_valid(_event_strip):
		for child in _event_strip.get_children():
			_event_strip.remove_child(child)
			child.queue_free()
		_event_strip.visible = false
		_layout_event_row()
	for row in _rows:
		if not row.has("history"):
			continue
		var history: Control = row["history"]
		history.visible = false
		for child in history.get_children():
			child.queue_free()


## 两种姿态（Kevin 2026-09-07，照手牌区的做法）：
## · 收着：叠 2px（1px 边框 + 1px 卡面），只有最上面那张画图标；
## · 摊开（鼠标停在整叠上）：每张完整露出、紧挨着往左排（右缘钉着不动，临时盖住种类小字无妨），
##   停在哪张哪张抬 2px、白边、压最上层。紧挨着排是有意的：张与张之间留缝的话，鼠标划过缝就算离开整叠、收回去又立刻摊开，会抖。
## 位置直接摆、不做补间：像素界面上 20px 的挪动补不补都一样，少一份「一张卡两条补间」的坑。
func _layout_history(history: Control) -> void:
	if history == null:
		return
	var chips := history.get_children()
	var count := chips.size()
	var expanded := bool(history.get_meta("expanded", false))
	var chip_w := HISTORY_ICON + 2.0
	for i in count:
		var chip: Control = chips[i]
		var hot := bool(chip.get_meta("hovered", false))
		var back := float(count - 1 - i)
		## 右缘按容器宽算，不写死 HISTORY_W —— 玩家行那只容器就是 HISTORY_W 宽，回合栏那只更宽（2026-09-07）
		var x := history.size.x - chip_w - back * (chip_w if expanded else HISTORY_STEP)
		if not expanded:
			x = maxf(0.0, x)
		var base_y := 2.0   ## 框顶留 2px 给悬停上抬
		chip.position = Vector2(x, base_y - (2.0 if hot else 0.0))
		chip.set_meta("base_y", base_y)
		chip.set_meta("base_z", i)
		chip.set_meta("top", i == count - 1)
		chip.z_index = 50 if hot else i
		chip.add_theme_stylebox_override("panel", _history_box(hot, chip.get_meta("accent", CWStyle.LINE)))
		## 收着时被压住的卡只露边框 + 一线卡面，图标不画；摊开后每张都画
		(chip.get_child(0) as Control).visible = expanded or i == count - 1 or hot


## 鼠标离开某张之后（下一帧再看）：整叠上一张都没停着才收回去 —— 划到相邻那张时先 exited 再 entered，
## 同一帧里看会误判成离开
func _collapse_if_idle(history: Control) -> void:
	if history == null or not is_instance_valid(history):
		return
	for c in history.get_children():
		if bool(c.get_meta("hovered", false)):
			return
	history.set_meta("expanded", false)
	_layout_history(history)


## 边框**不透明、1px**：叠放时露出来的 2px = 这 1px 边框 + 1px 卡面；半透明会和底下那张混成第三种颜色，
## CWStyle.box 默认的 2px 描边则会让露出来的 2px 全是边框、糊成一道实心色带
## accent = 静止时的边色：玩家行那排（打出的卡）用主色，回合栏那排（抽到的事件卡）按阵营染（2026-09-07）
func _history_box(hot: bool, accent := CWStyle.LINE) -> StyleBoxFlat:
	var box := CWStyle.box(1.0, Color("0e1620"), 1, 1)
	box.set_border_width_all(1)
	box.border_color = Color.WHITE if hot else accent
	return box


func _make_history_chip(rows: Dictionary, faction: int, card_name: String,
		accent := CWStyle.LINE) -> Panel:
	var chip := Panel.new()
	chip.size = Vector2(HISTORY_ICON + 2.0, HISTORY_ICON + 2.0)
	chip.mouse_filter = Control.MOUSE_FILTER_STOP
	chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	chip.add_theme_stylebox_override("panel", _history_box(false, accent))
	chip.set_meta("accent", accent)
	chip.set_meta("rows", rows)
	chip.set_meta("faction", faction)
	chip.set_meta("card_name", card_name)
	chip.set_meta("hovered", false)
	var tex := TextureRect.new()
	tex.texture = preload("res://assets/art/ui/card_chip.png")
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.position = Vector2(1, 1)
	tex.size = Vector2(HISTORY_ICON, HISTORY_ICON)
	chip.add_child(tex)
	## 停上去：整叠摊开、这张抬起（Kevin 2026-09-07：收着时叠 2px 根本点不到第二张）
	chip.mouse_entered.connect(func() -> void:
		chip.set_meta("hovered", true)
		var history := chip.get_parent() as Control
		if history != null:
			history.set_meta("expanded", true)
			_layout_history(history)
	)
	chip.mouse_exited.connect(func() -> void:
		chip.set_meta("hovered", false)
		var history := chip.get_parent() as Control
		if history != null:
			_layout_history(history)                 ## 这张先落回去（仍是摊开姿态）
			_collapse_if_idle.call_deferred(history)  ## 下一帧整叠没人停着才收
	)
	chip.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var at := chip.get_global_rect().position
		played_card_pressed.emit(rows, at.x, at.y)
	)
	return chip


func _build_end_button() -> PanelContainer:
	var p := PanelContainer.new()
	## 设计稿 .btn.go：底与描边同色，字反过来用深色
	var box := CWStyle.box(1.0, CWStyle.IMMUNE, 6, 8)
	box.border_color = CWStyle.IMMUNE
	p.add_theme_stylebox_override("panel", box)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var dark := Color("0d1620")
	for pair in [["结束回合", CWStyle.SIZE_BODY], ["空格", CWStyle.SIZE_LABEL]]:
		var l := CWStyle.label(pair[0], pair[1], dark)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			end_turn_pressed.emit())
	return p


# ============ 世界事件悬浮框 ============

## 悬停事件行时，在面板左侧浮出每个进行中事件的一句话效果（CWWorldFx.BLURB）和剩余回合。
## 每帧从 refresh() 进来，键（事件行文字）没变就不重搭；没悬停或没事件就藏起来。
func _update_event_tip(game: CWGame) -> void:
	if not _event_hover or not _events.visible:
		if _event_tip != null:
			_event_tip.visible = false
		return
	var key := _events.text
	if key == _event_tip_key and _event_tip != null:
		_event_tip.visible = true
		return
	_event_tip_key = key
	if _event_tip != null:
		remove_child(_event_tip)
		_event_tip.queue_free()
	var items: Array = []
	for e in game.events["active"]:
		if game.world_fx.is_world_event(e):
			items.append(e)
	var tip_w := EVENT_TIP_W
	## 效果正文**自己折行**（CWCardInfo.wrap_text），不用 Label 的 autowrap。
	## 2026-09-08 Kevin 截图：【抗原变异】那句 270px 宽的话在 256px 的框里没断开、
	## 单行冲出右边框。同一处还有另半个 bug —— block_h 写死「效果两行」，
	## 三行的句子会压到下一个事件的名字上。现在两件事一起解决：行数现算、块高跟着走。
	## 顺带白拿 wrap_text 的两条排版规矩：汉字与数字之间补空格、标点不做行首。
	var wrapped: Array = []                ## 与 items 一一对应的已折行正文
	var h: float = 8 * 2 + 15
	for e in items:
		var blurb: String = CWWorldFx.BLURB.get(e["name"], "")
		var dl := doubled_line(String(e.get("doubled", "")))
		if dl != "":
			blurb += "\n" + dl
		var ls := CWCardInfo.wrap_text(blurb, tip_w - 24.0)
		wrapped.append(ls)
		h += EVENT_NAME_H + ls.size() * EVENT_LINE_H + EVENT_BLOCK_GAP
	_event_tip = Control.new()
	_event_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_event_tip.size = Vector2(tip_w, h)
	_event_tip.position = Vector2(-(tip_w + 8.0), clampf(_events.position.y, 8.0, RECT.size.y - h - 8.0))
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_event_tip.add_child(bg)
	var title := CWStyle.label("进行中的世界事件", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	title.position = Vector2(12, 8)
	_event_tip.add_child(title)
	var y: float = 8 + 15
	for i in items.size():
		var e: Dictionary = items[i]
		var head := "【%s】%s" % [e["name"], "×%d" % int(e["stacks"]) if int(e["stacks"]) > 1 else ""]
		var name_label := CWStyle.label(head, CWStyle.SIZE_BODY, CWStyle.TEXT)
		name_label.position = Vector2(12, y)
		_event_tip.add_child(name_label)
		var left_label := CWStyle.label("本回合" if int(e["left"]) <= 1 else "剩 %d 回合" % int(e["left"]),
			CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		left_label.position = Vector2(12, y + 4)
		left_label.size = Vector2(tip_w - 24, 0)
		left_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_event_tip.add_child(left_label)
		var ls: PackedStringArray = wrapped[i]
		var blurb := CWStyle.label("\n".join(ls), CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
		blurb.position = Vector2(12, y + EVENT_NAME_H)
		_event_tip.add_child(blurb)
		y += EVENT_NAME_H + ls.size() * EVENT_LINE_H + EVENT_BLOCK_GAP
	add_child(_event_tip)


# ============ 被动技能悬浮框 ============

## 悬停玩家行时，在面板左侧浮出该细胞的已装备清单。没装备就不浮（空框是噪音）。
## 每帧从 refresh() 进来：装备可以在悬停期间变（BCL-2 触发会弃掉自己），
## 键没变就不重搭。死亡不掉装备（口径 #65 批），所以死了照样能看。
## 详情框里列什么：**纯函数**，测试直接核对，不用真渲染。
##
## 两档内容，因为两种用法的诉求不同：
## · **悬停**（`full = false`）只列已装备的永久技能 —— 平时划过右栏时最少的打扰，
##   没装备就干脆不浮（这是 2026-08-30 定的老行为，别因为加了固定就把它变吵）；
## · **固定**（`full = true`，点了那一行）列全套：细胞种类的自带技能 → 主动技能 → 已装备。
##   被动技能（【伪足穿透】【囊性护甲】【I-各司其职】…）**永远不进行动栏**，
##   这里是玩家唯一读得到它们的地方（2026-09-04 Kevin 要的）。
##
## 每项是 { text, info }：`info` = 悬停时浮出的 PRD 原文；`head` 项是小标题，不可悬停。
## 主动技能那一段直接走 `CWActions.action_kinds()` —— 和行动栏同一份清单，两处对不上是迟早的事。
## **即时卡挂上的修饰条目**（本回合 / 本世界回合 / 待触发）两种形态都列在最后（`mod_rows`）——
## 之前只有日志里看得到它们（Kevin 2026-09-06：「现在看不到即时的 buff」）。
static func tip_rows(game: CWGame, pid: int, full: bool) -> Array:
	if pid < 0 or pid >= game.cells.size():
		return []
	var cell: Dictionary = game.cell_of(pid)
	var immune: bool = cell["faction"] == CWData.Faction.IMMUNE
	var equipped: Array = cell["equipped"]
	var phase := CWCardData.cancer_phase(game.round_no)   ## 分档写法高亮当前档（Kevin 2026-09-06）
	var mods: Array = mod_rows(cell, phase)
	var out: Array = []
	if not full:
		if equipped.is_empty() and mods.is_empty():
			return []
		if not equipped.is_empty():
			out.append({ "head": "已装备 · 持续生效" })
			for n in equipped:
				out.append({ "text": n, "info": CWCardInfo.describe(n, cell["faction"], phase) })
		out.append_array(mods)
		return out
	var tinfo: Dictionary = CWCardInfo.describe_type(cell["itype"], "【细胞种类】") if immune \
		else CWCardInfo.describe_ctype(cell["ctype"])
	if not tinfo["lines"].is_empty():
		out.append({ "head": "细胞种类" })
		out.append({ "text": tinfo["name"], "info": tinfo })
	var acts: Array = []
	for act in game.actions.action_kinds(cell):
		acts.append({ "text": CWData.act_name(act, cell["faction"]),
			"info": CWCardInfo.describe_act_for(game, cell, act) })
	if not acts.is_empty():
		out.append({ "head": "主动技能" })
		out.append_array(acts)
	if not equipped.is_empty():
		out.append({ "head": "已装备 · 持续生效" })
		for n in equipped:
			out.append({ "text": n, "info": CWCardInfo.describe(n, cell["faction"], phase) })
	out.append_array(mods)
	return out


## 即时卡挂在细胞上的修饰条目（CWGame.add_mod）按时钟分三段：本回合 / 本世界回合 / 待触发（不过期，挂着等触发）。
## 同名合并、次数 >1 写「×N」；条目悬停浮出的是那张卡的 PRD 原文。
## 名字带「·待发」的是引擎内部标记（如【细胞因子网络】的待发计数），不是玩家打出的东西，不列。
## phase = 癌症卡的分期，条目详情里的分档写法高亮这一档（-1 = 不高亮）
static func mod_rows(cell: Dictionary, phase := -1) -> Array:
	var uses_by := { "turn": {}, "round": {}, "": {} }
	for m in cell["mods"]:
		var mod_name: String = m["name"]
		if mod_name.contains("·待发"):
			continue
		var clock: String = m["until"] if uses_by.has(m["until"]) else ""
		uses_by[clock][mod_name] = int(uses_by[clock].get(mod_name, 0)) + int(m["uses"])
	var out: Array = []
	for pair in [["turn", "即时 · 本回合"], ["round", "即时 · 本世界回合"], ["", "即时 · 待触发"]]:
		var group: Dictionary = uses_by[pair[0]]
		if group.is_empty():
			continue
		out.append({ "head": pair[1] })
		for mod_name in group:
			var uses: int = group[mod_name]
			out.append({ "text": mod_name if uses <= 1 else "%s ×%d" % [mod_name, uses],
				"info": CWCardInfo.describe(mod_name, cell["faction"], phase) })
	return out


## 框高：小标题 15、条目 24、上下内边距各 8；固定态底下多一行操作提示
static func tip_height(rows: Array, full: bool) -> float:
	var h := 16.0
	for r in rows:
		h += 15.0 if r.has("head") else 24.0
	return h + (15.0 if full else 0.0)


func _update_tip(game: CWGame) -> void:
	var full: bool = _tip_pinned >= 0
	var pid: int = _tip_pinned if full else _tip_pid
	var rows: Array = tip_rows(game, pid, full)
	if rows.is_empty():
		if _tip != null:
			_tip.visible = false
		_tip_key = ""
		return
	var names := PackedStringArray()
	for r in rows:
		names.append(r.get("head", r.get("text", "")) + str(r.get("info", {}).get("lines", [])))
	## 分期进键：条目的详情（含分档高亮）是搭框时算好捏在闭包里的，跨期要重搭才会换档
	var key := "%d|%d|%d|%s" % [pid, int(full), CWCardData.cancer_phase(game.round_no), ",".join(names)]
	if key == _tip_key and _tip != null:
		_tip.visible = true
		return
	_tip_key = key
	if _tip != null:
		remove_child(_tip)
		_tip.queue_free()
	_tip = Control.new()
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := tip_height(rows, full)
	_tip.size = Vector2(TIP_W, h)
	var row_top: float = PAD + ROUND_H + GAP + SCORE_H + GAP + pid * ROW_H
	_tip.position = Vector2(-(TIP_W + 8.0),
		clampf(row_top, 8.0, RECT.size.y - h - 8.0))
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 固定态整块底板也收鼠标：指针在框内任何位置都算「被控件占着」，棋盘就不会把底下那一格的详情浮上来
	## （Kevin 2026-09-06 截图：技能详情和格子详情叠在一起）。不固定时照旧放行，理由同下面条目那段注释
	bg.mouse_filter = Control.MOUSE_FILTER_STOP if full else Control.MOUSE_FILTER_IGNORE
	_tip.add_child(bg)
	var y := 8.0
	for r in rows:
		if r.has("head"):
			var head := CWStyle.label(r["head"], CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
			head.position = Vector2(12, y)
			_tip.add_child(head)
			y += 15.0
			continue
		var item := CWStyle.label(r["text"], CWStyle.SIZE_BODY, CWStyle.TEXT)
		item.position = Vector2(12, y)
		if full:
			## 固定态才收鼠标：不固定时框会随鼠标离开玩家行而收起，
			## 让它挡事件只会把「移开就收」变成「移不开」
			item.size = Vector2(TIP_W - 24, 22)
			item.mouse_filter = Control.MOUSE_FILTER_STOP
			var info: Dictionary = r["info"]
			item.mouse_entered.connect(func() -> void:
				item.add_theme_color_override("font_color", Color.WHITE)
				skill_hovered.emit(info, _tip.global_position.x - CWCardInfo.W - 8.0, item.get_global_rect().position.y))
			item.mouse_exited.connect(func() -> void:
				item.add_theme_color_override("font_color", CWStyle.TEXT)
				skill_hovered.emit({}, 0.0, -1.0))
		_tip.add_child(item)
		y += 24.0
	if full:
		var hint := CWStyle.label("停在技能上看详情 · 再点该行取消固定",
			CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
		hint.position = Vector2(12, y)
		_tip.add_child(hint)
	add_child(_tip)


## 能量旁的「预计收入」小字：免疫 = 下一次 S 阶段的【有氧呼吸】（CWWorld.aerobic_income），
## 癌症 = 回合末 / E 阶段的【无氧呼吸】份额（CWWorld.anaerobic_gain_for）。两个都是引擎的纯查询，
## 界面不抄算式（约定 #11）。纯函数，测试直接核对文案。
static func income_text(game: CWGame, cell: Dictionary) -> String:
	var v: int = game.world.aerobic_income(cell) if cell["faction"] == CWData.Faction.IMMUNE \
		else game.world.anaerobic_gain_for(cell)
	return "+%s" % CWData.fmt(v)


## 摆一个 Label 到面板内的绝对位置。
## 本面板全部绝对定位：各块高度是设计稿钉死的数，用容器反而要靠一堆 size_flags
## 才能复现同样的值，改起来还看不出跟标注稿的对应关系。
## 填 n 个方块。空格子不留白 —— 画成暗色描边，让「一共 8 格」这件事始终看得见。
func _set_pips(row: Dictionary, n: int, accent: Color) -> void:
	for k in row["pips"].size():
		var pip: ColorRect = row["pips"][k]
		pip.color = accent if k < n else CWStyle.TEXT_OFF_DIM
		pip.modulate.a = 1.0 if k < n else 0.45


## 悬浮详情的排版常量。效果正文的行数现算（见 _build_event_tip），所以块高不是定值。
## 世界事件悬浮框的排版常量。**别和上面被动技能框的 TIP_W(200) 混用**——两个框宽度不同。
const EVENT_TIP_W := 280.0        ## 框宽；效果正文按 EVENT_TIP_W - 24 折行
const EVENT_NAME_H := 24.0        ## 名字行（含右对齐的「剩 N 回合」）占的高度
const EVENT_LINE_H := 15.0        ## 效果正文每行的行高
const EVENT_BLOCK_GAP := 6.0      ## 两个事件之间留的空


## 进行中的世界事件一行字：「【基质阻隔】本回合·【增殖抑制】剩2回合」。
## 只列世界事件（`is_world_event`），卡牌挂的全局修饰（TGF-β…）不在这里 —— 那些有卡面可查。
## `left` 含当前回合：触发当回合的持续事件是「剩2回合」，回合末倒计时后是「剩1回合」。
## 写法故意不留空格：两个六字事件并排是 22 个字，232px 的行宽刚好放下；加空格就得省略号。
## 被【双重触发】加倍的事件，在名字后面加一枚「双重」标（Kevin 2026-09-08：
## 「不然玩家们不知道有双重触发」）。**三档都要标** —— 原来只有「数值翻倍」那档
## 因为 stacks>1 顺带露出个「×2」，另外两档（持续翻倍、连演两回合）在界面上
## 和普通事件一模一样，玩家完全看不出为什么这一条格外难缠。
static func active_events_text(game: CWGame) -> String:
	var parts: Array = []
	for e in game.events["active"]:
		if not game.world_fx.is_world_event(e):
			continue
		var s := "【%s" % e["name"]
		if String(e.get("doubled", "")) != "":
			s += "·双重"
		s += "】"
		if int(e["stacks"]) > 1:
			s += "×%d" % int(e["stacks"])
		s += "本回合" if int(e["left"]) <= 1 else "剩%d回合" % int(e["left"])
		parts.append(s)
	return "·".join(PackedStringArray(parts))


## 悬浮详情里补的那一句：【双重触发】把这条事件**怎么**加倍了。
## 三档说的是三件不同的事，不能糊成一句「效果翻倍」——
## 「数值翻倍」和「多演一个回合」对玩家的应对完全不同。
static func doubled_line(mode: String) -> String:
	match mode:
		"stacks":
			return "【双重触发】：两份同时生效，数值翻倍"
		"rounds":
			return "【双重触发】：持续回合翻倍"
		"repeat":
			return "【双重触发】：连续两个回合各完整生效一遍"
		_:
			return ""


## 把等级数字居中到「免疫等级」与记忆行之间那道缝里。
##
## **每次 refresh 都要重算**：缝的右边缘 = 记忆行的左缘，而记忆行右对齐、长度会变
## （「抗原记忆 0 / 6」比「抗原记忆 18 / 20」窄 15px，X 级又换成「效应记忆 25」）。
## 算死一个数就是又埋一个要人记得同步的常数 —— issue #6 正是那么来的。
##
## 做法是**把标签的盒子铺满整道缝、让它自己居中**，而不是算「中点减半个字宽」：
## 这样 I / II / III / X 宽度不同也各自居中，不必再去量字。
func _layout_level() -> void:
	if _level == null or _memory == null:
		return
	var f := CWStyle.FONT
	var cap_right: float = PAD + f.get_string_size(LEVEL_CAPTION,
		HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
	var mem_left: float = PAD + W - f.get_string_size(_memory.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
	_level.position.x = cap_right
	_level.size.x = maxf(mem_left - cap_right, 0.0)


## 当前这一档攒了多少（0..1）；**X 级返回 -1 = 没有下一级**，调用方据此把条收起来。
## **纯函数**，好直接测 —— 这一段有两个容易错的地方：
## ① 进度要按**本档区间**算（从 tiers[lv] 到 tiers[lv+1]），不是从 0 算，
##    否则 I→II 走到一半时条会显示 80%；
## ② 记忆**会被扣**（突变削 2），而等级只升不降 —— 于是 memory 可能掉到
##    tiers[lv] 以下，算出来是负的。钳住。
static func level_progress(memory: int, level: int, tiers: Array) -> float:
	if level >= tiers.size() - 1:
		return -1.0
	var lo := int(tiers[level])
	var hi := int(tiers[level + 1])
	if hi <= lo:
		return -1.0
	return clampf(float(memory - lo) / float(hi - lo), 0.0, 1.0)


## 右下角那行字。**升级前写成「8 / 10」**：光有当前值的话，「还差几次净化」
## 得玩家自己去记门槛（而门槛还按人数分档，记不住）。
## X 级之后没有门槛可写，回到只报数 —— 那时它管的是【效应应答】的费用，不是进度。
static func memory_text(memory: int, level: int, tiers: Array) -> String:
	var name := CWData.memory_name(level)
	if level >= tiers.size() - 1:
		return "%s %d" % [name, memory]
	return "%s %d / %d" % [name, memory, int(tiers[level + 1])]


func _put(l: Label, x: float, y: float, w: float,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	l.position = Vector2(x, y)
	l.size = Vector2(w, 0)
	l.horizontal_alignment = align
	add_child(l)
	return l
