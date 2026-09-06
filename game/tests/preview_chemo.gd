extends SceneTree
## 趋化源漩涡（像素风）的预览图 —— 给人看的工具，不是测试。
##
## 像素风对不对（有没有半透明的反锯齿边、方块有没有落在整数格上、逐帧步进看不看得出）
## 只有真渲染才看得出来。画法：棋盘上摆两个趋化源 —— 左边生效中（青），
## 右边最后一回合（暖橙、转得快），按参数给的时刻连拍几帧（步进要连拍才看得见）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_chemo.gd -- <输出.png> [秒数，逗号分隔连拍]
## 文件名自动加后缀 `_0.3.png`。
const WARMUP := 10

var _out := "user://chemo.png"
var _shots: Array = [0.3]
var _board: Node2D
var _live := CWChemoFx.new()
var _last := CWChemoFx.new()
var _frames := 0
var _t := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_shots.clear()
		for s in args[1].split(",", false):
			_shots.append(float(s))
	_shots.sort()
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	root.add_child(_board)
	## 和对局里一样挂在棋盘层（CWMatch 也是 board.add_child），位置用棋盘局部坐标
	_board.add_child(_live)
	_board.add_child(_last)


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	_t += delta
	var a := Vector2i(-2, 0)
	var b := Vector2i(2, 0)
	_live.sync(delta, _board.tile_center(a), _board.tile_z(a, _board.Z_MARK), false)
	_last.sync(delta, _board.tile_center(b), _board.tile_z(b, _board.Z_MARK), true)
	if _shots.is_empty() or _t < float(_shots[0]):
		return false
	var at: float = _shots.pop_front()
	var path := "%s_%s.png" % [_out.trim_suffix(".png"), str(at)]
	var err := root.get_texture().get_image().save_png(path)
	print("已保存 %s (err=%d)" % [path, err])
	return _shots.is_empty()
