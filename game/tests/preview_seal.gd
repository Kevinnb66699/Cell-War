extends SceneTree
## 【中和抗体】投递 + 封禁环的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：两个环是倾斜压扁的椭圆、符点反向绕行，
## 「读不读得出是两个环在反着转」只能看动图/连拍，代码层面验不了。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_seal.gd -- <输出.png>
const WARMUP := 12
const SHOTS := [0.4, 1.1, 2.0]     ## 抗体在飞 / 陆续封上 / 全封住只剩环在转
const TARGETS := [Vector2i(1, 0), Vector2i(2, -1), Vector2i(0, 2)]
var _out := "user://seal.png"
var _board: Node2D
var _fx: CWSealFx
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
	_fx = CWSealFx.new()
	_fx.z_index = _board.Z_OVER_BOARD
	_board.add_child(_fx)


func _sealed() -> Array[Vector2]:
	## 常驻那半在真对局里现读 game.neutralized；这里手摆三格
	var out: Array[Vector2] = []
	for c: Vector2i in TARGETS:
		out.append(_board.tile_center(c))
	return out


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_fx.play(_board.tile_center(Vector2i(-2, 1)), _sealed())
	## 封禁环在压制期间一直在，所以每帧都把「还封着谁」喂进去
	_fx.sync(d, _sealed())
	_t += d
	if _t < SHOTS[_shot]:
		return false
	root.get_texture().get_image().save_png(
		_out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot)
	_shot += 1
	return _shot >= SHOTS.size()
