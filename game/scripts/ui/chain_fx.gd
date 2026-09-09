## 巨噬【效应应答-连续吞噬】的每一口。照 tools/art-preview 的 **A 版「暴食冲刺」**（团队已选）。
##
## 一口 = 落点上炸开的组织碎屑 + 从细胞身上升起的强化粒子。
## **连得越多粒子越密**（选稿的「每吞一次，胞体与强化粒子都更有力量」）——
## 层数不在这儿数，现读引擎的 `chain_left`（见 `CWUIBridge.show_result`）。
##
## **选稿里那张吃豆人式的大嘴没有搬进来**：那要在连锁期间把巨噬的贴图整个换掉
## （`_sync_cells` 那条路），不是往棋盘上叠一层能做到的。留作后续。
class_name CWChainFx
extends Node2D

const TOTAL := 0.7           ## 一口演多久（连下一口会重新起）
const CRUMBS := 14           ## 碎屑数
const CRUMB_R := 22.0        ## 碎屑铺多远
const RISE := 37.0           ## 强化粒子往上飘多高
const ORBIT := 15.0          ## 粒子绕着细胞的半径
const PER_LEVEL := 4         ## 每多连一格多几颗粒子
const BASE_DOTS := 6
const INK_CRUMB := Color("d8bd8b")   ## 组织碎屑
const INK_SLASH := Color("f9edb1")   ## 咬合那两道
const INK_HOT := Color("ddec9e")     ## 粒子（飘到上半段）
const INK_COOL := Color("95be6a")    ## 粒子（刚升起）

var _t := 0.0
var _at := Vector2.ZERO
var _level := 0
var _active := false


func _init() -> void:
	visible = false


## at = 咬下去的那一格，level = 已经连了几口（0 起）
func play(at: Vector2, level: int) -> void:
	_at = at
	_level = level
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
	var p := clampf(_t / TOTAL, 0.0, 1.0)
	## 碎屑：黄金角散开，y 只推 0.7（贴地的透视）
	for i in CRUMBS:
		var a := float(i) * 2.399
		var d := p * (CRUMB_R + float(i % 5) * 2.0)
		var q := _at + Vector2(cos(a) * d, sin(a) * d * 0.7)
		draw_rect(Rect2(q.round(), Vector2(1.0 + float(i % 2), 1.0 + float(i % 2))),
			INK_CRUMB, true)
	## 咬合的两道：只在前半段，一闪即收 —— 拖长了就成了持续光效，不是「咬」
	if p < 0.45:
		draw_line(_at + Vector2(12.0, -12.0), _at + Vector2(20.0, -17.0), INK_SLASH, 2.0, false)
		draw_line(_at + Vector2(14.0, 7.0), _at + Vector2(21.0, 12.0), INK_SLASH, 2.0, false)
	## 强化粒子：绕着细胞升起，连得越多越密。飘到上半段换亮色 —— 「攒住了」
	var count := BASE_DOTS + _level * PER_LEVEL
	for i in count:
		var phase := fmod(p * 0.7 + float(i) / float(count), 1.0)
		var a := float(i) * 2.4
		var r := ORBIT + float(_level) * 2.0
		var q := _at + Vector2(cos(a) * r, 10.0 - phase * RISE + sin(a) * 5.0)
		var ink: Color = INK_HOT if phase > 0.65 else INK_COOL
		var w := 1.0 + (1.0 if i % 4 == 0 else 0.0)
		draw_rect(Rect2(q.round(), Vector2(w, w)), ink, true)
	## 已经攒到第几档：细胞头顶几个小十字，一眼数得出来
	for i in _level:
		_spark(_at + Vector2(-8.0 + float(i) * 8.0, -25.0))


func _spark(p: Vector2) -> void:
	draw_line(p + Vector2(-2.0, 0.0), p + Vector2(2.0, 0.0), INK_HOT, 1.0, false)
	draw_line(p + Vector2(0.0, -2.0), p + Vector2(0.0, 2.0), INK_HOT, 1.0, false)
