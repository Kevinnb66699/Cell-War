## cw_case_loader.gd —— L0 用例的 `world` 段 → CWGame（测试迁移规格 A-2 / C-1 步 3；从 l0_runner.gd 原样搬出来）
##
## 两个地方用它：l0_runner.gd（跑探针）与 l0_pre_dump.gd（闸二 2b：装出来的世界编成 envelope，与 C# 侧逐字段比）。
## 显式键表：用例里出现表外的键 = 硬错（A-5 闸 2c），与 C# 侧 L0/CaseModel.cs 的记录逐键相同。
## ⚠ 测试设施，不改任何游戏行为；细胞 id = 在 cells 列表里的序号（与 C# loader 同口径，闸二 2b 靠这个对得上）。
## 不带 class_name（同 xcheck_* 的规矩），用 preload 取。
extends RefCounted

const CASE_KEYS := ["id", "probe", "source", "world", "args", "expect"]
const WORLD_KEYS := ["radius", "round", "phase", "seat", "players", "tiles", "cells", "tuning"]
const PLAYER_KEYS := ["seat", "faction", "level", "memory"]
const TILE_KEYS := ["at", "state", "type", "solid", "cell", "mucus", "necrosis", "ossify_at"]
const CELL_KEYS := ["seat", "type", "at", "energy", "equipped", "marked", "differentiated"]

var errors: PackedStringArray = []


func fail(msg: String) -> void:
	errors.append(msg)


## 字典只许含表里的键；否则记一条错并返回 false
func only_keys(d: Dictionary, allowed: Array, where: String) -> bool:
	for k in d.keys():
		if not (k in allowed):
			fail("%s 里有不认识的键「%s」（许可：%s）" % [where, str(k), ", ".join(allowed)])
			return false
	return true


## 返回 null = 装不出来（errors 里有原因）
func load_world(spec: Dictionary) -> CWGame:
	if not only_keys(spec, WORLD_KEYS, "world"):
		return null
	for p in spec.get("players", []):
		if not only_keys(p, PLAYER_KEYS, "players"):
			return null
	for t in spec.get("tiles", []):
		if not only_keys(t, TILE_KEYS, "tiles"):
			return null
	for c in spec.get("cells", []):
		if not only_keys(c, CELL_KEYS, "cells"):
			return null
	var players: Array = spec.get("players", [])
	if players.is_empty():
		fail("用例没写 players")
		return null
	var order: Array = []
	for p in players:
		order.append(CWData.Faction.IMMUNE if p.get("faction", "") == "immune" else CWData.Faction.CANCER)
	var g := CWGame.new()
	g.init(order, 1)
	g.board_radius = int(spec.get("radius", 6))
	g.round_no = int(spec.get("round", 1))
	g.setup.build_board(g.board_radius)
	for t in spec.get("tiles", []):
		var at := pos(t.get("at", ""))
		if not g.tiles.has(at):
			fail("这一格在半径 %d 的棋盘外：%s" % [g.board_radius, t.get("at", "")])
			return null
		var tile := CWSetup.make_tile(at)
		tile["tissue"] = _tissue(t.get("state", "healthy"))
		tile["special"] = _special(t.get("type", "normal"))
		tile["solid"] = int(t.get("solid", 0))
		tile["mucus"] = bool(t.get("mucus", false))
		tile["necrosis"] = int(t.get("necrosis", 0))
		tile["ossify_at"] = int(t.get("ossify_at", 0))
		g.tiles[at] = tile
	for p in players:
		if p.get("faction", "") != "immune":
			continue
		g.memory = int(p.get("memory", 0))
		g.immune_level = _level(p.get("level", "I"))
	for c in spec.get("cells", []):
		var pid := int(c.get("seat", 0))
		var kind: String = c.get("type", "ImmuneBasic")
		var cell := CWSetup.make_cell(g.cells.size(), pid, _faction_of(kind), pos(c.get("at", "")),
			_itype(kind), _ctype(kind), int(c.get("energy", 300)))
		cell["marked"] = bool(c.get("marked", false))
		cell["differentiated"] = bool(c.get("differentiated", false))
		for s in c.get("equipped", []):
			cell["equipped"].append(s)
		g.cells.append(cell)
	## players[].cell_id 指向自己的细胞（init 填的是 pid，L0 盘面上不一定按席位序落子）；癌种从该席的细胞推，没落子 = -1（与 C# loader 同口径）
	for p in g.players:
		p["cell_id"] = -1
		p.erase("cancer_type")
	for i in g.cells.size():
		var owner: Dictionary = g.players[int(g.cells[i]["pid"])]
		owner["cell_id"] = i
		if int(g.cells[i]["ctype"]) >= 0:
			owner["cancer_type"] = int(g.cells[i]["ctype"])
	## 阶段与当前席位：C# 的 L0World 有 phase（默认 PlayerAction）与 seat（默认 0），GD 这边把流程游标摆到同一处
	var stage: String = { "Setup": "setup_place", "S": "round_start", "PlayerAction": "turn", "E": "e_phase" }.get(str(spec.get("phase", "PlayerAction")), "")
	if stage == "":
		fail("不认识的阶段：%s（只认 Setup / S / PlayerAction / E）" % str(spec.get("phase", "")))
		return null
	g.flow["stage"] = stage
	g.phase = CWGame.PHASE_NAMES.get(stage, g.phase)
	g.current_pid = int(spec.get("seat", 0)) if stage == "turn" else -1
	## 用例若在格上写了 cell（席位），必须与 cells 段一致 —— 两边各自反推、互相校验（闸二 2b 抓过这条口径相反）
	for t in spec.get("tiles", []):
		var declared := int(t.get("cell", -1))
		if declared < 0:
			continue
		var at := pos(t.get("at", ""))
		var here: Array = g.cells_at(at)
		if here.is_empty() or int(here[0]["pid"]) != declared:
			fail("格 %s 写了 cell=%d，但 cells 段里没有席位 %d 的细胞站在那儿" % [t.get("at", ""), declared, declared])
			return null
	for key in spec.get("tuning", {}):
		if not key in g.tune:
			fail("CWTuning 上没有这个旋钮：%s" % key)
			return null
		g.tune.set(key, spec["tuning"][key])
	return g if errors.is_empty() else null


