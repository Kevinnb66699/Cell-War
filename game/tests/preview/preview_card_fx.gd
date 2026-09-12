extends SceneTree
## 十四种卡牌粒子放大看（issue #28，选稿 R5 card-effects.js）—— 给人看的工具，不是测试。
##
## 每种一张图：三列各一块棋盘（zoom 2），同一场演出停在三个时刻（早 / 中 / 晚）。
## 细胞的摆法照抄 CWMatch（脚底 = 格顶面中心 + CELL_FOOT_DY，贴图 offset 抬半高）。
## 演出层不自己走时间（同 CWMatch 每帧 sync），这里各 sync 一次就停住，截图不怕帧数漂。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_card_fx.gd -- <输出前缀> [kind,kind,…]
## 输出 <前缀>_<kind>.png（960×540，三列各 320；窗口尺寸由 project.godot 定，脚本不改它）。
const WARMUP := 12
const SETTLE := 4
const COLS := 3
const COL_W := 320
const COL_H := 540
const ZOOM := 2.0
const C := Vector2i(0, 0)
const ART := {
	"immune": "res://assets/art/cells/anim/immune_breath.png",
	"tcell": "res://assets/art/cells/anim/tcell_breath.png",
	"bcell": "res://assets/art/cells/anim/bcell_breath.png",
	"dendritic": "res://assets/art/cells/anim/dendritic_breath.png",
	"melanoma": "res://assets/art/cells/anim/melanoma_breath.png",
}
## 游戏钟（选稿钟减 0.4）
const SHOTS := {
	"card_radiation": [0.3, 0.9, 1.5], "card_storm": [0.3, 0.9, 1.5], "card_inflammation": [0.3, 0.9, 1.5],
	"card_granule": [0.4, 0.9, 1.3], "card_acid": [0.4, 0.9, 1.3], "card_cascade": [0.6, 1.3, 2.3],
	"card_transfer": [0.5, 1.1, 1.6], "card_teleport": [0.5, 1.3, 1.8], "card_mark": [0.6, 1.3, 1.7],
	"card_repair": [0.1, 0.6, 1.3], "card_survive": [0.5, 1.2, 1.6], "card_degrade": [0.3, 0.6, 1.0],
	"card_clone": [0.5, 1.1, 1.6], "card_blood": [0.3, 0.8, 1.3],
}
var _out := "user://card_fx"
var _kinds: Array = []
var _i := 0
var _frames := 0
var _settle := 0
var _cols: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_kinds = SHOTS.keys()
	if args.size() > 1:
		_kinds = args[1].split(",")


func _tc(board: Node2D, c: Vector2i) -> Vector2:
	return board.tile_center(c)


func _tcs(board: Node2D, cs: Array) -> Array:
	var out: Array = []
	for c in cs:
		out.append(board.tile_center(c))
	return out


func _paint(board: Node2D, cs: Array, tissue: int, solid := 0.0) -> void:
	for c in cs:
		board.set_tissue(c, tissue, CWData.Special.NONE, false, solid)


func _cell(board: Node2D, art: String, at: Vector2i) -> void:
	var sp := Sprite2D.new()
	var tex: Texture2D = load(ART[art])
	sp.texture = tex
	sp.hframes = CWMatch.BREATH_FRAMES
	sp.offset = Vector2(0, -tex.get_height() / 2.0)
	sp.position = board.tile_center(at) + Vector2(0, CWMatch.CELL_FOOT_DY)
	sp.z_index = board.tile_z(at, board.Z_CELL)
	board.add_child(sp)


func _ring2() -> Array:
	var out: Array = []
	for q in range(-2, 3):
		for r in range(-2, 3):
			if maxi(maxi(absi(q), absi(r)), absi(q + r)) <= 2:
				out.append(Vector2i(q, r))
	return out


func _adj() -> Array:
	var out: Array = [C]
	for d in CWData.DIRS:
		out.append(C + d)
	return out


