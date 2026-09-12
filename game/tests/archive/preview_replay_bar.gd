extends SceneTree
## 回放播放条的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：它摆在行动栏那条位置（回放局行动栏不出现），
## 而那条底下就是手牌抽屉、右边就是右侧竖条 —— 挤没挤只能看图。
## 图里连**右侧竖条与手牌抽屉的壳**一起画（上两次都栽在「预览没画常驻件」上）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/archive/preview_replay_bar.gd -- <输出.png>
const WARMUP := 30
var _out := "user://bar.png"
var _frames := 0
var _cam: Camera2D
var _bar: CWReplayBar

func _initialize() -> void:
	_out = OS.get_cmdline_user_args()[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	root.add_child(load("res://scenes/Board.tscn").instantiate())
	_cam = Camera2D.new()
	root.add_child(_cam)
	var ui := CanvasLayer.new()
	root.add_child(ui)
	## 常驻件的壳：右侧竖条、手牌抽屉（静止态）、出牌列
	for r: Array in [[Rect2(696, 0, 264, 540), "右侧竖条"],
			[Rect2(12, CWHand.REST_TOP, 380, 26), "手牌（静止）"],
			[CWFeed.RECT, "出牌列"]]:
		var p := Panel.new()
		p.add_theme_stylebox_override("panel", CWStyle.box(0.35, Color("0a1018cc")))
		p.position = (r[0] as Rect2).position
		p.size = (r[0] as Rect2).size
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui.add_child(p)
		var t := CWStyle.label(str(r[1]), CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		t.position = (r[0] as Rect2).position + Vector2(6, 4)
		ui.add_child(t)
	_bar = CWReplayBar.new()
	ui.add_child(_bar)

func _process(_d: float) -> bool:
	_frames += 1
	_cam.zoom = Vector2(CWView.GAME_ZOOM, CWView.GAME_ZOOM)
	_cam.position = CWView.camera_pos_for(CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR,
		CWView.GAME_ZOOM, Vector2(960, 540))
	if _frames == 2:
		_bar.refresh(147, 384, false, 2.0)
	if _frames < WARMUP:
		return false
	root.get_texture().get_image().save_png(_out)
	return true
