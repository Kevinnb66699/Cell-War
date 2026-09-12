## mark_aura_fx.gd —— 树突状细胞【I-标记】光环范围的常驻演出
##
## Kevin 2026-09-08：「树突状的周围的格子常驻粒子效果，用来表明标记的范围」。
## 范围是 `CWData.MARK_RANGE`（2 格），一只树突最多罩住 19 格。
##
## **为什么不照搬趋化源那只漩涡**：那是**一格**上的演出，粒子密到能当地标；
## 这里要铺 19 格，同样的密度会把整片棋盘淹掉，连底下是什么组织都看不清。
## 所以这只演出走另一头 —— **每格三个像素、低透明度、朝树突缓慢飘一小段**。
## 关键是**每格自成一小簇**：飘的距离压在半格以内，簇与簇之间留得出空隙，
## 于是「哪些格在范围内」一眼可数。第一版让粒子飘 11px、跨进了邻格，
## 整片看起来就成了随机闪烁 —— 而这只演出的全部目的就是让人看出范围。
##
## 沿用趋化源那三条像素纪律（改动前先看 chemo_fx.gd 的头注）：
## ① 落在整数像素上（画之前取整，`draw_rect` 不用 `draw_circle`）；
## ② 时间按 `PIX_FPS` 量化，像逐帧动画；
## ③ 透明度只取几档，没有连续渐变。
##
## 颜色走免疫青（同趋化源，都是免疫方的东西）。两者不会混淆：
## 趋化源是**一格**上的密集漩涡，这只是**一片**上的稀疏流动，形状完全不同。
##
## 想看效果：`tests/preview/preview_mark_aura.gd`（真渲染，连拍几帧）。
class_name CWMarkAuraFx
extends Node2D

const PER_TILE := 3                  ## 每格几个粒子。3 是「这一格明显有东西」和「不淹没棋盘」的折中
## 一个周期里朝树突飘多远。**必须小于半个格宽**——
## 第一版给了 11px，粒子飘着飘着就跨进邻格，整片看起来像随机闪烁而不是一片区域，
## 而这只演出的**全部目的就是让人看出范围**（Kevin：「用来表明标记的范围」）。
## 收到 6px 之后每格自成一小簇，「哪些格在范围内」一眼可数。
const DRIFT_PX := 6.0
const LOOP_SEC := 1.6                ## 一个周期多久
const PIX_FPS := 12.0                ## 同趋化源：每秒 12 格的逐帧步进
const DOT_PX := 2                    ## 粒子方块边长
const COLOR := Color("30d1fa")       ## 免疫青
## 透明度分档：起手淡入、中段最亮、末尾淡出。**只有这几档**，不做连续渐变
const ALPHA_STEPS: Array[float] = [0.20, 0.42, 0.48, 0.36, 0.16]
## 粒子在**自己格子里**的起手偏移（相对格心）。三点错开成一小簇，
## 幅度压在 ±5px 内 —— 再大就压到格子边上，和邻格的簇糊成一片
const SEED_OFFSET: Array[Vector2] = [
	Vector2(-5.0, -2.0), Vector2(4.0, -3.0), Vector2(0.0, 3.0),
]

## 一格上的那几个粒子。
##
## **为什么每格要单独一个节点**：一个节点只有一个 `z_index`，而棋盘是**按排分层**的
## （组织块的 z = 自己的 y，前一排 +20）。拿一个 z 画满 19 格的话，比它靠前的那些排
## 会正正当当把粒子盖掉 —— Kevin 2026-09-08 报「有时候不显示」，其实是下半片一直被盖着，
## 而且树突站得越靠后盖得越多。同 `CWBoard._marks` 的做法：一格一个节点，各拿自己那格的 z。
class TileDots:
	extends Node2D
	var toward := Vector2.ZERO   ## 朝树突的方向（相对本格）
	var phase := 0.0
	var t := 0.0

	func _draw() -> void:
		var frame := CWMarkAuraFx.frame_of(t)
		for k in CWMarkAuraFx.PER_TILE:
			var prog := CWMarkAuraFx.progress_of(frame,
				phase + float(k) / CWMarkAuraFx.PER_TILE)
			var at: Vector2i = CWMarkAuraFx.offset_at(k, toward, prog)
			draw_rect(Rect2(at.x, at.y, CWMarkAuraFx.DOT_PX, CWMarkAuraFx.DOT_PX),
				Color(CWMarkAuraFx.COLOR, CWMarkAuraFx.alpha_of(prog)), true)


