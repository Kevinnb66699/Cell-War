extends SceneTree
## 【I-标记】光环范围常驻粒子的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：轨道与取整由 `t_mark_aura` 验着，但那验的是「点都在整数像素上、
## 没跑出范围」。**铺满 19 格之后整体密度合不合适**，代码层面验不了 ——
## 这只演出的全部难点就在「稀疏到不淹没棋盘，又密到看得出是一片」，只能把图摆出来看。
##
## 画法：中心放一只树突，把它 2 格内的格子都画成范围；连拍几帧看流动方向对不对。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_mark_aura.gd -- <输出.png>
const WARMUP := 12
const SHOTS := [0.0, 0.5, 1.0]     ## 连拍：单帧看不出粒子是朝树突飘的

var _out := "user://mark_aura.png"
var _board: Node2D
var _fx: CWMarkAuraFx
var _frames := 0
var _t := 0.0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	root.add_child(_board)
	_fx = CWMarkAuraFx.new()
	_board.add_child(_fx)


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	## 中心一只树突，2 格内全部进范围
	var at := Vector2i.ZERO
	var tiles: Array = []
	for c in CWData.all_coords():
		var dist := CWData.hex_dist(c, at)
		if dist > 0 and dist <= CWData.MARK_RANGE:
			tiles.append({ "pos": _board.tile_center(c),
				"z": _board.tile_z(c, _board.Z_MARK) })
	_fx.sync(d, [{ "origin": _board.tile_center(at), "tiles": tiles }])
	_t += d
	if _t < SHOTS[_shot]:
		return false
	var img := root.get_texture().get_image()
	var path := _out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot
	img.save_png(path)
	print("已保存 ", path)
	_shot += 1
	return _shot >= SHOTS.size()
