## settle_screen.gd —— 对局结束的结算屏
##
## 团队 2026-08-28 从四个方向里选的**丁：甲的画面 + 乙的数据**。
## 棋盘全见、压暗**只盖左边 696**、右侧竖条保持全亮 —— 竖条此刻就是终局读数，
## 每个人的能量和手牌都定格在那儿。横幅里装的是竖条**不显示**的那部分：
## 终局盘面的四个数，和带胜利线刻度的加权条。
##
## 分工是刻意的：**盘面数据归横幅，玩家清单留在竖条。**
## 再画一遍玩家卡片是重复占地方，所以横幅左下角那行小字把读者指过去。
##
## 尺寸照搬方向稿（960×540 设计分辨率）：横幅 696×300、上下居中、内边距 24/24/24/48。
## 和 [CWMatchPanel] 一样全部绝对定位 —— 各块位置是稿子钉死的数，
## 用容器反而要靠一堆 size_flags 才能复现，还看不出跟稿子的对应关系。
class_name CWSettleScreen
extends Control

## "restart" = 再来一局（同人数、新种子）；"menu" = 返回主菜单
signal chose(action: String)

# ---- 版面（方向稿钉死的数）----
const BANNER_W := 696       ## 只盖棋盘那半边
const BANNER_H := 300
const BANNER_Y := (540 - BANNER_H) / 2.0    # 120
const PAD_T := 24
const PAD_L := 48
const PAD_R := 24
const SCRIM_ALPHA := 0.5
const BORDER_A := 0.55      ## 横幅上下那两道描边的 alpha

const TITLE_H := 44         ## 40px 字的行高
const STAT_W := 300         ## 左边「终局盘面」那一块
const BAR_W := 300          ## 右边加权条
const BAR_H := 8
const BTN_H := 52           ## 和 CWActionBar.BTN_H 是同一个数，两处按钮要一样高
const BTN_GAP := 8

## 结局标签。四种 win_kind 里有两种是 30 回合到的**判定**，不是击溃 ——
## 标签必须把这件事说出来，否则「限时判定」会被读成「打赢了」。
const KIND_CHIP := {
	"immune_clear": "清场",
	"cancer_weighted": "占地",
	"limit_immune": "限时判定",
	"limit_cancer": "限时判定",
}

## 四个大数的字段名。顺序就是屏上从左到右的顺序。
const STAT_LABELS := ["健康", "癌组织", "固化", "其中坏死"]

# ---- 动画 ----
## 五拍，全程约 1.5 秒。**中途任意点击或按键直接到位** ——
## 和主菜单过场同一条规矩（团队要求：别等做完再补）。
## 缓动统一 TRANS_CUBIC / EASE_OUT，和开场推进、细胞淡入是同一套手感。
const T_HOLD := 0.35        ## ① 分出胜负后先空一拍，不然结算屏像是「卡了一下」才蹦出来
const T_SCRIM := 0.35       ## ② 压暗层淡入
const T_OPEN := 0.42        ## ③ 横幅从中线上下拉开
const T_ROW := 0.22         ## ④ 每一块内容淡入 + 上浮
const ROW_GAP := 0.07       ## 相邻两块错开多少
const T_COUNT := 0.55       ## ⑤ 四个数滚上去、加权条填过胜利线
const LIFT := 8.0           ## 上浮距离。**取偶数** —— 20px 字号下 1 字模像素 = 2 屏幕像素

var _scrim: ColorRect
var _clip: Control          ## 会长高的窗口，clip_contents 造出「从中线拉开」
var _panel: Control         ## 真正的横幅，在窗口里保持不动
var _rows: Array[Control] = []      ## 分批淡入的四块
var _fac: ColorRect
var _title: Label
var _chip: PanelContainer
var _chip_text: Label
var _reason: Label
var _meta: Label
var _stat_num: Array[Label] = []
var _stat_lbl: Array[Label] = []
var _w_num: Label           ## 加权当前值
var _w_max: Label
var _bar_fill: ColorRect
var _bar_tick: ColorRect
var _bar_note: Label
var _btns: Array[PanelContainer] = []
var _btn_titles: Array[Label] = []
var _btn_costs: Array[Label] = []

