extends SceneTree
## 【连续吞噬】每一口的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这只演出的意思全在「连得越多越有劲」——
## 粒子密度随层数涨得够不够看得出来，只能三档摆一起看。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_chain.gd -- <输出.png>
const WARMUP := 12
const LEVELS := [1, 2, 3]          ## 三档各拍一张（连了 1 / 2 / 3 口）
const AT := 0.25                   ## 每张都取「咬下去 0.25 秒」那一帧
var _out := "user://chain.png"
var _board: Node2D
var _fx: CWChainFx
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
	_fx = CWChainFx.new()
	_fx.z_index = _board.Z_OVER_BOARD
	_board.add_child(_fx)


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _t == 0.0:
		_fx.play(_board.tile_center(Vector2i.ZERO), LEVELS[_shot])
	_fx.sync(d)
	_t += d
	if _t < AT:
		return false
	root.get_texture().get_image().save_png(
		_out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot)
	_shot += 1
	_t = 0.0
	return _shot >= LEVELS.size()
