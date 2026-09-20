## chat_box.gd —— 房内聊天：Enter 唤出的可拖动对话框（Kevin 2026-09-09 定的形制）
##
## ## 为什么在左上角，和对局日志共用一块地
##
## 第一版摆在左下角、可自由拖动。**那儿摆不下**（Kevin 一眼看出来）：
## 出牌列 `CWFeed` 占 x 8..80 / y 76..348，手牌**悬停抬起时**占到 y 428，
## 行动提示条占 y 466..518 —— 左下角常驻件之间一点缝都没有。
##
## 改成 Kevin 提的**标签页**：和迷你日志共用左上角那块（`CWLogPanel.RECT`），
## 上面一条「日志 / 聊天」互斥切换。那块地本来就是信息列，不用新占屏幕。
##
## **代价是拖动没了** —— 能拖走的标签页就不是标签页了。
##
## ## 关着的时候怎么知道有人说话
##
## 标签上跟一个未读数；有新消息时左上那条 300×52 的迷你条**临时切到聊天页**
## 显示最近两条，几秒后自己切回日志页（`CWLogHint`）。
## 这就是「浮出两条」那个想法，只是实现成了标签切换 —— 零新增屏幕面积。
##
## ## 两条不做的
##
## · **不发音效** —— 这个仓库一点声音都没有；为聊天单开音频栈不值，
##   而且对局里正在掷骰、正在等自己的回合，提示音的打断成本高于它的价值。
## · **不弹窗、不抢焦点** —— 别人说话时你可能正在选迁移落点，
##   任何吃掉一次点击或按键的提示都会造成误操作。
##
## ## 阵营用颜色分，不写字
##
## 全体 = 中性色，己方 = 阵营色（免疫青 / 癌方橙，同棋盘上的阵营标识）。
## 在 300px 宽的浮出条里，多一行「[己方]」很占地方，而颜色是零成本的。
class_name CWChatBox
extends Control

signal said(text: String, team: bool)

## 和对局日志共用同一块地（见文件头）。改这儿要连着改 CWLogPanel.RECT
const RECT := Rect2(16, 16, 340, 460)
const ROW_H := 18.0
const MAX_ROWS := 20                     ## 框里最多显示几条（460 高装得下）
const PAD := 10.0
## 标题栏左边那行。右边贴着「全体 / 己方」那块（x = 宽 − 76），别把它写长到压上去
const TITLE := "聊天　Enter 收起　Tab 换频道"

var _lines: Array = []                   ## 收到的消息，新的在后
var _open := false
var _unread := 0
var _team := false                       ## 这一句发给谁：false 全体 / true 己方
var _panel: Panel
var _bar: Panel
var _rows: Array[Label] = []
var _scope: Label
var _input: LineEdit


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 本层不吃事件，只有框自己吃
	_build()
	_repaint()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	_open = true
	_unread = 0
	move_to_front()      ## 展开即置顶，同 CWLogPanel.toggle 的理由
	_panel.visible = true
	_input.text = ""
	_input.grab_focus()
	_repaint()


func close() -> void:
	_open = false
	_panel.visible = false
	_input.release_focus()
	_repaint()


func is_open() -> bool:
	return _open


## 收到一条。关着的时候记未读 —— 提醒归左上那条迷你条（CWLogHint 的聊天页）
func push(line: Dictionary) -> void:
	_lines.append(line)
	if _lines.size() > 200:
		_lines.pop_front()
	if not _open:
		_unread += 1
	_repaint()


## 最近几条（迷你条那边拿去显示）
func tail(n: int) -> Array:
	return _lines.slice(maxi(_lines.size() - n, 0))


func unread() -> int:
	return _unread


## 对局那边把按键转进来（Enter 唤出 / Esc 收起）。返回是否吃掉了这一下。
##
## **只认真正的回车键，不能用 `ui_accept`** —— Godot 里那个动作同时绑着回车**和空格**，
## 而空格是「结束回合」的快捷键（设计稿标的）。用 ui_accept 的话，
## 玩家想结束回合会弹出聊天框。
static func is_enter(event: InputEvent) -> bool:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return false
	return (event as InputEventKey).keycode in [KEY_ENTER, KEY_KP_ENTER]


## Tab = 换「这一句发给谁」（Kevin 2026-09-10）。**同样不能用动作名** ——
## `ui_focus_next` 就绑在 Tab 上，按动作判等于替焦点导航背书；这里认的是键本身。
static func is_tab(event: InputEvent) -> bool:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return false
	return (event as InputEventKey).keycode == KEY_TAB