var _built := false
var _tween: Tween
var _playing := false       ## 演出中：这期间按键只用来跳过
var _sel := 1               ## 默认停在「再来一局」上（.go 那个）
var _stats: Array[int] = [0, 0, 0, 0]
var _weighted := 0
var _goal := 1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 盖住底下棋盘的点击
	visible = false


# ============ 对外 ============

## 摆好数据并开演。中途放弃的那条路**不会**走到这里（winner 仍是 -1）。
func show_result(game: CWGame) -> void:
	if not _built:
		_build()
	_fill(game)
	visible = true
	_play()


## 回到主菜单 / 开新局前擦干净。下一局还会复用同一批节点。
func reset() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_playing = false
	visible = false
	modulate.a = 1.0


# ============ 取数 ============

func _fill(game: CWGame) -> void:
	var immune: bool = game.winner == CWData.Faction.IMMUNE
	var accent: Color = CWStyle.IMMUNE if immune else CWStyle.CANCER
	_fac.color = accent
	_title.text = "免疫胜利" if immune else "癌症胜利"
	_title.add_theme_color_override("font_color", accent)
	_chip.position.x = _title.position.x + CWStyle.FONT.get_string_size(
		_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_HERO).x + 14
	_chip_text.text = KIND_CHIP.get(game.win_kind, "")
	_chip_text.add_theme_color_override("font_color", accent)
	var chip_box := CWStyle.box(1.0, Color(0, 0, 0, 0), 3, 6)
	chip_box.border_color = Color(accent, 0.55)
	chip_box.set_border_width_all(2)
	_chip.add_theme_stylebox_override("panel", chip_box)
	_reason.text = _reason_text(game)

	_stats = [
		game.count_tissue(CWData.Tissue.HEALTHY),
		game.count_tissue(CWData.Tissue.CANCER),
		game.count_tissue(CWData.Tissue.SOLID),
		game.count_necrosis(),
	]
	_weighted = game.count_tissue(CWData.Tissue.CANCER) \
		+ 2 * game.count_tissue(CWData.Tissue.SOLID)
	_goal = maxi(game.tune.cancer_win_weighted, 1)
	_w_max.text = " / %d" % _goal
	_bar_note.text = "↑ 胜利线 %d" % _goal
	## 刻度钉在「胜利线占满条多少」的位置上；加权可能超过阈值（本例 98/64），
	## 所以条本身按 min(1, w/goal) 填，刻度按 goal/max(w, goal) 摆。
	_bar_tick.position.x = BAR_W * float(_goal) / float(maxi(_weighted, _goal))
	_bar_note.position.x = maxf(_bar_tick.position.x - 24.0, 0.0)
	_meta.text = "第 %d 回合 / 上限 %d　·　玩家结局见右侧竖条" % [
		game.round_no, game.tune.limit_round]


## 一句话胜因。**不直接用 game.win_reason** —— 那句自带「癌症胜利：」前缀，
## 和上面 40px 的标题重复；而且四种结局的句式不统一（两种带前缀、两种带后缀）。
## 这里按 win_kind 现写，数字仍旧从引擎取，文案与方向稿「四种结局」那张一致。
func _reason_text(game: CWGame) -> String:
	var w: int = game.count_tissue(CWData.Tissue.CANCER) \
		+ 2 * game.count_tissue(CWData.Tissue.SOLID)
	var cancerous: int = game.count_tissue(CWData.Tissue.CANCER) \
		+ game.count_tissue(CWData.Tissue.SOLID)
	match game.win_kind:
		"immune_clear":
			return "癌细胞全灭，且场上没有可用于复活的固化癌组织"
		"cancer_weighted":
			return "加权占地 %d >= %d，癌方达成占地胜利" % [w, game.tune.cancer_win_weighted]
		"limit_cancer":
			return "%d 回合到，癌性组织 %d >= %d，癌方判定胜" % [
				game.tune.limit_round, cancerous, game.tune.limit_cancerous]
		"limit_immune":
			return "%d 回合到，癌性组织 %d < %d，免疫方守住" % [
				game.tune.limit_round, cancerous, game.tune.limit_cancerous]
	return game.win_reason   ## 兜底：将来加了新的 win_kind 也不至于空着


