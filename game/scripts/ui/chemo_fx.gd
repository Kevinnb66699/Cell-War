## chemo_fx.gd —— 树突状细胞【I-趋化源】的场上演出：漩涡核心（像素风）
##
## Kevin 2026-09-04 定的方向：「一个格子，然后周围有粒子绕着转，
## 有种漩涡核心 / 龙卷风的感觉」。
## Kevin 2026-09-06：粒子要**像素风** —— 之前是反锯齿的圆点加连续渐变的尾迹，
## 和棋盘贴图摆在一起像贴上去的矢量图。
##
## **像素风的三条纪律（改动前先看）**：
## ① **落在整数像素上**：轨道照算，画之前取整；节点原点是格子顶面中心（整数坐标），
##    所以整数偏移 = 与贴图同一张像素格。画的是整数尺寸的方块（`draw_rect`），
##    不用 `draw_circle` —— 圆的边缘会出半透明的反锯齿像素。
## ② **时间量化**：相位按 PIX_FPS 步进（1/12 秒一格），像逐帧动画，不做逐帧平滑；
##    尾迹取的正是前几格时间的位置，于是每个残影都落在粒子刚才真正画过的像素上。
## ③ **颜色分档**：透明度只取 ALPHA_STEPS 里的几档（本体、前 1 / 2 / 3 格），没有连续渐变；
##    方块随档位缩小，运动方向仍一目了然。
##
## **为什么用 `_draw()` 手画而不是 GPUParticles2D**：
## ① 这个演出要**贴着六边形的斜视角**——粒子轨道是压扁的椭圆（`ORBIT_SQUASH`），
##    而不是正圆，粒子系统要做到这点得写自定义 shader，画反而更直接；
## ② 一次只可能有一个趋化源（PRD 明文），粒子总数固定 27 个，手画的开销可以忽略；
## ③ 手画的轨道是**纯函数**（`particle_at()` / `frame_pos()`），无头测试能直接核对
##    「粒子没跑出格子」「都落在整数像素上」这种回归，粒子系统只能靠眼睛看。
##
## 颜色走免疫青（它是免疫方的技能），核心一组脉动的菱形表示「还在生效」；
## 剩 1 回合时整体转成暖色并加快转速 —— 玩家不用去读日志也知道它快没了。
## 想看效果：`tests/preview_chemo.gd`（真渲染，连拍几帧）。
class_name CWChemoFx
extends Node2D

## 轨道：三层同心，各 9 个粒子。层数少一点、每层粒子多一点，
## 转起来才像「一股气流」而不是「几个点」。
const RINGS := 3
const PER_RING := 9
const ORBIT_R: Array[float] = [16.0, 24.0, 32.0]   ## 各层半径（像素，格子外接圆约 32）
const ORBIT_SQUASH := 0.52               ## 纵向压扁：六边形是斜视角，正圆会显得「立起来」
## 各层角速度（弧度/秒）；正负交替 = 剪切感，更像漩涡
const ORBIT_SPEED: Array[float] = [1.9, -1.35, 0.95]
## 各层整体上抬：内层高、外层低 —— 拉开一点才有**漏斗**的立体感（龙卷风是上宽下窄的锥）。
## 三层整体比初版高 5 像素（Kevin 2026-09-06 看预览：「有点穿模，往上抬升一点点」——
## 外层最低点原来落到格心下 14.6，压到格子前缘；现在是 9.6，仍在顶面内）
const RING_LIFT: Array[float] = [22.0, 14.5, 7.0]
const DOT_PX: Array[int] = [3, 2, 2]     ## 各层粒子方块边长（像素）：内层大，透视上离眼睛近

const PIX_FPS := 12.0                    ## 逐帧步进：每秒 12 格，像素动画的常用帧率
const TRAIL := 3                         ## 每个粒子拖 3 个残影 = 前 3 格时间的位置
const ALPHA_STEPS: Array[float] = [1.0, 0.6, 0.35, 0.15]   ## 本体与各段残影的透明度档位

const CORE_GLOW_R: Array[int] = [4, 5]   ## 核心外圈菱形「半径」（像素），脉动在两档之间跳
const CORE_R := 2                        ## 核心内圈菱形半径
const CORE_PULSE_HZ := 2.0               ## 外圈每秒跳两次档

