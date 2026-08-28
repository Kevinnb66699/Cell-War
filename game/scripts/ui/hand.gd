## hand.gd —— 左下角的手牌抽屉
##
## 尺寸与手感全部照搬定稿（设计稿 `.hand.stack` 那一版，团队 2026-08-27 定）：
## 卡 72×112，默认只把顶边那 26px 露出来（`top:514`，画布 540）；
## 叠放**每张露 52、压掉 20**（像杀戮尖塔那样有一点重叠，不做弧形也不做放大——
## 放大会把点阵字缩成非整数倍，直接糊）；
## 悬停那张抬起 86px 并把左右两边各推开 20px ——
## **推开量正好等于重叠量**，推完两边就不再压着抬起的那张。补间 0.12s ease-out。
##
## **卡面是占位的**：卡池还没定义，`cw_cards.gd` 抽到的是空白卡。
## 所以每张都写「未定 / 卡池待交付」，和设计稿的占位卡一致 ——
## 故意不编一个像模像样的卡名，免得被当成已经定好的内容。
##
## 手牌里**只可能是【技能】**：PRD 写「【事件】抽取后立即结算并弃置」，事件卡不进手牌。
class_name CWHand
extends Control

const CARD := Vector2(72, 112)
const LEFT := 12.0
const REST_TOP := 514.0     ## 收起时的顶边（只露 540-514 = 26px）
const LIFT := 86.0          ## 悬停抬起；抬完正好 428..540 全部露出
const PUSH := 20.0          ## 两边推开，等于重叠量
const STAGGER := 52.0       ## 每张露出的宽度
const SPAN := 300.0         ## 可用横向空间：12 到行动栏左缘 324 之间
const TWEEN := 0.12         ## 抬起/推开的补间
const DEAL := 0.45          ## 抽到的卡飞进手牌

var _cards: Array[Control] = []
var _hovered := -1
var _tweens: Array[Tween] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 空白处的点击要漏给棋盘


## 手牌数变化时调用。多出来的卡从 from（屏幕坐标）飞进来；
## from 传 Vector2.INF 表示不演，直接就位（读档、切玩家时用）。
func sync(count: int, from: Vector2 = Vector2.INF) -> void:
	while _cards.size() > count:
		var gone: Control = _cards.pop_back()
		gone.queue_free()
	while _cards.size() < count:
		var card := _make_card(_cards.size())
		_cards.append(card)
		add_child(card)
		if from == Vector2.INF:
			card.position = _slot(_cards.size() - 1)
		else:
			_fly_in(card, from, _cards.size() - 1)
	_layout()


## 抽牌那一下的起点：卡从**发起抽卡的那个细胞**身上飞出来，
## 而不是凭空出现在手牌区 —— 让「谁抽的」这件事自己说清楚。
func deal_from(count: int, from: Vector2) -> void:
	sync(count, from)


func clear() -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()
	_hovered = -1


# ============ 排布 ============

## 第 i 张卡的静止位置。张数多了就压缩间距 ——
## 手牌上限规则还没定，所以不能假设只有 5 张（超出就会盖到行动栏上）。
func _slot(i: int) -> Vector2:
	return Vector2(LEFT + i * _stagger(), REST_TOP)


func _stagger() -> float:
	if _cards.size() <= 1:
		return STAGGER
	return minf(STAGGER, (SPAN - CARD.x) / float(_cards.size() - 1))


func _layout() -> void:
	for t in _tweens:
		if t != null and t.is_valid():
			t.kill()
	_tweens.clear()
	for i in _cards.size():
		var card: Control = _cards[i]
		var to := _slot(i)
		if _hovered >= 0:
			if i == _hovered:
				to.y -= LIFT
			else:
				to.x += -PUSH if i < _hovered else PUSH
		card.z_index = 100 if i == _hovered else i
		var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(card, "position", to, TWEEN)
		_tweens.append(tw)
		_paint(card, i == _hovered)


func _fly_in(card: Control, from: Vector2, index: int) -> void:
	card.position = from
	card.scale = Vector2(0.25, 0.25)
	card.modulate.a = 0.0
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "position", _slot(index), DEAL)
	tw.parallel().tween_property(card, "scale", Vector2.ONE, DEAL)
	tw.parallel().tween_property(card, "modulate:a", 1.0, DEAL * 0.5)


# ============ 卡面 ============

func _make_card(index: int) -> Control:
	var card := Control.new()
	card.size = CARD
	card.pivot_offset = CARD / 2.0     ## 飞进来时从中心缩放，不然会从左上角抽过去
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var bg := Panel.new()
	bg.name = "BG"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(bg)

	## 类型标在顶上、名字压在底部（设计稿 .n 用的是 margin-top:auto）
	var kind := CWStyle.label("【即时】", CWStyle.SIZE_LABEL, CWStyle.IMMUNE)
	kind.position = Vector2(6, 6)
	card.add_child(kind)
	var name_label := CWStyle.label("未定", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	name_label.position = Vector2(6, CARD.y - 44)
	card.add_child(name_label)
	var note := CWStyle.label("卡池待交付", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	note.position = Vector2(6, CARD.y - 20)
	card.add_child(note)

	card.mouse_entered.connect(func() -> void: _hover(index))
	card.mouse_exited.connect(func() -> void: _hover(-1 if _hovered == index else _hovered))
	_paint(card, false)
	return card


func _hover(i: int) -> void:
	if _hovered == i:
		return
	_hovered = i
	_layout()


## 设计稿 .card：2px 描边、**顶边 4px**；悬停时描边转亮青。
func _paint(card: Control, hot: bool) -> void:
	var box := CWStyle.box(1.0 if hot else 0.45, CWStyle.PANEL)
	box.border_width_top = 4
	if hot:
		box.border_color = CWStyle.IMMUNE
	(card.get_node("BG") as Panel).add_theme_stylebox_override("panel", box)
