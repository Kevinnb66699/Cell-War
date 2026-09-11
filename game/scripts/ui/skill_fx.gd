## skill_fx.gd —— 一次性技能演出的合集（issue #15，2026-09-11）：照 tools/art-preview R4 团队选定的那几案逐笔复刻
##
## **一只节点画全部**：每种演出是这里的一个 kind，`play(kind, data)` 登记一条、`sync()` 走时间、
## `_draw()` 把还在演的逐条画出来。不给每种演出各建一个类 —— 它们只有「一段时间 + 几笔像素」，
## 共用的是 CWPix 那几支笔和同一套时间量化，各建一类只会多出十几份一模一样的 play/sync。
## 需要**代画细胞**或**常驻**的不在这里：连锁吞噬（CWChainFx）、囊性护甲 / 刚性屏障 / 头顶标记（CWCellDeco）。
##
## 坐标是**棋盘像素**，由 CWUIBridge.show_fx 换算好再给（细胞位 = 格顶面中心 + CELL_FOOT_DY，格位 = 格顶面中心）。
## 选稿里 0.65 秒的起手静止一律去掉：游戏里演出跟在结算之后，不需要「先看清局面」那一拍。
##
## 沿用像素纪律（chemo_fx.gd 头注）：① 整数像素（CWPix 负责）② 时间按 PIX_FPS 量化 ③ 透明度只取几档。
##
## 各 kind 的数据字段（Vector2 / Array[Vector2]）：
##   antibody      from（B 细胞）targets（癌细胞们）           immune-skills.js antibody v0「单发重击」
##   toxin         from（T 细胞）tiles（1 环七格）             immune-skills.js toxin v0「同步散射」
##   lyse          from（T 细胞）to（固化格）                   revised-effects.js lyse v1「三点连爆」
##   adhesion      from / to（两只癌细胞）                     immune-skills.js adhesion v1「紫晶冠印传递」
##   homing        from / to（血管格 / 落点）spread（被感染格）  revised-effects.js homing「双端血门 · 感染扩散」
##   pseudopod     to（目标格）roots（伸触手的癌性邻格）        revised-effects.js pseudopod v0「低弧牵引」
##   minimal       from / to（两格）                            cancer-skills.js minimal v0「细线疾行」
##   differentiate at（免疫细胞）                               common-skills.js differentiate v2「粒子重组」
##   respire       at（免疫细胞）                               common-skills.js respire v0「轻量吸收」
##   revive_immune at（复活格）                                 common-skills.js revive v0「归拢重生」
##   revive_cancer at（复活格）                                 common-skills.js revive v0「碎石重生」（癌方带碎石）
##   mutate        at（癌细胞）                                 common-skills.js mutate v0「双股消散」
##   anaerobic     at（癌细胞）sources（同连通块的癌性格）      revised-effects.js anaerobic v0「铜橙输能」
class_name CWSkillFx
extends Node2D

const PIX_FPS := 12.0
const DURATION := {
	"antibody": 1.4, "toxin": 1.05, "lyse": 2.05, "adhesion": 1.2, "homing": 2.9,
	"pseudopod": 2.4, "minimal": 1.2, "differentiate": 1.65, "respire": 1.65,
	"revive_immune": 1.65, "revive_cancer": 1.65, "mutate": 1.2, "anaerobic": 2.1,
}
## 头顶标记离细胞位多高（同 CWCellDeco.HEAD_DY）：黏连的传递轨迹从头到头
const HEAD_DY := -33.0

const ICE := Color("b7ecff")
const ICE_TAIL := Color("5688a5")
const ICE_FLASH := Color("edfaff")
const ICE_RING := Color("ccefff")
const VIOLET := Color("b88aff")
const VIOLET_BURST := Color("cab0ec")
const LYSE_INK := Color("efb96e")
const LYSE_GRAIN := Color("fff0cb")
const LYSE_CORE := Color("fff1ce")
const MARK_INK := Color("c39bff")
const BLOOD := Color("dd5265")
const BLOOD_PALE := Color("ffc1d3")
const BLOOD_STREAM := Color("dc536d")
const BLOOD_SPARK := Color("ffd1db")
const BLOOD_BURST := Color("f7a0b7")
const BLOOD_SPREAD := Color("dc738b")
const ROOT := Color("704449")
const ROOT_STEM := Color("cb807d")
const ARM_DARK := Color("593941")
const ARM_LIGHT := Color("cb807d")
const ARM_TIP := Color("f3b7a3")
const STEEL := Color("8aa9b8")
const CYAN := Color("83dce2")
const COPPER := Color("d98d68")
const PINK := Color("e88a9c")
const STONE := [Color("899291"), Color("cbd0cf"), Color("e1e4e2")]
const ANAEROBIC := Color("e58b65")
const ANAEROBIC_RISE := Color("f5c79a")

