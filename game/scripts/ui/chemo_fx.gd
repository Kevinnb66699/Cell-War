## chemo_fx.gd —— 树突状细胞【I-趋化源】的场上演出：漩涡核心
##
## Kevin 2026-09-04 定的方向：「一个格子，然后周围有粒子绕着转，
## 有种漩涡核心 / 龙卷风的感觉」。
##
## **为什么用 `_draw()` 手画而不是 GPUParticles2D**：
## ① 这个演出要**贴着六边形的斜视角**——粒子轨道是压扁的椭圆（`ORBIT_SQUASH`），
##    而不是正圆，粒子系统要做到这点得写自定义 shader，画反而更直接；
## ② 一次只可能有一个趋化源（PRD 明文），粒子总数固定 18 个，手画的开销可以忽略；
## ③ 手画的轨道是**纯函数**（`particle_at()`），无头测试能直接核对「粒子没跑出格子」
##    这种回归，粒子系统只能靠眼睛看。
##
## 颜色走免疫青（它是免疫方的技能），核心一圈脉动光晕表示「还在生效」；
## 剩 1 回合时整体转成暖色并加快转速 —— 玩家不用去读日志也知道它快没了。
class_name CWChemoFx
extends Node2D

## 轨道：三层同心，各 6 个粒子。层数少一点、每层粒子多一点，
## 转起来才像「一股气流」而不是「几个点」。
const RINGS := 3
const PER_RING := 9                      ## 每层粒子数：够密才像气流，不像几个点
const ORBIT_R: Array[float] = [16.0, 24.0, 32.0]   ## 各层半径（像素，格子外接圆约 32）
const ORBIT_SQUASH := 0.52               ## 纵向压扁：六边形是斜视角，正圆会显得「立起来」
## 各层角速度（弧度/秒）；正负交替 = 剪切感，更像漩涡
const ORBIT_SPEED: Array[float] = [1.9, -1.35, 0.95]
## 各层整体上抬：内层高、外层低 —— 拉开一点才有**漏斗**的立体感（龙卷风是上宽下窄的锥）
const RING_LIFT: Array[float] = [17.0, 9.5, 2.0]
const DOT_R: Array[float] = [2.2, 1.7, 1.3]        ## 各层粒子半径：内层大，透视上离眼睛近

const CORE_R := 7.0                      ## 核心圆
const CORE_PULSE := 2.4                  ## 核心脉动（弧度/秒）
const TRAIL := 7                         ## 每个粒子拖几个残影：拖长一点，转速才看得出来
const TRAIL_STEP := 0.042                ## 残影之间相隔多少「秒」的轨道位置

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


## 第 ring 层第 idx 个粒子在 t 时刻的位置（相对本节点原点）。
## **纯函数**：回归靠它核对轨道不越界、压扁比例对得上，不用真渲染。
static func particle_at(ring: int, idx: int, t: float) -> Vector2:
	var phase := TAU * idx / PER_RING + t * ORBIT_SPEED[ring]
	return Vector2(cos(phase) * ORBIT_R[ring],
		sin(phase) * ORBIT_R[ring] * ORBIT_SQUASH - RING_LIFT[ring])


func _draw() -> void:
	var tint: Color = COLOR_LAST if _last_round else COLOR_LIVE
	## 核心：两层脉动圆 —— 外圈淡、内圈实，看着像有东西在往里吸
	var pulse := 0.5 + 0.5 * sin(_t * CORE_PULSE)
	draw_circle(Vector2(0, -RING_LIFT[0]), CORE_R * (1.35 + 0.25 * pulse),
		Color(tint, 0.13 + 0.07 * pulse))
	draw_circle(Vector2(0, -RING_LIFT[0]), CORE_R * (0.7 + 0.1 * pulse), Color(tint, 0.55))
	## 三层粒子，每个带一条向后的残影：残影越靠后越淡越小 = 运动方向一目了然
	for ring in RINGS:
		for idx in PER_RING:
			for k in range(TRAIL, -1, -1):
				var pos := particle_at(ring, idx, _t - k * TRAIL_STEP)
				var fade := 1.0 - float(k) / (TRAIL + 1)
				draw_circle(pos, DOT_R[ring] * (0.35 + 0.65 * fade),
					Color(tint, 0.85 * fade * fade))
