extends SceneTree
## 代谢核心 / 骨髓的「积累进度外圈」对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：进度对不对 `t_store_ring` 已经验过了，但那验的是
## 「算式给了 0.5、shader 收到了 0.5」。**收到之后画成什么样**，代码层面验不了 ——
## 环从哪头长、2px 够不够粗、暗槽会不会糊成一团，只能把图摆出来看
## （方案定稿是 PIL 画的示意图，那不等于 shader 真跑对了）。
##
## 画法：9 个特殊组织格按 0 / 0.25 / 0.5 / 0.75 / 1.0 五档铺开，
## 核心与骨髓各一排，再补一格癌变核心。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_store_ring.gd -- <输出.png>
const WARMUP := 12

var _out := "user://store_ring.png"
var _board: Node2D
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	root.add_child(_board)


## 摆盘**必须等 `_ready()` 跑完**：棋盘的 `map` 是在那里建的，
## 在 `_initialize` 里调 set_store() 会全部静默返回（第一版就是这么白跑一趟的）。
func _setup() -> void:
	var fracs := [0.0, 0.25, 1.0]
	for i in CWData.CORES.size():
		var c: Vector2i = CWData.CORES[i]
		if i == 2:
			_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.CORE)
		_board.set_store(c, fracs[i], CWData.Special.CORE)
	var mf := [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0, 0.5, 1.0]
	for i in CWData.MARROWS.size():
		_board.set_store(CWData.MARROWS[i], mf[i], CWData.Special.MARROW)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_setup()
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	img.save_png(_out)
	print("已保存 ", _out)
	return true
