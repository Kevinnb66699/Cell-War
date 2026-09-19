extends SceneTree
## 新补的 ∞（U+221E）字形的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：字形闸 `t_font_coverage` 只守得住「这个码位在字库里」，
## 守不住「画出来像不像 ∞、糊不糊、和旁边的数字齐不齐腰」。点阵字形手画完
## 只能把它摆到真棋盘、真右栏机位上，按 CWStyle 的真字号看一眼
## （2026-09-19 Kevin：「补字形，如果没有相似字形，就用 INF」—— 像不像得看图定）。
##
## 摆位照抄 preview_feed.gd：真 Board.tscn + GAME 机位，右边让出 PANEL_WIDTH 的竖条，
## 三行样例就写在右栏里 —— 教程 S4 的「能量 ∞」正是在这个位置上屏的。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_infinity.gd -- <输出.png>
const WARMUP := 40

## 三行样例：单字、跟数字连写、跟中文连写 —— 三种都会在教程台词里出现
const LINES := ["∞", "∞ 3.0", "能量 ∞"]

var _out := "user://infinity.png"
var _frames := 0
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

	var left := 960.0 - CWView.PANEL_WIDTH
	var strip := Panel.new()
	strip.add_theme_stylebox_override("panel", CWStyle.box(0.25, Color("0a1018aa")))
	strip.size = Vector2(CWView.PANEL_WIDTH, 540)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pin(strip, Vector2(left, 0))

	## 每档字号各画一遍三行：20 是台词与数值的常规档，10 是最小档（糊不糊先在这里现形），
	## 30 那档一屏只出现一次，但 ∞ 真要顶上去当回合数旁的数值就是这个号
	var y := 14.0
	for size in [CWStyle.SIZE_BIG, CWStyle.SIZE_BODY, CWStyle.SIZE_LABEL]:
		_pin(CWStyle.label("字号 %d" % size, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
			Vector2(left + 12, y))
		y += 16.0
		for s in LINES:
			_pin(CWStyle.label(s, size, CWStyle.TEXT_HI), Vector2(left + 12, y))
			y += size + 6.0
		## 同高对照：∞ 该和数字齐腰，两行紧挨着才看得出高低差
		_pin(CWStyle.label("0123456789 ∞", size, CWStyle.TEXT), Vector2(left + 12, y))
		y += size + 16.0


func _process(_delta: float) -> bool:
	_frames += 1
	CWView.apply(_cam, _board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
	for f in _fixed:
		(f[0] as Control).position = f[1]
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
