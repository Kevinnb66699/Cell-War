## cw_tutor_spot.gd —— 教程的**提亮层**：把导演发来的「看这里」画在屏幕上
## （docs/新手引导v2_实现方案.md §5.1 / §5.4，S2，2026-09-19）
##
## **没有 class_name**：方案 §1.5 只给了三个例外（常驻壳 / 两版皮 / 层表），这一层由基类
## `cw_tutor_view.gd` preload，真机截图驱动的是壳与皮，不用直接点它。
##
## 三档 `mode`（方案 §5.1）：
## ① `soft`（缺省 = PRD 通用规则 8「较慢频次、反差较低的轻微闪烁」）——
##    ★ **Kevin 2026-09-19 的口径（方案 §5.5 第 1 条）：控件保持单线原样，只用闪烁提示。**
##    所以**拿得到真节点**的目标（今天只有行动栏按钮）**一笔都不画**：只把它自己的
##    `modulate.a` 按 `CWStyle` 那三个参数慢慢推拉 —— 轮廓线宽与颜色一字不差，只差亮度。
##    不加描边、不换底色、不套第二层框，这三件是拍板里点名不许做的。
##    拿不到节点的目标（右栏的块、手牌抽屉、棋盘格）才退到「描一圈」——
##    那些地方本来就没有自己的外框，描边是唯一指得着的办法。
## ② `arrow`：目标正上方一枚像素箭头（指着但不压住目标本身）。
## ③ `fullscreen`（PRD:445 全屏引导指向）：暗幕留洞 + 箭头。
##
## **目标每帧现算**（老 `guide_spotlight.gd` 的教训原样照抄）：棋盘会缩放、按钮会出没、
## 细胞会移动，缓存下来反而容易画在旧位置上。行动栏那一排按钮更是**问的时候才建**的 ——
## `point` 排在 `player` 前面，发意图的那一帧栏里还没有【迁移】这颗。
##
## 只画不挡：`mouse_filter` 一律 IGNORE。找不到目标就什么都不画、也不报错 ——
## 教程不硬锁步，提亮只是帮新手把视线放对地方。
extends Control

## 顶面六边形的几何：横向邻格相距 36、行距 20、隔行错半格（老 `guide_spotlight.gd:218-224` 原样搬）。
## 尖顶六边形外接圆半径 36/√3 ≈ 20.78，纵向再乘压扁比 20 ÷ (36·√3/2)
const HEX_R := 36.0 / sqrt(3.0)
const HEX_SQUASH := 20.0 / (36.0 * sqrt(3.0) / 2.0)

const LINE_W := 2.0
const GROW := 4.0            ## 矩形描边往外让几像素，别压在元素自己的描边上
## 像素箭头：3px 杆 + 11px 底边的实心三角，整数倍放大（同两版方向稿的画法）
const ARROW_W := 11.0
const ARROW_H := 12.0
const ARROW_GAP := 6.0       ## 箭尖离目标上缘几像素
const TIP_PAD := Vector2(8.0, 4.0)
const TIP_GAP := 6.0         ## 小气泡离目标几像素
const DIM := Color(0.0, 0.0, 0.0, 0.34)   ## `fullscreen` 那一档的暗幕（PRD:445）

## 装配方（`match.gd::_attach_tutor`）注入的四个句柄。**这一层只读它们的矩形**，
## 一个引擎对象都不碰（护栏 `t_no_engine_in_ui` 连 `scripts/tutor/**` 一起扫）
var action_bar = null        ## `bar:<按钮标题>` / `bar`
var panel = null             ## `panel:<什么>` / `row:<pid>` / `pips:<pid>`
var board = null             ## `hex:<q,r>` / `board`
var camera: Camera2D = null  ## 棋盘坐标 → 屏幕坐标要它的位置与缩放

var _targets: Array = []     ## 原始意图（每帧照它重算几何）
var _mode := "soft"
var _tip_text := ""
var _rects: Array[Rect2] = []   ## 本帧要描的矩形（屏幕坐标）
var _hexes: Array[Vector2] = [] ## 本帧要描的格子顶面中心（屏幕坐标）
var _nodes: Array = []          ## 本帧要「只闪亮度」的真控件
var _t := 0.0
var _tip: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_tip = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_tip.add_theme_stylebox_override("normal",
		CWStyle.plate(Color(CWStyle.PANEL, 0.96), int(TIP_PAD.y), int(TIP_PAD.x)))
	_tip.visible = false
	add_child(_tip)
	visible = false