var _t := 0.0
var _pool: Array[TileDots] = []      ## 复用的格子节点；多出来的藏起来，不销毁


## 每帧喂：`auras` 每项是一只树突的
## { origin: 它自己的格心, tiles: [{ pos: 格心, z: 那一格的 z }] }。
## 空数组 = 场上没有树突，什么都不画。
##
## **z 必须由调用方按格给**：只有棋盘知道每格该用什么 z（`CWBoard.tile_z`），
## 演出层自己猜一个就会重演「下半片被盖住」那个 bug。
func sync(delta: float, auras: Array) -> void:
	_t += delta
	var need := 0
	for a in auras:
		need += (a["tiles"] as Array).size()
	while _pool.size() < need:
		var d := TileDots.new()
		add_child(d)
		_pool.append(d)
	var i := 0
	for a in auras:
		var origin: Vector2 = a["origin"]
		for e in a["tiles"]:
			var pos: Vector2 = e["pos"]
			var d: TileDots = _pool[i]
			d.position = pos
			d.z_index = int(e["z"])
			d.toward = origin - pos
			d.phase = phase_of(pos)
			d.t = _t
			d.visible = true
			d.queue_redraw()
			i += 1
	## 树突死了 / 走开了：多出来的节点藏起来。每帧建删几十个节点纯属浪费
	for k in range(i, _pool.size()):
		_pool[k].visible = false
	visible = not auras.is_empty()


## t 时刻落在第几格时间。同一格里的任何时刻画出来都一样。
static func frame_of(t: float) -> int:
	return int(floor(t * PIX_FPS))


## 这一格、这个粒子在 `frame` 帧走完了周期的百分之多少（0~1）。
##
## `phase` 由格子坐标算出来，**每格错开** —— 不错开的话 19 格会整齐划一地脉动，
## 看起来像界面在闪，而不是像一片在流动。
static func progress_of(frame: int, phase: float) -> float:
	return fposmod(frame / PIX_FPS / LOOP_SEC + phase, 1.0)


## 相对格心的像素偏移：从起手偏移出发，朝 `toward` 方向飘 DRIFT_PX × 进度。
## **纯函数**，回归靠它核对「不越界、都是整数」，不用真渲染。
static func offset_at(seed_idx: int, toward: Vector2, prog: float) -> Vector2i:
	var dir: Vector2 = toward.normalized() if toward.length() > 0.001 else Vector2.ZERO
	return Vector2i((SEED_OFFSET[seed_idx % SEED_OFFSET.size()] + dir * DRIFT_PX * prog).round())


## 这一档进度用哪一档透明度。分档表是「淡入 → 最亮 → 淡出」，所以只按进度均分取档。
static func alpha_of(prog: float) -> float:
	var i := int(prog * ALPHA_STEPS.size())
	return ALPHA_STEPS[clampi(i, 0, ALPHA_STEPS.size() - 1)]


## 每格的相位偏移：拿格心坐标凑一个 0~1 的数。要的只是「稳定且看起来没规律」——
## 同一格每帧必须给同一个值，否则粒子会原地乱跳。
static func phase_of(tile: Vector2) -> float:
	return fposmod(sin(tile.x * 12.9898 + tile.y * 78.233) * 43758.5453, 1.0)


