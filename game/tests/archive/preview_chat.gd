extends SceneTree
## 聊天框的对照图 —— 给人看的工具，不是测试。
##
## 两种样子各一张：**开着**（左上角那块地，标题栏 + 全体/己方 + 消息列 + 输入行）与
## **关着**（迷你条切到聊天页，显示最近两条 + 标签上的未读数）。
##
## 图里连**手牌抽屉**和**出牌列**一起画 —— 第一版把聊天摆左下角，
## 预览图没画这两样，于是「一格棋盘都没压」是假象（Kevin 一眼看出来）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/archive/preview_chat.gd -- <输出.png> [open|shut]
const WARMUP := 30
var _out := "user://chat.png"
var _mode := "open"
var _frames := 0
var _cam: Camera2D
var _chat: CWChatBox
var _hint: CWLogHint

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
	_hint = CWLogHint.new()
	ui.add_child(_hint)
	_hint.set_chat(_chat)
	## 常驻件的壳：出牌列与手牌抽屉（抬起态）——第一版就是没画它们才看走眼
	for r: Array in [[CWFeed.RECT, "出牌列"],
			[Rect2(12, CWHand.REST_TOP - CWHand.LIFT, 380, CWHand.LIFT + 26), "手牌（悬停抬起）"]]:
		var p := Panel.new()
		p.add_theme_stylebox_override("panel", CWStyle.box(0.35, Color("0a1018cc")))
		p.position = (r[0] as Rect2).position
		p.size = (r[0] as Rect2).size
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui.add_child(p)
		var t := CWStyle.label(str(r[1]), CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		t.position = (r[0] as Rect2).position + Vector2(6, 4)
		ui.add_child(t)

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
