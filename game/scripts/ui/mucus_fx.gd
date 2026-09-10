## 印戒【I-黏液破裂】的引爆演出。照 tools/art-preview 的 **A 版「低位溅射」**（团队已选）。
##
## 两拍：
##   0 ~ CHARGE       胞体憋住：脚下一圈低位环收紧
##   CHARGE ~ TOTAL   贴地液浪向外推 + 碎滴散开
##
## **地上那层黏液不归这儿画**：这只演出只负责「炸开」那一下，不重复表达结果。
##
## ⚠ 这里原来写的是「棋盘贴图自己会变（见 CWBoard.set_tissue）」—— **那是句空头支票**：
## `set_tissue` 里从来没有过黏液这一档，于是自爆完地上一点痕迹都没有，
## 玩家只能一格格悬停去看详情栏（2026-09-10 Kevin 报上来）。
## 现在那层由 `CWMatch._sync_tiles` 摆一层色标（`CWMatch.MARK_MUCUS`），
## 颜色取的就是下面那个 `INK_DROP` —— 刚炸完的绿和地上留着的绿是同一个。
##
## 半径直接照抄选稿：预览的格距也是 36/20，92px ≈ 2.5 格，正好扫过
## `CWData.MUCUS_RADIUS`（2 格）的最外圈。
class_name CWMucusFx
extends Node2D

const CHARGE := 0.65         ## 憋住多久
const TOTAL := 1.75          ## 整只演出的长度（选稿是 0.65 + 1.1）
const CHARGE_R := 16.0       ## 憋住时脚下那圈的起始半径
const WAVE_R := 92.0         ## 液浪推到多远
const SQUASH := 0.6          ## 贴地椭圆的压扁比（等距棋盘上的「平躺」）
const DROPS := 20            ## 碎滴数
const INK_WAVE := Color("dbe6a0")    ## 液浪
const INK_DROP := Color("b4c76e")    ## 碎滴
const INK_CHARGE := Color("d7da92")  ## 憋住那圈

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
	if _t >= TOTAL:
		_active = false
		visible = false
	queue_redraw()


## 贴地的椭圆：等距棋盘上「平躺」的圈要把 y 压扁，不然读成竖着立在那儿
static func ground_ring(at: Vector2, r: float, squash: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(12, int(r))
	for i in n + 1:
		var a := TAU * float(i) / float(n)
		pts.append(at + Vector2(cos(a) * r, sin(a) * r * squash))
	return pts


func _draw() -> void:
	if not _active:
		return
	if _t < CHARGE:
		## 憋住：那圈随着蓄力一点点涨，涨幅很小 —— 「鼓起来」而不是「已经炸了」
		var p := _t / CHARGE
		draw_polyline(ground_ring(_at, CHARGE_R + p * 5.0, SQUASH), INK_CHARGE, 1.0, false)
		return
	var p := clampf((_t - CHARGE) / (TOTAL - CHARGE), 0.0, 1.0)
	draw_polyline(ground_ring(_at, p * WAVE_R, SQUASH), INK_WAVE, 1.0, false)
	## 碎滴：黄金角散布，越靠外的那几颗大一档。y 只推 0.7 —— 同样是贴地的透视
	for i in DROPS:
		var a := float(i) * 2.399
		var d := p * (WAVE_R - 10.0 + float(i % 5) * 2.0)
		var q := _at + Vector2(cos(a) * d, sin(a) * d * 0.7)
		var w := 1.0 + float(i % 2)
		draw_rect(Rect2(q.round(), Vector2(w, w)), INK_DROP, true)
