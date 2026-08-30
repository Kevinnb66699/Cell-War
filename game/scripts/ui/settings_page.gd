## settings_page.gd —— 设置：主菜单打开的小面板，改一下立即生效并落盘
##
## 视觉与键盘模型照抄对局配置面板（上下选行、左右拨值、Esc 返回）。
## 两处值行面板还不抽公共控件——共性归共性，这边没有「开始」行、
## 值改动是**即时副作用**（写 CWSettings + 存盘）而不是攒着确认，骨架并不同。
class_name CWSettingsPage
extends Control

const W := 264
const PAD := 16
const TITLE_H := 42
const ROW_H := 36

var _sel := 0
var _panel: Control
var _name_labels: Array[Label] = []
var _value_labels: Array[Label] = []
var _bars: Array[ColorRect] = []


## 行定义走函数不走常量：值的现状要从 CWSettings 读
func _rows() -> Array:
	return [
		{ "name": "AI 节奏", "texts": CWSettings.AI_DELAY_NAMES,
			"get": func() -> int: return CWSettings.AI_DELAYS.find(CWSettings.ai_delay_ms),
			"set": func(i: int) -> void:
				CWSettings.ai_delay_ms = CWSettings.AI_DELAYS[i] },
		{ "name": "掷骰动画", "texts": ["演出", "跳过"],
			"get": func() -> int: return 0 if CWSettings.dice_anim else 1,
			"set": func(i: int) -> void: CWSettings.dice_anim = i == 0 },
	]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func open() -> void:
	_sel = 0
	visible = true
	_repaint()


## 由 CWMainMenu 路由（同配置面板/规则速查）
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		visible = false
	elif event.is_action_pressed("ui_down"):
		_sel = mini(_sel + 1, _rows().size() - 1)
		_repaint()
	elif event.is_action_pressed("ui_up"):
		_sel = maxi(_sel - 1, 0)
		_repaint()
	elif event.is_action_pressed("ui_left"):
		_cycle(_sel, -1)
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("ui_accept"):
		_cycle(_sel, 1)


## 拨一格：立即写 CWSettings 并落盘（设置没有「取消」，改了就是改了）
func _cycle(row: int, dir: int) -> void:
	var rows := _rows()
	if row < 0 or row >= rows.size():
		return
	var n: int = rows[row]["texts"].size()
	var cur: int = maxi(rows[row]["get"].call(), 0)
	rows[row]["set"].call((cur + dir + n) % n)
	CWSettings.save_prefs()
	_repaint()


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var rows := _rows()
	var h: float = PAD + TITLE_H + rows.size() * ROW_H + PAD
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

	var title := CWStyle.label("设置", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD)
	_panel.add_child(title)

	for i in rows.size():
		var y: float = PAD + TITLE_H + i * ROW_H
		var hit := Control.new()
		hit.position = Vector2(0, y)
		hit.size = Vector2(W, ROW_H)
		hit.mouse_filter = Control.MOUSE_FILTER_PASS
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

		var name_label := CWStyle.label(rows[i]["name"], CWStyle.SIZE_BODY, CWStyle.TEXT_DIM)
		name_label.position = Vector2(PAD + 16, y + 5)
		_panel.add_child(name_label)
		_name_labels.append(name_label)

		var value := CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT)
		value.position = Vector2(W - PAD - 100, y + 5)
		value.size = Vector2(100, 26)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.mouse_filter = Control.MOUSE_FILTER_STOP
		value.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		value.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				get_viewport().set_input_as_handled()
				_sel = i
				_cycle(i, 1))
		_panel.add_child(value)
		_value_labels.append(value)

	var hint := CWStyle.label("←→ 拨值 · 改动立即生效 · ESC 返回",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.size = Vector2(W, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(0, h + 8)
	_panel.add_child(hint)


func _repaint() -> void:
	var rows := _rows()
	for i in rows.size():
		var on := i == _sel
		_bars[i].color = Color(CWStyle.IMMUNE, 1.0 if on else 0.0)
		_name_labels[i].add_theme_color_override("font_color",
			Color.WHITE if on else CWStyle.TEXT_DIM)
		var cur: int = maxi(rows[i]["get"].call(), 0)
		_value_labels[i].text = "< %s >" % rows[i]["texts"][cur]   ## 点阵字库没有 ‹ ›
		_value_labels[i].add_theme_color_override("font_color",
			CWStyle.TEXT_HI if on else CWStyle.TEXT)
