extends SceneTree
## 技能演出（issue #15，选稿 R4）的对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这批演出是逐笔照 tools/art-preview 的 JS 复刻的，`t_skill_fx` 验的是
## 「登记 / 收场 / 数据形状」，像素长得对不对只能把图摆出来和选稿页并排看。
## 一张图里同时摆：十二向黏液喷射、抗体单发重击、三点连爆、双端血门、低弧牵引、铜橙输能、
## 印戒的灰青小盾、骨肉瘤的骨牙底盘、癌细胞头顶的紫晶冠印、坏死格纹理、深红固化格。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_skill_fx.gd -- <输出.png>
## 连拍三帧：0.3 / 0.9 / 1.6 秒。
const WARMUP := 12
const SHOTS := [0.3, 0.9, 1.6]
var _out := "user://skill_fx.png"
var _board: Node2D
var _fx: CWSkillFx
var _mucus: CWMucusFx
var _game: CWGame
var _frames := 0
var _t := 0.0
var _shot := 0
var _spots: Array = []
var _cancers: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 270)
	root.add_child(_board)
	## 一局真的 CWGame 给装饰读状态：印戒（护甲未用）、骨肉瘤站固化格、一只被标记的黑色素瘤
	_game = CWGame.new()
	_game.init(CWData.FACTION_ORDER[6], 7)
	_game.setup.build_board()
	var spots := [Vector2i(-3, 1), Vector2i(3, -1), Vector2i(0, 3)]
	_spots = spots
	var kinds := [CWData.CancerType.SIGNET, CWData.CancerType.OSTEO, CWData.CancerType.MELANOMA]
	## 开局落子那一步不跑，细胞手摆（同 t_pressure 的做法）
	var cancers: Array = []
	for i in 3:
		var made := CWSetup.make_cell(i, 1, CWData.Faction.CANCER, spots[i], -1, int(kinds[i]))
		made["energy"] = 50
		_game.cells.append(made)
		cancers.append(made)
	_cancers = cancers
	for i in 3:
		var c: Dictionary = cancers[i]
		c["ctype"] = kinds[i]
		c["pos"] = spots[i]
		c["armor_used"] = false
		_game.tiles[spots[i]]["tissue"] = CWData.Tissue.SOLID if i == 1 else CWData.Tissue.CANCER
		if i == 2:
			c["marked"] = true
	_fx = CWSkillFx.new()
	_fx.z_index = _board.Z_OVER_BOARD
	_board.add_child(_fx)
	_mucus = CWMucusFx.new()
	_mucus.z_index = _board.Z_OVER_BOARD
	_board.add_child(_mucus)


## 棋盘的 map 要等它自己 _ready 之后才有：格子贴图 / 坏死 / 细胞 / 装饰都在 WARMUP 那一帧再摆
func _setup_scene() -> void:
	var spots: Array = _spots
	var cancers: Array = _cancers
	_board.set_tissue(spots[1], CWData.Tissue.SOLID, _game.tiles[spots[1]]["special"], false, 1.0)
	_board.set_tissue(spots[0], CWData.Tissue.CANCER, _game.tiles[spots[0]]["special"], false, 0.0)
	_board.set_tissue(spots[2], CWData.Tissue.CANCER, _game.tiles[spots[2]]["special"], false, 0.0)
	_board.set_necrosis([Vector2i(-2, -2), Vector2i(-1, -2)])
	var art := ["signet", "osteo", "melanoma"]
	for i in 3:
		var sp := Sprite2D.new()
		sp.texture = load("res://assets/art/cells/%s.png" % art[i])
		sp.position = _board.tile_center(spots[i]) + Vector2(0, CWMatch.CELL_FOOT_DY)
		sp.z_index = _board.tile_z(spots[i], _board.Z_CELL)
		_board.add_child(sp)
		for is_front in [false, true]:
			var deco := CWCellDeco.new()
			deco.front = bool(is_front)
			deco.game = _game
			deco.index = int(cancers[i]["id"])
			deco.position = _board.tile_center(spots[i])
			deco.z_index = sp.z_index + (1 if bool(is_front) else -1)
			_board.add_child(deco)


func _at(c: Vector2i, body := false) -> Vector2:
	return _board.tile_center(c) + Vector2(0, CWMatch.CELL_FOOT_DY if body else 0.0)


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_setup_scene()
		_mucus.play(_board.tile_center(Vector2i(-4, 3)))
		_fx.play("antibody", { "from": _at(Vector2i(-4, -1), true), "targets": [_at(Vector2i(-1, -1), true)] })
		_fx.play("lyse", { "from": _at(Vector2i(1, 2), true), "to": _at(Vector2i(2, 2)) })
		_fx.play("homing", { "from": _at(Vector2i(4, 1)), "to": _at(Vector2i(4, 3)), "spread": [_at(Vector2i(5, 2)), _at(Vector2i(3, 4))] })
		_fx.play("pseudopod", { "from": _at(Vector2i(1, -3)), "to": _at(Vector2i(2, -3)),
			"roots": [_at(Vector2i(3, -3)), _at(Vector2i(2, -4)), _at(Vector2i(3, -4)), _at(Vector2i(1, -2))] })
		_fx.play("anaerobic", { "at": _at(Vector2i(-3, 4), true), "sources": [_at(Vector2i(-2, 4)), _at(Vector2i(-4, 4)), _at(Vector2i(-3, 5)), _at(Vector2i(-2, 3))] })
		_fx.play("respire", { "at": _at(Vector2i(0, -1), true) })
		_fx.play("mutate", { "at": _at(Vector2i(0, 3), true) })
	_fx.sync(d)
	_mucus.sync(d)
	_t += d
	if _t < SHOTS[_shot]:
		return false
	root.get_texture().get_image().save_png(
		_out if _shot == 0 else _out.get_basename() + "_%d.png" % _shot)
	_shot += 1
	return _shot >= SHOTS.size()
