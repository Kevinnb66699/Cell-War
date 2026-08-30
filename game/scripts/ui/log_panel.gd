## log_panel.gd —— 对局日志面板：L 键开关的左侧浮层，给 game.logs 开一扇窗
##
## 设计稿见「界面小块」画布（2026-08-29）。引擎日志本就全量记在 game.logs，
## 这里只做展示：定长的 Label 池 + 一个「离底部多远」的偏移，每帧把窗口里的
## 行铺上去（同棋盘的每帧全量刷：text 没变时 Label 直接返回，代价接近零）。
##
## 盖在棋盘左半（那一侧信息密度低），不遮右栏与行动栏。滚轮翻页；
## 偏移 0 = 跟着最新行走，往上翻过就停在原地，再滚回底部才继续跟。
class_name CWLogPanel
extends Control

const RECT := Rect2(16, 16, 340, 460)
const PAD := 12
const TITLE_H := 28
const LINE_H := 19       ## 10px 字 + 行距（设计稿）
const FOOTER_H := 20
const SCROLL_STEP := 3   ## 滚轮一格翻几行

var active := false      ## 对局进行中才响应 L（同 CWPauseMenu.active 的语法）

var _lines: Array[Label] = []
var _offset := 0         ## 离底部多少行；0 = 跟随最新
var _thumb: ColorRect
var _track: ColorRect
var _visible_n := 0


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 面板要挡住底下棋盘的点击/悬停

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := CWStyle.label("对局日志", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD - 2)
	add_child(title)
	var key := CWStyle.label("L", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	key.size = Vector2(RECT.size.x - PAD * 2, 14)
	key.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	key.position = Vector2(PAD, PAD + 4)
	add_child(key)

	## 行池：能摆多少行就建多少个 Label，之后只改 text/颜色
	_visible_n = int((RECT.size.y - PAD * 2 - TITLE_H - FOOTER_H) / LINE_H)
	for i in _visible_n:
		var l := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT)
		l.position = Vector2(PAD, PAD + TITLE_H + i * LINE_H)
		l.size = Vector2(RECT.size.x - PAD * 2 - 10, LINE_H)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		add_child(l)
		_lines.append(l)

	_track = ColorRect.new()
	_track.color = Color(CWStyle.LINE, 0.15)
	_track.position = Vector2(RECT.size.x - PAD + 4, PAD + TITLE_H)
	_track.size = Vector2(4, _visible_n * LINE_H)
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_track)
	_thumb = ColorRect.new()
	_thumb.color = Color(CWStyle.LINE, 0.6)
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_thumb)

	var hint := CWStyle.label("滚轮翻页 · 新行自动跟到底 · 再按 L 收起",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.position = Vector2(PAD, RECT.size.y - PAD - 12)
	add_child(hint)


## 对局中随时可按 L 开关；面板开着时滚轮翻页（滚轮事件从 gui_input 进不来，
## 因为行 Label 都不吃鼠标，所以统一在这里收）
func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_L:
		get_viewport().set_input_as_handled()
		toggle()
		return
	if not visible or not (event is InputEventMouseButton) or not event.pressed:
		return
	if not get_rect().has_point(event.position):
		return   ## 只有指着面板滚才翻页，别把别处的滚轮吃掉
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		get_viewport().set_input_as_handled()
		_scroll(SCROLL_STEP)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		get_viewport().set_input_as_handled()
		_scroll(-SCROLL_STEP)


## 开/关面板。L 键与左上角入口提示（CWLogHint）共用这一条路，
## 开合时回到跟随最新行——上次翻到哪儿早就过时了。
func toggle() -> void:
	visible = not visible
	_offset = 0


func _scroll(delta_lines: int) -> void:
	_offset += delta_lines   ## refresh 里按当前总行数钳位（这里拿不到 game）


## 每帧由 CWMatch 调。窗口起点是纯函数（first_line），测试直接核对。
func refresh(game: CWGame) -> void:
	if not visible or game == null:
		return
	var total := game.logs.size()
	_offset = clampi(_offset, 0, maxi(total - _visible_n, 0))
	var first := first_line(total, _visible_n, _offset)
	for i in _visible_n:
		var idx := first + i
		if idx >= total or idx < 0:
			_lines[i].text = ""
			continue
		var s: String = game.logs[idx]
		_lines[i].text = s
		_lines[i].add_theme_color_override("font_color", line_color(s))
	## 滑块：高度按可见比例、位置按窗口在整卷里的位置
	var frac := 1.0 if total <= _visible_n else float(_visible_n) / total
	var h := maxf(_track.size.y * frac, 12.0)
	var span := _track.size.y - h
	var t := 0.0 if total <= _visible_n \
		else float(first) / float(total - _visible_n)
	_thumb.position = Vector2(_track.position.x, _track.position.y + span * t)
	_thumb.size = Vector2(4, h)


func hide_now() -> void:
	visible = false
	_offset = 0


## 窗口里第一行的下标：offset = 离底部多少行。纯函数，测试用。
static func first_line(total: int, lines: int, offset: int) -> int:
	return maxi(total - lines - offset, 0)


## 行着色跟着引擎日志的前缀语法走：▶ 回合头 / ★ 升级 / ☠ 死亡 / 缩进 = 细节。
## 纯函数，测试用。
static func line_color(s: String) -> Color:
	if s.begins_with("▶") or s.begins_with("==="):
		return CWStyle.TEXT_HI
	if s.begins_with("★"):
		return CWStyle.IMMUNE
	if s.begins_with("☠"):
		return CWStyle.CANCER
	if s.begins_with("　") or s.begins_with("（"):
		return CWStyle.TEXT_DIM
	return CWStyle.TEXT
