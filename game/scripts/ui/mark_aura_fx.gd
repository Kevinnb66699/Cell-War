## mark_aura_fx.gd —— 树突状细胞【I-标记】光环范围的常驻演出
##
## Kevin 2026-09-08：「树突状的周围的格子常驻粒子效果，用来表明标记的范围」。
## 范围是 `CWData.MARK_RANGE`（2 格），一只树突最多罩住 19 格。
##
## **为什么不照搬趋化源那只漩涡**：那是**一格**上的演出，粒子密到能当地标；
## 这里要铺 19 格，同样的密度会把整片棋盘淹掉，连底下是什么组织都看不清。
## 所以这只演出走另一头 —— **每格只有 2 个像素，低透明度，朝树突缓慢飘**。
## 密度换成了**方向性**：满屏零散的点看不出边界，而「都朝同一个地方流」一眼就读得出
## 「这一片归那只细胞管」。
##
## 沿用趋化源那三条像素纪律（改动前先看 chemo_fx.gd 的头注）：
## ① 落在整数像素上（画之前取整，`draw_rect` 不用 `draw_circle`）；
## ② 时间按 `PIX_FPS` 量化，像逐帧动画；
## ③ 透明度只取几档，没有连续渐变。
##
## 颜色走免疫青（同趋化源，都是免疫方的东西）。两者不会混淆：
## 趋化源是**一格**上的密集漩涡，这只是**一片**上的稀疏流动，形状完全不同。
##
## 想看效果：`tests/preview_mark_aura.gd`（真渲染，连拍几帧）。
class_name CWMarkAuraFx
extends Node2D

const PER_TILE := 2                  ## 每格几个粒子。**2 是上限不是起点** —— 19 格 × 2 = 38 个已经够密
const DRIFT_PX := 11.0               ## 一个周期里朝树突飘多远（像素）。不是飘到底：
                                     ## 飘满全程会横穿别的格子，看起来像「谁在乱丢点」而不是「这片在流动」
const LOOP_SEC := 1.6                ## 一个周期多久
const PIX_FPS := 12.0                ## 同趋化源：每秒 12 格的逐帧步进
const DOT_PX := 2                    ## 粒子方块边长
const COLOR := Color("30d1fa")       ## 免疫青
## 透明度分档：起手淡入、中段最亮、末尾淡出。**只有这几档**，不做连续渐变
const ALPHA_STEPS: Array[float] = [0.14, 0.30, 0.34, 0.26, 0.12]
## 粒子在格子里的起手偏移（相对格心）。两个点错开，别叠在一条线上
const SEED_OFFSET: Array[Vector2] = [Vector2(-6.0, -3.0), Vector2(5.0, 2.0)]

var _t := 0.0
var _auras: Array = []               ## [{ origin: Vector2, tiles: Array[Vector2] }]


## 每帧喂：`auras` 每项是一只树突的 { origin（它自己的格心）, tiles（范围内各格的格心） }。
## 空数组 = 场上没有树突，什么都不画。
func sync(delta: float, auras: Array, z: int) -> void:
	_t += delta
	_auras = auras
	z_index = z
	visible = not auras.is_empty()
	queue_redraw()


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


func _draw() -> void:
	var frame := frame_of(_t)
	for a in _auras:
		var origin: Vector2 = a["origin"]
		for tile: Vector2 in a["tiles"]:
			var toward: Vector2 = origin - tile
			var phase := phase_of(tile)
			for k in PER_TILE:
				var prog := progress_of(frame, phase + float(k) / PER_TILE)
				var at: Vector2i = Vector2i(tile.round()) + offset_at(k, toward, prog)
				draw_rect(Rect2(at.x, at.y, DOT_PX, DOT_PX), Color(COLOR, alpha_of(prog)), true)