## PRD 通用规则 8 的那条亮度曲线。**纯函数**：三个参数收敛在 `CWStyle` 一处，
## 常驻壳劝重置时的慢闪与这里走的是同一条
static func pulse(t: float) -> float:
	return lerpf(CWStyle.HALO_ALPHA_LO, CWStyle.HALO_ALPHA_HI,
		0.5 + 0.5 * sin(t * TAU / CWStyle.HALO_PERIOD))


## 一格顶面六边形的 7 个顶点（首尾相接），屏幕坐标（老 `guide_spotlight.gd:218-224`）
static func hex_points(center: Vector2, zoom: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 7:
		var a := deg_to_rad(30.0 + 60.0 * (i % 6))
		pts.append(center + Vector2(cos(a), sin(a) * HEX_SQUASH) * HEX_R * zoom)
	return pts


## 左下角手牌抽屉静止时的那一条（卡抬起会更高，但「卡在哪」看这一条就够）
## —— 老 `guide_spotlight.gd:211-215` 原样搬
static func hand_rect() -> Rect2:
	var s := CWView.screen_size()
	return Rect2(CWHand.LEFT, CWHand.REST_TOP, CWHand.SPAN, s.y - CWHand.REST_TOP)


## ① 提亮。`targets` 每条形如 { "kind":"ui", "id":… } / { "kind":"hex", "at":Vector2i }
func point(targets: Array, mode := "soft", tip := "") -> void:
	_restore()
	_targets = targets.duplicate(true)
	_mode = mode
	_tip_text = tip
	_t = 0.0
	visible = true
	_resolve()
	queue_redraw()


## ② 收掉。**必须把借走的 `modulate` 还回去** —— 不还的话那颗按钮会永远停在半亮上
func clear() -> void:
	_restore()
	_targets.clear()
	_rects.clear()
	_hexes.clear()
	_tip_text = ""
	_tip.visible = false
	visible = false
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	_resolve()
	var a := pulse(_t)
	for n in _nodes:
		(n as CanvasItem).modulate.a = a
	queue_redraw()


## 把借走的亮度还回去
func _restore() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			(n as CanvasItem).modulate.a = 1.0
	_nodes.clear()


## 意图 → 这一帧的几何。**有真节点的走节点、没有的才落到矩形**（见文件头 `soft` 那一条）
func _resolve() -> void:
	_restore()
	_rects.clear()
	_hexes.clear()
	for t in _targets:
		var row: Dictionary = t
		if str(row.get("kind", "")) == "hex":
			_hexes.append(_hex_center(row.get("at", Vector2i.ZERO)))
			continue
		var id := str(row.get("id", ""))
		if id.begins_with("hex:"):
			var qr := id.substr(4).split(",")
			if qr.size() == 2:
				_hexes.append(_hex_center(Vector2i(int(qr[0]), int(qr[1]))))
			continue
		var node := _node_of(id)
		if node != null:
			_nodes.append(node)
			continue
		var r := rect_of(id)
		if r.size != Vector2.ZERO:
			_rects.append(r)
	_place_tip()


## 拿得到本体的目标。今天只有行动栏按钮一支 —— 右栏的块是画出来的、没有独立节点，
## 手牌抽屉整条闪起来太吵。**这张表长一条，`soft` 就多一个「只闪亮度」的控件**
func _node_of(id: String) -> CanvasItem:
	if id.begins_with("bar:") and action_bar != null and is_instance_valid(action_bar):
		return action_bar.button_node(id.substr(4))
	return null


## 控件 id → 屏幕矩形（方案 §5.4 那张归宿表）。找不到 / 此刻不显示 → 零矩形，提亮就不画
func rect_of(id: String) -> Rect2:
	if id == "bar":
		return action_bar.bar_rect() if action_bar != null and is_instance_valid(action_bar) else Rect2()
	if id.begins_with("bar:"):
		return action_bar.button_rect(id.substr(4)) if action_bar != null and is_instance_valid(action_bar) else Rect2()
	if id == "hand":
		return hand_rect()
	if id == "board":
		return board_rect()
	if panel != null and is_instance_valid(panel):
		if id.begins_with("panel:"):
			return panel.rect_of(id.substr(6))
		if id.begins_with("row:") or id.begins_with("pips:"):
			return panel.rect_of(id)
	## `skill:<名>` 的技能栏是第七关才出现的件（PRD:479/491）⇒ **S10/S11 接**，
	## 在那之前这一支返回零矩形（什么都不画，不报错）
	return Rect2()


## 整张棋盘的屏幕包围框：全部格子顶面中心的极值，再让出半格
## （老 `guide_spotlight.gd:164-173` 原样搬）
func board_rect() -> Rect2:
	if board == null or not is_instance_valid(board) or camera == null:
		return Rect2()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in CWData.all_coords():
		var p: Vector2 = CWView.board_to_screen(camera, board.tile_center(c))
		lo = lo.min(p)
		hi = hi.max(p)
	var half := Vector2(HEX_R * sqrt(3.0) / 2.0, HEX_R * HEX_SQUASH) * _zoom()
	return Rect2(lo - half, hi - lo + half * 2.0)


func _hex_center(at: Vector2i) -> Vector2:
	if board == null or not is_instance_valid(board) or camera == null:
		return Vector2.ZERO
	return CWView.board_to_screen(camera, board.tile_center(at))


func _zoom() -> float:
	return camera.zoom.x if camera != null and is_instance_valid(camera) else 1.0


## 挂在目标旁的一句话（PRD:447/479/491）：贴第一个目标的上缘，顶到屏幕外就翻到下缘。
## 尾巴那枚尖角、气泡的形状是**皮**的语言（方向 A 的贴身气泡，S3），这一层只出最小的一块牌
func _place_tip() -> void:
	if _tip_text == "":
		_tip.visible = false
		return
	_tip.text = _tip_text
	var box := _tip.get_minimum_size()
	_tip.size = box
	var anchor := _first_rect()
	var x := clampf(anchor.position.x + anchor.size.x / 2.0 - box.x / 2.0,
		0.0, maxf(size.x - box.x, 0.0))
	var y := anchor.position.y - box.y - TIP_GAP
	if y < 0.0:
		y = anchor.position.y + anchor.size.y + TIP_GAP
	_tip.position = Vector2(x, y).round()
	_tip.visible = true


## 「第一个目标」在哪儿：矩形优先，其次是挂了亮度的控件，最后是格子
func _first_rect() -> Rect2:
	if not _rects.is_empty():
		return _rects[0]
	for n in _nodes:
		if is_instance_valid(n) and n is Control:
			return (n as Control).get_global_rect()
	if not _hexes.is_empty():
		var c: Vector2 = _hexes[0]
		var half := Vector2(HEX_R * sqrt(3.0) / 2.0, HEX_R * HEX_SQUASH) * _zoom()
		return Rect2(c - half, half * 2.0)
	return Rect2(size / 2.0, Vector2.ZERO)


func _draw() -> void:
	if _mode == "fullscreen":
		_draw_dim()
	var col := Color(CWStyle.IMMUNE, pulse(_t))
	## `soft`：有本体的那些一笔都不画（它们自己在闪亮度）；这里描的全是没本体的
	for r in _rects:
		draw_rect(r.grow(GROW), col, false, LINE_W)
	for h in _hexes:
		draw_polyline(hex_points(h, _zoom()), col, LINE_W)
	if _mode == "arrow" or _mode == "fullscreen":
		for r in _all_rects():
			_draw_arrow(Vector2(r.position.x + r.size.x / 2.0, r.position.y - ARROW_GAP), col)
		for h in _hexes:
			_draw_arrow(h - Vector2(0.0, HEX_R * HEX_SQUASH + ARROW_GAP), col)


## 暗幕留洞（PRD:445）：目标那一块不压暗，其余四条带子压
func _draw_dim() -> void:
	var hole := _first_rect().grow(GROW)
	draw_rect(Rect2(0.0, 0.0, size.x, maxf(hole.position.y, 0.0)), DIM, true)
	draw_rect(Rect2(0.0, hole.end.y, size.x, maxf(size.y - hole.end.y, 0.0)), DIM, true)
	draw_rect(Rect2(0.0, hole.position.y, maxf(hole.position.x, 0.0), hole.size.y), DIM, true)
	draw_rect(Rect2(hole.end.x, hole.position.y, maxf(size.x - hole.end.x, 0.0), hole.size.y),
		DIM, true)


## 像素箭头：尖朝下，`tip` 是箭尖那一点
func _draw_arrow(tip: Vector2, col: Color) -> void:
	var p := tip.round()
	draw_colored_polygon(PackedVector2Array([
		p, p + Vector2(-ARROW_W / 2.0, -ARROW_W / 2.0), p + Vector2(ARROW_W / 2.0, -ARROW_W / 2.0)]),
		col)
	draw_rect(Rect2(p + Vector2(-1.5, -ARROW_H), Vector2(3.0, ARROW_H - ARROW_W / 2.0)), col, true)


## 本帧所有「有框的」目标（描的 + 只闪亮度的），箭头与暗幕都照它走
func _all_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	out.append_array(_rects)
	for n in _nodes:
		if is_instance_valid(n) and n is Control:
			out.append((n as Control).get_global_rect())
	return out
