## T【效应应答-Excalibur】的光束。照 tools/art-preview 的 **B 版「双螺旋束」**（团队已选）。
##
## 三拍：
##   0 ~ CHARGE          蓄力：光点朝发动者收拢
##   CHARGE ~ +REACH     光束推出去，两道螺旋沿主线反向交织，中间留一条直光芯
##   ~ TOTAL             侧向波及的格子上各炸一小团，然后收
##
## **方向由引擎给**（`CWGame.beam_fx` → `show_beam`）。选稿里光束只往右打，
## 对局里六个方向都合法，所以这儿按 from→to 的轴向重算：
## `axis` 是主线方向，`perp` 是它的法线，螺旋在法线上正负各摆一道。
## 侧向波及也是引擎掷骰的结果（60%），表现层不许自己再掷一次。
class_name CWBeamFx
extends Node2D

const CHARGE := 0.65         ## 蓄力多久
const REACH := 0.55          ## 光束推到底要多久
const TOTAL := 2.2           ## 整只演出的长度
const START := 16.0          ## 光束从发动者身上偏出多少才起头（别糊在细胞脸上）
const SWELL := 7.0           ## 螺旋最粗处的振幅
const TWIST := 0.1           ## 螺旋的空间频率
const SPIN := 9.0            ## 螺旋的转速
const CHARGE_DOTS := 16
const SPLASH_AT := 1.0       ## 侧向波及从什么时候开始炸
const SPLASH_FOR := 1.2      ## 炸多久
const INK_A := Color("e3c071")     ## 一道螺旋：金
const INK_B := Color("fff3c5")     ## 另一道：暖白
const INK_CORE := Color("faf3d4")  ## 中间那条光芯
const INK_CHARGE := Color("f8dfaa")
const INK_SPLASH := Color("dabb80")

var _t := 0.0
var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _splash: Array[Vector2] = []
var _active := false


func play(from: Vector2, to: Vector2, splash: Array[Vector2]) -> void:
	_from = from
	_to = to
	_splash = splash.duplicate()
	_t = 0.0
	_active = true
	visible = true
	queue_redraw()


func sync(delta: float) -> void:
	if not _active:
		return
	_t += delta
	if _t >= TOTAL:
		_active = false
		visible = false
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	if _t < CHARGE:
		## 蓄力：光点从外朝发动者收，越收越紧 —— 「攒在剑上」
		_burst(_from, 1.0 - _t / CHARGE, INK_CHARGE, CHARGE_DOTS, 30.0)
		return
	var full: float = _from.distance_to(_to)
	if full <= START:
		return
	var axis := (_to - _from) / full
	var perp := Vector2(-axis.y, axis.x)
	var reach := clampf((_t - CHARGE) / REACH, 0.0, 1.0)
	var tip: float = lerpf(START, full, reach)
	## 两道螺旋：同一条包络（中间最粗、两头收尖）上，一道取正一道取负
	var s := START
	while s < tip:
		var env: float = sin((s - START) / maxf(full - START, 1.0) * PI) * SWELL
		var off: float = sin(s * TWIST - _t * SPIN) * env
		var base := _from + axis * s
		draw_rect(Rect2((base + perp * off).round(), Vector2(2, 2)), INK_A, true)
		draw_rect(Rect2((base - perp * off).round(), Vector2(2, 2)), INK_B, true)
		s += 1.0
	draw_line(_from + axis * START, _from + axis * tip, INK_CORE, 1.0, false)

	## 侧向波及：哪几格被扫到是**引擎掷的**，这儿只负责炸
	if _t > SPLASH_AT and _t < SPLASH_AT + SPLASH_FOR:
		var p := (_t - SPLASH_AT) / SPLASH_FOR
		for at in _splash:
			_burst(at, p, INK_SPLASH, 8, 13.0)


## 黄金角散布的一小团。p = 0 在原点、p = 1 铺到 radius；y 只推 0.7（贴地的透视）
func _burst(at: Vector2, p: float, ink: Color, count: int, radius: float) -> void:
	for i in count:
		var a := float(i) * 2.399
		var d := p * (radius + float(i % 5) * 2.0)
		var q := at + Vector2(cos(a) * d, sin(a) * d * 0.7)
		var w := 1.0 + float(i % 2)
		draw_rect(Rect2(q.round(), Vector2(w, w)), ink, true)
