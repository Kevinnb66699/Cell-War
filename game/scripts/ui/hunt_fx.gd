## 免疫猎杀：目标捕获准星。照 tools/art-preview 的 **C 版「方框通缉镜」**（Kevin 2026-09-09 定）。
##
## 三拍与选稿一致：
##   0 ~ SEARCH        【全局搜索】大方框在棋盘中央左右摆，同时朝目标收拢
##   SEARCH ~ LOCK     【收缩锁定】方框飞到目标身上并收紧（三次方缓出）
##   LOCK ~ TOTAL      【通缉】锁定定格，四角夹住目标
##
## **选稿里有三样是预览的舞台道具，没有搬进来**：
## · 「GLOBAL SEARCH / 全局搜索」和「LOCK」两行英文 —— 对局里这句话由引擎的通报说
##   （`game.announce("免疫猎杀", ...)`），棋盘上再飘一行英文是重复；
##   队友在 PR #4 里也已经把 LOCK 去掉过一次。
## · 横扫的扫描线 —— 那是预览用来交代「在全图找」的，对局里目标是玩家自己选的。
## · 脚下的水平追踪环 —— 【追踪趋化源】在对局里已经有常驻演出（`CWChemoFx`），
##   【标记】也有（`CWMarkAuraFx`）。再画一圈就是同一件事画三遍。
##
## 尺寸直接照抄：预览的格距也是 36/20（`draw.js` 的 `position()` 与 board.gd 同一套投影），
## 所以半径 87 → 19 这两个数在对局里是等值的，不用换算。
class_name CWHuntFx
extends Node2D

const SEARCH := 0.65         ## 搜索持续多久
const LOCK := 1.6            ## 到这一刻收缩完成、转入通缉
const TOTAL := 2.2           ## 整只演出的长度
const R_FAR := 87.0          ## 搜索期的方框半径
const R_NEAR := 19.0         ## 锁定后的方框半径
const SWEEP := 22.0          ## 搜索期左右摆的幅度
## 配色不跟选稿那份走。Kevin 2026-09-09：「所有技能颜色主色调不要都是黄绿色」——
## 选稿里的砂白/琥珀就在那个色系里。改用免疫青（搜索）→ 捕获粉（锁定）：
## 青是免疫方本来的色（board.gd 的 MARK_MOVE 同族），粉只在「咬住了」那一刻出现，
## 一眼能和场上任何常驻演出区分开。
const INK := Color("61d7e8")          ## 搜索：免疫青
const INK_LOCKED := Color("ff6b8a")   ## 锁定：捕获粉
const SPARK := Color("ffd166")        ## 锁定瞬间头顶那一下（只有 4 个像素，用来提亮）

var _t := 0.0
var _at := Vector2.ZERO      ## 目标格顶面中心
var _from := Vector2.ZERO    ## 搜索的起点（棋盘中心）
var _active := false


## at = 目标格顶面中心，from = 搜索起点（棋盘中心，见 CWUIBridge.show_result）
func play(at: Vector2, from: Vector2) -> void:
	_at = at
	_from = from
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
	## 没在演就一笔都不画。不加这道闸的话，谁把它裸着 add_child 进去
	## （没跟着写 visible = false），棋盘原点就凭空多一个方框
	if not _active:
		return
	var search := clampf(_t / SEARCH, 0.0, 1.0)
	var lock := clampf((_t - SEARCH) / (LOCK - SEARCH), 0.0, 1.0)
	var locked := _t >= LOCK
	var ink := INK_LOCKED if locked else INK
	## 收缩用三次方缓出：快到目标时慢下来，读起来才像「咬住了」而不是「掉进去了」
	var r := lerpf(R_FAR, R_NEAR, 1.0 - pow(1.0 - lock, 3.0))
	## 搜索期就已经在朝目标收拢了（选稿如此）——「搜索」的味道来自左右摆动而不是停在原地。
	## 一旦进入收缩期权重钉死在 1，位置就完全跟着目标走。
	var c := Vector2(
		lerpf(_from.x + sin(search * 4.0) * SWEEP, _at.x, 1.0 if lock > 0.0 else search),
		lerpf(_from.y, _at.y, search))

	## 方框四角：每个角往内收 35% 画一横一竖，只留「角」不留边
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := c + Vector2(sx * r, sy * r)
			draw_line(corner, corner - Vector2(sx * r * 0.35, 0.0), ink, 2.0, false)
			draw_line(corner, corner - Vector2(0.0, sy * r * 0.35), ink, 2.0, false)
	draw_arc(c, r * 0.8, 0.0, TAU, 48, ink, 1.0, false)   ## 内瞄准圆

	## 四根十字臂：从内圈探出到框外，把「这是个瞄准器」讲明白
	for i in 4:
		var a := TAU * float(i) / 4.0
		var d := Vector2(cos(a), sin(a))
		draw_line(c + d * r * 0.57, c + d * (r + 9.0), ink, 1.0, false)

	if locked:
		_spark(c + Vector2(0.0, -r - 10.0))
	else:
		## 没锁定时中心留一个小十字：框还在飘，得有个东西指着「正在瞄这儿」
		draw_line(c + Vector2(-5.0, 0.0), c + Vector2(5.0, 0.0), ink, 1.0, false)
		draw_line(c + Vector2(0.0, -5.0), c + Vector2(0.0, 5.0), ink, 1.0, false)


func _spark(p: Vector2) -> void:
	draw_line(p + Vector2(-2.0, 0.0), p + Vector2(2.0, 0.0), SPARK, 1.0, false)
	draw_line(p + Vector2(0.0, -2.0), p + Vector2(0.0, 2.0), SPARK, 1.0, false)
