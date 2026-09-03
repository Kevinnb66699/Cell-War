## net_hud.gd —— 联机对局里多出来的两样东西：每步倒计时、断线重连的遮罩
##
## 倒计时贴在棋盘区右上角（不占行动栏、不挡通报锚点）：服务器在 ask 里给的 left_ms 换算成本机的到期时刻，
## 只显示整秒；最后 10 秒换成癌方橙提醒。到点由服务器代打，这里不做任何判定（架构约定 #11）。
## 遮罩盖住棋盘区（右侧竖条保持可读）：断线时说「重连中」，房间没了说原因；由 CWMatch 按客户端状态开合。
class_name CWNetHud
extends Control

const COUNT_RIGHT := 696 - 12      ## 棋盘区右缘往里 12
const COUNT_Y := 12
const WARN_SECS := 10

var _count: Label
var _overlay: Control
var _overlay_text: Label
var _deadline := -1                ## ms；-1 = 没在计时


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_count.visible = false
	add_child(_count)
	_overlay = Control.new()
	_overlay.position = Vector2.ZERO
	_overlay.size = Vector2(CWView.screen_size().x - CWView.PANEL_WIDTH, CWView.screen_size().y)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP     ## 断线期间别让人点棋盘
	_overlay.visible = false
	add_child(_overlay)
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(scrim)
	_overlay_text = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_overlay_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay.add_child(_overlay_text)


## left_ms < 0 = 这一问不计时
func start_countdown(left_ms: int) -> void:
	if left_ms < 0:
		stop_countdown()
		return
	_deadline = Time.get_ticks_msec() + left_ms
	_count.visible = true
	_tick()


func stop_countdown() -> void:
	_deadline = -1
	_count.visible = false


## 剩几秒（没在计时返回 -1）；给测试和面板读
func seconds_left() -> int:
	if _deadline < 0:
		return -1
	return maxi(0, int(ceil((_deadline - Time.get_ticks_msec()) / 1000.0)))


## 空串 = 收起遮罩
func set_link(text: String) -> void:
	_overlay.visible = text != ""
	_overlay_text.text = text


func _process(_delta: float) -> void:
	if _deadline >= 0:
		_tick()


func _tick() -> void:
	var s := seconds_left()
	_count.text = "剩 %d 秒" % s
	_count.add_theme_color_override("font_color", CWStyle.CANCER if s <= WARN_SECS else CWStyle.TEXT_HI)
	_count.size = _count.get_minimum_size()
	_count.position = Vector2(COUNT_RIGHT - _count.size.x, COUNT_Y)
