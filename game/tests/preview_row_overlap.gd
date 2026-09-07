extends SceneTree
## 右栏玩家行第二行的占位图（Kevin 2026-09-07 拍到「图标重叠」）——给人看的工具，不是测试。
##
## 造的就是他那张照片的局面：联机局（种类后面跟「· 离线代打」）+ 本回合打过牌（历史小卡）。
## 画出每一段的实际左右边界，一眼看得出谁压了谁。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_row_overlap.gd -- <输出.png>
const WARMUP := 30

var _out := "user://row_overlap.png"
var _frames := 0
var _game: CWGame
var _panel: CWMatchPanel


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)

	_game = CWGame.new()
	_game.init(CWData.FACTION_ORDER[4], 1)
	_game.setup.build_board()
	var kinds := [CWData.CancerType.MELANOMA, CWData.CancerType.SCLC]
	for pid in 4:
		var pl: Dictionary = _game.players[pid]
		var immune: bool = pl["faction"] == CWData.Faction.IMMUNE
		var c := CWSetup.make_cell(pid, pid, pl["faction"], Vector2i(pid - 1, 2),
			CWData.ImmuneType.BASIC if immune else -1,
			-1 if immune else kinds[pid / 2])
		c["energy"] = 5 + pid * 9
		c["hand"] = ["炎症趋化"] if pid == 2 else []
		_game.cells.append(c)
	_game.round_no = 12

	_panel = CWMatchPanel.new()
	root.add_child(_panel)
	## 联机局：种类后面会跟「· 离线代打」/「· AI」，这正是照片里那一行
	_panel.net_seats = [
		{ "kind": "human", "online": true }, { "kind": "human", "online": false },
		{ "kind": "human", "online": true }, { "kind": "ai" },
	]


func _text(at: Vector2, s: String, size: int, color: Color) -> void:
	var l := CWStyle.label(s, size, color)
	l.position = at
	root.add_child(l)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_panel.position = Vector2(660, 0)
		_panel.refresh(_game)
		_panel.note_played_card(_game, 1, CWData.Faction.CANCER, "GLUT1高表达")
		_panel.note_played_card(_game, 1, CWData.Faction.CANCER, "上皮—间质转化")
		_panel.note_played_card(_game, 2, CWData.Faction.IMMUNE, "炎症趋化")
		_text(Vector2(40, 16), "右栏玩家行第二行：谁占了哪一段（联机局 + 本回合打过牌）", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		## 把每一段的边界量出来写在左边
		var y := 60.0
		for pid in 4:
			var row: Dictionary = _panel._rows[pid]
			var ty: Label = row["type"]
			var hist: Control = row["history"]
			var pip0: ColorRect = row["pips"][0]
			## 小卡右对齐在容器里，所以「最左那张」才是种类文字的边界（容器左缘不是）
			var n: int = hist.get_child_count()
			var chip_l: float = hist.position.x + hist.size.x
			if n > 0:
				chip_l -= (CWMatchPanel.HISTORY_ICON + 2.0) + float(n - 1) * CWMatchPanel.HISTORY_STEP
			var line := "%s：种类 %.0f..%.0f（%s）· 最左小卡 %.0f · 方块从 %.0f" % [
				_game.players[pid]["name"],
				ty.position.x, ty.position.x + ty.size.x, ty.text,
				chip_l, pip0.position.x]
			var overlap: bool = hist.visible and n > 0 and ty.position.x + ty.size.x > chip_l
			_text(Vector2(40, y), line + ("　← 重叠！" if overlap else ""), CWStyle.SIZE_LABEL,
				CWStyle.CANCER if overlap else CWStyle.TEXT_DIM)
			y += 18.0
		_text(Vector2(40, y + 16), "种类标签没开裁切 —— 不裁的 Label 最小宽 = 全文宽，会把定的 110 顶开，", CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
		_text(Vector2(40, y + 34), "于是「恶性黑色素瘤 · 离线代打」一路压到小卡底下。", CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
