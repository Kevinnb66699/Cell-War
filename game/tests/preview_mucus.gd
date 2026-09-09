extends SceneTree
## 【黏液破裂】引爆演出的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：液浪是贴地的椭圆（y 压 0.6），「躺平了还是立着」代码层面看不出来；
## 而这只演出的全部意思就在「贴着地面推出去」。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_mucus.gd -- <输出.png>
const WARMUP := 12
const SHOTS := [0.3, 0.9, 1.5]     ## 憋住 / 推到一半 / 快散完
var _out := "user://mucus.png"
var _board: Node2D
var _fx: CWMucusFx
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
	_fx = CWMucusFx.new()
	_fx.z_index = _board.Z_OVER_BOARD   ## 和 match.gd 的装配保持一致
	_board.add_child(_fx)


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_fx.play(_board.tile_center(Vector2i.ZERO))
	_fx.sync(d)
	_t += d
	if _t < SHOTS[_shot]:
		return false
	root.get_texture().get_image().save_png(
		_out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot)
	_shot += 1
	return _shot >= SHOTS.size()