var _plays: Array = []      ## [{ kind, t, data }]


func _init() -> void:
	visible = false


func play(kind: String, data: Dictionary) -> void:
	if not DURATION.has(kind):
		return
	_plays.append({ "kind": kind, "t": 0.0, "data": data })
	visible = true
	queue_redraw()


func active() -> int:
	return _plays.size()


func sync(delta: float) -> void:
	if _plays.is_empty():
		return
	var keep: Array = []
	for p in _plays:
		p["t"] = float(p["t"]) + delta
		if float(p["t"]) < duration(String(p["kind"])):
			keep.append(p)
	_plays = keep
	visible = not _plays.is_empty()
	queue_redraw()


static func duration(kind: String) -> float:
	return float(DURATION.get(kind, 0.0))


func _draw() -> void:
	for p in _plays:
		var t: float = floorf(float(p["t"]) * PIX_FPS) / PIX_FPS
		var d: Dictionary = p["data"]
		match String(p["kind"]):
			"antibody": _antibody(t, d)
			"toxin": _toxin(t, d)
			"lyse": _lyse(t, d)
			"adhesion": _adhesion(t, d)
			"homing": _homing(t, d)
			"pseudopod": _pseudopod(t, d)
			"minimal": _minimal(t, d)
			"differentiate": _differentiate(t, d)
			"respire": _respire(t, d)
			"revive_immune": _revive_immune(t, d)
			"revive_cancer": _revive_cancer(t, d)
			"mutate": _mutate(t, d)
			"anaerobic": _anaerobic(t, d)


static func _pts(d: Dictionary, key: String) -> Array:
	var out: Array = []
	for v in d.get(key, []):
		out.append(Vector2(v))
	return out


static func _v(d: Dictionary, key: String) -> Vector2:
	return Vector2(d.get(key, Vector2.ZERO))


## Y 形抗体直射：0.8 秒飞到，命中后 0.52 秒碎粒 + 一圈涟漪 + 头 0.12 秒一记白闪
func _antibody(t: float, d: Dictionary) -> void:
	var origin := _v(d, "from")
	for tp: Vector2 in _pts(d, "targets"):
		var f := clampf(t / 0.8, 0.0, 1.0)
		if f < 1.0:
			var at := origin.lerp(tp, f)
			for k in range(1, 5):
				CWPix.px(self, origin.lerp(tp, clampf(f - float(k) * 0.026, 0.0, 1.0)), ICE_TAIL, 2)
			CWPix.line(self, at + Vector2(0, 3), at, ICE, 2)
			CWPix.line(self, at, at + Vector2(-3, -3), ICE, 2)
			CWPix.line(self, at, at + Vector2(3, -3), ICE, 2)
		var age := t - 0.8
		if age >= 0.0 and age < 0.52:
			var hit := clampf(age / 0.52, 0.0, 1.0)
			CWPix.burst(self, tp, hit, ICE, 24, 25.0)
			if age < 0.12:
				CWPix.disc(self, tp, 6.0, ICE_FLASH, 0.8)
			CWPix.ring(self, tp, 4.0 + hit * 19.0, ICE_RING, 0.85)


## 紫色颗粒同时射向七格：0.65 秒飞到，落地 0.35 秒小爆
func _toxin(t: float, d: Dictionary) -> void:
	var origin := _v(d, "from")
	for tp: Vector2 in _pts(d, "tiles"):
		var f := clampf(t / 0.65, 0.0, 1.0)
		if f < 1.0:
			for j in 4:
				var along := clampf(f - float(j) * 0.026, 0.0, 1.0)
				var spread := float(j % 3 - 1) * 3.0
				var q := origin.lerp(tp, along)
				CWPix.px(self, Vector2(q.x + spread, q.y - float(j % 2) * 3.0), VIOLET, 2)
		var age := t - 0.65
		if age >= 0.0 and age < 0.35:
			CWPix.burst(self, tp, age / 0.35, VIOLET_BURST, 10, 10.0)


## 三点连爆：三粒颗粒隔 0.27 秒送入固化格，1.2 秒起三处错开炸开
func _lyse(t: float, d: Dictionary) -> void:
	var a := _v(d, "from")
	var b := _v(d, "to")
	const DETONATE := 1.2
	for i in 3:
		var p := CWPix.phase(t, float(i) * 0.27, 0.5)
		var end := b + Vector2(float(i - 1) * 9.0, -4.0)
		if p > 0.0 and p < 1.0:
			CWPix.trail(self, a, end, p, LYSE_INK, 4)
			CWPix.disc(self, a.lerp(end, p), 3.0, LYSE_GRAIN)
		elif p >= 1.0 and t < DETONATE:
			CWPix.disc(self, end, 2.0, LYSE_INK)
	if t >= DETONATE and t < DETONATE + 0.85:
		for i in 3:
			var start := DETONATE + float(i) * 0.17
			var local := CWPix.phase(t, start, 0.4)
			if t >= start and local < 1.0:
				var c := b + Vector2(-10.0 + float(i) * 10.0, -3.0)
				CWPix.burst(self, c, local, LYSE_INK, 10, 18.0)
				CWPix.disc(self, c + Vector2(0, -1), 3.0 * (1.0 - local), LYSE_CORE)


