extends SceneTree
## 聊天框的对照图 —— 给人看的工具，不是测试。
##
## 两种样子各一张：**开着**（标题栏 + 全体/己方 + 消息列 + 输入行）与
## **关着**（左下常驻提示「聊天　Enter」+ 未读数 + 浮出最近两条）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_chat.gd -- <输出.png> [open|shut]
const WARMUP := 30
var _out := "user://chat.png"
var _mode := "open"
var _frames := 0
var _cam: Camera2D
var _chat: CWChatBox

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_out = a[0]
	if a.size() > 1:
		_mode = a[1]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	root.add_child(load("res://scenes/Board.tscn").instantiate())
	_cam = Camera2D.new()
	root.add_child(_cam)
	var ui := CanvasLayer.new()
	root.add_child(ui)
	_chat = CWChatBox.new()
	ui.add_child(_chat)

func _process(_d: float) -> bool:
	_frames += 1
	_cam.zoom = Vector2(CWView.GAME_ZOOM, CWView.GAME_ZOOM)
	_cam.position = CWView.camera_pos_for(CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR,
		CWView.GAME_ZOOM, Vector2(960, 540))
	if _frames == WARMUP / 2:
		if _mode == "open":
			_chat.open()
		for line in [
			{ "nick": "甲", "seat": 0, "faction": CWData.Faction.IMMUNE,
				"scope": "all", "text": "这波我先手" },
			{ "nick": "乙", "seat": 1, "faction": CWData.Faction.CANCER,
				"scope": "all", "text": "别急，我有抗体" },
			{ "nick": "甲", "seat": 0, "faction": CWData.Faction.IMMUNE,
				"scope": "team", "text": "你去左边我去右边" },
			{ "nick": "丙", "seat": -1, "faction": -1, "scope": "all", "text": "稳" },
		]:
			_chat.push(line)
	if _frames < WARMUP:
		return false
	root.get_texture().get_image().save_png(_out)
	return true
