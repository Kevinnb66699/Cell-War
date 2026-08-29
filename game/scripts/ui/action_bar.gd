## action_bar.gd —— 底部行动栏：技能按钮 / 目标选择提示
##
## 两种形态，都照搬定稿设计稿：
##
## ① **技能栏**（`show(...)` 不带标题）：靠右排到 x=685，与棋盘右缘对齐，
##    上边 y=476。最挤的情况是 T细胞的四个技能，实测跨度 344px，放得下。
## ② **目标选择态**（带标题）：整条横过来，左边一行提示（20px 标题 + 10px 副标题），
##    右边靠右放按钮（通常是「取消」）。
##
## 只有一个出口信号 `chosen(下标)`。取消不另设信号 —— 取消就是其中某个按钮，
## 右键和 Esc 只是它的快捷方式。这样调用方一个 await 就能收全部结果。
class_name CWActionBar
extends Control

signal chosen(index: int)

## 技能栏：设计稿 .actions{left:324;top:476;width:361}，内部靠右
const BAR_RECT := Rect2(324, 476, 361, 52)
## 目标选择态：设计稿 .actions{left:12;top:466;width:673}
const PROMPT_RECT := Rect2(12, 466, 673, 52)
const GAP := 8
## 设计稿 .btn{padding:6px 8px}；高度统一 52 = 2+6+22+2+12+6+2，
## 免得少一行费用的按钮矮一截、整条参差不齐。
const PAD_V := 6
const PAD_H := 8
const BTN_H := 52
## 快捷键数字标在**费用行前面**。实测四个技能（T细胞，最挤的情况）共 331 / 361，
## 只有「迁移」会因为加前缀而变宽（它的标题最短、费用最长），加完 349，仍然放得下。
## 标在标题上不行：那样每个按钮都变宽，四个加起来就出界了。

var _row: HBoxContainer
var _hot := -1        ## 鼠标停在第几个按钮上
var _cancel := -1     ## 哪个按钮是「取消」；-1 = 这一问没有取消
var _disabled := {}   ## 灰掉的按钮节点集合。数字键和 _paint 都要查它
var _keys := false    ## 数字键此刻是否生效（只在技能栏形态）


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 空白处的点击要漏给棋盘
	clear()


## 装按钮的那一行懒建。
## 不放在 _ready 里，是因为程序化创建本控件时 _ready 要等到下一帧才跑
## （SceneTree 脚本里尤其明显），而调用方往往当帧就调 show_bar —— 那时 _row 还是 null。
func _row_node() -> HBoxContainer:
	if _row == null:
		_row = HBoxContainer.new()
		_row.add_theme_constant_override("separation", GAP)
		add_child(_row)
	return _row


## entries = [{ title, cost }]。title 为空表示技能栏形态，否则是目标选择态。
## hint 是标题下面那行 10px 小字，只在目标选择态显示。
## cancel_index 指出哪个按钮是「取消」，右键与 Esc 是它的快捷方式。
## **不传就表示这一问不能取消**，那时右键和 Esc 一律不响应 ——
## 上一版是「一律点最后一个按钮」，于是在「选择分化方向」那种提问里，
## Esc 会直接替玩家选中最后一个种类。
func show_bar(title: String, hint: String, entries: Array, cancel_index := -1,
		inset := 0.0) -> void:
	visible = true
	_cancel = cancel_index
	## 数字键只在技能栏形态生效 —— 目标选择态里唯一的按钮是「结束迁移」，
	## 在那儿按数字键退出太容易误触，Esc / 右键已经够用。
	## 必须在建按钮**之前**定下来：按钮要按它决定费用行前面标不标数字。
	_keys = title == "" and entries.size() > 0
	_row_node()
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	_hot = -1
	if title == "":
		_row.position = BAR_RECT.position
		_row.size = BAR_RECT.size
		_row.alignment = BoxContainer.ALIGNMENT_END
	else:
		_row.position = PROMPT_RECT.position
		_row.size = PROMPT_RECT.size
		_row.alignment = BoxContainer.ALIGNMENT_BEGIN
		if inset > 0.0:
			## 手牌那几问要把标题右移：选中/悬停的卡会抬进这条里，
			## 不让位的话卡面会压住标题（2026-08-29 试玩第一轮报的）
			var pad := Control.new()
			pad.custom_minimum_size.x = inset
			pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_row.add_child(pad)
		_row.add_child(_make_prompt(title, hint))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(spacer)
	_disabled.clear()
	for i in entries.size():
		var btn := _make_button(entries[i], i)
		if entries[i].get("disabled", false):
			_disabled[btn] = true
		_row.add_child(btn)
	## 必须在全部按钮建好、_disabled 填满之后再刷一遍底色。
	## **不能用 _set_hot(-1)** —— _hot 此刻就是 -1，那个函数开头就 return 了，
	## 于是灰按钮永远画不出灰（2026-08-28 团队试玩时报的：点不动但看着是亮的）。
	_repaint_all()


func clear() -> void:
	visible = false
	_disabled.clear()
	_keys = false
	for c in _row_node().get_children():
		_row.remove_child(c)
		c.queue_free()


## 这一问能不能取消。暂停菜单靠它判断 Esc 该给谁：
## 目标选择态里 Esc 是「取消选目标」，其余时候才是「打开暂停菜单」。
func can_cancel() -> bool:
	return visible and _cancel >= 0


