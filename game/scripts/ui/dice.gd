class_name CWDice
extends ColorRect
## 掷骰演出（方案 D：着色器解析求交，2026-08-27 团队定）。
##
## **结果不是这里决定的。** value 由 `CWGame.rng` 先掷好、经 `CWBridge.show_roll()`
## 传进来，本节点只负责把骰子演到那一面上（架构约定 #2）。
## 翻滚圈数用本节点自己的 `randf()` 取随机，只影响观感，**绝不碰 `game.rng`** ——
## 所以同种子可复现和将来的锁步联机都不受影响。
##
## `play()` 是协程，动画播完才返回；引擎 await 它，因此结算会等演出结束。

const SHADER := preload("res://assets/shaders/dice.gdshader")

const YAW := 0.74    ## 绕世界竖轴偏航，让三个面同时可见（轮廓成六边形，和组织块同形）
const TILT := 0.62   ## 视角俯仰，贴近棋盘那套压扁投影

## 让指定点数朝上的静止姿态。这六个姿态都是 90° 的整数倍，
## 转完之后立方体在世界空间里是轴对齐的，YAW 再绕竖轴转不会改变哪一面朝上。
const REST := {
	1: Vector3(-PI / 2, 0, 0),
	2: Vector3(0, 0, PI / 2),
	3: Vector3(0, 0, 0),
	4: Vector3(PI, 0, 0),
	5: Vector3(0, 0, -PI / 2),
	6: Vector3(PI / 2, 0, 0),
}

const DIE_PX := 72.0      ## 骰子在屏幕上的边长，和 64px 的组织块相当
const DROP_PX := 210.0    ## 起始高度

@export var pixelate := false:   ## 打开后降到棋盘的像素密度，风格贴回像素棋盘
	set(v):
		pixelate = v
		if material != null:
			material.set_shader_parameter("pixelate", 1.0 if v else 0.0)

var _rest := Vector3.ZERO
var _spin := Vector3.ZERO
var _ground := Vector2.ZERO


func _ready() -> void:
	custom_minimum_size = Vector2(DIE_PX, DIE_PX)
	size = custom_minimum_size
	pivot_offset = size / 2.0
	color = Color(0, 0, 0, 0)          # 底色透明，画面全部由着色器出
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("pixelate", 1.0 if pixelate else 0.0)
	_apply_rot(Vector3.ZERO)
	visible = false


## 静止时立方体**底面中心**距方块顶边多少像素。
## 由着色器的相机参数反推：世界「下」(0,-1,0) 经俯仰后，
## 投影到 uv.y = -4·cos(TILT)/(sin(TILT)+8)（相机在 z=8、视线半宽系数 0.25，
## 见 dice.gdshader 的 fragment()），再映回 0..1 的 UV。
## **改着色器的相机参数，这里要跟着改** —— t_dice() 会盯住这个关系。
static func contact_y(px: float) -> float:
	var uv_y := -4.0 * cos(TILT) / (sin(TILT) + 8.0)
	return (1.0 - (uv_y + 1.0) * 0.5) * px


## 把骰子摆到棋盘上某一点（该格顶面中心，用 board.tile_center() 取）。
## 骰子按**落地点**的 y 参与深度排序，和组织块同一套规则（board.gd 里 z_index = y）：
## 这样前排组织块会正确盖住骰子底部，而骰子腾空时也不会忽前忽后地跳。
func place_at(ground: Vector2) -> void:
	_ground = ground
	z_index = int(ground.y)
	_sync_pos(0.0)


func _sync_pos(height: float) -> void:
	position = _ground - Vector2(size.x * 0.5, contact_y(size.y) + height)


## 播一次掷骰。value 是已经掷好的结果，本方法只负责演到它。
## sides = 6 或 3；fast 用于 AI 掷骰的加速档。
func play(value: int, sides: int, fast := false) -> void:
	_rest = REST[_face_for(value, sides)]
	# 圈数随机只为观感不重复，用的是节点自己的 randf()，不碰 game.rng
	_spin = Vector3(3.0 + randf() * 2.0, 1.0 + randf() * 2.0, randf() * 1.5)
	visible = true

	var tw := create_tween()
	# 线性推进，缓动和落地弹跳都在 _step() 里自己算 —— 抛物线不是单调的，交给 Tween 缓动会变形
	tw.tween_method(_step, 0.0, 1.0, 0.55 if fast else 1.3)
	await tw.finished

	_step(1.0)
	await get_tree().create_timer(0.35 if fast else 0.55).timeout
	visible = false


## d3 借用同一颗 d6 演：1→2、2→4、3→6，正好落在 1-2 / 3-4 / 5-6 三个色区里。
## （骰面究竟用点数还是符号是决策 ②，团队还没拍板；改这里即可。）
func _face_for(value: int, sides: int) -> int:
	return value if sides == 6 else clampi(value * 2, 1, 6)


func _step(t: float) -> void:
	var p := 1.0 - pow(1.0 - t, 3.0)                  # easeOutCubic
	_apply_rot(_rest + (1.0 - p) * _spin * TAU)
	_sync_pos(_height_at(t))


## 下落 → 弹两下 → 停住
func _height_at(t: float) -> float:
	if t >= 0.92:
		return 0.0
	if t < 0.52:
		var k := t / 0.52
		return DROP_PX * (1.0 - k * k)
	if t < 0.76:
		return DROP_PX * 0.21 * sin((t - 0.52) / 0.24 * PI)
	return DROP_PX * 0.062 * sin((t - 0.76) / 0.16 * PI)


## 骰子自身姿态：Rz → Ry → Rx，不含偏航与俯仰。
## 抽成静态函数是为了让无头测试能直接验证 REST 表 ——
## 这张表错了骰子会停在错误的面上，而那种错只有肉眼能发现。
static func euler_basis(e: Vector3) -> Basis:
	var b := Basis(Vector3(0, 0, 1), e.z)
	b = Basis(Vector3(0, 1, 0), e.y) * b
	return Basis(Vector3(1, 0, 0), e.x) * b


## 复合旋转：骰子姿态 → 世界竖轴偏航 → 视角俯仰。
## 顺序必须和着色器里的假设一致：着色器只做 `v * rot` 求逆变换，不再另加视角。
func _apply_rot(e: Vector3) -> void:
	var b := Basis(Vector3(0, 1, 0), YAW) * euler_basis(e)
	b = Basis(Vector3(1, 0, 0), TILT) * b
	material.set_shader_parameter("rot", b)
