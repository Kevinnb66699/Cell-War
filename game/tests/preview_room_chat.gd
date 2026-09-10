extends SceneTree
## 等待室（含右栏聊天）的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：左栏被席位排满（214..394 席位、398 未入座、438 按钮），
## 聊天只能摆右栏。「右栏那张板会不会和席位挤在一起、会不会出槽」只能看图。
##
## **背景必须画主菜单的棋盘装饰**（`CWView.MENU_*` 那套机位）——
## 联机面板是在菜单场景里开的，菜单淡出的只有 `$UI/Screen` 那层字，
## 棋盘装饰一直在。第一版预览用纯色背景，于是「会不会遮住右边的地图」这个问题
## 在图上根本看不出来（Kevin 问的正是这个）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_room_chat.gd -- <输出.png>
const WARMUP := 30
var _out := "user://room.png"
var _frames := 0
var _p: CWOnlinePanel
var _cam: Camera2D

func _initialize() -> void:
	_out = OS.get_cmdline_user_args()[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	## 主菜单的棋盘装饰：菜单机位（放大 3.2、锚点 595,227）
	root.add_child(load("res://scenes/Board.tscn").instantiate())
	_cam = Camera2D.new()
	root.add_child(_cam)
	var ui := CanvasLayer.new()
	root.add_child(ui)
	_p = CWOnlinePanel.new()
	ui.add_child(_p)
	_p.client = CWNetClient.new()
	var seats: Array = []
	for i in 4:
		seats.append({ "kind": "", "nick": "", "ready": false, "tier": "",
			"online": false, "faction": CWData.FACTION_ORDER[4][i] })
	seats[0] = { "kind": "human", "nick": "甲", "ready": true, "tier": "",
		"online": true, "faction": CWData.Faction.IMMUNE }
	seats[1] = { "kind": "human", "nick": "乙", "ready": false, "tier": "",
		"online": true, "faction": CWData.Faction.CANCER }
	seats[3] = { "kind": "ai", "nick": "AI·专家", "ready": false, "tier": "mc",
		"online": false, "faction": CWData.Faction.CANCER }
	_p.client.room = { "t": "room", "code": "ABCDEF", "public": true, "timer": 60,
		"players": 4, "state": "waiting", "host": "甲", "you_host": true,
		"you_seat": 0, "token": "x", "seats": seats, "members": ["甲", "乙", "丙"], "games": 0 }
	_p.client.code = "ABCDEF"
	_p.client.my_seat = 0
	_p.client.chat_log = [
		{ "nick": "甲", "seat": 0, "faction": CWData.Faction.IMMUNE,
			"scope": "all", "text": "还差一个人" },
		{ "nick": "乙", "seat": 1, "faction": CWData.Faction.CANCER,
			"scope": "all", "text": "我叫上老三" },
		{ "nick": "甲", "seat": 0, "faction": CWData.Faction.IMMUNE,
			"scope": "team", "text": "这局我们先手" },
		{ "nick": "丙", "seat": -1, "faction": -1, "scope": "all", "text": "我先看看" },
	]

func _process(_d: float) -> bool:
	_frames += 1
	_cam.zoom = Vector2(CWView.MENU_ZOOM, CWView.MENU_ZOOM)
	_cam.position = CWView.camera_pos_for(CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR,
		CWView.MENU_ZOOM, Vector2(960, 540))
	## **不能在 _initialize 里 open()**：那时节点刚 add_child、`_ready` 还没跑，
	## 面板的 `_build()` 也就没跑，`_roots` 是空的 —— 上一个预览侥幸没踩到，
	## 因为它把 open() 写在了 _process 里
	if _frames == 2:
		_p.open()
		_p._show_page(CWOnlinePanel.Page.ROOM)
	## **等淡入真的走完再拍**，别数帧：`open()` 是 0.32 秒的**时间**补间，
	## 而这个循环不吃 vsync，一帧可能只有几毫秒 —— 数十几帧只等到 0.1 秒，
	## 拍下来整块 `modulate.a` 才 0.3，图里的字全是半透明的
	## （2026-09-09 Kevin 一句「为什么这图片里面的字这么淡」才揭穿）
	if _frames < WARMUP or _p.modulate.a < 1.0:
		return false
	root.get_texture().get_image().save_png(_out)
	return true
