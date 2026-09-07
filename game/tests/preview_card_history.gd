extends SceneTree
## 出牌表现层的预览图（队友 2026-09-06「新增卡牌特效」合并后）—— 给人看的工具，不是测试。
##
## 一张图摆三样：① 左下角手牌悬停（描边转纯白）② 右栏玩家行的本回合历史小卡（行底手牌方块左边；免疫A 收着、癌症A 摊开且停在中间那张）
## ③ 棋盘上细胞头顶的飞卡（同一张 16px 小卡，定格在上浮途中）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_card_history.gd -- <输出.png>
const WARMUP := 30

var _out := "user://card_history.png"
var _frames := 0
var _game: CWGame
var _panel: CWMatchPanel
var _hand: CWHand


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)

	## ③ 棋盘 + 一个癌细胞 + 头顶飞卡（定格）
	var board: Node2D = load("res://scenes/Board.tscn").instantiate()
	board.position = Vector2(360, 300)
	root.add_child(board)
	var at := Vector2i(0, 0)
	var cell := Sprite2D.new()
	cell.texture = CWMatch.CANCER_ART[CWData.CancerType.MELANOMA]
	cell.hframes = CWMatch.BREATH_FRAMES
	cell.centered = true
	cell.offset = Vector2(0, -cell.texture.get_height() / 2.0)
	cell.position = board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY)
	cell.z_index = board.tile_z(at, board.Z_MARK) + 1
	board.add_child(cell)
	var fx := Sprite2D.new()
	## 直接 load 而不引用 CWMatch.CARD_FX_TEXTURE：那是 preload 常量，贴图的 import 还没生成时跨脚本解析会失败
	fx.texture = load("res://assets/art/ui/card_chip.png")
	fx.position = cell.position + Vector2(0, -30.0 - CWMatch.CARD_FX_RISE * 0.45)
	fx.scale = Vector2.ONE * CWMatch.CARD_FX_SCALE
	fx.modulate = Color(1, 1, 1, 0.7)
	fx.z_index = cell.z_index + 1
	board.add_child(fx)

	## ② 右栏：四人局，癌症A 本回合打了两张、免疫A 打了一张
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
	_panel = CWMatchPanel.new()
	root.add_child(_panel)
	_panel.refresh(_game)
	_panel.note_played_card(_game, 1, CWData.Faction.CANCER, "糖酵解爆发")
	_panel.note_played_card(_game, 1, CWData.Faction.CANCER, "GLUT1高表达")
	_panel.note_played_card(_game, 1, CWData.Faction.CANCER, "上皮—间质转化")
	_panel.note_played_card(_game, 0, CWData.Faction.IMMUNE, "炎症趋化")
	## 癌症A 那叠摊开、停在中间那张（模拟悬停：直接发 mouse_entered）
	var hist: Control = _panel._rows[1]["history"]
	hist.get_child(1).mouse_entered.emit()

	## ① 手牌：三张，第一张悬停抬起
	_hand = CWHand.new()
	root.add_child(_hand)
	var names := PackedStringArray(["炎症趋化", "补体调理", "细胞膜修复"])
	_hand.sync(names.size(), Vector2.INF, names)
	_hand._hover(0)

	_caption(Vector2(150, 470), "① 手牌悬停：描边转纯白、上浮")
	_caption(Vector2(150, 486), "　 （双击打出 / 右键双击弃置照旧）")
	_caption(Vector2(180, 120), "③ 打出时细胞头顶飞出一枚小卡：上浮 28px、0.42 秒渐隐")
	_caption(Vector2(430, 200), "② 右栏玩家行：本回合打出的卡叠成小卡 →")
	_caption(Vector2(430, 216), "　 悬停抬起、点一下看原始卡面；换回合清空")


func _caption(at: Vector2, text: String) -> void:
	var l := CWStyle.label(text, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	l.position = at
	root.add_child(l)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