const COLOR_LIVE := Color("30d1fa")      ## 免疫青：生效中
const COLOR_LAST := Color("ffb03a")      ## 暖橙：只剩最后一回合
const LAST_SPEEDUP := 1.6                ## 最后一回合转速倍率

var _t := 0.0
var _last_round := false                 ## 只剩 1 回合？由 CWMatch 每帧喂


func _ready() -> void:
	z_as_relative = false


## CWMatch 每帧调：位置、层级、是否最后一回合，全由对局那边算好喂进来。
## 自己不去读 game —— 演出层不碰引擎状态（架构约定 #11）。
func sync(delta: float, at: Vector2, z: int, last_round: bool) -> void:
	_t += delta * (LAST_SPEEDUP if last_round else 1.0)
	position = at
	z_index = z
	_last_round = last_round
	queue_redraw()


## 第 ring 层第 idx 个粒子在 t 时刻的（连续）轨道位置，相对本节点原点。
## **纯函数**：回归靠它核对轨道不越界、压扁比例对得上，不用真渲染。
static func particle_at(ring: int, idx: int, t: float) -> Vector2:
	var phase := TAU * idx / PER_RING + t * ORBIT_SPEED[ring]
	return Vector2(cos(phase) * ORBIT_R[ring],
		sin(phase) * ORBIT_R[ring] * ORBIT_SQUASH - RING_LIFT[ring])


## t 时刻落在第几格时间（整数帧号）。同一格里的任何时刻画出来都一样。
static func frame_of(t: float) -> int:
	return int(floor(t * PIX_FPS))


## 同一格时间量化回秒（frame_of 的逆运算，取格子起点）。
static func quantize(t: float) -> float:
	return frame_of(t) / PIX_FPS


## 第 frame 格时间，粒子本体落在哪个像素：轨道位置取整。**纯函数**，回归核对「都是整数、不越界」。
## 帧号用整数传，避免「秒 - k/12」在浮点里差一点点掉到前一格。
static func frame_pos(ring: int, idx: int, frame: int) -> Vector2i:
	return Vector2i(particle_at(ring, idx, frame / PIX_FPS).round())


## t 时刻的粒子像素 = 该时刻所在格的 frame_pos。
static func pixel_at(ring: int, idx: int, t: float) -> Vector2i:
	return frame_pos(ring, idx, frame_of(t))


func _draw() -> void:
	var tint: Color = COLOR_LAST if _last_round else COLOR_LIVE
	var frame := frame_of(_t)
	var core := Vector2i(0, -int(round(RING_LIFT[0])))
	## 核心：两层菱形 —— 外圈在两档半径之间跳（脉动），内圈实
	var big: bool = int(floor(frame / PIX_FPS * CORE_PULSE_HZ)) % 2 == 0
	_draw_diamond(core, CORE_GLOW_R[1] if big else CORE_GLOW_R[0], Color(tint, 0.3))
	_draw_diamond(core, CORE_R, Color(tint, 0.8))
	## 三层粒子，每个带 TRAIL 段残影：残影 = 前 k 格时间的位置，档位递减、方块缩小
	for ring in RINGS:
		for idx in PER_RING:
			for k in range(TRAIL, -1, -1):
				var p: Vector2i = frame_pos(ring, idx, frame - k)
				var s: int = maxi(1, DOT_PX[ring] - k)
				_draw_px_square(p, s, Color(tint, ALPHA_STEPS[k]))


## 以 center 为中心、边长 s 的整数方块（s 为偶数时向左上偏半格 —— 反正都在整数格上）
func _draw_px_square(center: Vector2i, s: int, color: Color) -> void:
	var tl := Vector2(center) - Vector2(floor(s / 2.0), floor(s / 2.0))
	draw_rect(Rect2(tl, Vector2(s, s)), color)


## 菱形：逐行画 1 像素高的横条，第 y 行半宽 = r - |y|
func _draw_diamond(center: Vector2i, r: int, color: Color) -> void:
	for y in range(-r, r + 1):
		var hw := r - absi(y)
		draw_rect(Rect2(Vector2(center.x - hw, center.y + y), Vector2(hw * 2 + 1, 1)), color)