## 全体 ⇄ 己方。标题栏点一下、按 Tab，两条路同一个出口
func toggle_scope() -> void:
	_team = not _team
	_repaint()


func handle_key(event: InputEvent) -> bool:
	if is_enter(event) and not _open:
		open()
		return true
	if _open and event.is_action_pressed("ui_cancel"):
		close()
		return true
	## 兜底：框开着但焦点不在输入框上（点了别处）时，Tab 走的是这一条。
	## 正常情况焦点在输入框上，那一下在 `_input` 自己那层就截住了（见 _build）
	if _open and is_tab(event):
		toggle_scope()
		return true
	return false


# ============ 构建 ============

func _build() -> void:
	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", CWStyle.box(0.9, Color("10202ef2")))
	_panel.position = RECT.position
	_panel.size = RECT.size
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	## 标题栏。**不可拖** —— 它是标签页的一页，拖走就不是标签页了（见文件头）
	_bar = Panel.new()
	_bar.add_theme_stylebox_override("panel", CWStyle.box(0.5, Color("16283aff")))
	_bar.size = Vector2(RECT.size.x, 22)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_bar)
	## 标题栏顺带当快捷键表：这两下都不在别处写着，不标出来就只有翻代码才知道
	var title := CWStyle.label(TITLE, CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, 4)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(title)
	## 发给谁：点一下换，或者按 Tab。**用颜色说话**，不写「[全体]」那种前缀
	_scope = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
	_scope.position = Vector2(RECT.size.x - 76, 4)
	_scope.mouse_filter = Control.MOUSE_FILTER_STOP
	_scope.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_scope.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			toggle_scope())
	_bar.add_child(_scope)

	for i in MAX_ROWS:
		var l := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
		l.position = Vector2(PAD, 28 + i * ROW_H)
		l.size = Vector2(RECT.size.x - PAD * 2, ROW_H)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_panel.add_child(l)
		_rows.append(l)

	_input = LineEdit.new()
	_input.position = Vector2(PAD, RECT.size.y - 30)
	_input.size = Vector2(RECT.size.x - PAD * 2, 22)
	_input.max_length = CWNet.CHAT_MAX
	_input.placeholder_text = "说点什么…"
	_input.add_theme_font_override("font", CWStyle.FONT)
	_input.add_theme_font_size_override("font_size", CWStyle.SIZE_LABEL)
	_input.text_submitted.connect(_submit)
	## Tab **必须在输入框自己这一层截**：框开着时焦点就在它上面，
	## 而 Godot 的焦点导航（`ui_focus_next`）排在 `_unhandled_input` 前面 ——
	## 不 accept 的话这一下会被拿去切焦点，`handle_key` 那条根本轮不到，
	## 而且输入框还会丢焦点（下一个字就打不进去了）
	_input.gui_input.connect(func(e: InputEvent) -> void:
		if is_tab(e):
			_input.accept_event()
			toggle_scope())
	_panel.add_child(_input)

func _submit(text: String) -> void:
	var msg := text.strip_edges()
	_input.text = ""
	if msg.is_empty():
		return
	said.emit(msg, _team)


# ============ 呈现 ============

## 一条消息该用什么颜色。**全体 = 中性，己方 = 阵营色** —— 不写「[己方]」那种前缀
static func line_color(line: Dictionary) -> Color:
	if String(line.get("scope", "all")) != "team":
		return CWStyle.TEXT_HI
	match int(line.get("faction", -1)):
		CWData.Faction.IMMUNE: return CWStyle.IMMUNE
		CWData.Faction.CANCER: return CWStyle.CANCER
	return CWStyle.TEXT_DIM        ## 观众自成一档：中性偏暗


## 一行长什么样。**纯函数**，好直接测
static func line_text(line: Dictionary) -> String:
	var who := String(line.get("nick", ""))
	if int(line.get("seat", -1)) < 0:
		who += "（观众）"
	return "%s：%s" % [who, String(line.get("text", ""))]


func _repaint() -> void:
	_scope.text = "己方" if _team else "全体"
	_scope.add_theme_color_override("font_color",
		CWStyle.IMMUNE if _team else CWStyle.TEXT_HI)
	for i in MAX_ROWS:
		var idx: int = _lines.size() - MAX_ROWS + i
		var l: Label = _rows[i]
		if idx < 0:
			l.text = ""
			continue
		l.text = line_text(_lines[idx])
		l.add_theme_color_override("font_color", line_color(_lines[idx]))