# ============ 演出 ============

func _play() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_playing = true
	_scrim.color = Color(0, 0, 0, 0)
	_set_open(0.0)
	for row in _rows:
		row.modulate.a = 0.0
		row.position.y = row.get_meta("y") + LIFT
	_set_count(0.0)

	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_interval(T_HOLD)
	_tween.tween_property(_scrim, "color:a", SCRIM_ALPHA, T_SCRIM)
	## 横幅在压暗还没走完时就开始拉开 —— 两段完全前后相接会显得拖沓
	_tween.parallel().tween_method(_set_open, 0.0, 1.0, T_OPEN) \
		.set_delay(T_SCRIM * 0.3)
	for i in _rows.size():
		var row: Control = _rows[i]
		var at: float = T_OPEN * 0.8 + i * ROW_GAP
		_tween.parallel().tween_property(row, "modulate:a", 1.0, T_ROW).set_delay(at)
		_tween.parallel().tween_property(row, "position:y", row.get_meta("y"), T_ROW) \
			.set_delay(at)
	## 数字和进度条跟着「数据」那一块（第 3 块）一起动：
	## 条要**看得见地越过胜利线**，那一下就是这局的结论。
	_tween.parallel().tween_method(_set_count, 0.0, 1.0, T_COUNT) \
		.set_delay(T_OPEN * 0.8 + 2 * ROW_GAP)
	_tween.tween_callback(func() -> void: _playing = false)


## 横幅从中线上下拉开：窗口长高，面板在窗口里保持不动。
func _set_open(k: float) -> void:
	var h: float = BANNER_H * k
	var top: float = BANNER_Y + (BANNER_H - h) / 2.0
	_clip.position = Vector2(0, top)
	_clip.size = Vector2(BANNER_W, h)
	_panel.position = Vector2(0, BANNER_Y - top)


## 四个数滚上去 + 加权条填过去。k 是 0..1 的进度（缓动已经由 tween 做过）。
func _set_count(k: float) -> void:
	for i in _stat_num.size():
		_stat_num[i].text = str(int(round(_stats[i] * k)))
	var w: int = int(round(_weighted * k))
	_w_num.text = str(w)
	_bar_fill.size.x = BAR_W * clampf(float(w) / float(maxi(_weighted, _goal)), 0.0, 1.0)


## 跳到演出结束的状态。演出中的任意点击/按键都会走这里。
func skip() -> void:
	if not _playing:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_playing = false
	_scrim.color = Color(0, 0, 0, SCRIM_ALPHA)
	_set_open(1.0)
	for row in _rows:
		row.modulate.a = 1.0
		row.position.y = row.get_meta("y")
	_set_count(1.0)


# ============ 输入 ============

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _playing:
		## 演出中：任何一下都只是「别演了」，不当成选择 —— 免得手快的人误触
		if (event is InputEventKey or event is InputEventMouseButton) and event.pressed:
			get_viewport().set_input_as_handled()
			skip()
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		chose.emit("menu")
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()
		_sel = 1 - _sel
		_repaint()
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_activate(_sel)


func _activate(i: int) -> void:
	if _playing:
		return
	chose.emit("menu" if i == 0 else "restart")


# ============ 建节点（只跑一次）============

