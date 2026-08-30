## config_panel.gd —— 对局配置面板：人数 / 阵营 / AI 强度，主菜单「开始对局」后弹出
##
## 设计稿见 docs 索引的「界面小块」画布（2026-08-29）。视觉语汇照抄暂停菜单与
## 退出确认那一族：压暗层 + 264 宽描边面板 + 4×22 选中竖条 + 辉光。仍不抽公共控件——
## 本面板多了「左右拨值」，和前两处的共性只剩壳子（主菜单确认页注释里约好的再评估，评过了）。
##
## 键盘模型：上下选行、左右拨值、回车在「开始对局」上才确认（在选项行上=往后拨一格）；
## Esc = 返回主菜单。鼠标：悬停选行、点箭头/值拨值、点「开始对局」确认。
## **打开时焦点就停在「开始对局」**：回车两下 = 用默认配置直接开局，老玩家零成本。
## 取值在局与局之间保留（这次玩 6 人，下次打开还是 6 人）。
class_name CWConfigPanel
extends Control

## cfg = { players: 2/4/6, faction: CWData.Faction 或 -1（观战）, smart: bool }
signal confirmed(cfg: Dictionary)

const W := 264
const PAD := 16
const TITLE_H := 42
const ROW_H := 36
const START_GAP := 10   ## 「开始对局」与选项行之间空出半行，读起来是两组东西

## 行定义：顺序即键盘上下顺序；default 是 values 的下标。
## 「观战」= faction -1 → human_players 留空，一局带演出的 AI 互搏（CWUIBridge ③）。
const ROWS := [
	{ "key": "players", "name": "对局人数", "values": [2, 4, 6],
		"texts": ["2 人", "4 人", "6 人"], "default": 1 },
	{ "key": "faction", "name": "我的阵营",
		"values": [CWData.Faction.IMMUNE, CWData.Faction.CANCER, -1],
		"texts": ["免疫方", "癌症方", "观战"], "default": 0 },
	{ "key": "smart", "name": "AI 强度", "values": [false, true],
		"texts": ["普通", "较强"], "default": 0 },
]

## 值区右贴边排布：[‹][值][›]，宽度 12/88/12、间隔 6（见设计稿标注版）
const ARROW_W := 12
const VALUE_W := 88
const ARROW_GAP := 6

var _pick: Array[int] = []
var _sel := ROWS.size()          ## 焦点行；== ROWS.size() 表示「开始对局」
var _panel: Control
var _name_labels: Array[Label] = []
var _value_labels: Array[Label] = []
var _arrow_labels: Array = []    ## [ [‹, ›], ... ]
var _bars: Array[ColorRect] = []
var _start_label: Label
var _glow: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 盖住底下菜单项的点击
	visible = false
	for row in ROWS:
		_pick.append(row["default"])
	_build()


func open() -> void:
	_sel = ROWS.size()
	visible = true
	_repaint()


## 由 CWMainMenu 的 _unhandled_input 转发（覆盖层统一走「菜单路由」，
## 两个 _unhandled_input 抢事件的顺序问题从根上不存在——同暂停菜单的取舍）。
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		visible = false
	elif event.is_action_pressed("ui_down"):
		_sel = mini(_sel + 1, ROWS.size())
		_repaint()
	elif event.is_action_pressed("ui_up"):
		_sel = maxi(_sel - 1, 0)
		_repaint()
	elif event.is_action_pressed("ui_left"):
		_cycle(_sel, -1)
	elif event.is_action_pressed("ui_right"):
		_cycle(_sel, 1)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		if _sel == ROWS.size():
			_confirm()
		else:
			_cycle(_sel, 1)   ## 在选项行上回车 = 往后拨一格（和点值一致）


func config() -> Dictionary:
	var cfg := {}
	for i in ROWS.size():
		cfg[ROWS[i]["key"]] = ROWS[i]["values"][_pick[i]]
	return cfg


## 人类坐第几号位：该阵营在行动顺序里的第一个座位（观战返回 -1）。
## 单独成 static 是给无头测试直接查座位规则用。
static func human_seat(n_players: int, faction: int) -> int:
	if faction < 0:
		return -1
	var order: Array = CWData.FACTION_ORDER[n_players]
	for i in order.size():
		if order[i] == faction:
			return i
	return -1


func _cycle(row: int, dir: int) -> void:
	if row < 0 or row >= ROWS.size():
		return
	var n: int = ROWS[row]["values"].size()
	_pick[row] = (_pick[row] + dir + n) % n
	_repaint()


func _confirm() -> void:
	visible = false
	confirmed.emit(config())


# ============ 搭建 ============

