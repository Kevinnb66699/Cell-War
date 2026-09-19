extends SceneTree
## 攻击大成功的金字（Kevin 2026-09-19）—— 给人看的工具，不是测试。
##
## 同一块棋盘上左右各一只结果气泡：左「攻击成功」（照旧的白字青边）、右「攻击大成功」（金字），
## 在盖章 / 闪光 / 收场三个时刻各截一帧：
##   godot --path game --script res://tests/preview/preview_crit_gold.gd -- <输出前缀>
## 落地 `<输出前缀>_0.png`（0.05 s，盖章刚落）/ `_1.png`（0.3 s，闪光 + 火花）/ `_2.png`（1.2 s，收场）
##
## **不能加 --headless**：要的就是真渲染。
const WARMUP := 12
const SHOTS := [0.05, 0.3, 1.2]
const LEFT := Vector2i(-2, 0)
const RIGHT := Vector2i(2, 0)

var _out := "user://crit_gold"
var _board: Node2D
var _toast: CWToast
var _frames := 0
var _t := -1.0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_toast = CWToast.new()
	root.add_child(_toast)


func _dice_rect(c: Vector2i) -> Rect2:
	## 照 CWUIBridge._dice_rect 的意思：骰子的外框在格子上方一百多像素；这里给个同尺寸的框
	var p: Vector2 = _board.position + _board.tile_center(c) * _board.scale.x
	return Rect2(p - Vector2(30, 60), Vector2(60, 60))


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_board.scale = Vector2(CWView.GAME_ZOOM, CWView.GAME_ZOOM)
		_board.position = Vector2(CWView.GAME_ANCHOR.x, 300.0) \
			- _board.tile_center(Vector2i.ZERO) * CWView.GAME_ZOOM
		_board.set_tissue(LEFT, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
		_board.set_tissue(RIGHT, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
		_toast.bubble_at("攻击成功", _dice_rect(LEFT), 5.0)
		_toast.bubble_crit_at("攻击大成功", _dice_rect(RIGHT), 5.0)
		_t = 0.0
		return false
	_t += delta
	if _shot < SHOTS.size() and _t >= float(SHOTS[_shot]):
		var path := "%s_%d.png" % [_out, _shot]
		var err := root.get_texture().get_image().save_png(path)
		print("已保存 %s（t=%.2f，err=%d）" % [path, _t, err])
		_shot += 1
	return _shot >= SHOTS.size()
