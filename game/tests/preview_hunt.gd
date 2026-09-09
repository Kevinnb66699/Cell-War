extends SceneTree
## 【免疫猎杀】捕获准星的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：准星画在棋盘层上，而棋盘是按排分 z_index 的
## （board.gd 那段 z 约定）。「它到底盖在格子上面还是掉到棋盘后面」代码层面看不出来 ——
## 合进来的第一版就是没设 z，整只沉在格子底下，只从格缝里漏出几个像素
## （骰子 2026-08-27 栽的是同一个坑）。
##
## 画法：把准星打在棋盘中下部的一格（那里前排格子的 z 最大，最容易压住它），
## 连拍三帧看收缩过程 —— 搜索青 → 捕获粉。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_hunt.gd -- <输出.png>
const WARMUP := 12
const SHOTS := [0.2, 0.8, 1.4]     ## 单帧看不出「收缩」，也撞不上换色那一下

var _out := "user://hunt.png"
var _board: Node2D
var _fx: CWHuntFx
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
	_fx = CWHuntFx.new()
	_fx.z_index = _board.Z_OVER_BOARD   ## 和 match.gd 的装配保持一致
	_board.add_child(_fx)


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_fx.play(_board.tile_center(Vector2i(0, 1)))
	_fx.sync(d)
	_t += d
	if _t < SHOTS[_shot]:
		return false
	var img := root.get_texture().get_image()
	var path := _out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot
	img.save_png(path)
	print("已保存 ", path)
	_shot += 1
	return _shot >= SHOTS.size()
