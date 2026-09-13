extends SceneTree
## 普通攻击的撞击演出放大看（队友 PR #30）—— 给人看的工具，不是测试。
##
## 三列一张图，同一场撞击停在三个时刻（冲上去 / 接触 / 收场）；两行分别是
## 「目标活下来」（攻击者弹回原格）和「目标被打死」（攻击者进格、尸体被撞飞）。
## 细胞的摆法照抄 CWMatch（脚底 = 格顶面中心 + CELL_FOOT_DY），演出层每列各 sync 一次就停住。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_attack_fx.gd -- <输出前缀>
const WARMUP := 12
const SETTLE := 4
const COLS := 3
const COL_W := 320
const COL_H := 270
const ZOOM := 2.0
const SHOTS := [0.16, 0.26, 0.5]
const FROM := Vector2i(-1, 0)
const TO := Vector2i(0, 0)
var _out := "user://attack_fx"
var _frames := 0
var _settle := 0
var _done := false
var _cols: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]


## 一格棋盘 + 一条停在 t 的撞击演出。killed = 目标被打死那一版
func _column(t: float, killed: bool) -> Node2D:
	var board: Node2D = load("res://scenes/Board.tscn").instantiate()
	board.scale = Vector2(ZOOM, ZOOM)
	return board


func _fill(board: Node2D, t: float, killed: bool) -> void:
	board.set_tissue(TO, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
	var fx: Node2D = preload("res://scripts/ui/attack_fx.gd").new()   ## 没有 class_name（要走热更）
	fx.z_index = board.Z_OVER_BOARD
	board.add_child(fx)
	var foot := Vector2(0, CWMatch.CELL_FOOT_DY)
	fx.play({ "cid": 0, "target_id": 1, "entered": killed, "target_alive": not killed,
			"attacker_alive": true, "hit": true },
		board.tile_center(FROM) + foot, board.tile_center(TO) + foot,
		CWMatch.IMMUNE_ART[CWData.ImmuneType.BASIC], CWMatch.CANCER_ART[CWData.CancerType.MELANOMA])
	fx.sync(t)


func _build() -> void:
	for row in 2:
		for k in COLS:
			var holder := SubViewportContainer.new()
			holder.position = Vector2(k * COL_W, row * COL_H)
			holder.size = Vector2(COL_W, COL_H)
			var vp := SubViewport.new()
			vp.size = Vector2i(COL_W, COL_H)
			vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			holder.add_child(vp)
			var board := _column(float(SHOTS[k]), row == 1)
			vp.add_child(board)
			root.add_child(holder)
			board.position = Vector2(COL_W / 2.0, COL_H / 2.0) - board.tile_center(TO) * ZOOM
			_fill(board, float(SHOTS[k]), row == 1)
			_cols.append(holder)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _settle > 0:
		_settle -= 1
		if _settle == 0:
			root.get_texture().get_image().save_png(_out + ".png")
			return true
		return false
	if _done:
		return false
	_build()
	_done = true
	_settle = SETTLE
	return false
