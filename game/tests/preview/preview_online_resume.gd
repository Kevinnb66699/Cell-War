extends SceneTree
## 大厅页的「回到对局」入口（issue #46）—— 给人看的工具，不是测试。
##
## 面板挂在主菜单同一槽位上，右侧是棋盘：照 `preview_online_lan.gd` 把棋盘 + 菜单机位一起画上
## （排版预览用平底色会骗人）。两张对照：
##   · `_before.png` 没有可回去的对局 —— 今天的大厅，自己那一局只写「观众 n/m」
##   · `_after.png`  有回程票 —— 房间码预填、状态行把话说在前头、自己那一行改写成「← 回到对局」
##
## 要看的三处：①状态行那一句**不出面板**（SIZE_LABEL，从 SLOT_X 起，右边到 538）；
## ②自己那一行与别的房间行等宽同色（它仍是一条普通的可点行，只是文案不同）；
## ③预填的房间码落在输入框里、没把「加入」挤走。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_online_resume.gd -- <输出前缀>
const WARMUP := 12
var _out := "user://online_resume"
var _board: Node2D
var _cam: Camera2D
var _panel: CWOnlinePanel
var _frames := 0

## 大厅里摆的几行：两间等人的房 + 一间正在打的（那间就是「我」刚退出来的那一局）
const MY_CODE := "3GMBAJ"
const WAITING := [
	{ "code": "K7Q2M4", "players": 4, "seated": 2, "humans": 2, "timer": 60, "host": "阿岚",
		"watchers": 0, "watch_max": 8, "watch_hands": false, "state": "waiting" },
	{ "code": "B9X1T0", "players": 6, "seated": 5, "humans": 3, "timer": 90, "host": "十二个字的昵称一二三四五",
		"watchers": 0, "watch_max": 8, "watch_hands": false, "state": "waiting" },
]
const LIVE := [
	{ "code": MY_CODE, "players": 4, "seated": 4, "humans": 2, "timer": 60, "host": "阿岚",
		"watchers": 2, "watch_max": 8, "watch_hands": false, "state": "playing" },
]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = Color("0d1620")
	bg.size = CWView.screen_size()
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_cam.make_current()
	var ui := CanvasLayer.new()
	root.add_child(ui)
	_panel = CWOnlinePanel.new()
	ui.add_child(_panel)


func _fill() -> void:
	_panel._lobby_rooms = WAITING.duplicate(true)
	_panel._lobby_live = LIVE.duplicate(true)
	_panel._compose_lobby()
	_panel._lobby_sel = _panel._first_room_row()
	_panel._repaint_lobby()


func _process(_d: float) -> bool:
	_frames += 1
	CWView.apply(_cam, _board, CWView.MENU_ZOOM, CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR)
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_panel.open()
		_panel.modulate.a = 1.0
		_panel._show_page(CWOnlinePanel.Page.LOBBY)
		_panel._roots[CWOnlinePanel.Page.LOBBY].modulate.a = 1.0
		_fill()
		return false
	if _frames == WARMUP + 4:
		root.get_texture().get_image().save_png(_out + "_before.png")
		## 有回程票：这三处跟着一起变（预填 / 状态行 / 自己那一行）
		_panel._resume = { "code": MY_CODE, "token": "0123456789abcdef" }
		_panel._hint_resume()
		_fill()
		return false
	if _frames == WARMUP + 8:
		root.get_texture().get_image().save_png(_out + "_after.png")
		return true
	return false
