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
var _agreed := 0             ## 上一次收到的同意数，用来认出「票况变了」

signal voted(agree: bool)


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
			visible = false
			_voted = false      ## 下一次投票要能重新投
			_agreed = 0
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
	_clock.text = "%d 秒" % int(ceil(float(vote.get("left_ms", 0)) / 1000.0))
	_agreed = agreed.size()


## 拆局 / 终局时收摊
func reset() -> void:
	visible = false
	_voted = false
	_agreed = 0
