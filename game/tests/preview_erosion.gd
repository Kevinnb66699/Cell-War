extends SceneTree
## 【E-侵蚀】过场的方向对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：方向弄反了不会报任何错，只会让玩家看见癌从**空的那一侧**
## 漫过来。代码层面已经验过两道（美术图的癌变像素重心 vs 轴向→像素推导、
## `t_erosion_fx` 的帧序与下标），但这两道验的都是「我以为的对应」自洽，
## 验不了「我以为的对应」本身对不对 —— 那只能把图摆出来看。
##
## 画法：中心一圈六格各演一个方向，**并且把「癌从哪来」的那一格真的画成癌组织**。
## _cells 每项是 [演过场的格, 方向下标, 源头格]。
## 对的话，每一格的癌变部分都朝着它那个癌邻居；错的话一眼就看出是背着的。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_erosion.gd -- <输出.png>
const WARMUP := 10
const CANCER_TEX = preload("res://assets/art/tissue_cancer.png")

var _out := "user://erosion.png"
var _board: Node2D
var _fx := CWErosionFx.new()
var _cells: Array = []      ## [格子, 方向下标]
var _frames := 0
var _t := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	root.add_child(_board)
	## 中心的六个邻居各演一个方向：坐标 = 中心 + DIRS[i]，
	## 它的「来源」= 再往外一格（也就是 DIRS[i] 方向上的下一格），把那格画成癌。
	for i in CWData.DIRS.size():
		var at: Vector2i = CWData.DIRS[i] * 2
		var src: Vector2i = at + CWData.DIRS[i]
		if not CWData.is_on_board(at) or not CWData.is_on_board(src):
			continue
		_cells.append([at, i, src])
		_fx.play(at, i)


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	_t += delta
	## 停在第一帧：过场只有 0.32 秒，连拍两帧要起两次 Godot，不值当。
	## 想看第二帧就把下面这行的 0.0 改成 CWErosionFx.FRAME_TIME。
	## 源头那格画成癌 —— **必须放在 _process 里**：_initialize() 跑的时候
	## Board._ready() 还没建出 map，那时调 set_tile_tex 会静默什么也不做。
	for e in _cells:
		_board.set_tile_tex(e[2], CANCER_TEX)
		var tex: Texture2D = _fx.frame_of(e[0])
		if tex != null:
			_board.set_tile_tex(e[0], tex)
	if _t < 0.25:
		return false
	await_capture()
	return true


func await_capture() -> void:
	var img := root.get_texture().get_image()
	img.save_png(_out)
	print("已保存 ", _out)