func pos(text: String) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2:
		fail("坐标要写成 \"q,r\"，拿到的是 \"%s\"" % text)
		return Vector2i.ZERO
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


func _tissue(s: String) -> int:
	match s:
		"healthy": return CWData.Tissue.HEALTHY
		"cancer": return CWData.Tissue.CANCER
		"solid": return CWData.Tissue.SOLID
	fail("不认识的组织状态：%s" % s)
	return CWData.Tissue.HEALTHY


func _special(s: String) -> int:
	match s:
		"normal": return CWData.Special.NONE
		"core": return CWData.Special.CORE
		"marrow": return CWData.Special.MARROW
		"vessel": return CWData.Special.VESSEL
	fail("不认识的组织类型：%s" % s)
	return CWData.Special.NONE


func _level(s: String) -> int:
	match s:
		"I": return 0
		"II": return 1
		"III": return 2
		"X": return 3
	fail("不认识的免疫等级：%s" % s)
	return 0


func _faction_of(kind: String) -> int:
	return CWData.Faction.CANCER if kind in ["Melanoma", "SignetRing", "Osteosarcoma", "SmallCellLung"] \
		else CWData.Faction.IMMUNE


func _itype(kind: String) -> int:
	match kind:
		"ImmuneBasic": return CWData.ImmuneType.BASIC
		"BCell": return CWData.ImmuneType.B_CELL
		"TCell": return CWData.ImmuneType.T_CELL
		"Macrophage": return CWData.ImmuneType.MACRO
		"Dendritic": return CWData.ImmuneType.DENDRITIC
	return -1


func _ctype(kind: String) -> int:
	match kind:
		"Melanoma": return CWData.CancerType.MELANOMA
		"SignetRing": return CWData.CancerType.SIGNET
		"Osteosarcoma": return CWData.CancerType.OSTEO
		"SmallCellLung": return CWData.CancerType.SCLC
	return -1
