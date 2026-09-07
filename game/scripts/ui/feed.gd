## feed.gd —— 棋盘左侧的**事件列表**（Kevin 2026-09-07：「右上角的提示太过拥挤，不要保留」）
##
## 原来世界事件、别人打牌这些「不挂在某一格上」的通报，是在棋盘顶带弹一条气泡、几秒就走。
## 扎堆时挤成一团，走了就再也找不回来。现在改成左侧一列**留得住的条目**：
## 世界回合推进、世界事件、别人抽卡 / 打牌，最近 MAX_ROWS 条常驻，**点一条展开看全文**，
## 点别处收起（同日志面板、细胞信息栏的那套「点开的东西点一下就关」）。
##
## 为什么留在左边：右上角要留给联机的倒计时与延迟，左上角那条迷你日志正好是它的「上一格」——
## 两者一列对齐（同 x、同宽），读起来是一件事：上面是流水账的尾巴，下面是值得留住的大事。
##
## 与迷你日志的分工：迷你日志是**全部**日志的尾巴（一行一行滚），这里只收**大事**且**不滚走**。
class_name CWFeed
extends Control

const RECT := Rect2(16, 76, 300, 148)   ## 迷你日志（16,16,300,52）正下方，同 x 同宽
const PAD := 7.0
const ROW_H := 18.0
const MAX_ROWS := 6                     ## 再多就压到棋盘中部去了；旧的自动挤掉，全量仍在对局日志里
const DETAIL_LINE := 15.0               ## 展开后每行正文的行高
const FADE := 0.22

var _rows: Array = []                   ## [{ box: Panel, label: Label, text: String, color: Color }]
var _open := -1                         ## 展开的是第几条；-1 = 都收着
var _detail: Control


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	## 只有条目本身收鼠标：空白处要漏给棋盘，否则左边这一片就点不动棋子了
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 记一条。kind 是行首那两三个字（「世界事件」「抽卡」…），text 是全文。
## color 给行首那几个字上色，正文一律常规色 —— 一眼扫下来先看见是哪一类。
func add_entry(kind: String, text: String, color: Color = CWStyle.TEXT_DIM) -> void:
	var box := Panel.new()
	box.add_theme_stylebox_override("panel", CWStyle.box(0.35, Color("0a1018cc")))
	box.position = Vector2(0, 0)
	box.size = Vector2(RECT.size.x, ROW_H)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var tag := CWStyle.label(kind, CWStyle.SIZE_LABEL, color)
	tag.position = Vector2(PAD, 3)
	box.add_child(tag)
	var body := CWStyle.label(text, CWStyle.SIZE_LABEL, CWStyle.TEXT)
	## **先开裁切再定尺寸**（架构约定；不裁的 Label 最小宽 = 全文宽，会把定的宽度顶开、文字冲出这一行）
	body.clip_text = true
	body.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	body.position = Vector2(PAD + CWStyle.FONT.get_string_size(kind,
		HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x + 6.0, 3)
	body.size = Vector2(RECT.size.x - body.position.x - PAD, ROW_H - 6)
	box.add_child(body)
	add_child(box)
	var row := { "box": box, "text": text, "kind": kind, "color": color }
	_rows.append(row)
	box.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		box.accept_event()
		var idx: int = _index_of(box)
		_open = -1 if _open == idx else idx
		_layout())
	while _rows.size() > MAX_ROWS:
		var gone: Dictionary = _rows.pop_front()
		(gone["box"] as Node).queue_free()
		if _open >= 0:
			_open -= 1
	_open = -1        ## 来了新的就把展开的收起来：位置全变了，展开着会跳
	_layout()
	box.modulate.a = 0.0
	create_tween().tween_property(box, "modulate:a", 1.0, FADE)


func clear_all() -> void:
	for r in _rows:
		(r["box"] as Node).queue_free()
	_rows.clear()
	_open = -1
	_drop_detail()


func _index_of(box: Control) -> int:
	for i in _rows.size():
		if _rows[i]["box"] == box:
			return i
	return -1


## 最新的一条在**最上面**：这一列贴着迷你日志往下长，眼睛从上往下扫，新的先看见
func _layout() -> void:
	_drop_detail()
	var y := 0.0
	for i in range(_rows.size() - 1, -1, -1):
		var box: Control = _rows[i]["box"]
		box.position = Vector2(0, y)
		y += ROW_H + 2.0
		if i == _open:
			y += _build_detail(y, String(_rows[i]["text"]))


## 展开的那条：正文折行摊在它下面。返回占了多高
func _build_detail(at_y: float, text: String) -> float:
	var lines := CWCardInfo.wrap_text(text, RECT.size.x - PAD * 4)
	_detail = Panel.new()
	_detail.add_theme_stylebox_override("panel", CWStyle.box(0.55, Color("0a1018f2")))
	_detail.position = Vector2(PAD, at_y)
	_detail.size = Vector2(RECT.size.x - PAD * 2, PAD + DETAIL_LINE * lines.size() + PAD)
	_detail.mouse_filter = Control.MOUSE_FILTER_STOP   ## 别让点在详情上的那一下漏到棋盘
	add_child(_detail)
	var y := PAD
	for line in lines:
		var l := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
		l.position = Vector2(PAD, y)
		_detail.add_child(l)
		y += DETAIL_LINE
	return _detail.size.y + 2.0


func _drop_detail() -> void:
	if _detail != null and is_instance_valid(_detail):
		_detail.queue_free()
	_detail = null


## 点别处收起（同日志面板、细胞信息栏的那套）。**不吃这一下**：这一列浮在棋盘上，
## 玩家点棋盘多半是要走子，把那一下也吞了反而讨嫌
func _unhandled_input(event: InputEvent) -> void:
	if _open < 0:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_open = -1
	_layout()