## 一列的场景：细胞 + 一条停在 t 的演出。按 kind 摆，照选稿 card-effects.js 的布局。
## **棋盘必须已经进树**（_ready 跑过，tile_center / set_tissue 才有格可用）—— _build 先挂再调这里
func _scene(kind: String, board: Node2D, t: float) -> void:
	var fx := CWSkillFx.new()
	fx.z_index = board.Z_OVER_BOARD
	var data := {}
	match kind:
		"card_radiation":
			var region: Array = _adj() + [Vector2i(2, 0), Vector2i(2, -1), Vector2i(-2, 1)]
			_paint(board, [C, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, -1), Vector2i(2, 0)], CWData.Tissue.CANCER)
			data = { "tiles": _tcs(board, region) }
		"card_storm", "card_inflammation":
			var area: Array = _ring2() if kind == "card_storm" else _adj()
			var cancer: Array = []
			for c: Vector2i in area:
				if c.x > 0:
					cancer.append(c)
			_paint(board, cancer, CWData.Tissue.CANCER)
			_cell(board, "immune", C)
			_cell(board, "melanoma", Vector2i(1, 0))
			data = { "at": _tc(board, C), "tiles": _tcs(board, area) }
		"card_granule", "card_cascade":
			_paint(board, [Vector2i(1, 0), Vector2i(2, -1), Vector2i(1, 1)], CWData.Tissue.CANCER)
			_cell(board, "tcell" if kind == "card_granule" else "bcell", Vector2i(-1, 0))
			_cell(board, "melanoma", Vector2i(1, 0))
			data = { "from": _tc(board, Vector2i(-1, 0)), "to": _tc(board, Vector2i(1, 0)),
				"tiles": _tcs(board, [Vector2i(2, -1), Vector2i(1, 1)]) }
		"card_acid":
			_paint(board, [Vector2i(-1, 0)], CWData.Tissue.CANCER)
			_cell(board, "melanoma", Vector2i(-1, 0))
			_cell(board, "immune", Vector2i(1, 0))
			data = { "from": _tc(board, Vector2i(-1, 0)), "to": _tc(board, Vector2i(1, 0)) }
		"card_transfer":
			_cell(board, "immune", Vector2i(-1, 0))
			_cell(board, "immune", Vector2i(1, 0))
			data = { "from": _tc(board, Vector2i(-1, 0)), "to": _tc(board, Vector2i(1, 0)) }
		"card_teleport":
			_cell(board, "immune", Vector2i(1, 0))
			data = { "from": _tc(board, Vector2i(-1, 0)), "to": _tc(board, Vector2i(1, 0)) }
		"card_mark":
			_paint(board, [Vector2i(1, 0)], CWData.Tissue.CANCER)
			_cell(board, "dendritic", Vector2i(-1, 0))
			_cell(board, "melanoma", Vector2i(1, 0))
			data = { "from": _tc(board, Vector2i(-1, 0)), "to": _tc(board, Vector2i(1, 0)) }
		"card_repair":
			_cell(board, "immune", C)
			data = { "at": _tc(board, C) }
		"card_survive":
			_paint(board, [C], CWData.Tissue.CANCER)
			_cell(board, "melanoma", C)
			data = { "at": _tc(board, C) }
		"card_degrade":
			_paint(board, [Vector2i(1, 0)], CWData.Tissue.SOLID, 1.0)
			_cell(board, "immune", C)
			data = { "at": _tc(board, Vector2i(1, 0)) }
		"card_clone":
			_paint(board, [C], CWData.Tissue.CANCER)
			_cell(board, "melanoma", C)
			var tiles: Array = [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1)]
			data = { "at": _tc(board, C), "tiles": _tcs(board, tiles), "tiles_axial": tiles }
		"card_blood":
			var cs: Array = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]
			_paint(board, cs, CWData.Tissue.CANCER)
			for c: Vector2i in cs:
				_cell(board, "melanoma", c)
			data = { "drawer": _tc(board, Vector2i(-1, 0)), "cells": _tcs(board, cs) }
	board.add_child(fx)
	fx.play(kind, data)
	fx.sync(t)


func _build(kind: String) -> void:
	var shots: Array = SHOTS.get(kind, [0.3, 0.9, 1.5])
	for k in COLS:
		var holder := SubViewportContainer.new()
		holder.position = Vector2(k * COL_W, 0)
		holder.size = Vector2(COL_W, COL_H)
		var vp := SubViewport.new()
		vp.size = Vector2i(COL_W, COL_H)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		holder.add_child(vp)
		var board: Node2D = load("res://scenes/Board.tscn").instantiate()
		board.scale = Vector2(ZOOM, ZOOM)
		vp.add_child(board)
		root.add_child(holder)   ## 进树 → 棋盘 _ready 跑完，格子才在
		board.position = Vector2(COL_W / 2.0, COL_H / 2.0) - board.tile_center(C) * ZOOM
		_scene(kind, board, float(shots[k]))
		_cols.append(holder)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _settle > 0:
		_settle -= 1
		if _settle == 0:
			var kind: String = _kinds[_i]
			root.get_texture().get_image().save_png("%s_%s.png" % [_out, kind])
			print("saved ", kind)
			for h in _cols:
				root.remove_child(h)
				h.free()
			_cols.clear()
			_i += 1
			return _i >= _kinds.size()
		return false
	_build(_kinds[_i])
	_settle = SETTLE
	return false
