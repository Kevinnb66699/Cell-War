## 巨噬【效应应答-连续吞噬】的每一口。照 tools/art-preview 的 **A 版「暴食冲刺」**（团队已选）。
##
## 一口的节奏（`f` = 这一口走了多少，0~1）：
##   张口 → 冲刺（缓入缓出）→ 咬合 → 碎屑爆散 → 强化粒子上升
##
## **连锁期间巨噬的贴图要让位**：选稿画的是一只张着口的胞体，不是「在细胞上叠一层」。
## 所以 `chewing_cid` 期间 `CWMatch._sync_cells` 把那只细胞的节点藏起来，由这儿画。
## 咬完（演出收场）真身自然回到落点上 —— 引擎那时早就把它挪过去了。
##
## **连得越多越有劲**：胞体更大、粒子更密、头顶多一个小十字。
## 层数不在这儿数，现读引擎的 `chain_left`（见 `CWUIBridge.show_result`）。
class_name CWChainFx
extends Node2D

const TOTAL := 0.7           ## 一口演多久（连下一口会重新起）
const LUNGE_AT := 0.16       ## 冲刺从这一刻起
const LUNGE_FOR := 0.43      ## 冲刺持续多久
const BITE_AT := 0.61        ## 到这一刻算咬合完成
const BASE_R := 13.0         ## 胞体半径的基数
const OPEN_MAX := 0.95       ## 张口的最大附加角（弧度）
const OPEN_MIN := 0.30       ## 张口的底角
const OPEN_SHUT := 0.06      ## 咬合之后剩多少（不归零 —— 完全闭合就读不出是张嘴了）
const CRUMBS := 14
const CRUMB_R := 22.0
const RISE := 37.0
const ORBIT := 15.0
const PER_LEVEL := 4
const BASE_DOTS := 6
const INK_RIM := Color("dde9a5")     ## 胞体外缘
const INK_SKIN := Color("799e62")    ## 胞膜
const INK_CORE := Color("476f4c")    ## 胞质
const INK_NUC := Color("a0d29a")     ## 细胞核
const INK_NUC_HI := Color("e4f1b8")
const INK_LIP := Color("edf3c6")     ## 上下唇
const INK_TOOTH := Color("fff6d8")   ## 张到最大时唇尖那一点
const INK_DASH := Color("8eac6a")    ## 冲刺速度线
const INK_CRUMB := Color("d8bd8b")   ## 组织碎屑
const INK_SLASH := Color("f9edb1")
const INK_HOT := Color("ddec9e")
const INK_COOL := Color("95be6a")

var chewing_cid := -1        ## 此刻由这只演出代画的细胞（-1 = 没有）；CWMatch 据此藏真身
var _t := 0.0
var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _level := 0
var _active := false


func _init() -> void:
	visible = false


## from/to = 这一口从哪咬到哪，level = 已经连了几口（1 起），cid = 这只巨噬的细胞下标
func play(from: Vector2, to: Vector2, level: int, cid: int) -> void:
	_from = from
	_to = to
	_level = level
	chewing_cid = cid
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
		chewing_cid = -1
	queue_redraw()


## 张口角度：起手微张 → 冲刺途中张到最大 → 咬合后几乎闭上
static func opening_at(f: float) -> float:
	if f > BITE_AT:
		return OPEN_SHUT
	return OPEN_MIN + sin(clampf(f / 0.58, 0.0, 1.0) * PI) * OPEN_MAX


## 张着口的胞体轮廓：圆心 + 一段圆弧，缺口正对着咬的方向 —— 就是「吃豆人」那个形状
static func maw_shape(at: Vector2, r: float, opening: float, dir: float) -> PackedVector2Array:
	var pts := PackedVector2Array([at])
	var span := TAU - opening * 2.0
	var n := maxi(10, int(r))
	for i in n + 1:
		var a := dir + opening + span * float(i) / float(n)
		pts.append(at + Vector2(cos(a), sin(a)) * r)
	return pts


