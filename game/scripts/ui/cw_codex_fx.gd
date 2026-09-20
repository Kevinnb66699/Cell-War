## 图鉴动画舞台：复用游戏内 CWSkillFx 与已落地的专用特效节点。
## 预览数据只提供固定的示例坐标，不参与对局规则或随机数。
extends Node2D

const SKILL_FX := preload("res://scripts/ui/skill_fx.gd")
const BEAM_FX := preload("res://scripts/ui/beam_fx.gd")
const CHAIN_FX := preload("res://scripts/ui/chain_fx.gd")
const HUNT_FX := preload("res://scripts/ui/hunt_fx.gd")
const CHEMO_FX := preload("res://scripts/ui/chemo_fx.gd")
const MARK_FX := preload("res://scripts/ui/mark_aura_fx.gd")
const MUCUS_FX := preload("res://scripts/ui/mucus_fx.gd")
const SEAL_FX := preload("res://scripts/ui/seal_fx.gd")

const IMMUNE_TEX := preload("res://assets/art/cells/anim/immune_breath.png")
const B_TEX := preload("res://assets/art/cells/anim/bcell_breath.png")
const T_TEX := preload("res://assets/art/cells/anim/tcell_breath.png")
const MACRO_TEX := preload("res://assets/art/cells/anim/macrophage_breath.png")
const DENDRITIC_TEX := preload("res://assets/art/cells/anim/dendritic_breath.png")
const MELANOMA_TEX := preload("res://assets/art/cells/anim/melanoma_breath.png")
const SIGNET_TEX := preload("res://assets/art/cells/anim/signet_breath.png")
const OSTEO_TEX := preload("res://assets/art/cells/anim/osteo_breath.png")
const SCLC_TEX := preload("res://assets/art/cells/anim/sclc_breath.png")
const HEALTH_TEX := preload("res://assets/art/tissue_normal.png")
const CANCER_TEX := preload("res://assets/art/tissue_cancer.png")

const CENTER := Vector2(150, 82)
## 与正式 CWBoard 的 BOARD_RADIUS=6 对齐：完整 127 格棋盘在展示框内绘制，
## 超出展示框的部分由外层 stage_clip.clip_contents 裁切。
const MAP_RADIUS := 6
const MAP_STEP := Vector2(36, 20)
const TOP_FACE_DY := 4.0
const CELL_FOOT_DY := 6.0
const Z_CELL := 2
const Z_OVER_BOARD := 4096
const DURATION := {
	"beam": 2.2, "chain": 0.7, "hunt": 2.2, "chemo": 2.0, "mark_aura": 1.6,
	"mucus": 1.75, "seal": 2.2,
}

var _fx: Node2D
var _special: Node2D
var _kind := ""
var _time := 0.0
var _speed := 1.0
var _map_root: Node2D


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_build_map()
	set_process(true)


## 动画预览沿用正式棋盘的组织贴图，铺一块 19 格的蜂窝局部地图。
## 地图是持久背景；技能循环重播只清动态 FX，不重复创建或闪烁背景。
func _build_map() -> void:
	if _map_root != null and is_instance_valid(_map_root):
		return
	_map_root = Node2D.new()
	_map_root.name = "PreviewMap"
	## 不使用负 z-index：图鉴右侧的 Panel 是兄弟节点，负层会被它的背景完全盖住。
	## 地图与动画同处正常 Canvas 层，动态 FX 再用更高 z-index 压到地图之上。
	_map_root.z_index = 0
	_map_root.set_meta("codex_persistent", true)
	add_child(_map_root)
	## 完整铺设半径 6 的轴坐标棋盘（127 格）；地图故意远大于展示框，
	## 由外层裁切容器只显示框内部分。
	for q in range(-MAP_RADIUS, MAP_RADIUS + 1):
		var r_min: int = maxi(-MAP_RADIUS, -q - MAP_RADIUS)
		var r_max: int = mini(MAP_RADIUS, -q + MAP_RADIUS)
		for r in range(r_min, r_max + 1):
			var tile := Sprite2D.new()
			## 右侧几格为癌组织，让净化、攻击和扩散动画都有可读的地形语境。
			var cancerous := q > 0 or (q == 0 and r == -1)
			tile.texture = CANCER_TEX if cancerous else HEALTH_TEX
			## 正式棋盘的 Sprite2D 原点是 34px 贴图中心，比 26px 顶面中心低 4px。
			tile.position = _tile_center(Vector2i(q, r)) + Vector2(0, TOP_FACE_DY)
			tile.modulate = Color.WHITE
			tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			## 与 CWBoard.new_tissue() 相同：组织格按贴图中心 y 做画家排序。
			tile.z_index = int(tile.position.y)
			_map_root.add_child(tile)


## 与 CWBoard 的压扁轴坐标投影一致：六邻偏移为 (±36,0) / (±18,±20)。
static func _tile_center(coord: Vector2i) -> Vector2:
	return CENTER + Vector2((coord.x + coord.y * 0.5) * MAP_STEP.x, coord.y * MAP_STEP.y)


