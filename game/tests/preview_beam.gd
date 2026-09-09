extends SceneTree
## 【Excalibur】双螺旋光束的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：选稿里光束只往右打，对局里六个方向都合法，
## 螺旋是按 from→to 的法线重算的 —— 「斜着打出去还像不像双螺旋」只能看图。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_beam.gd -- <输出.png>
const WARMUP := 12
const SHOTS := [0.4, 1.0, 1.6]     ## 蓄力 / 推出去 / 侧向波及在炸
const FROM := Vector2i(-3, 1)
const TO := Vector2i(3, 1)
const SPLASH := [Vector2i(0, 0), Vector2i(1, 2), Vector2i(-1, 1)]
var _out := "user://beam.png"
var _board: Node2D
var _fx: CWBeamFx
var _frames := 0
var _t := 0.0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 260)
	root.add_child(_board)
	_fx = CWBeamFx.new()
	_fx.z_index = _board.Z_OVER_BOARD
	_board.add_child(_fx)


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		var pts: Array[Vector2] = []
		for c: Vector2i in SPLASH:
			pts.append(_board.tile_center(c))
		_fx.play(_board.tile_center(FROM), _board.tile_center(TO), pts)
	_fx.sync(d)
	_t += d
	if _t < SHOTS[_shot]:
		return false
	root.get_texture().get_image().save_png(
		_out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot)
	_shot += 1
	return _shot >= SHOTS.size()
