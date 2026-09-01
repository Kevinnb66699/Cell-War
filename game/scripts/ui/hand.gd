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
##
## **2026-09-01 团队改成全双击**：左键双击=打出、右键双击=弃置，**单击一律不做事**。
## 为什么单击留空：打出和弃置都不可逆，而卡只有 72px 宽、还互相压叠 26~52px，
## 单击误触的代价太高。留空之后「点一下没反应」变成正常现象，靠卡底提示说清楚。
## 同一次改动里弃置也不再走确认条了——双击已是强意图，再确认一拍是重复收费。
##
## 完整卡面排版（效果文等）另议，先不做：**效果文本引擎里根本不存在**，
## `cw_card_data.gd` 只有卡名/类别/权重。团队要的「悬停查看详情」卡在这一步上。
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

## 手牌手势（由询问桥消费；没在等询问时点了也只是空响，无副作用）。
##
## **按意图命名、不按手势命名**：手势这半年已经改过两轮（单击 → 双击），
## 而「玩家想打这张 / 想弃这张」没变。旧名字 `card_double_clicked` 与
## `card_right_clicked` 并排放着还会骗人——现在两个都是双击。
signal play_requested(card_name: String)       ## 左键双击
signal discard_requested(card_name: String)    ## 右键双击
## 悬停到哪张卡上了（空串 = 移开了）。给 CWCardInfo 用——团队 2026-09-01 要的
## 「悬停查看详情」。抽屉自己不画详情框：它只有 72px 宽，装不下效果正文
signal card_hovered(card_name: String)

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
var _drag := -1        ## 正被拖着的那张（下标；-1 = 没在拖）
var _grab := Vector2.ZERO   ## 按下时光标相对卡左上角的偏移，拖动时保持不变（卡才不会跳）


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 空白处的点击要漏给棋盘


