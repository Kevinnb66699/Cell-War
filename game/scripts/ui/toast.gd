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
## 排队显示（全局通报那只实例用）：正在显示时后来的先排着，等这一条淡出再上下一条。
## 世界事件、复活失败这类通报常在 S / E 阶段扎堆蹦出来，直接 show_at 会互相顶掉，
## 玩家只看得见最后一条（Kevin 2026-09-06「都显示得太快」）—— 光拉长 hold 治不了顶掉。
var _queue: Array = []   ## [{ text, avoid, hold, max_w }]
var _busy := false
## 独立气泡（bubble_at）：非骰子的说明各自一只、各自淡出，互不顶掉；只在 hide_now 时一并清掉
var _bubbles: Array = []


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
## max_w > 0：超过这个宽度就按字折行（顶带右半只有三百多像素，世界事件那句会超）
func show_at(text: String, avoid: Rect2, hold: float, max_w := 0.0) -> void:
	_label.text = wrap_body(text, max_w) if max_w > 0.0 else text
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


## 排队版 show_at：空闲就立刻显示，忙着就排到后面；hold 必须 > 0（排着的东西得自己走完）。
## 一条走完（淡出结束）→ _on_done 上下一条。骰子旁那行字**不该**用它 —— 结果要贴着当下的骰子，
## 排队会让说明落在盘面之后。
func queue_at(text: String, avoid: Rect2, hold: float, max_w := 0.0) -> void:
	if _busy:
		_queue.append({ "text": text, "avoid": avoid, "hold": maxf(hold, 0.1), "max_w": max_w })
		return
	_busy = true
	show_at(text, avoid, maxf(hold, 0.1), max_w)
	_tween.finished.connect(_on_done)


func _on_done() -> void:
	_busy = false
	if _queue.is_empty():
		return
	var n: Dictionary = _queue.pop_front()
	queue_at(n["text"], n["avoid"], n["hold"], float(n.get("max_w", 0.0)))


## 独立气泡：不碰骰子旁那只 `_box`，自己一只、自己淡出、淡完自毁。非骰子的说明（事件卡效果、复活失败、
## 次数用尽……）走这里 —— 它们要停得久（CWUIBridge.TEXT_HOLD），停久了就不能让下一条顶掉（Kevin 2026-09-06）。
## 摆位同 place()，再避开还活着的气泡：重叠就往上挪一格（挪到顶了就往下）。
func bubble_at(text: String, avoid: Rect2, hold: float, max_w := 0.0) -> Control:
	var box := _make_box()
	var label: Label = box.get_child(0)
	label.text = wrap_body(text, max_w) if max_w > 0.0 else text
	## 先进树再量尺寸：不在树里的容器还没拿到主题字体，最小尺寸量出来偏小，摆位和避让都会按错的高度算
	add_child(box)
	box.size = box.get_combined_minimum_size()
	var pos := place(box.size, avoid, CWView.screen_size())
	box.position = _dodge(pos, box.size)
	_bubbles.append(box)
	var tw := create_tween()
	tw.tween_property(box, "modulate:a", 1.0, FADE_IN)
	tw.tween_interval(maxf(hold, 0.1))
	tw.tween_property(box, "modulate:a", 0.0, FADE_OUT)
	tw.finished.connect(func() -> void:
		_bubbles.erase(box)
		if is_instance_valid(box):
			box.queue_free())
	return box


## 和活着的气泡重叠就往上挪（气泡高 + 4），挪到画布上沿就改往下挪
func _dodge(pos: Vector2, size_: Vector2) -> Vector2:
	var rect := Rect2(pos, size_)
	var up := true
	for _k in 8:
		var hit := false
		for b in _bubbles:
			if is_instance_valid(b) and Rect2(b.position, b.size).intersects(rect):
				hit = true
				break
		if not hit:
			break
		if up and rect.position.y - size_.y - 4.0 < MARGIN:
			up = false
		rect.position.y += (-(size_.y + 4.0)) if up else (size_.y + 4.0)
	return rect.position


## 按字把一句 20px 正文折进 max_w（含内边距）：中文没有空格可断，逐字累加；标点不落行首（同 CWCardInfo）
static func wrap_body(text: String, max_w: float) -> String:
	var limit := max_w - PAD_H * 2.0
	var out := PackedStringArray()
	for para in text.split("\n"):
		var line := ""
		for ch in para:
			var tryout := line + ch
			if line != "" and CWStyle.FONT.get_string_size(tryout, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_BODY).x > limit:
				if CWCardInfo.NO_LINE_START.contains(ch) and line.length() > 1:
					out.append(line.substr(0, line.length() - 1))
					line = line[line.length() - 1] + ch
				else:
					out.append(line)
					line = ch
			else:
				line = tryout
		out.append(line)
	return "\n".join(out)


func _make_box() -> PanelContainer:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel",
		CWStyle.box(0.55, Color("0a1018f2"), PAD_V, PAD_H))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI))
	box.modulate.a = 0.0
	return box


## 只收骰子旁那只 `_box`（掷骰时的「攻击」标签），气泡与队列不动 —— 骰子停稳、结果另起气泡时用
func hide_box() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_box.modulate.a = 0.0


func hide_now() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_queue.clear()
	_busy = false
	_box.modulate.a = 0.0
	for b in _bubbles:
		if is_instance_valid(b):
			b.queue_free()
	_bubbles.clear()
