extends SceneTree
## 三种要对准细胞的演出放大看（issue #26）—— 给人看的工具，不是测试。
##
## 有氧「轻量吸收」/ 无氧「铜橙输能」/ 伪足穿透「触手拉细胞」都得和细胞贴图对上位置，
## 一张 960×540 的全盘图看不清一两个像素的错位，这里把棋盘放大 3 倍、只摆四格。
## 细胞的摆法照抄 CWMatch（脚底 = 格顶面中心 + CELL_FOOT_DY，贴图 offset 抬半高），
## 伪足那只细胞每帧问 CWSkillFx.carry_pos() —— 和 _sync_cells 一样。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_fx_cell.gd -- <输出前缀>
## 连拍五帧：0.15 / 0.35 / 0.55 / 0.8 / 1.6 秒（前四张跟着伪足的四拍走 —— issue #29 压到 1 秒；末张看有氧 / 无氧的尾声）。
const WARMUP := 12
const SHOTS := [0.15, 0.35, 0.55, 0.8, 1.6]
const ZOOM := 3.0
const RESPIRE_AT := Vector2i(-1, 0)
const ANAEROBIC_AT := Vector2i(1, 0)
const PULL_FROM := Vector2i(-1, 2)
const PULL_TO := Vector2i(0, 2)
const REVIVE_AT := Vector2i(0, 0)      ## 碎石重生（#27 白条）：固化格上复活
var _out := "user://fx_cell"
var _board: Node2D
var _fx: CWSkillFx
var _puller: Sprite2D
var _frames := 0
var _t := 0.0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.scale = Vector2(ZOOM, ZOOM)
	root.add_child(_board)
	_fx = CWSkillFx.new()
	_fx.z_index = _board.Z_OVER_BOARD
	_board.add_child(_fx)


func _cell(tex_path: String, at: Vector2i) -> Sprite2D:
	var sp := Sprite2D.new()
	var tex: Texture2D = load(tex_path)
	sp.texture = tex
	sp.hframes = CWMatch.BREATH_FRAMES
	sp.offset = Vector2(0, -tex.get_height() / 2.0)
	sp.position = _board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY)
	sp.z_index = _board.tile_z(at, _board.Z_CELL)
	_board.add_child(sp)
	return sp


## 同 CWUIBridge.show_fx 的换算：脚底、胞体中心、半径
func _body(at: Vector2i, sp: Sprite2D) -> Dictionary:
	var half := sp.texture.get_height() / 2.0
	return { "foot": _board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY),
		"body": _board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY - half), "r": half }


func _setup_scene() -> void:
	## 棋盘放大后把中央这几格摆到画面中间
	_board.position = Vector2(480, 200) - _board.tile_center(Vector2i(0, 1)) * ZOOM
	for c in [RESPIRE_AT, ANAEROBIC_AT, PULL_FROM, PULL_TO]:
		_board.set_tissue(c, CWData.Tissue.CANCER if c != RESPIRE_AT else CWData.Tissue.HEALTHY, CWData.Special.NONE, false, 0.0)
	var immune := _cell("res://assets/art/cells/anim/immune_breath.png", RESPIRE_AT)
	var mel := _cell("res://assets/art/cells/anim/melanoma_breath.png", ANAEROBIC_AT)
	_puller = _cell("res://assets/art/cells/anim/melanoma_breath.png", PULL_FROM)
	var r := _body(RESPIRE_AT, immune)
	_fx.play("respire", { "at": r["foot"], "at_body": r["body"], "r": r["r"] })
	var a := _body(ANAEROBIC_AT, mel)
	var sources: Array = []
	for n in [Vector2i(2, 0), Vector2i(1, -1), Vector2i(2, -1)]:
		_board.set_tissue(n, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
		sources.append(_board.tile_center(n))
	_fx.play("anaerobic", { "at": a["foot"], "at_body": a["body"], "r": a["r"], "sources": sources })
	var p := _body(PULL_FROM, _puller)
	var roots: Array = []
	for n in [Vector2i(1, 2), Vector2i(0, 3), Vector2i(1, 1)]:
		_board.set_tissue(n, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
		roots.append(_board.tile_center(n))
	_fx.play("pseudopod", { "from": _board.tile_center(PULL_FROM), "to": _board.tile_center(PULL_TO),
		"roots": roots, "from_body": p["body"], "r": p["r"], "cid": 7 })
	## 复活那一刻固化格已经碎成普通癌组织了（CWWorld.revive_cancer 先 crack_to_cancer 再报演出），
	## 所以脚下摆普通癌组织 —— 摆成固化的话马赛克和底图同色，等于什么都看不见
	_board.set_tissue(REVIVE_AT, CWData.Tissue.CANCER, CWData.Special.NONE, false, 0.0)
	_fx.play("revive_cancer", { "at": _board.tile_center(REVIVE_AT) })


func _process(d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_setup_scene()
	_fx.sync(d)
	## 和 CWMatch._sync_cells 一样：被拉的细胞听演出层的，演完站回新格
	var carried: Variant = _fx.carry_pos(7)
	_puller.position = carried if carried != null else _board.tile_center(PULL_TO) + Vector2(0, CWMatch.CELL_FOOT_DY)
	_t += d
	if _t < SHOTS[_shot]:
		return false
	root.get_texture().get_image().save_png("%s_%d.png" % [_out, _shot])
	_shot += 1
	return _shot >= SHOTS.size()