func _build() -> void:
	_built = true
	_scrim = ColorRect.new()
	## 压暗**只盖 0..696**：右侧竖条此刻是终局读数，要保持能读（方向丁的立意）
	_scrim.position = Vector2.ZERO
	_scrim.size = Vector2(BANNER_W, 540)
	_scrim.color = Color(0, 0, 0, 0)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

	_clip = Control.new()
	_clip.clip_contents = true          ## 「从中线拉开」全靠它
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)

	_panel = Control.new()
	_panel.size = Vector2(BANNER_W, BANNER_H)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_panel)

	var bg := Panel.new()
	## 上下两道描边、左右不封口 —— 横幅是横着「通」出去的，不是一个方块
	var box := CWStyle.box(BORDER_A, Color(CWStyle.PANEL, 0.95))
	box.set_border_width_all(0)
	box.border_width_top = 2
	box.border_width_bottom = 2
	bg.add_theme_stylebox_override("panel", box)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bg)

	var right: float = BANNER_W - PAD_R
	var y: float = PAD_T

	# ① 宣告：阵营色条 + 40px 标题 + 结局标签
	var r1 := _row(y)
	_fac = ColorRect.new()
	_fac.position = Vector2(PAD_L, 0)
	_fac.size = Vector2(6, TITLE_H)
	_fac.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r1.add_child(_fac)
	_title = CWStyle.label("", CWStyle.SIZE_HERO, CWStyle.TEXT_HI)
	_title.position = Vector2(PAD_L + 20, -2)
	r1.add_child(_title)
	_chip = PanelContainer.new()
	## 标签跟在标题右边。**量出标题实际多宽**，别按「四个字」算 ——
	## 现在四种结局的标题恰好都是 4 个字，改一个字就会错位。
	_chip.position = Vector2(0, 14)   ## x 在 _fill() 里按标题宽度定
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip_text = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT)
	_chip.add_child(_chip_text)
	r1.add_child(_chip)
	y += TITLE_H + 10

	# ② 一句话胜因
	var r2 := _row(y)
	_reason = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT)
	_reason.position = Vector2(PAD_L, 0)
	r2.add_child(_reason)
	y += 22 + 12

	# ③ 数据：一道分隔线 + 左四个大数 + 右加权条
	var r3 := _row(y)
	var rule := ColorRect.new()
	rule.color = Color(CWStyle.LINE, 0.25)
	rule.position = Vector2(PAD_L, 0)
	rule.size = Vector2(right - PAD_L, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r3.add_child(rule)
	_build_stats(r3, PAD_L, 16)
	_build_bar(r3, right - BAR_W, 20)
	y += 1 + 16 + 70 + 14

	# ④ 底部：一行小字 + 两个按钮，钉在横幅底边上方
	var r4 := _row(BANNER_H - PAD_T - BTN_H)
	_meta = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_meta.position = Vector2(PAD_L, BTN_H - 14)   ## 和按钮底边对齐
	r4.add_child(_meta)
	_build_buttons(r4, right)

	_repaint()


## 一块内容。位置记在 meta 里 —— 上浮动画要在「原位」和「原位 + LIFT」之间来回。
func _row(y: float) -> Control:
	var c := Control.new()
	c.position = Vector2(0, y)
	c.size = Vector2(BANNER_W, 0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_meta("y", y)
	_panel.add_child(c)
	_rows.append(c)
	return c


func _build_stats(parent: Control, x: float, y: float) -> void:
	var lbl := CWStyle.label("终局盘面　%d 格" % CWData.all_coords().size(),
		CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	lbl.position = Vector2(x, y)
	parent.add_child(lbl)
	var col: float = STAT_W / 4.0
	for i in STAT_LABELS.size():
		## 健康是好事用亮色，癌与固化用癌方色，坏死是叠加项所以压暗一档
		var color: Color = CWStyle.TEXT_HI
		if i == 1 or i == 2:
			color = CWStyle.CANCER
		elif i == 3:
			color = CWStyle.TEXT_DIM
		var n := CWStyle.label("0", CWStyle.SIZE_BIG, color)
		n.position = Vector2(x + i * col, y + 20)
		parent.add_child(n)
		_stat_num.append(n)
		var t := CWStyle.label(STAT_LABELS[i], CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		t.position = Vector2(x + i * col, y + 54)
		parent.add_child(t)
		_stat_lbl.append(t)


func _build_bar(parent: Control, x: float, y: float) -> void:
	var cap := CWStyle.label("癌性加权　癌 + 2 × 固化", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	cap.position = Vector2(x, y + 8)
	parent.add_child(cap)
	_w_num = CWStyle.label("0", CWStyle.SIZE_BODY, CWStyle.CANCER)
	_w_num.position = Vector2(x, y)
	_w_num.size = Vector2(BAR_W - 36, 0)
	_w_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(_w_num)
	_w_max = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_w_max.position = Vector2(x, y + 8)
	_w_max.size = Vector2(BAR_W, 0)
	_w_max.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(_w_max)

	var track := ColorRect.new()
	track.color = Color("0a0f16")
	track.position = Vector2(x, y + 28)
	track.size = Vector2(BAR_W, BAR_H)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = CWStyle.CANCER
	_bar_fill.position = Vector2(x, y + 28)
	_bar_fill.size = Vector2(0, BAR_H)
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_bar_fill)
	## 胜利线：一根竖刻度，比条高出上下各 4px，条填过它的那一下就是结论
	var tick_root := Control.new()
	tick_root.position = Vector2(x, y + 28)
	tick_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tick_root)
	_bar_tick = ColorRect.new()
	_bar_tick.color = CWStyle.TEXT_HI
	_bar_tick.position = Vector2(0, -4)
	_bar_tick.size = Vector2(2, BAR_H + 8)
	_bar_tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tick_root.add_child(_bar_tick)
	_bar_note = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_bar_note.position = Vector2(0, 14)
	tick_root.add_child(_bar_note)


func _build_buttons(parent: Control, right: float) -> void:
	## 从右往左摆，和行动栏的「靠右排」是同一套语汇
	var specs := [
		{ "title": "返回主菜单", "cost": "Esc", "go": false },
		{ "title": "再来一局", "cost": "同样人数 · 新种子", "go": true },
	]
	var x: float = right
	for i in range(specs.size() - 1, -1, -1):
		var p := _make_button(specs[i], i)
		var w: float = _button_width(specs[i])
		x -= w
		p.position = Vector2(x, 0)
		p.size = Vector2(w, BTN_H)
		parent.add_child(p)
		x -= BTN_GAP
	_btns.reverse()
	_btn_titles.reverse()
	_btn_costs.reverse()


func _button_width(spec: Dictionary) -> float:
	var f := CWStyle.FONT
	var w: float = maxf(
		f.get_string_size(spec["title"], HORIZONTAL_ALIGNMENT_LEFT, -1,
			CWStyle.SIZE_BODY).x,
		f.get_string_size(spec["cost"], HORIZONTAL_ALIGNMENT_LEFT, -1,
			CWStyle.SIZE_LABEL).x)
	return w + 8 * 2 + 2 * 2      ## padding 8 + 描边 2（和 CWActionBar 一致）


func _make_button(spec: Dictionary, index: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var t := CWStyle.label(spec["title"], CWStyle.SIZE_BODY, CWStyle.TEXT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var c := CWStyle.label(spec["cost"], CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	c.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(c)
	p.set_meta("go", spec["go"])
	p.mouse_entered.connect(func() -> void:
		if _playing:
			return
		_sel = index
		_repaint())
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			if _playing:
				skip()
			else:
				_activate(index))
	_btns.append(p)
	_btn_titles.append(t)
	_btn_costs.append(c)
	return p


## 选中态：`.go` 那个是青底深字（和竖条的「结束回合」同一套），
## 另一个走行动栏的描边按钮；选中就把描边点亮、字提到纯白。
func _repaint() -> void:
	for i in _btns.size():
		var on: bool = i == _sel
		var go: bool = _btns[i].get_meta("go")
		var box: StyleBoxFlat
		if go:
			box = CWStyle.box(1.0, CWStyle.IMMUNE, 6, 8)
			box.border_color = Color.WHITE if on else CWStyle.IMMUNE
			_btn_titles[i].add_theme_color_override("font_color", Color("0d1620"))
			_btn_costs[i].add_theme_color_override("font_color", Color(0.05, 0.09, 0.13, 0.65))
		else:
			box = CWStyle.box(1.0 if on else 0.5, CWStyle.BTN_BG, 6, 8)
			_btn_titles[i].add_theme_color_override("font_color",
				Color.WHITE if on else CWStyle.TEXT)
			_btn_costs[i].add_theme_color_override("font_color", CWStyle.TEXT_DIM)
		_btns[i].add_theme_stylebox_override("panel", box)
