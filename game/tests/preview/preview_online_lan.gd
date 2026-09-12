extends SceneTree
## 联机面板的连接页与局域网页（Kevin 2026-09-12 局域网开服）—— 给人看的工具，不是测试。
##
## 面板挂在主菜单同一槽位上，右侧是棋盘：这里照 preview_config 的做法把棋盘 + 菜单机位一起画上
## （排版预览用平底色会骗人），两页各截一张：连接页（第三行「局域网」入口、地址框右边的「默认」）、
## 局域网页（端口 / 本机地址 / 两行提示 / 「开服并进入大厅」）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_online_lan.gd -- <输出前缀>
const WARMUP := 12
var _out := "user://online_lan"
var _board: Node2D
var _cam: Camera2D
var _panel: CWOnlinePanel
var _frames := 0
var _shot := 0


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


func _process(_d: float) -> bool:
	_frames += 1
	CWView.apply(_cam, _board, CWView.MENU_ZOOM, CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR)
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_panel.open()
		_panel.modulate.a = 1.0
		return false
	if _frames == WARMUP + 3:
		root.get_texture().get_image().save_png(_out + "_connect.png")
		_panel._show_page(CWOnlinePanel.Page.LAN)
		_panel._lan_ips.text = "192.168.1.5 · 10.0.0.7"   ## 无头机器上未必有局域网地址，摆两个看排版
		_panel._set_status("端口 8611 开不起来（Already in use），多半已被占用，换一个")
		return false
	## 切页有 PAGE_FADE 淡入，等它走完再截，不然截到一张半透明的
	if _frames == WARMUP + 3 + int(ceil(CWOnlinePanel.PAGE_FADE * 60.0)) + 4:
		root.get_texture().get_image().save_png(_out + "_lan.png")
		return true
	return false