func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var h: float = PAD + TITLE_H + ROWS.size() * ROW_H + START_GAP + ROW_H + PAD
	var screen := CWView.screen_size()
	_panel = Control.new()
	_panel.position = Vector2((screen.x - W) / 2.0, (screen.y - h) / 2.0)
	_panel.size = Vector2(W, h)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bg)

	var title := CWStyle.label("对局配置", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD)
	_panel.add_child(title)

	for i in ROWS.size():
		_build_row(i)
	_build_start()

	## 键位提示：面板下方居中一行小字
	var hint := CWStyle.label("↑↓ 选行 · ←→ 拨值 · 回车 确认 · ESC 返回",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.size = Vector2(W, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(0, h + 8)
	_panel.add_child(hint)


func _row_y(i: int) -> float:
	return PAD + TITLE_H + i * ROW_H


func _build_row(i: int) -> void:
	var y := _row_y(i)
	## 整行的悬停感应区：划过即把焦点带过来（和主菜单项一致）
	var hit := Control.new()
	hit.position = Vector2(0, y)
	hit.size = Vector2(W, ROW_H)
	hit.mouse_filter = Control.MOUSE_FILTER_PASS   ## 只感应悬停，点击留给箭头/值
	hit.mouse_entered.connect(func() -> void:
		_sel = i
		_repaint())
	_panel.add_child(hit)

	var bar := ColorRect.new()
	bar.position = Vector2(PAD, y + 7)
	bar.size = Vector2(4, 22)
	bar.color = Color(CWStyle.IMMUNE, 0.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bar)
	_bars.append(bar)

	var name_label := CWStyle.label(ROWS[i]["name"], CWStyle.SIZE_BODY, CWStyle.TEXT_DIM)
	name_label.position = Vector2(PAD + 16, y + 5)
	_panel.add_child(name_label)
	_name_labels.append(name_label)

	var x0 := W - PAD - (ARROW_W + ARROW_GAP + VALUE_W + ARROW_GAP + ARROW_W)
	var left := _clicky("‹", Vector2(x0, y + 5), func() -> void: _tap(i, -1))
	var value := _clicky("", Vector2(x0 + ARROW_W + ARROW_GAP, y + 5), func() -> void: _tap(i, 1))
	value.size = Vector2(VALUE_W, 26)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var right := _clicky("›", Vector2(x0 + ARROW_W + ARROW_GAP + VALUE_W + ARROW_GAP, y + 5),
		func() -> void: _tap(i, 1))
	_value_labels.append(value)
	_arrow_labels.append([left, right])


func _build_start() -> void:
	var y := _row_y(ROWS.size()) + START_GAP
	var bar := ColorRect.new()
	bar.position = Vector2(PAD, y + 7)
	bar.size = Vector2(4, 22)
	bar.color = Color(CWStyle.IMMUNE, 0.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bar)
	_bars.append(bar)

	## 辉光整套只备一份、只随「开始对局」亮（同 CWPauseMenu / 主菜单确认页）
	_glow = Control.new()
	_glow.position = Vector2(PAD + 16, y + 5)
	_glow.size = Vector2(W - PAD * 2 - 16, 28)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_glow)
	for layer in CWPauseMenu.GLOW:
		var g := CWStyle.label("开始对局", CWStyle.SIZE_BODY, Color(1, 1, 1, 0))
		g.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		g.add_theme_constant_override("outline_size", layer[0])
		g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_glow.add_child(g)

	_start_label = _clicky("开始对局", Vector2(PAD + 16, y + 5), _confirm)
	var hit := Control.new()
	hit.position = Vector2(0, y)
	hit.size = Vector2(W, ROW_H)
	hit.mouse_filter = Control.MOUSE_FILTER_PASS
	hit.mouse_entered.connect(func() -> void:
		_sel = ROWS.size()
		_repaint())
	_panel.add_child(hit)


## 可点击的文字：命中框贴着字、手型光标、左键回调（点击必须标记已处理，
## 否则会漏到 main.gd 被「过场中点一下跳过」接走——主菜单踩过的同一个坑）
func _clicky(text: String, at: Vector2, on_click: Callable) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT)
	label.position = at
	label.size = label.get_minimum_size()
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	_panel.add_child(label)
	return label


func _tap(row: int, dir: int) -> void:
	_sel = row
	_cycle(row, dir)


# ============ 呈现 ============

func _repaint() -> void:
	for i in ROWS.size():
		var on := i == _sel
		_bars[i].color = Color(CWStyle.IMMUNE, 1.0 if on else 0.0)
		_name_labels[i].add_theme_color_override("font_color",
			Color.WHITE if on else CWStyle.TEXT_DIM)
		_value_labels[i].text = ROWS[i]["texts"][_pick[i]]
		_value_labels[i].add_theme_color_override("font_color",
			CWStyle.TEXT_HI if on else CWStyle.TEXT)
		for a in _arrow_labels[i]:
			(a as Label).add_theme_color_override("font_color",
				CWStyle.IMMUNE if on else CWStyle.TEXT_OFF)
	var start_on := _sel == ROWS.size()
	_bars[ROWS.size()].color = Color(CWStyle.IMMUNE, 1.0 if start_on else 0.0)
	_start_label.add_theme_color_override("font_color",
		Color.WHITE if start_on else CWStyle.TEXT)
	_glow.visible = start_on
