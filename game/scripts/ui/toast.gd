## toast.gd —— 骰子旁边那行字
##
## 团队 2026-08-27 定骰子表现时就写明了：「轮到谁交给 HUD 和**骰子旁边那行字**」。
## 所以这块先说这次掷的是什么（"攻击"/"突变"/"抗体"），骰子停稳之后再换成结算说明
## （"攻击大成功"、"突变：无事发生"…）。
##
## **文字一律由引擎给**（`CWGame.announce`）：点数怎么判读是规则，
## 表现层照着点数自己再判一遍等于把规则抄了第二份，改一处就会对不上。
##
## 样式取设计稿的 `.tip`：半透明深底 + 2px 描边。位置跟着骰子走 ——
## 骰子刻意落在棋盘格上（不是 UI 浮层），为的就是把「谁在打谁」和「结果」在空间上绑死，
## 说明文字自然也得跟过去，不能丢回屏幕角落。
class_name CWToast
extends Control

const PAD_V := 8
const PAD_H := 12
const FADE_IN := 0.10
const FADE_OUT := 0.25
const GAP := 10.0       ## 提示和骰子之间留的空
const MARGIN := 8.0     ## 贴画布边时留的余量

var _box: PanelContainer
var _label: Label
var _tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 纯提示，别挡棋盘的点击
	_box = PanelContainer.new()
	_box.add_theme_stylebox_override("panel",
		CWStyle.box(0.55, Color("0a1018f2"), PAD_V, PAD_H))
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_box.add_child(_label)
	add_child(_box)
	_box.modulate.a = 0.0


## 在 avoid（骰子在屏幕上的外框）**旁边**显示一行字，不压到它上面。
## hold <= 0 表示一直留着，等下一次 show_at() 或 hide_now() ——
## 掷骰过程中显示「攻击」用的就是这一档，骰子停稳后再换成结果并给它一个 hold。
func show_at(text: String, avoid: Rect2, hold: float) -> void:
	_label.text = text
	_box.size = _box.get_combined_minimum_size()
	_box.position = place(_box.size, avoid, CWView.screen_size())
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_box, "modulate:a", 1.0, FADE_IN)
	if hold > 0.0:
		_tween.tween_interval(hold)
		_tween.tween_property(_box, "modulate:a", 0.0, FADE_OUT)


## 提示放哪儿：横向对齐骰子中线，纵向**优先浮在骰子上方**，上面塞不下就翻到下面。
##
## 锚点必须是骰子的**外框**而不是格子中心 —— 骰子在屏幕上有一百多像素高，
## 拿格子中心当锚点，提示会直接压在骰面上（2026-08-28 团队截图报的就是这个）。
## 抽成 static 是为了能直接测：这类错只有截图才看得出来。
static func place(box: Vector2, avoid: Rect2, screen: Vector2) -> Vector2:
	var y: float = avoid.position.y - GAP - box.y
	if y < MARGIN:
		y = avoid.end.y + GAP                    ## 上面塞不下，翻到骰子下面
	return Vector2(
		clampf(avoid.get_center().x - box.x / 2.0, MARGIN, screen.x - box.x - MARGIN),
		clampf(y, MARGIN, screen.y - box.y - MARGIN))


func hide_now() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_box.modulate.a = 0.0
