extends SceneTree
## 量一量：棋盘左侧那一列（迷你日志 / CWFeed）压到了几个格子（Kevin 2026-09-07 问的）。
## 给人看的量尺，不是测试。
##
## 跑：godot --headless --path game --script res://tests/archive/check_feed_overlap.gd
##
## board.map 的键是「行,列」下标而不是轴坐标（见 board.gd 的 axial_to_rc），
## 所以这里直接读它存的 position，别再走 tile_center()。
const TILE_W := 40.0   ## 六边形贴图 40×34（顶面 26 + 立面 8），按整张贴图算占位偏保守
const TILE_H := 34.0


var _board: Node2D
var _cam: Camera2D


## 摆好场面。**量在 _process 里做**：_initialize 期间 add_child 还没触发 _ready，
## board.map 是空的（同 preview_feed 那个「窗口自己摆位」的坑，都是这一阶段树还没搭完）
func _initialize() -> void:
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cam = Camera2D.new()
	root.add_child(_cam)


func _process(_delta: float) -> bool:
	var board := _board
	var cam := _cam
	CWView.apply(cam, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)

	var rects := {
		"迷你日志 CWLogHint": Rect2(16, 16, 300, 52),
		"出牌列 CWFeed     ": CWFeed.RECT,
	}
	var span := Rect2()
	var first := true
	var hit := {}
	var min_x := 1e9
	for name in rects:
		hit[name] = []
	for key in board.map:
		var p: Vector2 = board.map[key]["position"] - Vector2(0, board.TOP_FACE_DY)
		var c := CWView.board_to_screen(cam, p)
		var sz := Vector2(TILE_W, TILE_H) * CWView.GAME_ZOOM
		var r := Rect2(c - sz * 0.5, sz)
		span = r if first else span.merge(r)
		first = false
		min_x = minf(min_x, r.position.x)
		for name in rects:
			if (rects[name] as Rect2).intersects(r):
				(hit[name] as Array).append(key)
	print("棋盘 %d 格，屏幕包围盒 %s（左缘 %.1f，上缘 %.1f）"
		% [board.map.size(), span, span.position.x, span.position.y])
	for name in rects:
		var got: Array = hit[name]
		print("%s %s → 压住 %d 格%s" % [name, rects[name], got.size(),
			("" if got.is_empty() else "，例如 " + str(got.slice(0, 5)))])
	return true
