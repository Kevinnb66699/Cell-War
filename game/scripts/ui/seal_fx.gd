## B【效应应答-中和抗体】的封禁演出。照 tools/art-preview 的 **A 版**（团队已选）：
## Y 形抗体从 B 细胞飞向每个目标，抵达后在目标身上立起**两个反向绕行的封禁环**。
##
## 这只演出**两半都要**：
##   · 一次性的投递（`play`）—— 抗体飞出去那一下；
##   · 常驻的封禁环（`sync` 的 sealed 列表）—— 压制持续 2 个世界回合，
##     期间那些癌细胞的种类技能与永久卡是失效的，盘面上得看得出来。
##     常驻这半读的是引擎写下的 `neutral_until`，不在这儿重算「谁挨着健康组织」
##     （那是规则，表现层不许抄第二份）。
##
## 目标一个个错开 0.12 秒出发（选稿如此）：同时到达会读成一次群体特效，
## 错开才看得出「一个一个封」。
class_name CWSealFx
extends Node2D

const STAGGER := 0.12        ## 每个目标晚出发多久
const FLIGHT := 0.95         ## 一枚抗体飞多久
const RING_R := 20.0         ## 封禁环半径
const RING_SQUASH := 0.48    ## 环的压扁比
const TILTS := [-0.7, 0.7]   ## A 版两个环各自的倾角
const RUNES := 4             ## 每个环上绕行的符点数
const INK_A := Color("7de3ff")   ## 一号环：抗体青
const INK_B := Color("b99cff")   ## 二号环：中和紫
const INK_FLY := Color("7de3ff") ## 飞行中的抗体
const INK_SPARK := Color("e7f7ff")

var _t := 0.0                ## 常驻环的相位；一直在走，不清零
var _fly := -1.0             ## 投递计时；< 0 = 没在投递
var _from := Vector2.ZERO
var _targets: Array[Vector2] = []
var _sealed: Array[Vector2] = []


func _init() -> void:
	visible = false


## 一次性投递：from = B 细胞，targets = 这次被封住的那几格
func play(from: Vector2, targets: Array[Vector2]) -> void:
	_from = from
	_targets = targets.duplicate()
	_fly = 0.0
	visible = true
	queue_redraw()


## 每帧：sealed = 此刻仍被压制的目标（现读 neutral_until，见 CWMatch._sync_seal）
func sync(delta: float, sealed: Array[Vector2]) -> void:
	_t += delta
	_sealed = sealed
	if _fly >= 0.0:
		_fly += delta
		if _fly > FLIGHT + STAGGER * float(maxi(_targets.size(), 1)):
			_fly = -1.0
			_targets.clear()
	visible = _fly >= 0.0 or not _sealed.is_empty()
	if visible:
		queue_redraw()


func _draw() -> void:
	## 常驻环里，**抗体还没飞到的那几格先不画** —— 引擎是一瞬间把压制全部记上的，
	## 照着状态直接画的话三个环会在抗体起飞前就亮起来，投递那一拍就白演了
	var inflight := _inflight()
	for at in _sealed:
		if not inflight.has(at):
			_seal(at)
	if _fly < 0.0:
		return
	for i in _targets.size():
		var p := clampf((_fly - float(i) * STAGGER) / FLIGHT, 0.0, 1.0)
		if p < 1.0:
			_antibody(_from.lerp(_targets[i], p), 4.0, INK_FLY)


## 此刻还在半路上的目标（键是落点，给 _draw 拿来遮住对应的环）
func _inflight() -> Dictionary:
	var out := {}
	if _fly < 0.0:
		return out
	for i in _targets.size():
		if (_fly - float(i) * STAGGER) / FLIGHT < 1.0:
			out[_targets[i]] = true
	return out


## 立在目标身上的两个环：一个顺一个逆，符点反向绕行 —— 「双向封禁」的读法来源
func _seal(at: Vector2) -> void:
	for i in TILTS.size():
		var tilt: float = TILTS[i]
		var ink: Color = INK_A if i == 0 else INK_B
		draw_polyline(_tilted_ring(at, tilt), ink, 1.0, false)
		for j in RUNES:
			var a := fmod(_t * (1.0 if i == 0 else -1.0) * 2.0
				+ float(j) * TAU / float(RUNES) + TAU * 10.0, TAU)
			var q := at + _tilt(Vector2(cos(a) * RING_R, sin(a) * RING_R * RING_SQUASH), tilt)
			draw_rect(Rect2(q.round(), Vector2(2, 2)), ink, true)
			if j == 0:
				_spark(q, INK_SPARK)


func _tilted_ring(at: Vector2, tilt: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 33:
		var a := TAU * float(i) / 32.0
		pts.append(at + _tilt(Vector2(cos(a) * RING_R, sin(a) * RING_R * RING_SQUASH), tilt))
	return pts


static func _tilt(v: Vector2, tilt: float) -> Vector2:
	return Vector2(v.x * cos(tilt) - v.y * sin(tilt), v.x * sin(tilt) + v.y * cos(tilt))


## Y 形抗体：一竖两撇，最省像素又一眼认得出是抗体
func _antibody(at: Vector2, size: float, ink: Color) -> void:
	draw_line(at, at + Vector2(0.0, size), ink, 2.0, false)
	draw_line(at, at + Vector2(-size, -size), ink, 2.0, false)
	draw_line(at, at + Vector2(size, -size), ink, 2.0, false)


func _spark(p: Vector2, ink: Color) -> void:
	draw_line(p + Vector2(-2.0, 0.0), p + Vector2(2.0, 0.0), ink, 1.0, false)
	draw_line(p + Vector2(0.0, -2.0), p + Vector2(0.0, 2.0), ink, 1.0, false)
