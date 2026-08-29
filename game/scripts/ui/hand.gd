## hand.gd —— 左下角的手牌抽屉
##
## 尺寸与手感全部照搬定稿（设计稿 `.hand.stack` 那一版，团队 2026-08-27 定）：
## 卡 72×112，默认只把顶边那 26px 露出来（`top:514`，画布 540）；
## 叠放**每张露 52、压掉 20**（像杀戮尖塔那样有一点重叠，不做弧形也不做放大——
## 放大会把点阵字缩成非整数倍，直接糊）；
## 悬停那张抬起 86px 并把左右两边各推开 20px ——
## **推开量正好等于重叠量**，推完两边就不再压着抬起的那张。补间 0.12s ease-out。
##
## 卡名与类型是真的（卡池 2026-08-28 落地）；抬起后底部是**操作提示**——
## 方案甲（团队 2026-08-29 定）：左键点卡=打出、右键=弃置，手势信号发给询问桥。
## 完整卡面排版（效果文等）另议，先不做。
##
## **卡面方案乙**（团队 2026-08-28 定）：静止时每张只露出顶上 26px，
## 名字就写在那 26px 里，10px 点阵字，**写全名、不加省略号** ——
## 露得出多少算多少，露不出的部分由后一张卡物理盖住（团队 2026-08-28 定）。
## 省略号本身也要占一个字的位置，去掉它反而多露一个字。
##
## 为什么不是写在卡底：卡底在屏幕外。上一版把名字放在 `y+68`，静止时根本看不见，
## 五张手牌长得一模一样，不悬停分不出谁是谁。
##
## **卡必须开 clip_contents**：名字最长 9 个字 = 90px，比卡本身还宽 18px。
## 非最后一张有后一张压着，看不出来；**最后一张没有邻居**，不裁就会溢到棋盘上。
##
## 代价是手牌一多就看不全：8 张时 `_stagger()` 压到 33px，一张只露得下 3 个字，
## 而且【补体级联】和【补体调理】都会显示成「补体级」「补体调」——只差最后一个字。
## 团队知道并选择先这样试。
##
## 手牌里**只可能是【技能】**：PRD 写「【事件】抽取后立即结算并弃置」，事件卡不进手牌。
class_name CWHand
extends Control

## 方案甲的两个手势（由询问桥消费；没在等询问时点了也只是空响，无副作用）
signal card_clicked(card_name: String)         ## 左键：打出
signal card_right_clicked(card_name: String)   ## 右键：弃置

const CARD := Vector2(72, 112)
const LEFT := 12.0
const REST_TOP := 514.0     ## 收起时的顶边（只露 540-514 = 26px）
const LIFT := 86.0          ## 悬停抬起；抬完正好 428..540 全部露出
const PUSH := 20.0          ## 两边推开，等于重叠量
const STAGGER := 52.0       ## 每张露出的宽度
const SPAN := 300.0         ## 可用横向空间：12 到行动栏左缘 324 之间
const TWEEN := 0.12         ## 抬起/推开的补间
const DEAL := 0.45          ## 抽到的卡飞进手牌
const DEAL_SCALE := 0.25    ## 起飞时的缩放
const NAME_PAD := 6         ## 卡名左右内边距
const SELECT_LIFT := 34.0   ## 目标选择态里选中卡的半抬高度（低于悬停的 86，给底条留位）

var _cards: Array[Control] = []
var _hovered := -1
var _tweens := {}      ## 卡 -> 正在跑的补间。**一张卡同时只能有一条**
var _dealing := {}     ## 卡 -> true，正在飞进来（走长补间、还要补缩放和淡入）
## 每张卡的名字。卡池还没实现（cw_cards.gd 是桩），所以现在恒为空 → 显示「未定」。
## 卡系统落地后由 CWMatch 把真名传进来，这里就是现成的。
var _names: PackedStringArray = PackedStringArray()
var _selected := -1    ## 目标选择态里正在打的那张（下标；-1 = 无）


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 空白处的点击要漏给棋盘


## 手牌数变化时调用。多出来的卡从 from（屏幕坐标）飞进来；
## from 传 Vector2.INF 表示不演，直接就位（读档、切玩家时用）。
func sync(count: int, from: Vector2 = Vector2.INF,
		names: PackedStringArray = PackedStringArray()) -> void:
	_names = names
	_selected = -1     ## 手牌一变（打出/弃置/抽取）选中态就过时了，由桥重设
	while _cards.size() > count:
		var gone: Control = _cards.pop_back()
		_dealing.erase(gone)
		_tweens.erase(gone)
		gone.queue_free()
	while _cards.size() < count:
		var card := _make_card(_cards.size())
		_cards.append(card)
		add_child(card)
		if from == Vector2.INF:
			card.position = _slot(_cards.size() - 1)
			continue
		## 这里**只摆起点和起始姿态，不起补间** —— 飞到哪儿由 _layout() 统一算。
		##
		## 上一版在这儿自己起了一条 0.45s 的补间飞向 _slot()，而紧接着 _layout()
		## 又给同一张卡起了一条 0.12s 的补间：两条同时改 position，短的先到、
		## 长的接着往回演 —— 表现就是「卡先瞬间到位、再闪回去重播一遍抽取动画」
		## （团队 2026-08-27 报的）。**一张卡同时只能有一条补间**，这是本文件的铁律。
		card.position = from
		card.scale = Vector2(DEAL_SCALE, DEAL_SCALE)
		card.modulate.a = 0.0
		_dealing[card] = true
	_layout()


