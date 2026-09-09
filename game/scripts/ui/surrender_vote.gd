class_name CWSurrenderVote
extends Control
## 投降投票的票面（联机，Kevin 2026-09-09 定案：一人发起、同阵营全票通过）。
##
## **只画，不判。** 够不够票、超时、冷却全由服务器算（`CWRoom.surrender`）——
## 客户端自己判会给作弊留口子：改一个客户端就能替队友投同意。
## 本节点收到什么就画什么，玩家点了只负责把一票送上去。
##
## 摆在**顶部居中**：左上角是对局日志、右边是竖条 HUD、底下是行动栏，
## 中间偏上那条是这局唯一还空着的横向带子。**不做模态** ——
## 30 秒里对局照常进行，队友不该因为要投票而被冻住。
##
## 没投过票时露两个按钮；投过了改成「等队友」——**投出去就不能改**（服务器只收第一票），
## 所以按钮必须消失，留着会让人以为还能反悔。

const W := 320.0
const H := 74.0
const TOP := 12.0

var _title: Label
var _count: Label
var _clock: Label
var _yes: Label
var _no: Label
var _voted := false          ## 我这一票投出去没有（本地记，服务器不回执单票）
var _deadline := 0           ## 本地时钟上的截止时刻（ms）；0 = 没有在跑的投票
var _stamp := 0              ## 上一条票面报文的收到时刻，用来认出「换了一条新的」

signal voted(agree: bool)


## 票面报文里的 `left_ms` 是**服务器广播那一刻**的剩余时间，而服务器只在票况变化时才广播 ——
## 照着它画的话秒数永远不动（Kevin 2026-09-09 报「没有倒数的效果」）。
## 所以换算成本地时钟上的一个截止时刻，之后每帧自己减。
## **服务器仍然是超时的唯一裁判**：这里只负责把那个数画得像在走，
## 真到点是服务器 `_end_vote("超时")` 说了算，客户端算快算慢都不影响判定。
static func deadline_of(at_ms: int, left_ms: int) -> int:
	return at_ms + maxi(left_ms, 0)


## 还剩几秒（向上取整，且不为负）。抽成纯函数是为了无头测试能直接核对。
static func seconds_left(deadline: int, now: int) -> int:
	return int(ceil(maxf(float(deadline - now), 0.0) / 1000.0))


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 只有按钮吃鼠标，别挡住棋盘
	size = Vector2(W, H)
	visible = false
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", CWStyle.box(0.75, CWStyle.PANEL, 0, 0))
	add_child(panel)

	_title = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_title.position = Vector2(14, 8)
	add_child(_title)
	_count = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_count.position = Vector2(14, 34)
	add_child(_count)
	_clock = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.CANCER)
	_clock.position = Vector2(14, 50)
	add_child(_clock)

	_yes = CWStyle.clickable_label(self, "同意", Vector2(W - 132, 26),
		func() -> void: _cast(true))
	_no = CWStyle.clickable_label(self, "拒绝", Vector2(W - 64, 26),
		func() -> void: _cast(false))
	_no.add_theme_color_override("font_color", CWStyle.TEXT_DIM)


func _cast(agree: bool) -> void:
	if _voted:
		return
	_voted = true
	_yes.visible = false
	_no.visible = false
	_count.text = "已投出，等队友"
	voted.emit(agree)


## 每帧从 `CWNetClient.surrender_vote` 喂过来；空字典 = 没有投票，收起来。
## `my_pid` 是屏幕前这位的席位，用来判断「我要不要投」——
## 发起人自己那一票服务器已经算上了，不该再问他一遍。
func sync(vote: Dictionary, my_pid: int, viewport_w: float) -> void:
	if vote.is_empty():
		if visible:
			reset()
		return
	position = Vector2((viewport_w - W) * 0.5, TOP)
	var need: Array = vote.get("need", [])
	var agreed: Array = vote.get("agreed", [])
	## 服务器不回执单票，所以「我投过没有」这件事本地记；
	## 但**重连之后本地是空的** —— 用 agreed 里有没有我兜底，免得回来后又被问一遍
	if my_pid in agreed:
		_voted = true
	visible = true
	var mine: bool = my_pid >= 0 and my_pid in need
	_title.text = "本方发起投降" if mine else "对方在投降表决"
	if mine and not _voted:
		_count.text = "全队同意才生效"
		_yes.visible = true
		_no.visible = true
	else:
		_count.text = "已同意 %d / %d" % [agreed.size(), need.size()]
		_yes.visible = false
		_no.visible = false
	## 只在**收到新报文**时重算截止时刻。sync() 每帧都被调、而 vote 是同一份缓存，
	## 每次都重算的话截止时刻会被一直往后推，秒数照样不动。
	var at: int = int(vote.get("at_ms", 0))
	if at != _stamp:
		_stamp = at
		_deadline = deadline_of(at, int(vote.get("left_ms", 0)))
	_tick()


## 秒数每帧自己走。**不能只靠 sync()** —— 它是 CWMatch._sync_link() 调的，
## 而那个只在对局流播完的间隙才跑；掷骰、抽卡那几秒里秒数会卡住。
func _process(_delta: float) -> void:
	if visible and _deadline > 0:
		_tick()


func _tick() -> void:
	_clock.text = "%d 秒" % seconds_left(_deadline, Time.get_ticks_msec())


## 拆局 / 终局时收摊
func reset() -> void:
	visible = false
	_voted = false
	_deadline = 0
	_stamp = 0
