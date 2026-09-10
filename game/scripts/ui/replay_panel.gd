## replay_panel.gd —— 对局回放：主菜单同一槽位的左侧面板，一页列表
##
## 面板槽语法照配置面板与联机面板（CWConfigPanel / CWOnlinePanel）：主菜单淡出后
## 本面板在同一位置淡入，眉题 / 标题 / 行 / 按钮的坐标逐个照抄那两边，
## 所以三块面板换来换去时字不会跳。
##
## **只列本地那份**（`user://replays/`）。联机局的回放终局时由服务器推下来、
## 从服务器目录下载的也会落到同一个地方 —— 所以「本地」不等于「只有单机局」，
## 它是「这台机器手上有的」。
##
## 选中一份 → `picked`，main.gd 拿它建播放器、把镜头推进棋盘。
class_name CWReplayPanel
extends Control

signal cancelled                       ## Esc / 返回主菜单：菜单把自己淡回来
signal picked(data: Dictionary)        ## 选了一份要看的

const SLOT_X := 120.0                  ## 槽位左缘（同另外两块面板）
const BTN_Y := 438.0
const FADE_IN := 0.32
const LIST_Y0 := 296.0
const LIST_W := 400.0                  ## 一行定宽，超出加省略号（同大厅房间行）
const LIST_H := 26.0
const LIST_N := 5
const ROW_LABEL := Color("9fb6bd")

var _rows: Array[Label] = []
var _files: PackedStringArray = []
var _sel := -1
var _sub: Label
var _note: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 整层接管：底下淡掉的菜单项收不到点击
	visible = false
	_build()


func open() -> void:
	refresh()
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_IN)


## 重扫一遍磁盘。每次进来都扫 —— 刚打完一局回来就该看见它
func refresh() -> void:
	_files = CWReplay.list_files()
	_sel = 0 if not _files.is_empty() else -1
	_sub.text = "共 %d 份（最多留 %d）" % [_files.size(), CWReplay.KEEP]
	_note.text = ""
	_repaint()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_back()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
		if _sel >= 0:
			var d := 1 if event.is_action_pressed("ui_down") else -1
			_sel = clampi(_sel + d, 0, mini(_files.size(), LIST_N) - 1)
			_repaint()
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_play(_sel)


func _back() -> void:
	visible = false
	cancelled.emit()


## 选中第 i 行开看。读不出就地报错、不关面板 ——
## 回放文件会被人拷来拷去，坏一份不该把人踢回主菜单
func _play(i: int) -> void:
	if i < 0 or i >= _files.size():
		return
	var d := CWReplay.read(_files[i])
	if d.is_empty():
		_note.text = "这份回放读不出来（版本不符或文件损坏）"
		return
	visible = false
	picked.emit(d)


# ============ 构建与呈现 ============

func _build() -> void:
	## 槽位自带一份左侧暗罩（同另外两块面板：菜单的 Scrim 跟着菜单整层淡走了）
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.44, 1.0])
	grad.colors = PackedColorArray([Color(0.078431, 0.121569, 0.180392, 0.96),
		Color(0.078431, 0.121569, 0.180392, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_to = Vector2(1, 0)
	var scrim := TextureRect.new()
	scrim.texture = tex
	scrim.size = Vector2(538, 540)
	scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var fv := FontVariation.new()
	fv.base_font = CWStyle.FONT
	fv.spacing_glyph = 2
	var eyebrow := CWStyle.label("REPLAY", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	eyebrow.add_theme_font_override("font", fv)
	eyebrow.position = Vector2(SLOT_X, 127)
	add_child(eyebrow)
	var title := CWStyle.label("对局回放", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(SLOT_X, 160)
	add_child(title)
	_sub = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_sub.position = Vector2(SLOT_X, 200)
	add_child(_sub)

	var head := CWStyle.label("这台机器上的回放", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	head.position = Vector2(SLOT_X, LIST_Y0 - 16)
	add_child(head)
	for i in LIST_N:
		var row := _clicky("", Vector2(SLOT_X, LIST_Y0 + i * LIST_H), func() -> void: _play(i))
		row.mouse_entered.connect(func() -> void:
			if i < _files.size():
				_sel = i
				_repaint())
		_rows.append(row)
	_note = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.CANCER)
	_note.position = Vector2(SLOT_X, LIST_Y0 + LIST_N * LIST_H + 6)
	add_child(_note)

	_clicky("刷新", Vector2(SLOT_X, BTN_Y + 5), refresh)
	_clicky("返回主菜单", Vector2(SLOT_X + 80, BTN_Y + 5), _back)


func _repaint() -> void:
	for i in LIST_N:
		var l: Label = _rows[i]
		if i >= _files.size():
			l.text = "（还没有回放：打完一局就会存下来）" if i == 0 and _files.is_empty() else ""
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			l.add_theme_color_override("font_color", CWStyle.TEXT_OFF)
			l.size = l.get_minimum_size()
			continue
		l.text = summary_line(CWReplay.read(_files[i]))
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		l.add_theme_color_override("font_color",
			Color.WHITE if i == _sel else CWStyle.TEXT_HI)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.size = Vector2(LIST_W, l.get_minimum_size().y)


## 一行摘要。**纯函数**，好直接测：时间在最前（拿来认「哪一局」的就是它），
## 胜方在最后（读不到也不影响判断是哪一局）
static func summary_line(d: Dictionary) -> String:
	if d.is_empty():
		return "（这份读不出来）"
	var who := "未分胜负"
	match int(d.get("winner", -1)):
		CWData.Faction.IMMUNE: who = "免疫胜"
		CWData.Faction.CANCER: who = "癌症胜"
	return "%s  %d 人局  第 %d 回合  %s" % [str(d.get("at", "")),
		int(d.get("players", 0)), int(d.get("round", 0)), who]


func _clicky(text: String, at: Vector2, on_click: Callable) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	label.position = at
	label.size = label.get_minimum_size()
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	add_child(label)
	return label