func _draw() -> void:
	if not _active:
		return
	var f := clampf(_t / TOTAL, 0.0, 1.0)
	## 冲刺：缓入缓出，别匀速滑过去 —— 「扑」的力量感全在这条曲线上
	var lunge := clampf((f - LUNGE_AT) / LUNGE_FOR, 0.0, 1.0)
	var sprint: float = lunge * lunge * (3.0 - 2.0 * lunge)
	var at := _from.lerp(_to, sprint).round()
	var dir: float = (_to - _from).angle()
	var r: float = BASE_R + float(_level)
	var opening := opening_at(f)

	## 冲刺尾流：三道短线拖在身后，只在冲的那段有
	if lunge > 0.0 and lunge < 1.0:
		for i in range(1, 4):
			var back := at - Vector2(cos(dir), sin(dir)) * (float(i) * 8.0 + 8.0)
			draw_line(back + Vector2(0.0, float(i) * 4.0 - 7.0),
				back - Vector2(6.0, 0.0) + Vector2(0.0, float(i) * 4.0 - 7.0),
				INK_DASH, 2.0, false)

	## 胞体：三层由外到内叠出边缘、胞膜、胞质的分层（选稿是按到圆心的距离分的）
	draw_colored_polygon(maw_shape(at, r, opening, dir), INK_RIM)
	draw_colored_polygon(maw_shape(at, r - 2.0, opening, dir), INK_SKIN)
	draw_colored_polygon(maw_shape(at, r - 4.0, opening, dir), INK_CORE)
	## 细胞核偏在后方 —— 嘴在前，核被挤到后面，一眼看得出朝向
	var nuc := at - Vector2(cos(dir), sin(dir)) * r * 0.35
	draw_circle(nuc, 4.0, INK_NUC)
	draw_rect(Rect2((nuc + Vector2(-1.0, -2.0)).round(), Vector2(2, 2)), INK_NUC_HI, true)
	## 上下唇：两道亮线勾出嘴的开口
	for side: float in [-1.0, 1.0]:
		var a: float = dir + side * opening
		var d := Vector2(cos(a), sin(a))
		draw_line(at + d * 3.0, at + d * (r - 1.0), INK_LIP, 1.0, false)
		if opening > 0.25:
			draw_rect(Rect2((at + d * (r - 4.0)).round(), Vector2(2, 2)), INK_TOOTH, true)

	## 咬中之后：碎屑从落点爆开 + 两道咬合白光
	if f > 0.57:
		var impact := clampf((f - 0.57) / 0.37, 0.0, 1.0)
		for i in CRUMBS:
			var ca := float(i) * 2.399
			var cd := impact * (CRUMB_R + float(i % 5) * 2.0)
			var q := _to + Vector2(cos(ca) * cd, sin(ca) * cd * 0.7)
			var w := 1.0 + float(i % 2)
			draw_rect(Rect2(q.round(), Vector2(w, w)), INK_CRUMB, true)
		if impact < 0.5:
			draw_line(at + Vector2(12.0, -12.0), at + Vector2(20.0, -17.0), INK_SLASH, 2.0, false)
			draw_line(at + Vector2(14.0, 7.0), at + Vector2(21.0, 12.0), INK_SLASH, 2.0, false)

	## 强化粒子：绕着胞体升起，连得越多越密；飘到上半段换亮色 = 「攒住了」
	var count := BASE_DOTS + _level * PER_LEVEL
	for i in count:
		var phase := fmod(f * 0.7 + float(i) / float(count), 1.0)
		var pa := float(i) * 2.4
		var pr := ORBIT + float(_level) * 2.0
		var q := at + Vector2(cos(pa) * pr, 10.0 - phase * RISE + sin(pa) * 5.0)
		var ink: Color = INK_HOT if phase > 0.65 else INK_COOL
		var w := 1.0 + (1.0 if i % 4 == 0 else 0.0)
		draw_rect(Rect2(q.round(), Vector2(w, w)), ink, true)
	## 已经攒到第几档：头顶几个小十字，数得出来
	for i in _level:
		_spark(at + Vector2(-8.0 + float(i) * 8.0, -25.0))


func _spark(p: Vector2) -> void:
	draw_line(p + Vector2(-2.0, 0.0), p + Vector2(2.0, 0.0), INK_HOT, 1.0, false)
	draw_line(p + Vector2(0.0, -2.0), p + Vector2(0.0, 2.0), INK_HOT, 1.0, false)
