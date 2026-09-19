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
signal opened                            ## 刚展开（对局那边据此收掉同一块地上的日志面板）

## 和对局日志共用同一块地（见文件头）。改这儿要连着改 CWLogPanel.RECT
const RECT := Rect2(16, 16, 340, 460)
const ROW_H := 18.0
const MAX_ROWS := 20                     ## 框里最多显示几条（460 高装得下）
const PAD := 10.0
## 标题栏左边那行。右边贴着「全体 / 己方」那块（x = 宽 − 76），别把它写长到压上去
const TITLE := "聊天　Esc 收起　Tab 换频道"
## 输入行高：10px 点阵字的行框 14（ascent 11 / descent 3）+ 上下内边距 2×2，留 4 px 余量
const INPUT_H := 22.0

var _lines: Array = []                   ## 收到的消息，新的在后
var _open := false
## 回车唤出只在对局进行中接（结算屏上回车归它自己的按钮、本地局没人可聊）；开着时的 Esc / Tab 不受它管
var active := true
var _unread := 0
var _team := false                       ## 这一句发给谁：false 全体 / true 己方
## 「己方」标签用**本地玩家自己**的阵营色（Kevin 2026-09-17：癌症方的己方要黄）；-1 = 观众，没有己方
var team_faction := -1
var _panel: Panel
var _bar: Panel
var _rows: Array[Label] = []
var _scope: Label
var _line: LineEdit


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
	_line.text = ""
	_line.grab_focus()
	_repaint()
	opened.emit()


func close() -> void:
	_open = false
	_panel.visible = false
	_line.release_focus()
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


## 换了连接就从头来：新 client 的 chat_log 是空的，旧游标会让新消息永远搬不进来（CWMatch.start_online 调）
func clear() -> void:
	_lines.clear()
	_unread = 0
	_repaint()


## 最近几条（迷你条那边拿去显示）
func tail(n: int) -> Array:
	return _lines.slice(maxi(_lines.size() - n, 0))


func unread() -> int:
	return _unread


## 键盘全在下面 `_input` 一处（Enter 唤出 / Esc 收起 / Tab 换频道）。
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


## 键盘：**Enter 唤出、Esc 收起、Tab 换频道**（收起原是回车，Kevin 2026-09-17 改成 Esc）。
##
## 走 `_input` 而不是 `_unhandled_input`，是为了**先于暂停菜单判定**（Kevin 特意叮嘱的顺序）：
## Godot 派发 `_unhandled_input` 按场景树**逆序**，暂停菜单是 Match.tscn 里 UI 下的节点、排在 CWMatch 前头，
## 它收到 Esc 就 toggle 并标记已处理，框根本轮不到。回车同理：`ui_accept` 绑着回车，
## 右栏「结束回合」的 `_unhandled_key_input` 会先把它吃掉。`_input` 在 GUI 与所有 unhandled 之前，谁也抢不走；
## 暂停菜单开着时整棵树是暂停的，这里不会被调到，Esc 照常归菜单。
## 只在三种情形出手：关着时的回车、开着时的 Esc 与 Tab；输入框里的回车（发送）照旧归它自己。
## Tab 截在这一层还省掉了输入框上那一道 accept：焦点导航（`ui_focus_next`）也排在 `_input` 后面。
func _input(event: InputEvent) -> void:
	## 暂停菜单压在上面（联机局不冻树）：回车 / Esc / Tab 全归菜单。**这一条必须在最前面** ——
	## 本框的键盘走 `_input`，比谁都早，不让路的话 Esc 会被它先吃掉、菜单关不掉（issue #45）
	if CWPauseMenu.modal():
		return
	if not _open:
		if active and is_enter(event):
			get_viewport().set_input_as_handled()
			open()
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()
	elif is_tab(event):
		get_viewport().set_input_as_handled()
		toggle_scope()


## 点框外空白处收起（Kevin 2026-09-10 报的第二条；`CWLogPanel` 早就是这么做的）。
## **吃掉这一下**：框压着棋盘左上角，点它外面就是「我想关掉它」，不该顺手把细胞走过去。
## 点在框上的到不了这儿：面板是 MOUSE_FILTER_STOP，输入框、频道标签各自截住自己那一下
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	get_viewport().set_input_as_handled()
	close()


