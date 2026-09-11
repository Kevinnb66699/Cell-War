## cell_deco.gd —— 跟着某只癌细胞走的**常驻**装饰（issue #15，2026-09-11）：
## 印戒【囊性护甲】的两枚小盾、骨肉瘤【刚性屏障】的骨牙底盘、被标记癌细胞的头顶紫晶冠印。
## 照 tools/art-preview R4 团队选定的案逐笔复刻：armor C「灰青小盾」、barrier A「骨牙底盘」、mark_visual B「紫晶冠印」。
##
## **每只细胞两个节点**（front / back）：盾要绕着胞体转、骨牙要嵌在胞体前后，
## 前后各一半 —— 一个节点画不出「一半压在细胞后面」。两个节点都挂在 CWMatch 的 _cells_root 上，
## 位置 = 那一格的顶面中心（选稿的坐标系），z 由 CWMatch._sync_cells 按细胞节点 ±1 摆。
## 状态**每帧现读引擎**（`game.cells[index]`），这儿不另记一份：护甲用掉了（armor_used）盾就收，
## 走下固化格底盘就没，标记消了冠印就没。只有「标记是哪一刻出现的」得自己记 —— 缩入动画从那一刻数。
class_name CWCellDeco
extends Node2D

const INK_ARMOR := Color("92b4aa")
const ARMOR_ALPHA := 0.42
const BARRIER := [Color("72665a"), Color("cbbb97"), Color("f0e2bd")]
const BARRIER_SHADOW := Color("303938")
const INK_MARK := Color("c39bff")
const INK_MARK_CORE := Color("fff0ff")
const HEAD_DY := -33.0        ## 冠印中心离细胞位（格顶面中心 + CELL_FOOT_DY）多高：选稿是胞体中心上 29px
const TOOTH_H := 6

var front := false            ## true = 画在细胞前面的那一半
var game: CWGame
var index := -1               ## game.cells 的下标
var _t := 0.0
var _marked_since := -1.0     ## 标记出现的时刻（_t 的读数）；-1 = 此刻没标记


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


## 某枚小盾此刻在哪、在前面还是后面（选稿：轨道 18×7、角速度 0.85、两枚相隔半圈）。**纯函数**。
static func shield_at(t: float, i: int, body: Vector2) -> Dictionary:
	var angle := t * 0.85 + float(i) * PI
	return { "pos": body + Vector2(cos(angle) * 18.0, -3.0 + sin(angle) * 7.0), "front": sin(angle) >= 0.0 }


## 六枚骨牙的落点（选稿：q·13 + r·6.5, r·7，按 y 排序）。**纯函数**。
static func teeth() -> Array:
	var out: Array = []
	for d: Vector2i in CWData.DIRS:
		out.append(Vector2(float(d.x) * 13.0 + float(d.y) * 6.5, float(d.y) * 7.0))
	out.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
	return out


## 冠印的半径：刚出现时 18、0.3 秒起 0.6 秒内缩到 5（选稿 headMarker 的 size）。**纯函数**。
static func marker_size(age: float) -> int:
	var k := CWPix.phase(age, 0.3, 0.6)
	return 5 + roundi((1.0 - k) * 13.0)


func _draw() -> void:
	if game == null or index < 0 or index >= game.cells.size():
		return
	var c: Dictionary = game.cells[index]
	if not bool(c["alive"]) or int(c["faction"]) != CWData.Faction.CANCER:
		_marked_since = -1.0
		return
	var body := Vector2(0, CWMatch.CELL_FOOT_DY)
	match int(c["ctype"]):
		CWData.CancerType.SIGNET:
			if game.type_ability_on(c) and not bool(c.get("armor_used", false)):
				_armor(body)
		CWData.CancerType.OSTEO:
			if game.type_ability_on(c) and game.tiles.has(c["pos"]) \
					and int(game.tiles[c["pos"]]["tissue"]) == CWData.Tissue.SOLID:
				_barrier()
	if bool(c.get("marked", false)):
		if _marked_since < 0.0:
			_marked_since = _t
		if front:
			_marker(body, _t - _marked_since)
	else:
		_marked_since = -1.0


## 两枚小盾沿贴地椭圆轨道慢转，低透明度、细像素轮廓；前后各归各的节点画
func _armor(body: Vector2) -> void:
	var ink := Color(INK_ARMOR, ARMOR_ALPHA)
	for i in 2:
		var s: Dictionary = shield_at(_t, i, body)
		if bool(s["front"]) != front:
			continue
		var p: Vector2 = s["pos"]
		CWPix.line(self, p + Vector2(-3, -3), p + Vector2(3, -3), ink)
		CWPix.line(self, p + Vector2(-3, -3), p + Vector2(-2, 1), ink)
		CWPix.line(self, p + Vector2(3, -3), p + Vector2(2, 1), ink)
		CWPix.line(self, p + Vector2(-2, 1), p + Vector2(0, 3), ink)
		CWPix.line(self, p + Vector2(2, 1), p + Vector2(0, 3), ink)


## 骨牙底盘：后面那半画底座三层 + 靠后的骨牙，前面那半只画靠前的骨牙（嵌在胞体前）
func _barrier() -> void:
	if not front:
		CWPix.disc(self, Vector2(0, 3), 15.0, BARRIER_SHADOW, 0.45)
		CWPix.disc(self, Vector2(0, 1), 14.0, BARRIER[1], 0.42)
		CWPix.disc(self, Vector2.ZERO, 11.0, BARRIER[0], 0.4)
	for a: Vector2 in teeth():
		if (a.y >= 0.0) != front:
			continue
		var direction := signf(a.x)
		for k in TOOTH_H:
			var half := 3.0 * (1.0 - float(k) / float(TOOTH_H))
			var x := a.x + direction * float(k) * 0.28
			CWPix.line(self, Vector2(x - half, a.y - float(k)), Vector2(x + half, a.y - float(k)), BARRIER[1])
			CWPix.px(self, Vector2(x - half, a.y - float(k)), BARRIER[2])


## 紫晶冠印：菱心缩入 + 双翼切角 + 四粒绕行碎片
func _marker(body: Vector2, age: float) -> void:
	var y := body.y + HEAD_DY
	var size := float(marker_size(age))
	var c := Vector2(0, y)
	CWPix.line(self, c + Vector2(0, -size), c + Vector2(size, 0), INK_MARK, 2)
	CWPix.line(self, c + Vector2(size, 0), c + Vector2(0, size), INK_MARK, 2)
	CWPix.line(self, c + Vector2(0, size), c + Vector2(-size, 0), INK_MARK, 2)
	CWPix.line(self, c + Vector2(-size, 0), c + Vector2(0, -size), INK_MARK, 2)
	CWPix.px(self, c + Vector2(-1, -1), INK_MARK_CORE, 3)
	for side in [-1.0, 1.0]:
		CWPix.line(self, c + Vector2(side * 9.0, 3), c + Vector2(side * 14.0, -2), INK_MARK, 2)
		CWPix.line(self, c + Vector2(side * 14.0, -2), c + Vector2(side * 14.0, -7), INK_MARK)
	for i in 4:
		var a := float(i) * PI / 2.0 + _t * 2.0
		CWPix.px(self, c + Vector2(cos(a) * 18.0, sin(a) * 10.0), INK_MARK, 2)
