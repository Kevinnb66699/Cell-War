## log_hint.gd —— 左上角「对局日志 L」常驻入口提示（团队 2026-08-30 定案：方案A）
##
## 钉在日志面板将来展开的那个角上（CWLogPanel.RECT.position）：按 L 或点这条提示，
## 面板就从提示所在的位置长出来、盖掉提示——「提示在哪，面板就在哪」，空间上自洽；
## 观战和亲手打都常驻可见（另一候选「右栏底部」会和「结束回合」按钮挤在一起）。
## 显隐归 CWMatch 管（开局亮、面板开着让位、拆局收起），这里只画外观、收点击。
class_name CWLogHint
extends Control

signal pressed   ## 点提示 = 按 L（CWMatch 把它接到 CWLogPanel.toggle）

const SIZE := Vector2(76, 22)
const KEY_BOX := 16      ## 「L」底框的边长

var _bg: Panel
var _text: Label


func _ready() -> void:
	position = CWLogPanel.RECT.position
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	## 必须标记已处理，否则点击会漏到 main.gd 被「过场中点一下跳过」接走（主菜单踩过的坑）
	gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			pressed.emit())
	mouse_entered.connect(func() -> void: _paint(true))
	mouse_exited.connect(func() -> void: _paint(false))

	## 底板与「L」底框都用 1px 描边：整条提示只有 22px 高，
	## 全局那套 2px 描边（CWStyle.box）在这个尺寸上太重，试过一眼假
	_bg = Panel.new()
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_text = CWStyle.label("对局日志", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_text.position = Vector2(7, 5)
	add_child(_text)

	var key := Panel.new()
	key.add_theme_stylebox_override("panel", _box(Color("16232f"), Color(CWStyle.LINE, 1.0)))
	key.position = Vector2(SIZE.x - KEY_BOX - 6, (SIZE.y - KEY_BOX) / 2.0)
	key.size = Vector2(KEY_BOX, KEY_BOX)
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(key)
	var l := CWStyle.label("L", CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	key.add_child(l)
	_paint(false)


## 可点的东西要会答话（本作的悬停语言）：描边提亮一档、灰字转常规
func _paint(hot: bool) -> void:
	_bg.add_theme_stylebox_override("panel",
		_box(CWStyle.BTN_BG, Color(CWStyle.LINE, 0.9 if hot else 0.5)))
	_text.add_theme_color_override("font_color", CWStyle.TEXT if hot else CWStyle.TEXT_DIM)


static func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(1)
	return b