## 标记从一只癌细胞的头顶传给另一只：一串紫粒 1.2 秒飞过去（新标记由 CWCellDeco 缩入）
func _adhesion(t: float, d: Dictionary) -> void:
	var s := _v(d, "from") + Vector2(0, HEAD_DY)
	var n := _v(d, "to") + Vector2(0, HEAD_DY)
	var f := clampf(t / 1.2, 0.0, 1.0)
	var q := s.lerp(n, f)
	for j in 4:
		CWPix.px(self, Vector2(q.x - float(j) * 3.0, q.y + float(j % 2)), MARK_INK, 2 if j == 0 else 1)


## 双端血门：两格各开一圈血环，血粒 1.25 秒流过去，落点炸一下，再逐格把感染送到邻格
func _homing(t: float, d: Dictionary) -> void:
	var a := _v(d, "from")
	var b := _v(d, "to")
	var p := CWPix.phase(t, 0.05, 1.25)
	for gate in [[a, false], [b, true]]:
		var at: Vector2 = gate[0]
		var open: float = CWPix.phase(t, 0.2, 0.45) if bool(gate[1]) else 1.0 - CWPix.phase(t, 1.0, 0.6)
		if open > 0.0:
			CWPix.ring(self, at + Vector2(0, -7), 19.0 * open, BLOOD, 0.85)
			CWPix.ring(self, at + Vector2(0, -7), 16.0 * open, BLOOD_PALE, 0.85, t * 3.0, t * 3.0 + 4.7)
	if p > 0.0 and p < 1.0:
		for i in 13:
			var f := clampf(p - float(i) * 0.022, 0.0, 1.0)
			CWPix.px(self, Vector2(lerpf(a.x, b.x, f), a.y - 7.0 + sin(f * PI * 4.0) * 4.0),
				BLOOD_STREAM if i % 3 != 0 else BLOOD_SPARK, 2 if i % 4 != 0 else 3)
	if t >= 1.3 and t < 1.85:
		CWPix.burst(self, b + Vector2(0, -4), CWPix.phase(t, 1.3, 0.55), BLOOD_BURST, 17, 23.0)
	var spread := _pts(d, "spread")
	for i in spread.size():
		var at: Vector2 = spread[i]
		var start := 1.6 + float(i) * 0.18
		var approach := CWPix.phase(t, start - 0.25, 0.25)
		var sp := CWPix.phase(t, start, 0.65)
		if approach > 0.0 and approach < 1.0:
			CWPix.trail(self, b, at, approach, BLOOD_SPREAD, 5)
		if t >= start and sp < 1.0:
			## 透明度只取三档（纪律 ③）
			var alpha := 1.0 if sp < 0.34 else (0.66 if sp < 0.67 else 0.33)
			for k in 9:
				var angle := float(k) * 2.399
				var radius := 3.0 + sp * 13.0
				CWPix.px(self, Vector2(at.x + cos(angle) * radius, at.y + sin(angle) * radius * 0.45 - sp * 7.0),
					Color(BLOOD_SPREAD if k % 3 != 0 else BLOOD_SPARK, alpha), 1 if k % 3 != 0 else 2)


## 低弧牵引：目标格的癌性邻格冒出根、伸出低弧触手抓住胞体边缘，抓稳后收回
func _pseudopod(t: float, d: Dictionary) -> void:
	var b := _v(d, "to")
	var actor := b + Vector2(0, -5)
	var retract := CWPix.phase(t, 1.85, 0.5)
	var sprout := CWPix.phase(t, 0.0, 0.3) * (1.0 - retract)
	var reach := CWPix.phase(t, 0.3, 0.6)
	var roots := _pts(d, "roots")
	if sprout > 0.0:
		for r: Vector2 in roots:
			CWPix.disc(self, r, 3.0 * sprout, ROOT, 0.6)
			CWPix.line(self, r, r + Vector2(0, -4.0 * sprout), ROOT_STEM, 2)
	var extension := reach * (1.0 - retract)
	if extension <= 0.0:
		return
	for r: Vector2 in roots:
		var angle := (r - actor).angle()
		var grip := actor + Vector2(cos(angle) * 9.0, sin(angle) * 7.0)
		var end := r.lerp(grip, extension)
		var pts: Array[Vector2] = []
		for i in 17:
			var f := float(i) / 16.0
			var q := r.lerp(end, f)
			pts.append(Vector2(q.x, q.y - sin(f * PI) * 8.0 * extension))
		for stroke in [[ARM_DARK, 4, 0.0], [ARM_LIGHT, 2, -1.0]]:
			var off := Vector2(0, float(stroke[2]))
			for i in range(1, pts.size()):
				CWPix.line(self, pts[i - 1] + off, pts[i] + off, stroke[0], int(stroke[1]))
		CWPix.disc(self, end + Vector2(0, -1), 2.0, ARM_TIP)


