## pix.gd —— 选稿（tools/art-preview/draw.js）那几支像素笔的 GDScript 版，各只演出共用
##
## 逐笔对照 draw.js：pixel / line / ring / disc / spark / burst，坐标一律先取整再画
## （像素纪律 ①，见 chemo_fx.gd 头注）。line 不用 draw_line 的抗锯齿直线，
## 而是照 draw.js 那样沿线逐像素落方块 —— 两边才会一模一样。
## 尺寸按选稿 1× 原样：选稿的格距 36 / 20 与 CWBoard 相同，像素偏移可以直接照抄。
##
## 全是 static，第一个参数是要画到哪个 CanvasItem 上（在它的 _draw 里调）。
class_name CWPix
extends RefCounted


static func px(ci: CanvasItem, at: Vector2, color: Color, size: int = 1) -> void:
	ci.draw_rect(Rect2(at.round(), Vector2(size, size)), color, true)


## 沿较长那一边的步数逐点落 size×size 的方块（draw.js 的 line）
static func line(ci: CanvasItem, a: Vector2, b: Vector2, color: Color, width: int = 1) -> void:
	var n := ceili(maxf(maxf(absf(b.x - a.x), absf(b.y - a.y)), 1.0))
	for i in n + 1:
		px(ci, a.lerp(b, float(i) / float(n)), color, width)


## 空心椭圆（贴地时 squash < 1），可只画一段弧（start~end 弧度）、可整体倾斜
static func ring(ci: CanvasItem, c: Vector2, r: float, color: Color, squash := 1.0,
		start := 0.0, end := TAU, tilt := 0.0) -> void:
	if r <= 0.0:
		return
	var step := 1.0 / maxf(24.0, r * 2.0)
	var a := start
	while a <= end:
		var u := cos(a) * r
		var v := sin(a) * r * squash
		px(ci, Vector2(c.x + u * cos(tilt) - v * sin(tilt), c.y + u * sin(tilt) + v * cos(tilt)), color)
		a += step


## 实心椭圆：判据与取整同 draw.js 的 disc（i²/r² + j²/(r·s)² ≤ 1），按行铺
static func disc(ci: CanvasItem, c: Vector2, r: float, color: Color, squash := 1.0) -> void:
	if r <= 0.0:
		return
	var ry := r * squash
	if ry <= 0.0:
		return
	for j in range(-ceili(ry), floori(ry) + 1):
		var k := 1.0 - float(j * j) / (ry * ry)
		if k < 0.0:
			continue
		var half := floorf(sqrt(k) * r)
		ci.draw_rect(Rect2(Vector2(c.x - half, c.y + float(j)).round(), Vector2(half * 2.0 + 1.0, 1.0)), color, true)


## 十字火花
static func spark(ci: CanvasItem, c: Vector2, color: Color, size: int = 3) -> void:
	line(ci, c - Vector2(size, 0), c + Vector2(size, 0), color)
	line(ci, c - Vector2(0, size), c + Vector2(0, size), color)


## 黄金角散布的碎粒：p 0→1 往外飞（inward = 往里收），y 压 0.7 = 贴地透视
static func burst(ci: CanvasItem, c: Vector2, p: float, color: Color, count := 20, radius := 45.0,
		inward := false) -> void:
	for i in count:
		var a := float(i) * 2.399
		var d := ((1.0 - p) if inward else p) * (radius + float(i % 5) * 2.0)
		px(ci, c + Vector2(cos(a) * d, sin(a) * d * 0.7), color, 1 + i % 2)


## 从 a 飞向 b 的一串尾迹：头两颗大一档（revised-effects.js 的 trail）
static func trail(ci: CanvasItem, a: Vector2, b: Vector2, p: float, color: Color, count := 7) -> void:
	for i in count:
		var f := clampf(p - float(i) * 0.035, 0.0, 1.0)
		px(ci, a.lerp(b, f), color, 2 if i < 2 else 1)


## 带一点上下抖动的粒子路径（common-skills.js 的 path）
static func path(ci: CanvasItem, a: Vector2, b: Vector2, p: float, color: Color, v := 0) -> void:
	for i in 7 + v * 3:
		var f := clampf(p - float(i) * 0.035, 0.0, 1.0)
		var q := a.lerp(b, f)
		px(ci, Vector2(q.x, q.y + sin(float(i + v)) * 2.0), color, 2 if i == 0 else 1)


## 0~1 的分段进度：从 start 起、长 length 的那一段（选稿里到处都是这个 phase/stage）
static func phase(t: float, start: float, length: float) -> float:
	return clampf((t - start) / length, 0.0, 1.0)