## 「玩家正在打字」：焦点落在文本框上。对局里的单键快捷键（`CWLogPanel` 的 L、
## `CWMatchPanel` 的空格、`CWActionBar` 的数字键、图鉴的方向键）先问这一条再动 ——
## 不然聊天打到 L 就弹出日志（Kevin 2026-09-10 报的第三条）。
## **判焦点、不判「框开没开」**：框开着但焦点被点走了，那时按 L 就该是开日志；
## 反过来输入法组字时按键多半到不了输入框的 accept，只有焦点这一条靠得住 ——
## 拼音选字的数字 / 空格正是误触的重灾区。
static func typing(viewport: Viewport) -> bool:
	if viewport == null:
		return false
	var owner := viewport.gui_get_focus_owner()
	return owner is LineEdit or owner is TextEdit


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

	## 输入行贴着面板底边留 PAD。原来写的 y = 460−30、高 22 又没配样式：Godot 默认主题把 LineEdit
	## 撑到 31 高、外加一圈粗灰的圆角聚焦描边，整条压在面板底边上（Kevin 2026-09-17 截图报的「位置有问题」）。
	## 样式同等待室那份（CWOnlinePanel._edit）：仓库自己的 2px 描边框，内边距定死，最小高度算得出来
	_line = LineEdit.new()
	_line.max_length = CWNet.CHAT_MAX
	_line.placeholder_text = "说点什么…"
	_line.context_menu_enabled = false
	_line.add_theme_font_override("font", CWStyle.FONT)
	_line.add_theme_font_size_override("font_size", CWStyle.SIZE_LABEL)
	_line.add_theme_color_override("font_color", CWStyle.TEXT_HI)
	_line.add_theme_color_override("font_placeholder_color", CWStyle.TEXT_OFF)
	_line.add_theme_color_override("caret_color", CWStyle.IMMUNE)
	## 内边距随字号折半（等待室 20px 字配 8，这里 10px 字配 6），样式族同 CWOnlinePanel._edit
	_line.add_theme_stylebox_override("normal", CWStyle.box(0.45, CWStyle.BTN_BG, 2, 6))
	_line.add_theme_stylebox_override("focus", CWStyle.box(1.0, CWStyle.BTN_BG, 2, 6))
	_line.text_submitted.connect(_submit)
	_panel.add_child(_line)
	## 尺寸要在**进树之后**定。探针实测（2026-09-17）：override 排在 size 前面也不够 —— 主题缓存要到进树那一刻才刷新，
	## 进树前 set_size 一律被默认主题的最小高度 31 撑住，之后换了样式也不会缩回去（Control 的 size 只会被最小尺寸顶大）
	_line.position = Vector2(PAD, RECT.size.y - PAD - INPUT_H)
	_line.size = Vector2(RECT.size.x - PAD * 2, INPUT_H)

## 回车：有话就发，空串什么都不做 —— 收起是 Esc 的活（Kevin 2026-09-17）。
## 09-16 曾让空串回车收起，治的是「从迷你条点开之后关不掉」；改成 Esc 之后那条靠 `_input` 里的 Esc 与点框外收起
func _submit(text: String) -> void:
	var msg := text.strip_edges()
	_line.text = ""
	if msg.is_empty():
		return
	said.emit(msg, _team)


# ============ 呈现 ============

## 阵营色：免疫青 / 癌方橙；观众自成一档，中性偏暗。消息行与「己方」标签共用这一份
static func faction_color(faction: int) -> Color:
	match faction:
		CWData.Faction.IMMUNE: return CWStyle.IMMUNE
		CWData.Faction.CANCER: return CWStyle.CANCER
	return CWStyle.TEXT_DIM


## 一条消息该用什么颜色。**全体 = 中性，己方 = 阵营色** —— 不写「[己方]」那种前缀
static func line_color(line: Dictionary) -> Color:
	if String(line.get("scope", "all")) != "team":
		return CWStyle.TEXT_HI
	return faction_color(int(line.get("faction", -1)))


## 一行长什么样。**纯函数**，好直接测
static func line_text(line: Dictionary) -> String:
	var who := String(line.get("nick", ""))
	if int(line.get("seat", -1)) < 0:
		who += "（观众）"
	return "%s：%s" % [who, String(line.get("text", ""))]


func _repaint() -> void:
	_scope.text = "己方" if _team else "全体"
	_scope.add_theme_color_override("font_color",
		faction_color(team_faction) if _team else CWStyle.TEXT_HI)
	for i in MAX_ROWS:
		var idx: int = _lines.size() - MAX_ROWS + i
		var l: Label = _rows[i]
		if idx < 0:
			l.text = ""
			continue
		l.text = line_text(_lines[idx])
		l.add_theme_color_override("font_color", line_color(_lines[idx]))