## 细线疾行：落点身后三道钢青短线，朝来路拖着
func _minimal(t: float, d: Dictionary) -> void:
	if t >= 1.2:
		return
	var from := _v(d, "from")
	var to := _v(d, "to")
	var dir := (to - from).normalized() if to != from else Vector2(1, 0)
	var at := to + Vector2(0, -5)
	for i in 3:
		var lift := Vector2(0, -5.0 + float(i) * 5.0)
		CWPix.line(self, at - dir * (17.0 + float(i) * 4.0) + lift, at - dir * (10.0 + float(i) * 4.0) + lift, STEEL)


## 粒子重组：青色碎粒从外圈收拢到胞体
func _differentiate(t: float, d: Dictionary) -> void:
	CWPix.burst(self, _v(d, "at") + Vector2(0, -5), t / 1.65, CYAN, 9, 20.0, true)


## 轻量吸收：七粒青色颗粒沿螺旋往胞体里收，尾声胞体右上亮一点
func _respire(t: float, d: Dictionary) -> void:
	var a := _v(d, "at")
	var p := t / 1.65
	if p < 1.0:
		for i in 7:
			var f := fmod(p + float(i) / 9.0, 1.0)
			CWPix.px(self, Vector2(a.x + cos(float(i) * 2.4) * (1.0 - f) * 22.0, a.y + (1.0 - f) * 18.0), CYAN, 1 + i % 2)
	if p > 0.6:
		CWPix.px(self, a + Vector2(14, -12), CYAN, 2)


## 归拢重生：十四粒青色碎粒往复活格收拢
func _revive_immune(t: float, d: Dictionary) -> void:
	CWPix.burst(self, _v(d, "at") + Vector2(0, -5), t / 1.65, CYAN, 14, 25.0, true)


## 碎石重生：依托的石块逐格散去（同一张伪随机石纹倒着放），铜色碎粒往格里收拢
func _revive_cancer(t: float, d: Dictionary) -> void:
	var a := _v(d, "at")
	var p := t / 1.65
	stone_patch(self, a, 1.0 - p)
	CWPix.burst(self, a + Vector2(0, -5), p, COPPER, 14, 25.0, true)


## 选稿的 stonePatch：3px 石粒按一条固定的伪随机序铺满一格；p 决定露出前几名（同一序，涨落都不洗牌）
static func stone_patch(ci: CanvasItem, a: Vector2, p: float) -> void:
	var y := -9
	while y <= 8:
		var x := -13
		while x <= 13:
			if absf(float(x)) + absf(float(y)) * 0.6 <= 17.0 and posmod(x * 7 + y * 13 + 101, 23) <= p * 24.0:
				CWPix.px(ci, a + Vector2(x, y), STONE[posmod(x + y + 60, 3)], 3)
			x += 3
		y += 3


## 双股消散：两股铜 / 粉像素绕着胞体上方扭动，七成时长后散尽
func _mutate(t: float, d: Dictionary) -> void:
	var a := _v(d, "at")
	if t / 1.65 >= 0.7:
		return
	for i in 9:
		var y := a.y - 23.0 + float(i) * 3.0
		var x := sin(float(i) + t * 5.0) * 7.0
		CWPix.px(self, Vector2(a.x + x, y), COPPER)
		CWPix.px(self, Vector2(a.x - x, y), PINK)


## 铜橙输能：同连通块的癌性格各送三串暖色颗粒进胞体，后半程胞体上方冒热气
func _anaerobic(t: float, d: Dictionary) -> void:
	var a := _v(d, "at")
	var p := t / 2.1
	var end := a + Vector2(0, -5)
	if p > 0.0 and p < 1.0:
		for s: Vector2 in _pts(d, "sources"):
			for i in 3:
				CWPix.trail(self, s, end, fmod(p * 1.6 + float(i) / 3.0, 1.0), ANAEROBIC, 5)
	if p > 0.5:
		for i in 6:
			CWPix.px(self, Vector2(a.x - 9.0 + float(i) * 3.0, a.y - 18.0 - fmod(t * 9.0 + float(i) * 3.0, 14.0)),
				ANAEROBIC_RISE, 2)
