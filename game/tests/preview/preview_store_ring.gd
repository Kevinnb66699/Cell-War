extends SceneTree
## 代谢核心 / 骨髓的「积累进度外圈」对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：进度对不对 `t_store_ring` 已经验过了，但那验的是
## 「算式给了 0.5、shader 收到了 0.5」。**收到之后画成什么样**，代码层面验不了 ——
## 环从哪头长、2px 够不够粗、暗槽会不会糊成一团，只能把图摆出来看
## （方案定稿是 PIL 画的示意图，那不等于 shader 真跑对了）。
##
## 画法：9 个特殊组织格按 0 / 0.25 / 0.5 / 0.75 / 1.0 五档铺开，核心与骨髓各一排。
##
## **癌变格必须给到不满的进度**（2026-09-14）：环由「暗槽 + 亮圈」两张贴图叠出来，
## 进度 1.0 时亮圈把暗槽整圈盖住 —— 这一版之前癌变核心正是钉在 1.0，
## 于是换掉暗槽贴图，渲出来一个像素都不变。癌变骨髓那时更是一格都没摆。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_store_ring.gd -- <输出.png>
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
	## 癌变那格（i == 2）给 0.25：暗槽露得最多，换了底色一眼看得出来
	var fracs := [0.0, 1.0, 0.25]
	for i in CWData.CORES.size():
		var c: Vector2i = CWData.CORES[i]
		if i == 2:
			_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.CORE)
		_board.set_store(c, fracs[i], CWData.Special.CORE,
			CWData.Tissue.CANCER if i == 2 else CWData.Tissue.HEALTHY)
	## 骨髓要连**贴图**一起摆：2026-09-08 起有卡 / 空仓是两张图，
	## 只看环的话看不出这一对组合起来是什么样
	var mf := [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0, 0.5, 1.0]
	var stocked := [false, false, false, true, false, true]
	## 最后两格摆成癌变（一格空仓 0.5、一格有卡满仓）—— 癌变骨髓的环此前一格都没画过
	for i in CWData.MARROWS.size():
		var tis: int = CWData.Tissue.CANCER if i >= 4 else CWData.Tissue.HEALTHY
		_board.set_tissue(CWData.MARROWS[i], tis, CWData.Special.MARROW, stocked[i])
		_board.set_store(CWData.MARROWS[i], mf[i], CWData.Special.MARROW, tis)


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