## 抽牌那一下的起点：卡从**发起抽卡的那个细胞**身上飞出来，
## 而不是凭空出现在手牌区 —— 让「谁抽的」这件事自己说清楚。
func deal_from(count: int, from: Vector2,
		names: PackedStringArray = PackedStringArray()) -> void:
	sync(count, from, names)


func clear() -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()
	_tweens.clear()
	_dealing.clear()
	_hovered = -1
	_selected = -1


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
	for i in _cards.size():
		var card: Control = _cards[i]
		var to := _slot(i)
		if _hovered >= 0:
			if i == _hovered:
				to.y -= LIFT
			else:
				to.x += -PUSH if i < _hovered else PUSH
		if i == _selected and i != _hovered:
			to.y -= SELECT_LIFT    ## 正在打的卡半抬着，提醒「选目标呢」
		card.z_index = 100 if i == _hovered else (60 if i == _selected else i)
		var running: Tween = _tweens.get(card)
		if running != null and running.is_valid():
			running.kill()          ## 一张卡只留一条补间
		var dealing: bool = _dealing.has(card)
		var tw := card.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(card, "position", to, DEAL if dealing else TWEEN)
		if dealing:
			tw.parallel().tween_property(card, "scale", Vector2.ONE, DEAL)
			tw.parallel().tween_property(card, "modulate:a", 1.0, DEAL * 0.5)
			tw.tween_callback(func() -> void: _dealing.erase(card))
		_tweens[card] = tw
		## 名字写全，不做截断 —— 露不出的部分由后一张卡盖住 / 被 clip_contents 裁掉
		var cname: String = _names[i] if i < _names.size() else ""
		(card.get_node("Name") as Label).text = cname if cname != "" else "未定"
		if CWCardData.CARDS.has(cname):
			(card.get_node("Kind") as Label).text = "【%s】" % \
				CWCardData.KIND_NAMES[CWCardData.CARDS[cname]["kind"]]
		## 目标选择态里，没被选中的卡压暗一档（不动正在飞入的卡——它的透明度归补间管）
		if not _dealing.has(card):
			card.modulate.a = 1.0 if _selected < 0 or i == _selected else 0.55
		_paint(card, i == _hovered or i == _selected)


## 第 i 张卡静止时**实际露出多宽**：被后一张压住的只剩 _stagger()，最后一张露整卡宽。
## 界面里不用它（名字写全就完了），留着是给测试核对「到底能看见几个字」。
func exposed_width(i: int) -> float:
	return CARD.x if i >= _cards.size() - 1 else _stagger()


# ============ 卡面 ============

func _make_card(index: int) -> Control:
	var card := Control.new()
	card.size = CARD
	## 名字写全不截断，靠这一条把溢出部分裁掉（理由见文件头）
	card.clip_contents = true
	card.pivot_offset = CARD / 2.0     ## 飞进来时从中心缩放，不然会从左上角抽过去
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var bg := Panel.new()
	bg.name = "BG"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(bg)

	## 类型标在顶上、名字压在底部（设计稿 .n 用的是 margin-top:auto）
	## 名字写在顶部那 26px 里 —— 静止时唯一看得见的地方。文本由 _layout() 按露出宽度截断。
	var name_label := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
	name_label.name = "Name"
	name_label.position = Vector2(NAME_PAD, 7)
	card.add_child(name_label)
	## 下面这两行只有抬起来才看得见，属于「详情」的一部分
	var kind := CWStyle.label("【即时】", CWStyle.SIZE_LABEL, CWStyle.IMMUNE)
	kind.name = "Kind"
	kind.position = Vector2(NAME_PAD, CARD.y - 52)
	card.add_child(kind)
	## 操作提示拆两行：卡只有 72px 宽，写一行会被 clip_contents 裁掉后半句
	## （2026-08-29 试玩第一轮报的：「右键弃置」看不见）
	var note := CWStyle.label("左键打出", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	note.position = Vector2(NAME_PAD, CARD.y - 34)
	card.add_child(note)
	var note2 := CWStyle.label("右键弃置", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	note2.position = Vector2(NAME_PAD, CARD.y - 18)
	card.add_child(note2)
	
	card.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			card_clicked.emit(_name_at(index))
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			card_right_clicked.emit(_name_at(index)))
	card.mouse_entered.connect(func() -> void: _hover(index))
	card.mouse_exited.connect(func() -> void: _hover(-1 if _hovered == index else _hovered))
	_paint(card, false)
	return card


func _name_at(i: int) -> String:
	return _names[i] if i < _names.size() else ""


## 目标选择态：把名为 card_name 的那张半抬并高亮，其余压暗（"" = 清除）。询问桥调用。
func set_selected(card_name: String) -> void:
	var idx := -1
	if card_name != "":
		for i in _names.size():
			if _names[i] == card_name:
				idx = i
				break
	if _selected == idx:
		return
	_selected = idx
	_layout()


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
