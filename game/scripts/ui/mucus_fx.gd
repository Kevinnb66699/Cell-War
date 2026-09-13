## 印戒【I-黏液破裂】的引爆演出。照 tools/art-preview R4 的 **B 版「十二向黏液喷射」**（团队 2026-09-11 改选，issue #15）。
##
## 两拍：
##   0 ~ CHARGE       胞体憋住：脚下一圈低位环收紧
##   CHARGE ~ TOTAL   十二道黏液沿等分角喷出、先抬后落，每道带一滴亮头
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
const WAVE_R := 82.0         ## 十二道喷射推到多远（选稿 reach = p·82，扫过 2 格作用圈的外缘）
const JETS := 12             ## 十二向
const JET_LIFT := 17.0       ## 先抬后落的高度（−sin(p·π)·17）
const INK_JET := Color("b6cd73")     ## 喷射的液柱
const INK_JET_TIP := Color("e0e5a1") ## 液柱头上那滴
const SQUASH := 0.6          ## 贴地椭圆的压扁比（等距棋盘上的「平躺」）
const DROPS := 20            ## 碎滴数
const INK_WAVE := Color("dbe6a0")    ## 液浪
const INK_DROP := Color("b4c76e")    ## 碎滴
const INK_CHARGE := Color("d7da92")  ## 憋住那圈

var _t := 0.0
var _at := Vector2.ZERO
var _active := false


## 地上那层黏液跟着液浪走（Kevin 2026-09-13，issue #31：「应该先炸开，然后随着中间黏液特效扩散，
## 格子从里到外出现黏液，而不是直接出现」）。返回真 = 液浪还没推到这一格，这一帧先别画它
## （`CWMatch._sync_tiles` 每帧问一次）。演出没在跑 → 一律假，地上那层照常全画。
##
## 比的是**贴地的椭圆**：等距棋盘上纵向被压扁了（同 ground_ring 的 SQUASH），
## 不换算的话上下那两圈会比左右晚半拍才铺上。
func pending(p: Vector2) -> bool:
	if not _active:
		return false
	var d := p - _at
	return Vector2(d.x, d.y / SQUASH).length() > front()


## 此刻液浪推到多远（棋盘像素）。憋住那一拍还没炸，前沿是 0
func front() -> float:
	if not _active or _t <= CHARGE:
		return 0.0
	return WAVE_R * clampf((_t - CHARGE) / (TOTAL - CHARGE), 0.0, 1.0)


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
	if p >= 1.0:
		return
	## 十二向喷射（选稿 rupture v1）：十二道短线沿等分角射出、每道带一滴亮头，
	## 整体先抬后落 —— 喷起来再落到地上；落地那层膜由 CWMatch._sync_tiles 摆（结果不在这儿重复表达）
	for i in JETS:
		var a := float(i) * PI / 6.0
		var reach := p * WAVE_R
		var x := _at.x + cos(a) * reach
		var y := _at.y + sin(a) * reach * 0.6 - sin(p * PI) * JET_LIFT
		CWPix.line(self, Vector2(x - cos(a) * 11.0, y - sin(a) * 7.0), Vector2(x, y), INK_JET, 2)
		CWPix.disc(self, Vector2(x, y), 3.0, INK_JET_TIP, 0.7)
