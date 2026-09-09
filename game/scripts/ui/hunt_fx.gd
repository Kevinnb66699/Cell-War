## 免疫猎杀：目标捕获准星。只画准星，不画 LOCK 文案或脚下水平圈。
class_name CWHuntFx
extends Node2D

const COLOR_SEARCH := Color("61d7e8")
const COLOR_CAPTURED := Color("ff6b8a")
var _t := 0.0
var _at := Vector2.ZERO
var _active := false

func play(at: Vector2) -> void:
	_at = at
	_t = 0.0
	_active = true
	visible = true
	queue_redraw()

func sync(delta: float) -> void:
	if not _active:
		return
	_t += delta
	if _t >= 1.6:
		_active = false
		visible = false
		queue_redraw()
		return
	queue_redraw()

func _draw() -> void:
	## 没在演就一笔都不画。不加这道闸的话，谁把它裸着 add_child 进去
	## （没跟着写 visible = false），棋盘原点就凭空多一圈 72px 的准星
	if not _active:
		return
	var p := clampf(_t / 1.6, 0.0, 1.0)
	var r := lerpf(72.0, 18.0, 1.0 - pow(1.0 - p, 3.0))
	var color := COLOR_CAPTURED if p >= 0.6 else COLOR_SEARCH
	for i in 12:
		var a := TAU * float(i) / 12.0
		var inner := _at + Vector2(cos(a), sin(a)) * (r - 3.0)
		var outer := _at + Vector2(cos(a), sin(a)) * (r + 3.0)
		draw_line(inner, outer, color, 2.0, false)
	for i in 4:
		var a := TAU * float(i) / 4.0
		draw_line(_at + Vector2(cos(a), sin(a)) * r * 0.55,
			_at + Vector2(cos(a), sin(a)) * (r + 8.0), color, 2.0, false)