static func _cell_foot(coord: Vector2i) -> Vector2:
	return _tile_center(coord) + Vector2(0, CELL_FOOT_DY)


static func _tile_z(coord: Vector2i, above: int) -> int:
	return int(_tile_center(coord).y + TOP_FACE_DY) + above


static func _coord_nearest(point: Vector2) -> Vector2i:
	var best := Vector2i.ZERO
	var best_distance := INF
	for q in range(-MAP_RADIUS, MAP_RADIUS + 1):
		var r_min: int = maxi(-MAP_RADIUS, -q - MAP_RADIUS)
		var r_max: int = mini(MAP_RADIUS, -q + MAP_RADIUS)
		for r in range(r_min, r_max + 1):
			var coord := Vector2i(q, r)
			var distance := point.distance_squared_to(_tile_center(coord))
			if distance < best_distance:
				best_distance = distance
				best = coord
	return best


func set_speed(value: float) -> void:
	_speed = value


static func supports(kind: String) -> bool:
	return DURATION.has(kind) or SKILL_FX.DURATION.has(kind)


func replay() -> void:
	_time = 0.0
	_play_current()


func clear() -> void:
	for child in get_children():
		if not child.get_meta("codex_persistent", false):
			child.queue_free()
	_fx = null
	_special = null
	_kind = ""
	_time = 0.0


func play(kind: String) -> void:
	clear()
	if not supports(kind):
		push_warning("CWCodexFx: unsupported animation kind '%s'" % kind)
		return
	_kind = kind
	_play_current()


func _process(delta: float) -> void:
	if _kind == "":
		return
	_time += delta * _speed
	if _special != null:
		_sync_special(delta * _speed)
	if _fx != null:
		_fx.sync(delta * _speed)
	if _time >= _duration():
		_time = 0.0
		_play_current()


func _duration() -> float:
	if DURATION.has(_kind):
		return float(DURATION[_kind])
	return SKILL_FX.duration(_kind)


func _play_current() -> void:
	for child in get_children():
		if not child.get_meta("codex_persistent", false):
			child.queue_free()
	_fx = null
	_special = null
	if _kind in DURATION:
		_play_special()
		return
	_fx = SKILL_FX.new()
	_fx.z_index = Z_OVER_BOARD
	add_child(_fx)
	_fx.play(_kind, _sample(_kind))
	_add_actors(_kind)


func _sync_special(step: float) -> void:
	match _kind:
		"beam": (_special as CWBeamFx).sync(step)
		"chain": (_special as CWChainFx).sync(step)
		"hunt": (_special as CWHuntFx).sync(step)
		"chemo": (_special as CWChemoFx).sync(step, CENTER, 0, false)
		"mark_aura":
			var tiles := [
				{"pos": _tile_center(Vector2i.ZERO), "z": _tile_z(Vector2i.ZERO, 0)},
				{"pos": _tile_center(Vector2i(1, 0)), "z": _tile_z(Vector2i(1, 0), 0)},
				{"pos": _tile_center(Vector2i(0, 1)), "z": _tile_z(Vector2i(0, 1), 1)},
			]
			(_special as CWMarkAuraFx).sync(step, [{"origin": CENTER, "tiles": tiles}])
		"mucus": (_special as CWMucusFx).sync(step)
		"seal":
			var sealed: Array[Vector2] = [_tile_center(Vector2i(1, 0))]
			(_special as CWSealFx).sync(step, sealed)


func _play_special() -> void:
	_special = null
	match _kind:
		"beam":
			_special = BEAM_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
			(_special as CWBeamFx).play(_tile_center(Vector2i(-1, 0)), _tile_center(Vector2i(1, 0)), [_tile_center(Vector2i(0, 1))])
			_add_actor(T_TEX, Vector2i(-1, 0))
			_add_actor(MELANOMA_TEX, Vector2i(1, 0))
		"chain":
			_special = CHAIN_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
			(_special as CWChainFx).play(_tile_center(Vector2i(-1, 0)), _tile_center(Vector2i(1, 0)), 2, 0)
			_add_actor(MACRO_TEX, Vector2i(-1, 0))
		"hunt":
			_special = HUNT_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
			(_special as CWHuntFx).play(_tile_center(Vector2i(1, 0)), _tile_center(Vector2i.ZERO))
			_add_actor(DENDRITIC_TEX, Vector2i.ZERO)
			_add_actor(MELANOMA_TEX, Vector2i(1, 0))
		"chemo":
			_special = CHEMO_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
		"mark_aura":
			_special = MARK_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
			_add_actor(DENDRITIC_TEX, Vector2i.ZERO)
			_add_actor(MELANOMA_TEX, Vector2i(1, 0))
		"mucus":
			_special = MUCUS_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
			(_special as CWMucusFx).play(CENTER)
			_add_actor(SIGNET_TEX, Vector2i.ZERO)
		"seal":
			_special = SEAL_FX.new()
			_special.z_index = Z_OVER_BOARD
			add_child(_special)
			var targets: Array[Vector2] = [_tile_center(Vector2i(1, 0))]
			(_special as CWSealFx).play(_tile_center(Vector2i(-1, 0)), targets)
			_add_actor(B_TEX, Vector2i(-1, 0))
			_add_actor(MELANOMA_TEX, Vector2i(1, 0))


