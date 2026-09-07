extends SceneTree
## 棋盘左侧出牌列的预览图（Kevin 2026-09-07：右上角那条通报删掉，改成左边一列缩小的真卡）——
## 给人看的工具，不是测试。棋盘按对局机位摆，好看清这一列一格都没压着。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_feed.gd -- <输出.png>
const WARMUP := 40

var _out := "user://feed.png"
var _frames := 0
var _feed: CWFeed
var _board: Node2D
var _cam: Camera2D
var _ui: CanvasLayer
var _fixed: Array = []


## 界面一律挂 CanvasLayer：挂在 root 下会跟着 Camera2D 的画布变换一起跑掉
func _pin(c: Control, at: Vector2) -> Control:
	_ui.add_child(c)
	c.position = at
	_fixed.append([c, at])
	return c


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_ui = CanvasLayer.new()
	root.add_child(_ui)
	## 迷你日志（现状就有）也画个壳，好看清两者连成左边一列
	var hint := Panel.new()
	hint.add_theme_stylebox_override("panel", CWStyle.box(0.35, Color("0a1018cc")))
	hint.size = Vector2(300, 52)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pin(hint, Vector2(16, 16))
	_pin(CWStyle.label("对局日志  L", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), Vector2(23, 20))
	## 右侧竖条只画个壳，标出棋盘两边各让了多少
	var strip := Panel.new()
	strip.add_theme_stylebox_override("panel", CWStyle.box(0.25, Color("0a1018aa")))
	strip.size = Vector2(CWView.PANEL_WIDTH, 540)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pin(strip, Vector2(960 - CWView.PANEL_WIDTH, 0))
	_pin(CWStyle.label("右侧竖条", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		Vector2(960 - CWView.PANEL_WIDTH + 12, 12))


func _process(_delta: float) -> bool:
	_frames += 1
	CWView.apply(_cam, _board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
	for f in _fixed:
		(f[0] as Control).position = f[1]
	if _frames == 1:
		_feed = CWFeed.new()
		_pin(_feed, CWFeed.RECT.position)
		## 最早的先加：这一列越新的越靠上
		var deck := [
			["免疫抑制因子", "癌症B", CWData.Faction.CANCER, true],   ## 事件卡：底行「谁 + 事件卡」
			["自分泌生存信号", "癌症B", CWData.Faction.CANCER, false],
			["炎症趋化", "免疫B", CWData.Faction.IMMUNE, false],
			["糖酵解爆发", "癌症A", CWData.Faction.CANCER, false],
		]
		for d in deck:
			_feed.add_card(String(d[0]), String(d[1]), int(d[2]),
				CWCardInfo.describe(String(d[0]), int(d[2]), 0), bool(d[3]))
		_pin(CWStyle.label("← 打出的卡 / 抽到的事件卡 / 世界事件，越新的越靠上；点一张看全文",
			CWStyle.SIZE_LABEL, CWStyle.TEXT_HI), Vector2(70, 502))
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
