## replay_bar.gd —— 回放的播放控制条
##
## ## 为什么摆在行动栏那条位置
##
## 回放局**没有真人席位**（`human_players` 是空的），所以行动栏根本不出现，
## 底部中间那条 361×52 一直空着。玩家在对局里本来就习惯往那儿看「我现在能做什么」，
## 回放里「我现在能拖到哪儿」是同一类问题，放同一个地方最省认知。
##
## 条本身比行动栏宽一点（跟棋盘同宽），因为进度条要拖得动 ——
## 361px 里塞三个按钮 + 进度 + 步数 + 倍速，进度条只剩一百来像素，拖起来太糙。
##
## ## 键盘与鼠标同权
##
## 空格 / ← → / ↑ ↓ 在 `CWMatch._replay_key` 里；这条只是把同样的事做成看得见的。
## 两边都只**发信号**，真正的推进统一由 `CWMatch._replay_loop` 执行 ——
## 一帧只处理一次，连点几下不会有两个 seek 同时推同一局。
class_name CWReplayBar
extends Control

signal jumped(to: int)        ## 拖进度 / 点快进快退：想去第几步
signal paused_toggled
signal speed_cycled

## 与棋盘同宽（`CWView.board_span`），纵坐标**对齐行动栏**（324,476,361,52）——
## 回放局行动栏不出现，这条就顶它的位置，玩家的视线不用换地方
const RECT := Rect2(88, 476, 600, 52)
const PAD := 12.0
const BTN_W := 40.0
const BAR_X := 200.0          ## 进度条左缘（相对本条）
const BAR_H := 6.0
const JUMP := 10              ## 快进快退一下几步（同键盘）

var total := 0
var at := 0
var paused := false
var speed := 1.0

var _bar_bg: ColorRect
var _bar_fill: ColorRect
var _play: Label
var _count: Label
var _speed: Label
var _dragging := false


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


## 每帧由 CWMatch 喂：现在放到第几步、共几步、暂停没有、几倍速
func refresh(p_at: int, p_total: int, p_paused: bool, p_speed: float) -> void:
	at = p_at
	total = p_total
	paused = p_paused
	speed = p_speed
	_repaint()


func _build() -> void:
	var plate := Panel.new()
	plate.add_theme_stylebox_override("panel", CWStyle.box(0.42, Color(CWStyle.PANEL, 0.92)))
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(plate)

	_btn("◀◀", PAD, func() -> void: jumped.emit(at - JUMP))
	_play = _btn("▶", PAD + BTN_W + 6.0, func() -> void: paused_toggled.emit())
	_btn("▶▶", PAD + (BTN_W + 6.0) * 2.0, func() -> void: jumped.emit(at + JUMP))

	## 进度条：点哪儿跳哪儿，按住能拖
	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(CWStyle.TEXT_OFF, 0.35)
	_bar_bg.position = Vector2(BAR_X, RECT.size.y / 2.0 - BAR_H / 2.0)
	_bar_bg.size = Vector2(_bar_w(), BAR_H)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_bar_bg.gui_input.connect(_on_bar_input)
	add_child(_bar_bg)
	_bar_fill = ColorRect.new()
	_bar_fill.color = CWStyle.IMMUNE
	_bar_fill.position = _bar_bg.position
	_bar_fill.size = Vector2(0, BAR_H)
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar_fill)

	_count = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_count.position = Vector2(BAR_X + _bar_w() + 10.0, RECT.size.y / 2.0 - 8.0)
	add_child(_count)
	_speed = _btn("1x", RECT.size.x - PAD - BTN_W, func() -> void: speed_cycled.emit())


## 进度条能有多宽：整条减去左边三个按钮、右边步数与倍速
func _bar_w() -> float:
	return RECT.size.x - BAR_X - 96.0 - PAD - BTN_W


func _btn(text: String, x: float, on_click: Callable) -> Label:
	var l := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	l.position = Vector2(x, RECT.size.y / 2.0 - 10.0)
	l.size = Vector2(BTN_W, 20)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	l.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	l.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	add_child(l)
	return l


func _on_bar_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_dragging = e.pressed
		if e.pressed:
			_seek_at(e.position.x)
	elif e is InputEventMouseMotion and _dragging:
		_seek_at(e.position.x)


## 条上某个横坐标对应第几步。**纯函数拆出来**好直接测：
## 拖到最左是第 0 步、最右是最后一步，中间线性
static func step_at(x: float, bar_w: float, total: int) -> int:
	if bar_w <= 0.0 or total <= 0:
		return 0
	return clampi(int(round(x / bar_w * float(total))), 0, total)


func _seek_at(x: float) -> void:
	jumped.emit(step_at(x, _bar_w(), total))


func _repaint() -> void:
	## 暂停键写两个 `▮`（U+25AE BLACK VERTICAL RECTANGLE）。
	##
	## 第一版写 `❚`（U+275A），点阵字库**没有**这个字形，直接渲成方块；
	## 换 ASCII 的 `II` 又读成两个字母而不是图标。字库其实是有暂停符的 ——
	## `⏸`（U+23F8）也在，但它的字形只有两根**很细很短**的竖条、还偏上，
	## 摆在 `◀◀` `▶▶` 那两个实心三角中间明显轻一档（出图比过五个候选）。
	## `▮` 是实心竖块，和三角同重量，两个并排就是标准暂停图标。
	_play.text = "▶" if paused else "▮▮"
	_count.text = "%d / %d" % [at, total]
	_speed.text = ("%.2f" % speed).rstrip("0").rstrip(".") + "x"
	var p: float = 0.0 if total <= 0 else clampf(float(at) / float(total), 0.0, 1.0)
	_bar_fill.size = Vector2(_bar_w() * p, BAR_H)
