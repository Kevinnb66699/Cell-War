extends SceneTree
## 等待室（含右栏聊天）的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：左栏被席位排满（214..394 席位、398 未入座、438 按钮），
## 聊天只能摆右栏。「右栏那张板会不会和席位挤在一起、会不会出槽」只能看图。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_room_chat.gd -- <输出.png>
const WARMUP := 30
var _out := "user://room.png"
var _frames := 0
var _p: CWOnlinePanel

func _initialize() -> void:
	_out = OS.get_cmdline_user_args()[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
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
	## **不能在 _initialize 里 open()**：那时节点刚 add_child、`_ready` 还没跑，
	## 面板的 `_build()` 也就没跑，`_roots` 是空的 —— 上一个预览侥幸没踩到，
	## 因为它把 open() 写在了 _process 里
	if _frames == 2:
		_p.open()
		_p._show_page(CWOnlinePanel.Page.ROOM)
	if _frames < WARMUP:
		return false
	root.get_texture().get_image().save_png(_out)
	return true