func _add_actor(texture: Texture2D, coord: Vector2i) -> void:
	var actor := Sprite2D.new()
	actor.texture = texture
	actor.hframes = 6
	actor.frame = 0
	actor.offset = Vector2(0, -texture.get_height() / 2.0)
	actor.position = _cell_foot(coord)
	actor.z_index = _tile_z(coord, Z_CELL)
	actor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(actor)


func _add_actors(kind: String) -> void:
	match kind:
		"antibody":
			_add_actor(B_TEX, Vector2i(-1, 0)); _add_actor(MELANOMA_TEX, Vector2i(1, 0))
		"toxin": _add_actor(T_TEX, Vector2i.ZERO)
		"lyse":
			_add_actor(T_TEX, Vector2i(-1, 0)); _add_actor(OSTEO_TEX, Vector2i(1, 0))
		"adhesion":
			_add_actor(MELANOMA_TEX, Vector2i(-1, 0)); _add_actor(MELANOMA_TEX, Vector2i(1, 0))
		"homing":
			_add_actor(MELANOMA_TEX, Vector2i(-1, 0)); _add_actor(MELANOMA_TEX, Vector2i(1, 0))
		"pseudopod": _add_actor(MELANOMA_TEX, Vector2i(-1, 0))
		"minimal":
			_add_actor(SCLC_TEX, Vector2i(-1, 0)); _add_actor(SCLC_TEX, Vector2i(1, 0))
		"differentiate", "respire", "revive_immune": _add_actor(IMMUNE_TEX, Vector2i.ZERO)
		"revive_cancer", "mutate", "anaerobic": _add_actor(MELANOMA_TEX, Vector2i.ZERO)
		_: _add_actor(IMMUNE_TEX, Vector2i.ZERO)


func _sample(kind: String) -> Dictionary:
	var a := _tile_center(Vector2i(-1, 0))
	var b := _tile_center(Vector2i(1, 0))
	var ring: Array[Vector2] = [_tile_center(Vector2i.ZERO), _tile_center(Vector2i(1, 0)),
		_tile_center(Vector2i(0, 1)), _tile_center(Vector2i(-1, 1)),
		_tile_center(Vector2i(-1, 0)), _tile_center(Vector2i(0, -1)),
		_tile_center(Vector2i(1, -1))]
	match kind:
		"antibody": return {"from": a, "targets": [b]}
		"toxin": return {"from": CENTER, "tiles": ring}
		"lyse": return {"from": a, "to": b}
		"adhesion": return {"from": a, "to": b}
		"homing": return {"from": a, "to": b, "spread": [_tile_center(Vector2i(1, 0)), _tile_center(Vector2i(0, 1)), _tile_center(Vector2i(1, -1))]}
		"pseudopod": return {"from": a, "to": b, "from_body": _cell_foot(Vector2i(-1, 0)) - Vector2(0, 12), "roots": [_tile_center(Vector2i(1, 0)) + Vector2(-12, 8), _tile_center(Vector2i(1, 0)) + Vector2(0, 12), _tile_center(Vector2i(1, 0)) + Vector2(12, 8)], "r": 12.0, "cid": 0, "to_tile": Vector2i(1, 0)}
		"minimal": return {"from": a, "to": b}
		"differentiate": return {"at": _tile_center(Vector2i.ZERO)}
		"respire": return {"at_body": _cell_foot(Vector2i.ZERO) - Vector2(0, 10), "at": _tile_center(Vector2i.ZERO), "r": 12.0}
		"revive_immune", "revive_cancer", "mutate": return {"at": _tile_center(Vector2i.ZERO)}
		"anaerobic": return {"at_body": _cell_foot(Vector2i.ZERO) - Vector2(0, 10), "at": _tile_center(Vector2i.ZERO), "r": 12.0, "sources": [a, b, _tile_center(Vector2i(0, -1))]}
		"card_radiation", "card_storm", "card_inflammation": return {"tiles": ring}
		"card_granule", "card_acid", "card_cascade": return {"from": a, "to": b, "tiles": [_tile_center(Vector2i(0, 1)), _tile_center(Vector2i(1, -1))]}
		"card_transfer": return {"from": a, "to": b}
		"card_teleport": return {"from": a, "to": b}
		"card_mark": return {"from": a, "to": b}
		"card_repair", "card_survive", "card_degrade": return {"at": _tile_center(Vector2i.ZERO)}
		"card_clone": return {"at": _tile_center(Vector2i.ZERO), "tiles": [_tile_center(Vector2i(1, 0)), _tile_center(Vector2i(0, 1)), _tile_center(Vector2i(-1, 1))], "tiles_axial": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1)]}
		"card_blood": return {"drawer": _tile_center(Vector2i.ZERO), "cells": [a, _tile_center(Vector2i.ZERO), b]}
	return {"at": _tile_center(Vector2i.ZERO)}
