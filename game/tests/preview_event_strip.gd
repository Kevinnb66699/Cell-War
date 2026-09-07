extends SceneTree
## 「抽到即结算的事件卡记进回合数那一栏」的预览图（Kevin 2026-09-07 拍板方案乙，已实装）——
## 给人看的工具，不是测试。这一版画的是**真的实装**（走 `CWMatchPanel.note_event_card`），
## 不再是示意节点：左边收着的样子，右边悬停摊开的样子。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_event_strip.gd -- <输出.png>
const WARMUP := 30
const PANEL_H := 208.0    ## 只截到第一名玩家行，好和玩家行那排「打出的卡」对比
const XS := [90.0, 520.0]

var _out := "user://event_strip.png"
var _frames := 0
var _game: CWGame
var _panels: Array = []


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
	var spots := [Vector2i(-3, 0), Vector2i(3, 0), Vector2i(-3, 3), Vector2i(3, -3)]
	for pid in 4:
		var pl: Dictionary = _game.players[pid]
		var c := CWSetup.make_cell(pid, pid, pl["faction"], spots[pid],
			CWData.ImmuneType.BASIC if pl["faction"] == CWData.Faction.IMMUNE else -1,
			-1 if pl["faction"] == CWData.Faction.IMMUNE else CWData.CancerType.MELANOMA)
		c["energy"] = 35 + pid * 7
		_game.cells.append(c)
	_game.round_no = 12
	_game.phase = "行动阶段"
	_game.events["active"].append({ "name": "基质阻隔", "left": 2, "stacks": 1, "data": {} })

	_text(Vector2(90, 16), "抽到即结算的事件卡：记进「回合数」那一栏（方案乙，已实装）", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_text(Vector2(90, 44), "本世界回合内所有人抽到的事件卡，按发生先后排在世界事件那一行右侧；边色 = 抽到它的阵营。回合一换就清空。",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)

	for i in 2:
		var holder := Control.new()
		holder.position = Vector2(XS[i], 76)
		holder.size = Vector2(CWMatchPanel.RECT.size.x, PANEL_H)
		holder.clip_contents = true
		root.add_child(holder)
		var p := CWMatchPanel.new()
		holder.add_child(p)
		_panels.append(p)


func _text(at: Vector2, s: String, size: int, color: Color) -> void:
	var l := CWStyle.label(s, size, color)
	l.position = at
	root.add_child(l)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		for i in 2:
			var p: CWMatchPanel = _panels[i]
			p.position = Vector2.ZERO
			p.refresh(_game)
			## 真的走实装那条路
			p.note_event_card(_game, CWData.Faction.IMMUNE, "急性炎症反应")
			p.note_event_card(_game, CWData.Faction.CANCER, "糖酵解爆发")
			p.note_event_card(_game, CWData.Faction.IMMUNE, "抗原呈递增强")
			p.note_event_card(_game, CWData.Faction.CANCER, "克隆增殖")
			## 玩家行那排「自己打出的卡」留着做对比
			p.note_played_card(_game, 0, CWData.Faction.IMMUNE, "炎症趋化")
			p.note_played_card(_game, 0, CWData.Faction.IMMUNE, "补体调理")
			if i == 1:
				## 右边这份演悬停：停在中间那张上（摊开 + 抬起 + 白边）
				(p._event_strip.get_child(1) as Control).mouse_entered.emit()
		_text(Vector2(XS[0] + 16, 76 + PANEL_H + 12), "收着：叠 2px，最新的在最右", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		_text(Vector2(XS[0] + 16, 76 + PANEL_H + 42), "世界事件文字自动裁到小卡左边。", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		_text(Vector2(XS[1] + 16, 76 + PANEL_H + 12), "悬停：整叠摊开，停着那张抬起", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		_text(Vector2(XS[1] + 16, 76 + PANEL_H + 42), "点一下出那张卡的原始卡面（当前分期那一档高亮）。", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		_text(Vector2(90, 500), "玩家行右下那两张（主色边）是「自己打出的卡」，和上面按阵营染色的事件卡分开 —— 这正是这次改的点。",
			CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