## 右键和 Esc 都等于点「取消」那个按钮。
## 写在这里而不是棋盘里：能不能取消是**行动栏的状态**，棋盘不该知道这件事。
func _unhandled_input(event: InputEvent) -> void:
	if not can_cancel():
		return
	var by_key: bool = event.is_action_pressed("ui_cancel")
	var by_rmb: bool = event is InputEventMouseButton and event.pressed 		and event.button_index == MOUSE_BUTTON_RIGHT
	if not (by_key or by_rmb):
		return
	get_viewport().set_input_as_handled()
	chosen.emit(_cancel)


func _make_prompt(title: String, hint: String) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(CWStyle.label(title, CWStyle.SIZE_BODY, CWStyle.TEXT_HI))
	if hint != "":
		v.add_child(CWStyle.label(hint, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM))
	return v


## 一个按钮：2px 描边 + 上下两行（名字 20px / 费用 10px），内边距 6×8。
## 尺寸由内容撑出来，和设计稿的 .btn 一致。
func _make_button(entry: Dictionary, index: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.custom_minimum_size.y = BTN_H
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	v.add_child(CWStyle.label(entry["title"], CWStyle.SIZE_BODY, CWStyle.TEXT))
	## 费用行 = [快捷键数字（垫灰底）] + [费用文字]。
	## 数字垫底是为了和费用文字拉开对比（团队 2026-08-27 要求）；
	## 同时去掉了原来那个「·」分隔符 —— 它是个全角字符、比垫块的内边距还宽，
	## 省下来正好抵掉垫块，整条宽度不涨（可用余量只有几个像素，见 t_action_bar_width）。
	var cost: String = entry.get("cost", "")
	if _keys or cost != "":
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _keys:
			line.add_child(_key_badge(index + 1))
		if cost != "":
			line.add_child(CWStyle.label(cost, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM))
		v.add_child(line)
	## 灰掉的按钮：不接鼠标、不高亮、不响应点击。**位置照占** ——
	## 这正是「按钮不消失只变暗」的意义：宽度和数字快捷键的编号都不再变
	if not entry.get("disabled", false):
		p.mouse_entered.connect(func() -> void: _set_hot(index))
		p.mouse_exited.connect(func() -> void: _set_hot(-1 if _hot == index else _hot))
		p.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				chosen.emit(index))
	else:
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.mouse_default_cursor_shape = Control.CURSOR_ARROW
	_paint(p, false)
	return p


## 快捷键数字那一小块：灰底 + 比费用文字亮一档的字。
func _key_badge(n: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_theme_stylebox_override("panel",
		CWStyle.plate(Color(CWStyle.TEXT_DIM, 0.25), 1, 3))
	p.add_child(CWStyle.label(str(n), CWStyle.SIZE_LABEL, CWStyle.TEXT))
	return p


## 按钮下标 → 它在 _row 里的第几个孩子（目标选择态前面多了提示和弹簧两个孩子）
func _button_index(child: int) -> int:
	var n := 0
	for i in child:
		if _row.get_child(i) is PanelContainer:
			n += 1
	return n


## 按当前的 _hot 和 _disabled 把所有按钮重画一遍。
func _repaint_all() -> void:
	var n := 0
	for c in _row_node().get_children():
		if c is PanelContainer:
			_paint(c, n == _hot)
			n += 1


func _set_hot(index: int) -> void:
	if _hot == index:
		return
	_hot = index
	_repaint_all()


## 三种态：灰掉 / 常态 / 悬停。灰掉的按钮描边和文字都压暗一档，
## 但**底色保持不变** —— 底色一变就会读成「另一种按钮」，而不是「同一个按钮不可用」。
func _paint(p: PanelContainer, hot: bool) -> void:
	var off: bool = _disabled.has(p)
	p.add_theme_stylebox_override("panel",
		CWStyle.box(0.22 if off else (1.0 if hot else 0.5), CWStyle.BTN_BG, PAD_V, PAD_H))
	var labels := p.get_child(0).get_children()
	var title_color: Color = CWStyle.TEXT_OFF if off \
		else (CWStyle.TEXT_HI if hot else CWStyle.TEXT)
	(labels[0] as Label).add_theme_color_override("font_color", title_color)
	## 费用那一行（数字角标 + 费用文字）也一起压暗
	if labels.size() > 1:
		for c in (labels[1] as Control).get_children():
			if c is Label:
				(c as Label).add_theme_color_override("font_color",
					CWStyle.TEXT_OFF_DIM if off else CWStyle.TEXT_DIM)


## 数字键 1..9 = 从左到右的第几个按钮。
## 加这个是因为「迁移」改成切换式之后，键鼠切换的成本比点按钮还高（团队反馈）。
func _unhandled_key_input(event: InputEvent) -> void:
	if not _keys or not visible:
		return
	if not (event is InputEventKey) or not event.pressed or event.is_echo():
		return
	var code: int = (event as InputEventKey).keycode
	if code < KEY_1 or code > KEY_9:
		return
	var index: int = code - KEY_1
	if index >= _count() or _is_disabled(index):
		return
	get_viewport().set_input_as_handled()
	chosen.emit(index)


func _is_disabled(index: int) -> bool:
	var n := 0
	for c in _row_node().get_children():
		if c is PanelContainer:
			if n == index:
				return _disabled.has(c)
			n += 1
	return false


func _count() -> int:
	var n := 0
	for c in _row_node().get_children():
		if c is PanelContainer:
			n += 1
	return n
