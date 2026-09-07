extends SceneTree
## 棋盘左侧事件列表的预览图（Kevin 2026-09-07：右上角那条通报删掉，改成这一列）——
## 给人看的工具，不是测试。左边一份收着、右边一份展开着（点开某条看全文的样子）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_feed.gd -- <输出.png>
const WARMUP := 30

var _out := "user://feed.png"
var _frames := 0
var _feeds: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	## 棋盘垫在底下，好看清这一列压住了多少
	var board: Node2D = load("res://scenes/Board.tscn").instantiate()
	board.position = Vector2(348, 300)
	root.add_child(board)

	_text(Vector2(16, 4), "棋盘左侧的事件列表（顶替原来右上角那条通报）", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	for i in 2:
		var f := CWFeed.new()
		root.add_child(f)
		_feeds.append(f)


func _text(at: Vector2, s: String, size: int, color: Color) -> void:
	var l := CWStyle.label(s, size, color)
	l.position = at
	root.add_child(l)


func _process(_delta: float) -> bool:
	_frames += 1
	## 直接挂在 SceneTree root（Window）下的 Control 会被窗口自己的布局摆回去，
	## 所以每帧都按预览要的位置摆一次 —— 只是这张图的事，游戏里挂在 ui 层下不受影响
	for i in _feeds.size():
		(_feeds[i] as Control).position = Vector2(16 + i * 470, CWFeed.RECT.position.y)
	if _frames == 1:
		for f: CWFeed in _feeds:
			f.add_entry("世界事件", "世界事件【基质阻隔】：癌细胞移动能量花费翻倍（持续 2 回合）", CWStyle.CANCER)
			f.add_entry("抽卡", "免疫B 经由「基因表达」抽了 1 张", CWStyle.IMMUNE)
			f.add_entry("对手", "癌症A 打出【糖酵解爆发】", CWStyle.CANCER)
			f.add_entry("队友", "免疫B 打出【炎症趋化】", CWStyle.IMMUNE)
			f.add_entry("抽卡", "癌症B 经由「突变」抽了 1 张", CWStyle.CANCER)
		## 右边那份：点开最早那条（画在最下面的那条世界事件）—— 它最长，正好看清折行
		var f2: CWFeed = _feeds[1]
		f2._open = 0
		f2._layout()
		_text(Vector2(16, 46), "收着的样子", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		_text(Vector2(486, 46), "点开一条的样子", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		_text(Vector2(16, 240), "一条一行，越新的越靠上；最多留 %d 条，旧的自动挤掉。" % CWFeed.MAX_ROWS,
			CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		_text(Vector2(486, 240), "全文折行摊在那一条下面；点别处收起。",
			CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		_text(Vector2(486, 258), "全量仍在对局日志里（L）。", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