## 手牌数变化时调用。多出来的卡从 from（屏幕坐标）飞进来；
## from 传 Vector2.INF 表示不演，直接就位（读档、切玩家时用）。
func sync(count: int, from: Vector2 = Vector2.INF,
		names: PackedStringArray = PackedStringArray()) -> void:
	_names = names
	_selected = -1     ## 手牌一变（打出/弃置/抽取）选中态就过时了，由桥重设
	_drag = -1         ## 同理：张数一变下标就不作数了，正在拖的那张可能已经被 free 掉
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
	_drag = -1


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
		## 拖动中的那张由 _input 直接摆位。这里连碰都不能碰 ——
		## 本文件的铁律是「一张卡同时只能有一条补间」，给它起补间会和拖动打架：
		## 补间每帧把 position 拉向槽位，拖动每帧拉向光标，表现是卡黏在半路抖
		if i == _drag:
			continue
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
	## 改成双击后这两行更满了：10px 点阵字 × 6 字 = 60px，加左边距 6 = 66，卡宽 72。
	## **单击不做事，所以这两行必须写清是「双击」**——否则玩家只会得到一次沉默。
	## `t_hand_note_fits` 盯着别再加字。
	var note := CWStyle.label("双击打出", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	note.position = Vector2(NAME_PAD, CARD.y - 34)
	card.add_child(note)
	var note2 := CWStyle.label("右键双击弃置", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	note2.position = Vector2(NAME_PAD, CARD.y - 18)
	card.add_child(note2)
	
	card.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed:
			return
		## 只认双击（团队 2026-09-01）。单击**故意什么都不发**——
		## 以前左键单击就打出，双击的第二下要特判「别再发一次单击」；
		## 现在两条路都只在 double_click 上开口，那个特判自然没了。
		if not mb.double_click:
			## 左键按住 = 开始拖。**双击的那一下不开拖**：双击序列是
			## 按-放-按(dc)-放，第一下已经开过一次拖，第二下再开只会在原地抖一下
			## ⚠ 这里给的 `mb.position` 是**卡自己的局部坐标**（0..72, 0..112）——
			## `gui_input` 送来的事件 Godot 已经换算到该控件的局部空间了。
			## 而抓取偏移要的正是「按在卡上的哪一点」，所以直接用，**不要再套
			## make_input_local**（那是按手牌层换算的，套了会得到一个荒唐的偏移，
			## 拖起来卡直接飞到画布外面 —— 2026-09-01 队友报的「拖动中卡牌消失」就是它）
			if mb.button_index == MOUSE_BUTTON_LEFT:
				_begin_drag(index, mb.position)
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			play_requested.emit(_name_at(index))
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			discard_requested.emit(_name_at(index)))
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


# ============ 拖出打出（团队 2026-09-01）============
#
# **拖出 = 双击**，就这一句。松手点在抽屉外面就发 `play_requested`，
# 之后照常进选目标态——**落点那一格不算选中的目标**（团队定的，别自作主张接上）。
#
# 为什么判定放在「松手」而不是「越过边界那一刻」：松手才是玩家表达完意图的时刻，
# 而且这样天然就有「拖出去又拖回来 = 反悔」，不用另写取消。


## 抽屉自己占的那块矩形。松手点落在**外面**才算拖出。
## 左边到 0 而不是到 LEFT：往左拖出画布不该算打出，那多半是手滑。
## 纯函数，测试直接核对边界。
static func drawer_rect(screen: Vector2) -> Rect2:
	var top := REST_TOP - LIFT          ## 428：卡抬起后的顶边，抽屉的实际上沿
	return Rect2(0.0, top, LEFT + SPAN, screen.y - top)


## `grab_local` = 按下点在**卡自己的局部坐标**里的位置，也就是「抓的是卡上哪一点」。
## 拖动时 `position = 光标 - grab_local`，卡就不会跳到光标底下去。
func _begin_drag(index: int, grab_local: Vector2) -> void:
	if index < 0 or index >= _cards.size():
		return
	_drag = index
	_grab = grab_local
	var card: Control = _cards[index]
	card.z_index = 200                     ## 压过所有卡（_layout 给的最高是悬停的 100）
	## 悬停抬起那条补间可能还在跑。不杀掉的话它会和拖动抢 position ——
	## 补间拉向槽位、拖动拉向光标，前 0.12 秒卡会黏在半路抖（本文件铁律：一张卡一条补间）
	var running: Tween = _tweens.get(card)
	if running != null and running.is_valid():
		running.kill()
	_tweens.erase(card)


## 拖动中的卡不归 _layout() 管，所以事件得在这一层收：光标离开卡面之后，
## 卡自己的 gui_input 就再也收不到了（Control 只在指针压在自己身上时才有 gui_input）。
func _input(event: InputEvent) -> void:
	if _drag < 0:
		return
	var me := event as InputEventMouse
	if me == null:
		return
	var at: Vector2 = (make_input_local(me) as InputEventMouse).position
	if event is InputEventMouseMotion:
		_cards[_drag].position = at - _grab
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var i := _drag
	_drag = -1
	_layout()                              ## 松手先让卡飞回抽屉，无论打不打得出去
	if not drawer_rect(_screen()).has_point(at):
		play_requested.emit(_name_at(i))


## 画布尺寸。**不用 get_viewport_rect()**：无头测试里没有真视口，
## 而 CWView 那份是工程设置里的设计分辨率，两边都拿得到。
func _screen() -> Vector2:
	return CWView.screen_size()


func _hover(i: int) -> void:
	if _hovered == i:
		return
	_hovered = i
	## 详情框自己按 CWCardInfo.DELAY 延时浮出——这里只报「现在停在谁身上」。
	## 移开时报空串，不是「保持上一张」：划过一串卡不该留下一路详情框。
	card_hovered.emit(_name_at(i) if i >= 0 else "")
	_layout()


## 设计稿 .card：2px 描边、**顶边 4px**；悬停时描边转亮青。
func _paint(card: Control, hot: bool) -> void:
	var box := CWStyle.box(1.0 if hot else 0.45, CWStyle.PANEL)
	box.border_width_top = 4
	if hot:
		box.border_color = CWStyle.IMMUNE
	(card.get_node("BG") as Panel).add_theme_stylebox_override("panel", box)
