## cw_world_loader.gd —— cwxworld/2 的 `world` 段 ⇄ CWGame（测试迁移规格 A-2 / C-1 步 8；键表口径 = 规格 §0.6.1）
##
## 此前它住在 game/tests/cw_case_loader.gd（测试工具）。新手引导（docs/新手引导_实现方案.md S0，2026-09-19）要在产品代码里
## 用它灌关卡盘面，而导出预设 exclude_filter="tests/*" —— 产品侧 preload("res://tests/…") 一导出就白屏，所以上提到
## scripts/kernel/；tests/cw_case_loader.gd 改为薄委托（extends 这里），**不许出现第三份键表**。旋钮白名单 TUNE_PATH 仍指
## res://tests/contract_tune.json：第一章零旋钮、_load_tuning 在 tuning 为空时直接返回，json 到第一次真拧旋钮那一片再搬（方案 §2.2）。
##
## 四处用它：l0_runner.gd（跑探针与契约步）、l0_pre_dump.gd（闸二 2b）、tests/rec/（录制代理落 pre/post）、教程舞台（S3 起）。
## 显式键表：用例里出现表外的键 = 硬错（闸 2c）。**仓库里只许两份键表**：这一份与 L0/CaseModel.cs，逐键相同（C# KeyTableTests 按路径读这个文件）。
##
## 四条口径（§0.6.1，改之前先读）：
##   1. **派生量不进 spec**：`tile.cell`（由 `cells[].at` 反推）、`chain_cell`（由 `cells[].chain_running`）、
##      细胞 `id`（由 cells 列表序）、`differentiated`（由 cells 现算）、`win_reason`（由 `win_kind` 现算）、
##      `feed_seq`（演出流水号）、`cancer_alarm.hold_rounds`（旋钮的转写）—— 写了当场红。
##   2. **loader 不编数据**：没有任何兜底推导。`marked` / `mark_left` / `mark_round` 写一个就得写三个；
##      癌席 `cancer_type` 必填、**没有 `"none"` 哨兵**；格子省略 `type` = **棋盘本来的特殊组织**
##      （`CWData.special_of(at)`），不是「抹成普通格」—— 后者正是 loader 在替用例编数据。
##   3. **dump 省略默认值**，`minify(spec)` 按同一张默认表把 spec 也削一遍；闸二 2a 比的是
##      `dump_world(load_world(spec)) ≡ minify(spec)`。loader 少读一个键，dump 就少一条，当场红。
##      `minify` 是**独立实现**，绝不转调 load/dump —— 转调了就是自己比自己，什么也抓不到。
##   4. **UNLOADABLE**：`load_world` 返回 null 且 `errors` 首条以 `"UNLOADABLE: "` 开头（§0.6.1 第 7 条）。
##      两个 runner 单列这一档计数并整体红 —— 仓库用例集里不许有装不进的用例。
##
## 细胞 33 键的账（§0.6.1 第 4 条）：构造三键 `seat` / `type` / `at` + 30 个可写状态键
## （`cw_obs_proto.gd:CELL` 去掉 `d` 的 36 键，减去派生的 `id` / `pid` / `faction` / `pos` / `itype` / `ctype`）。
##
## 不带 class_name（同 xcheck_* 的规矩），用 preload 取。
extends RefCounted

## 旋钮契约表（§0.6.3）。两侧同读这一份：C# 的 WorldLoader.WithKnob 也读它，按 tier 分桶，拒绝的集合必须一样。
const TUNE_PATH := "res://tests/contract_tune.json"

## cwxcase/2 的 13 键（§0.6.2 第 1 条）
const CASE_KEYS := ["schema", "id", "probe", "op", "covers", "status", "prd", "source",
	"harvested_from", "world", "rolls", "args", "expect"]
## cwxworld/2 的顶层 15 键（§0.6.1 第 1 条）
const WORLD_KEYS := ["radius", "round", "phase", "seat",
	"winner", "win_kind", "effector_round",
	"chemo", "chemo_track", "cancer_alarm",
	"players", "tiles", "cells", "events", "tuning"]
const PLAYER_KEYS := ["seat", "faction", "level", "memory", "cancer_type"]
## 12 键 = `at` + cw_setup.gd:make_tile 全 11 键。**不收 `cell`**：占位由 cells[].at 反推（§0.6.1 第 3 条）
const TILE_KEYS := ["at", "state", "type", "solid", "necrosis", "mucus", "newborn",
	"ossify_at", "store", "cards", "prod", "toxin_round"]
const CELL_KEYS := ["seat", "type", "at",
	"energy", "alive", "marked", "mark_left", "mark_round", "effector_used", "hand", "equipped",
	"mods", "play_n", "equip_seq", "fx_turn", "fx_round", "differentiated", "chemo_cd",
	"armor_used", "mutate_used", "toxin_used", "antibody_used", "metastasis_used", "jump_used",
	"draws_used", "attacks_used", "respawn_round", "camp_round", "camp_pos",
	"chain_left", "chain_bonus", "neutral_until", "chain_running"]
## 修饰条目四元组（E-2）：出处 cw_obs_proto.gd:MOD。**不带 `data`** —— 它不在 envelope 白名单里
const MOD_KEYS := ["name", "uses", "until", "seq"]
const EVENTS_KEYS := ["pool", "active", "double_next"]
const EFFECT_KEYS := ["name", "left", "stacks", "doubled", "data"]
const CHEMO_KEYS := ["at", "left", "by", "cid"]
const TRACK_KEYS := ["cid", "at", "left"]
## `hold_rounds` 是旋钮（tune.cancer_win_hold_rounds）的转写，走 tuning，不在这儿装（§0.6.1 第 1 条）
const ALARM_KEYS := ["streak"]

## `res://tests/l0` 下**不是用例数组**的文件。两个扫这个目录的脚本（l0_runner.gd / l0_pre_dump.gd）
## 都要跳过它们，否则「解不出用例数组」一条假红。diff 夹具按 §0.6.2 就住在这个目录里。
const NON_CASE_FILES := ["diff_fixture.json"]

## L0 的能量缺省是 **300（30.0）**，不是 CWData.INIT_ENERGY（30 = 3.0）—— 与 C# L0Cell.Energy = 300 同口径。
## 别「顺手改成常量」：改了 45 条老用例的盘面会整批变样（§0.6.1 第 4 条明写）。
const DEFAULT_ENERGY := 300

## `Finished` = 终局（winner 非空 ⇔ Finished，两侧 loader 都校验）：GD 的 stage 停在 e_phase、协议 phase 由 is_over 派生；C# 是 Phase.Finished
const PHASE_TO_STAGE := { "Setup": "setup_place", "S": "round_start", "PlayerAction": "turn", "E": "e_phase", "Finished": "e_phase" }
## `init` → `Setup`：老测试用 make_game 造的局停在 init（没跑 run_setup、细胞由测试手放），协议 `phase` 对 init / setup_place 都编成 setup，
## envelope 上等价 —— 不映的话录制代理 / 收割器对这类局一条都录不到（2026-09-19 首跑 t_pressure 5 条全 UNLOADABLE）
const STAGE_TO_PHASE := { "init": "Setup", "setup_place": "Setup", "round_start": "S", "turn": "PlayerAction", "e_phase": "E" }
const WINNER_WORDS := { "": -1, "immune": CWData.Faction.IMMUNE, "cancer": CWData.Faction.CANCER }
const WIN_KINDS := ["", "immune_clear", "cancer_weighted", "limit_cancer", "limit_immune"]
const CANCER_KINDS := ["Melanoma", "SignetRing", "Osteosarcoma", "SmallCellLung"]

static var _tune_table: Dictionary = {}

var errors: PackedStringArray = []


func fail(msg: String) -> void:
	errors.append(msg)


## 装不进这套数据结构（不是用例写错，是 GD 表达不出来）—— 首条恒以 "UNLOADABLE: " 开头（§0.6.1 第 7 条）
func unloadable(msg: String) -> void:
	errors.insert(0, "UNLOADABLE: " + msg)


## 字典只许含表里的键；否则记一条错并返回 false
func only_keys(d: Dictionary, allowed: Array, where: String) -> bool:
	for k in d.keys():
		if not (k in allowed):
			fail("%s 里有不认识的键「%s」（许可：%s）" % [where, str(k), ", ".join(allowed)])
			return false
	return true


## 旋钮契约表：`{旋钮名: {name, tier, gd, cs, in_rule_fields, note}}`（§0.6.3）
static func tune_table() -> Dictionary:
	if _tune_table.is_empty():
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TUNE_PATH))
		if raw is Dictionary and (raw as Dictionary).has("knobs"):
			var t := {}
			for row in (raw as Dictionary)["knobs"]:
				t[str((row as Dictionary).get("name", ""))] = row
			_tune_table = t
	return _tune_table


# =====================================================================
# 装载
# =====================================================================

## 返回 null = 装不出来（errors 里有原因；首条以 "UNLOADABLE: " 开头 = 结构上装不进）
func load_world(spec: Dictionary) -> CWGame:
	if not only_keys(spec, WORLD_KEYS, "world"):
		return null
	var players: Array = spec.get("players", [])
	if players.is_empty():
		fail("用例没写 players")
		return null
	for p in players:
		if not only_keys(p, PLAYER_KEYS, "players"):
			return null
	for t in spec.get("tiles", []):
		if not only_keys(t, TILE_KEYS, "tiles"):
			return null
	for c in spec.get("cells", []):
		if not only_keys(c, CELL_KEYS, "cells"):
			return null

	var order: Array = []
	for p in players:
		var faction := str(p.get("faction", ""))
		if faction != "immune" and faction != "cancer":
			fail("席位 %d 的 faction 只认 immune / cancer，拿到的是「%s」" % [int(p.get("seat", -1)), faction])
			return null
		order.append(CWData.Faction.IMMUNE if faction == "immune" else CWData.Faction.CANCER)
	var g := CWGame.new()
	g.init(order, 1)
	g.board_radius = int(spec.get("radius", CWData.BOARD_RADIUS))
	g.round_no = int(spec.get("round", 1))
	g.setup.build_board(g.board_radius)

	if not _load_tiles(g, spec):
		return _abort(g)
	if not _load_immune_globals(g, players):
		return _abort(g)
	if not _load_cells(g, spec):
		return _abort(g)
	if not _load_players(g, players):
		return _abort(g)
	if not _load_flow(g, spec):
		return _abort(g)
	if not _load_globals(g, spec):
		return _abort(g)
	if (str(spec.get("phase", "PlayerAction")) == "Finished") != (int(g.winner) != -1):
		unloadable("phase 写 Finished 当且仅当 winner 非空（协议 phase 由胜负派生：GD is_over / C# Phase.Finished）")
		return _abort(g)
	if not _load_events(g, spec):
		return _abort(g)
	if not _load_tuning(g, spec.get("tuning", {})):
		return _abort(g)
	return g if errors.is_empty() else _abort(g)


## CWGame 的九个模块件互相持有（m.game = self），不 dispose 就是一个引用环 ——
## 装不出来的那几条不拆，套件退出时会报 "ObjectDB instances leaked"
func _abort(g: CWGame) -> CWGame:
	g.dispose()
	return null


func _load_tiles(g: CWGame, spec: Dictionary) -> bool:
	for t in spec.get("tiles", []):
		var at := pos(str(t.get("at", "")))
		if not g.tiles.has(at):
			fail("这一格在半径 %d 的棋盘外：%s" % [g.board_radius, str(t.get("at", ""))])
			return false
		var tile: Dictionary = g.tiles[at]
		tile["tissue"] = _tissue(str(t.get("state", "healthy")))
		## 省略 type = 棋盘本来的那一格（core / marrow / vessel 照旧）。写死成 NONE 就是 loader 在编数据
		if t.has("type"):
			tile["special"] = _special(str(t["type"]))
		tile["solid"] = int(t.get("solid", 0))
		tile["necrosis"] = int(t.get("necrosis", 0))
		tile["mucus"] = bool(t.get("mucus", false))
		tile["newborn"] = bool(t.get("newborn", false))
		tile["ossify_at"] = int(t.get("ossify_at", 0))
		tile["store"] = int(t.get("store", 0))
		tile["cards"] = int(t.get("cards", 0))
		tile["prod"] = int(t.get("prod", 0))
		tile["toxin_round"] = int(t.get("toxin_round", 0))
	return errors.is_empty()


## GD 的抗原记忆 / 免疫等级是**阵营共享的全局量**（E-5：C# 那边加阵营级读法，这边不动）。
## 多免疫席位写得不一样 ⇒ GD 结构上装不出来，当场 UNLOADABLE，不许挑一条灌进去。
func _load_immune_globals(g: CWGame, players: Array) -> bool:
	var seen := false
	for p in players:
		if str(p.get("faction", "")) != "immune":
			continue
		var lv := _level(str(p.get("level", "I")))
		var mem := int(p.get("memory", 0))
		if seen and (lv != g.immune_level or mem != g.memory):
			unloadable("多个免疫席位的 level / memory 不一致 —— GD 是阵营共享的全局量，装不出来（E-5）")
			return false
		g.immune_level = lv
		g.memory = mem
		seen = true
	return true


func _load_cells(g: CWGame, spec: Dictionary) -> bool:
	for c in spec.get("cells", []):
		var pid := int(c.get("seat", 0))
		if pid < 0 or pid >= g.players.size():
			fail("细胞写了不存在的席位 %d" % pid)
			return false
		var kind := str(c.get("type", "ImmuneBasic"))
		if _faction_of(kind) == CWData.Faction.IMMUNE and _itype(kind) < 0:
			fail("不认识的细胞种类：%s" % kind)
			return false
		## 三个标记字段同进同出（§0.6.1 第 4 条）：写一个就得写三个，loader 不补默认
		var marks := 0
		for name in ["marked", "mark_left", "mark_round"]:
			if c.has(name):
				marks += 1
		if marks != 0 and marks != 3:
			fail("细胞（席位 %d）的 marked / mark_left / mark_round 只写了 %d 个 —— 写了一个就要三个都写" % [pid, marks])
			return false
		## 细胞 id = 在 cells 列表里的序号（与 C# loader 同口径，闸二 2b 靠这个对得上）
		var cell := CWSetup.make_cell(g.cells.size(), pid, _faction_of(kind), pos(str(c.get("at", ""))),
			_itype(kind), _ctype(kind), int(c.get("energy", DEFAULT_ENERGY)))
		cell["alive"] = bool(c.get("alive", true))
		cell["marked"] = bool(c.get("marked", false))
		cell["mark_left"] = int(c.get("mark_left", 0))
		cell["mark_round"] = int(c.get("mark_round", -1))
		cell["effector_used"] = bool(c.get("effector_used", false))
		cell["hand"] = _strings(c.get("hand", []))
		cell["equipped"] = _strings(c.get("equipped", []))
		cell["play_n"] = int(c.get("play_n", 0))
		cell["equip_seq"] = _str_int_map(c.get("equip_seq", {}))
		cell["fx_turn"] = _str_int_map(c.get("fx_turn", {}))
		## fx_round 的值恒为 true（cw_game.gd 的重置写的就是 true），spec 里写成名字数组即可，与 envelope 同形
		var fxr := {}
		for n in c.get("fx_round", []):
			fxr[str(n)] = true
		cell["fx_round"] = fxr
		cell["differentiated"] = bool(c.get("differentiated", false))
		cell["chemo_cd"] = int(c.get("chemo_cd", 0))
		cell["armor_used"] = bool(c.get("armor_used", false))
		cell["mutate_used"] = bool(c.get("mutate_used", false))
		cell["toxin_used"] = int(c.get("toxin_used", 0))
		cell["antibody_used"] = int(c.get("antibody_used", 0))
		cell["metastasis_used"] = bool(c.get("metastasis_used", false))
		cell["jump_used"] = int(c.get("jump_used", 0))
		cell["draws_used"] = int(c.get("draws_used", 0))
		cell["attacks_used"] = int(c.get("attacks_used", 0))
		cell["respawn_round"] = int(c.get("respawn_round", -1))
		cell["camp_round"] = int(c.get("camp_round", -1))
		cell["camp_pos"] = pos(str(c.get("camp_pos", "0,0")))
		## 动态 4 键（不在 make_cell 里，envelope 用 get 取默认）
		cell["chain_left"] = int(c.get("chain_left", 0))
		cell["chain_bonus"] = int(c.get("chain_bonus", 0))
		cell["neutral_until"] = int(c.get("neutral_until", -1))
		cell["chain_running"] = bool(c.get("chain_running", false))
		var mods: Array = []
		for m in c.get("mods", []):
			if not only_keys(m, MOD_KEYS, "cells[].mods"):
				return false
			mods.append({ "name": str(m.get("name", "")), "uses": int(m.get("uses", 0)),
				"until": str(m.get("until", "")), "seq": int(m.get("seq", 0)), "data": {} })
		cell["mods"] = mods
		g.cells.append(cell)
	## 一格一细胞：两只站同一格 ⇒ 语义键下标会静默换靶（A-1 的路径文法），装载期就拦掉
	var occupied := {}
	for cell in g.cells:
		var at: Vector2i = cell["pos"]
		if occupied.has(at):
			fail("格 %s 上站了两只细胞 —— cwxworld/2 不表达同格" % str(at))
			return false
		occupied[at] = true
	## 免疫分化种类由 cells 现算（§0.6.1 第 1 条）：不这么置，两侧 envelope 的 g.differentiated 对不上
	g.differentiated = _differentiated_of(g)
	return errors.is_empty()


## 现算口径（两侧逐字同）：`cell["differentiated"] == true` 且 itype 不是 BASIC 的那些 itype，去重后升序
static func _differentiated_of(g: CWGame) -> Array:
	var seen := {}
	for cell in g.cells:
		if not bool(cell.get("differentiated", false)):
			continue
		var t := int(cell["itype"])
		if t > CWData.ImmuneType.BASIC:
			seen[t] = true
	var out: Array = seen.keys()
	out.sort()
	return out


## players[].cell_id 指向自己的细胞（init 填的是 pid，L0 盘面上不一定按席位序落子）；
## 癌种**必填**、**不认 `"none"`**（§0.6.1 第 2 条）：没落子的那一席也得写一个真癌种。
func _load_players(g: CWGame, players: Array) -> bool:
	for p in g.players:
		p["cell_id"] = -1
		p.erase("cancer_type")
	for i in g.cells.size():
		g.players[int(g.cells[i]["pid"])]["cell_id"] = i
	for i in players.size():
		var spec_p: Dictionary = players[i]
		if int(spec_p.get("seat", i)) != i:
			fail("players 第 %d 条写的 seat 是 %d —— 席位按列表序，两者必须一致" % [i, int(spec_p.get("seat", i))])
			return false
		if str(spec_p.get("faction", "")) != "cancer":
			if spec_p.has("cancer_type"):
				fail("席位 %d 是免疫方，不许写 cancer_type" % i)
				return false
			continue
		if spec_p.has("level") or spec_p.has("memory"):
			fail("席位 %d 是癌方，不许写 level / memory（那是免疫阵营的共享量）" % i)
			return false
		if not spec_p.has("cancer_type"):
			fail("癌席 %d 没写 cancer_type —— 必填，且没有 \"none\" 哨兵（§0.6.1 第 2 条）" % i)
			return false
		var ct := _ctype(str(spec_p["cancer_type"]))
		if ct < 0:
			fail("不认识的癌种：%s（只认 %s）" % [str(spec_p["cancer_type"]), ", ".join(CANCER_KINDS)])
			return false
		g.players[i]["cancer_type"] = ct
		## 与该席细胞互校：cells[].type 已经把癌种说过一遍，两处写岔了要当场红（同 tile.cell 那条教训）
		var cid := int(g.players[i]["cell_id"])
		if cid >= 0 and int(g.cells[cid]["ctype"]) != ct:
			fail("癌席 %d 的 cancer_type 与它细胞的 type 对不上" % i)
			return false
	return true


func _load_flow(g: CWGame, spec: Dictionary) -> bool:
	var word := str(spec.get("phase", "PlayerAction"))
	var stage: String = PHASE_TO_STAGE.get(word, "")
	if stage == "":
		fail("不认识的阶段：%s（只认 Setup / S / PlayerAction / E / Finished）" % word)
		return false
	g.flow["stage"] = stage
	g.phase = CWGame.PHASE_NAMES.get(stage, g.phase)
	g.current_pid = int(spec.get("seat", 0)) if stage == "turn" else -1
	return true


func _load_globals(g: CWGame, spec: Dictionary) -> bool:
	var winner := str(spec.get("winner", ""))
	if not WINNER_WORDS.has(winner):
		fail("不认识的 winner：%s（只认 \"\" / immune / cancer）" % winner)
		return false
	g.winner = int(WINNER_WORDS[winner])
	var kind := str(spec.get("win_kind", ""))
	if not (kind in WIN_KINDS):
		fail("不认识的 win_kind：%s（只认 %s）" % [kind, ", ".join(WIN_KINDS)])
		return false
	g.win_kind = kind
	## win_reason 是文案，由 win_kind 现算 —— 不收、不 dump、对拍时抹空（§0.6.1 第 1 条）
	g.effector_round = int(spec.get("effector_round", -1))
	if spec.has("cancer_alarm"):
		var al: Dictionary = spec["cancer_alarm"]
		if not only_keys(al, ALARM_KEYS, "cancer_alarm"):
			return false
		g.cancer_win_streak = int(al.get("streak", 0))
	if spec.has("chemo"):
		var ch: Dictionary = spec["chemo"]
		if not only_keys(ch, CHEMO_KEYS, "chemo"):
			return false
		## by 与 cid 都写席位；by 落成席位本身（GD 的 chemo["by"] 存的就是 pid），cid 落成解析出来的 cell id
		var by := int(ch.get("by", -1))
		if _cell_of_seat(g, by, "chemo.by") == -2:
			return false
		var cid := _cell_of_seat(g, int(ch.get("cid", -1)), "chemo.cid")
		if cid == -2:
			return false
		g.chemo = { "at": pos(str(ch.get("at", "0,0"))), "left": int(ch.get("left", 0)), "by": by, "cid": cid }
	if spec.has("chemo_track"):
		var tr: Dictionary = spec["chemo_track"]
		if not only_keys(tr, TRACK_KEYS, "chemo_track"):
			return false
		var cid := _cell_of_seat(g, int(tr.get("cid", -1)), "chemo_track.cid")
		if cid == -2:
			return false
		g.chemo_track = { "cid": cid, "at": pos(str(tr.get("at", "0,0"))), "left": int(tr.get("left", 0)) }
	return true


## 席位 → 该席**唯一的活细胞**的 id（§0.6.1 第 1 条）。-1 原样透传 = 这一席的细胞已经死了 / 没有。
## `chemo.by` 也走这一条（它落成席位本身，但同样要求那一席解析得出唯一活细胞）。
## 返回 -2 = 出错了（0 只或 ≥2 只活细胞 ⇒ UNLOADABLE）
func _cell_of_seat(g: CWGame, seat: int, where: String) -> int:
	if seat == -1:
		return -1
	if seat < 0 or seat >= g.players.size():
		fail("%s 要写席位，拿到的是 %d" % [where, seat])
		return -2
	var found := -1
	var n := 0
	for i in g.cells.size():
		var cell: Dictionary = g.cells[i]
		if int(cell["pid"]) == seat and bool(cell["alive"]):
			found = i
			n += 1
	if n != 1:
		unloadable("%s 指到席位 %d，但这一席有 %d 只活细胞 —— 解析不出唯一的那一只（写 -1 表示已死）" % [where, seat, n])
		return -2
	return found


## ⚠ `events.pool` 自 2026-09-19（世界事件删除）起**缺省就是空表**，这里仍是
## **覆盖**不是追加（§0.6.1 第 5 条）—— 键是协议保留字段，用例照样能写。
func _load_events(g: CWGame, spec: Dictionary) -> bool:
	if not spec.has("events"):
		return true
	var ev: Dictionary = spec["events"]
	if not only_keys(ev, EVENTS_KEYS, "events"):
		return false
	if ev.has("pool"):
		g.events["pool"] = _strings(ev["pool"])
	g.events["double_next"] = bool(ev.get("double_next", false))
	var active: Array = []
	for e in ev.get("active", []):
		if not only_keys(e, EFFECT_KEYS, "events.active"):
			return false
		## `stacks: n` 装成**一条** stacks = n（§0.6.1 第 5 条；C# InstallEffect(name, left, stacks) 有这个形参）
		active.append({ "name": str(e.get("name", "")), "left": int(e.get("left", 0)),
			"stacks": int(e.get("stacks", 1)), "doubled": str(e.get("doubled", "")),
			"data": (e.get("data", {}) as Dictionary).duplicate(true) })
	g.events["active"] = active
	return true


## 四档处置（§0.6.3）：A / A′ 接；B 硬错并报「C# 无对应物（E-3）」；C 硬错报「不在白名单」；表外报「未知旋钮」。
## 往这里加「假旋钮」或静默跳过，两条都不许 —— 今天 GD「if not key in g.tune 全放行」作废。
func _load_tuning(g: CWGame, spec: Dictionary) -> bool:
	if spec.is_empty():
		return true
	var table := tune_table()
	if table.is_empty():
		fail("读不到 %s —— 旋钮契约表是两侧共用的唯一一份，没有它不许装旋钮" % TUNE_PATH)
		return false
	var def := CWTuning.new()
	## **两趟**（B5）：`name[]`（把分档表截到这个长度）一律先于 `name[i]`（改某一档）——
	## JSON 对象的键序不可靠，靠插入序就是给自己埋雷。C# `L0/WorldLoader.cs:Tune` 同
	for len_pass in [true, false]:
		for key in spec:
			if str(key).ends_with("[]") != len_pass:
				continue
			if not _load_knob(g, table, def, str(key), spec[key]):
				return false
	return true


## 一个旋钮的处置（四档白名单 + 三种写法：裸名 / `name[i]` / `name[]`）。
## 从 `_load_tuning` 里原样搬出来的 —— 搬的理由是那边要跑两趟，不是这里要改判据。
func _load_knob(g: CWGame, table: Dictionary, def: CWTuning, key: String, value: Variant) -> bool:
	var name := key
	var idx := -1
	var is_len := false
	if name.ends_with("]"):
		var lb := name.find("[")
		if lb < 0:
			fail("旋钮下标写错了：%s（形如 proliferate_per_adjacent[1]，1 基；`name[]` = 表长）" % name)
			return false
		var idx_text := name.substr(lb + 1, name.length() - lb - 2)
		name = name.substr(0, lb)
		if idx_text == "":
			is_len = true   ## B5：`name[]` = 把这张分档表截到这个长度
		else:
			idx = int(idx_text)
	if not table.has(name):
		fail("未知旋钮：%s（不在 %s 里）" % [name, TUNE_PATH])
		return false
	var tier := str((table[name] as Dictionary).get("tier", ""))
	if tier == "B":
		fail("旋钮 %s：**C# 无对应物（E-3）** —— 这不是 loader 的活，是内核的活" % name)
		return false
	if tier == "C":
		fail("旋钮 %s 不在白名单（contract_tune.json C 档：登记在案、不接）" % name)
		return false
	if tier != "A" and tier != "A'":
		fail("旋钮 %s 的 tier「%s」不认识（只认 A / A' / B / C）" % [name, tier])
		return false
	if not name in g.tune:
		fail("CWTuning 上没有这个旋钮：%s" % name)
		return false
	if is_len:
		## B5-2 本批**只许缩短（含清空）**：加长要先定新槽位的初值，本批不定 ⇒ UNLOADABLE（不是 fail）。
		## 两趟保证这一步之前没人动过长度，所以这里的当前长度就是缺省长度
		if not (g.tune.get(name) is Array):
			fail("旋钮 %s 不是分档表，写不得 %s[]" % [name, name])
			return false
		var tbl: Array = g.tune.get(name)
		var want := int(value)
		if want < 0 or want > tbl.size():
			unloadable("旋钮 %s[] 要 %d 档，缺省只有 %d 档 —— 本批只许缩短（含清空），加长得先定新槽位的初值" % [name, want, tbl.size()])
			return false
		g.tune.set(name, tbl.slice(0, want))
		return true
	if idx >= 0:
		var arr: Array = g.tune.get(name)
		if idx < 1 or idx > arr.size():
			fail("旋钮下标越界：%s[%d]（1..%d，1 基）" % [name, idx, arr.size()])
			return false
		if not _is_num(arr[idx - 1]):
			fail("旋钮 %s 的档位不是整数（%s）—— cwxtune/1 只表达 int / bool / 分档整数表" % [name, type_string(typeof(arr[idx - 1]))])
			return false
		arr[idx - 1] = int(value)
		return true
	## 值一律是 int（C# 那边是 Dictionary<string,int>），bool 写 1/0；按属性本来的类型落地
	var cur: Variant = def.get(name)
	if cur is bool:
		g.tune.set(name, int(value) != 0)
	elif cur is Array:
		fail("旋钮 %s 是分档表，要写下标：%s[i]（1 基）或 %s[]（表长）" % [name, name, name])
		return false
	elif not _is_num(cur):
		fail("旋钮 %s 不是整数旋钮（%s）—— cwxtune/1 只表达 int / bool / 分档整数表" % [name, type_string(typeof(cur))])
		return false
	else:
		g.tune.set(name, int(value))
	return true


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


# =====================================================================
# dump —— 闸二 2a 的载体（A-2 末段）。没有它，「只进世界不进文件」的字段永远漏
# =====================================================================

func dump_world(g: CWGame) -> Dictionary:
	var out := {}
	if int(g.board_radius) != CWData.BOARD_RADIUS:
		out["radius"] = int(g.board_radius)
	if int(g.round_no) != 1:
		out["round"] = int(g.round_no)
	var stage := str(g.flow["stage"])
	var word: String = STAGE_TO_PHASE.get(stage, "")
	if word == "":
		unloadable("流程停在「%s」，cwxworld/2 只表达 Setup / S / PlayerAction / E / Finished" % stage)
		return {}
	if int(g.winner) != -1:
		word = "Finished"   ## 终局：协议 phase 由 is_over 派生，spec 里写 Finished（与 C# Phase.Finished 同）
	if word != "PlayerAction":
		out["phase"] = word
	if stage == "turn" and int(g.current_pid) != 0:
		out["seat"] = int(g.current_pid)
	if int(g.winner) != -1:
		out["winner"] = "immune" if int(g.winner) == CWData.Faction.IMMUNE else "cancer"
	if str(g.win_kind) != "":
		out["win_kind"] = str(g.win_kind)
	if int(g.effector_round) != -1:
		out["effector_round"] = int(g.effector_round)
	if not g.chemo.is_empty():
		out["chemo"] = { "at": at_text(g.chemo["at"]), "left": int(g.chemo["left"]),
			"by": int(g.chemo["by"]), "cid": _seat_of_cell(g, int(g.chemo.get("cid", -1))) }
	if not g.chemo_track.is_empty():
		out["chemo_track"] = { "cid": _seat_of_cell(g, int(g.chemo_track.get("cid", -1))),
			"at": at_text(g.chemo_track.get("at", Vector2i.ZERO)), "left": int(g.chemo_track.get("left", 0)) }
	if int(g.cancer_win_streak) != 0:
		out["cancer_alarm"] = { "streak": int(g.cancer_win_streak) }
	out["players"] = _dump_players(g)
	var tiles := _dump_tiles(g)
	if not tiles.is_empty():
		out["tiles"] = tiles
	var cells := _dump_cells(g)
	if not cells.is_empty():
		out["cells"] = cells
	var ev := _dump_events(g)
	if not ev.is_empty():
		out["events"] = ev
	var tn := _dump_tuning(g)
	if not tn.is_empty():
		out["tuning"] = tn
	## 规矩 5（A-4「装不回去就不录」）的执行机构：半路报过错就整份作废。
	## 录制代理只看返回值空不空（cw_recorder.gd:begin/finish），
	## 半截 players 一旦当成 world 落进草稿，两侧装的就不是同一个世界。
	if not errors.is_empty():
		return {}
	return out


## cell id → 席位（spec 里 chemo.cid / chemo_track.cid 写的是席位）；-1 原样
func _seat_of_cell(g: CWGame, cid: int) -> int:
	if cid < 0 or cid >= g.cells.size():
		return -1
	return int(g.cells[cid]["pid"])


func _dump_players(g: CWGame) -> Array:
	var out: Array = []
	for p in g.players:
		var immune := int(p["faction"]) == CWData.Faction.IMMUNE
		var e := { "seat": int(p["id"]), "faction": "immune" if immune else "cancer" }
		if immune:
			if int(g.immune_level) != 0:
				e["level"] = _level_name(int(g.immune_level))
			if int(g.memory) != 0:
				e["memory"] = int(g.memory)
		else:
			var ct := int(p.get("cancer_type", -1))
			if ct < 0:
				unloadable("癌席 %d 没有癌种 —— cwxworld/2 的 cancer_type 必填，没有 \"none\" 哨兵" % int(p["id"]))
				return out
			e["cancer_type"] = _ctype_name(ct)
		out.append(e)
	return out


func _dump_tiles(g: CWGame) -> Array:
	var keys: Array = g.tiles.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	var out: Array = []
	for c: Vector2i in keys:
		var t: Dictionary = g.tiles[c]
		var e := { "at": at_text(c) }
		if int(t["tissue"]) != CWData.Tissue.HEALTHY:
			e["state"] = _tissue_name(int(t["tissue"]))
		## 默认 = 棋盘本来的特殊组织（§0.6.1 第 3 条），不是 normal
		if int(t["special"]) != int(CWData.special_of(c)):
			e["type"] = _special_name(int(t["special"]))
		for pair in [["solid", 0], ["necrosis", 0], ["ossify_at", 0], ["store", 0],
				["cards", 0], ["prod", 0], ["toxin_round", 0]]:
			if int(t[pair[0]]) != int(pair[1]):
				e[pair[0]] = int(t[pair[0]])
		for name in ["mucus", "newborn"]:
			if bool(t[name]):
				e[name] = true
		if e.size() > 1:
			out.append(e)
	return out


func _dump_cells(g: CWGame) -> Array:
	var out: Array = []
	for cell in g.cells:
		var e := { "seat": int(cell["pid"]), "type": _kind_name(cell), "at": at_text(cell["pos"]) }
		if int(cell["energy"]) != DEFAULT_ENERGY:
			e["energy"] = int(cell["energy"])
		if not bool(cell["alive"]):
			e["alive"] = false
		## 三键同进同出：任一个不是默认值就三个一起写（loader 那边也是「写一个就得写三个」）
		if bool(cell["marked"]) or int(cell["mark_left"]) != 0 or int(cell["mark_round"]) != -1:
			e["marked"] = bool(cell["marked"])
			e["mark_left"] = int(cell["mark_left"])
			e["mark_round"] = int(cell["mark_round"])
		if not (cell["hand"] as Array).is_empty():
			e["hand"] = _strings(cell["hand"])
		if not (cell["equipped"] as Array).is_empty():
			e["equipped"] = _strings(cell["equipped"])
		if not (cell["mods"] as Array).is_empty():
			var mods: Array = []
			for m in cell["mods"]:
				mods.append({ "name": str(m["name"]), "uses": int(m.get("uses", 0)),
					"until": str(m.get("until", "")), "seq": int(m.get("seq", 0)) })
			e["mods"] = mods
		if not (cell["equip_seq"] as Dictionary).is_empty():
			e["equip_seq"] = _str_int_map(cell["equip_seq"])
		if not (cell["fx_turn"] as Dictionary).is_empty():
			e["fx_turn"] = _str_int_map(cell["fx_turn"])
		if not (cell["fx_round"] as Dictionary).is_empty():
			var fxr: Array = _strings((cell["fx_round"] as Dictionary).keys())
			fxr.sort()
			e["fx_round"] = fxr
		for pair in [["play_n", 0], ["chemo_cd", 0], ["toxin_used", 0], ["antibody_used", 0],
				["jump_used", 0], ["draws_used", 0], ["attacks_used", 0], ["respawn_round", -1],
				["camp_round", -1], ["chain_left", 0], ["chain_bonus", 0], ["neutral_until", -1]]:
			if int(cell.get(pair[0], pair[1])) != int(pair[1]):
				e[pair[0]] = int(cell.get(pair[0], pair[1]))
		for name in ["effector_used", "differentiated", "armor_used", "mutate_used",
				"metastasis_used", "chain_running"]:
			if bool(cell.get(name, false)):
				e[name] = true
		if Vector2i(cell["camp_pos"]) != Vector2i.ZERO:
			e["camp_pos"] = at_text(cell["camp_pos"])
		out.append(e)
	return out


func _dump_events(g: CWGame) -> Dictionary:
	var out := {}
	var pool: Array = _strings(g.events["pool"])
	if not pool.is_empty():   ## 空表 = 缺省（世界事件删除后 pool 恒 []）
		out["pool"] = pool
	if bool(g.events["double_next"]):
		out["double_next"] = true
	var active: Array = []
	for e in g.events["active"]:
		active.append({ "name": str(e["name"]), "left": int(e.get("left", 0)),
			"stacks": int(e.get("stacks", 1)), "doubled": str(e.get("doubled", "")),
			"data": (e.get("data", {}) as Dictionary).duplicate(true) })
	if not active.is_empty():
		out["active"] = active
	return out


func _dump_tuning(g: CWGame) -> Dictionary:
	var out := {}
	var def := CWTuning.new()
	var table := tune_table()
	var names: Array = table.keys()
	names.sort()
	for key in names:
		var name := str(key)
		var tier := str((table[name] as Dictionary).get("tier", ""))
		if tier != "A" and tier != "A'":
			continue
		if not name in g.tune:
			continue
		var v: Variant = g.tune.get(name)
		var d: Variant = def.get(name)
		if v is Array:
			var cur: Array = v
			var dv: Array = d
			## B5-3：长度不同（含被清空）先写 `name[]`。以前空表连循环体都不进 ——
			## 「分档表被清空」在 dump 里一个键都不出现，往返回来表又满了（COVERAGE 的 B5）
			if cur.size() != dv.size():
				out["%s[]" % name] = cur.size()
			for i in mini(cur.size(), dv.size()):
				## 非整数的分档表（erosion_tiles 是 Array[Vector2i]）cwxtune/1 表达不了，装载期也进不来
				if not _is_num(cur[i]):
					break
				if int(cur[i]) != int(dv[i]):
					out["%s[%d]" % [name, i + 1]] = int(cur[i])
			continue
		if v == d:
			continue
		if not (v is bool) and not _is_num(v):
			continue
		out[name] = (1 if v else 0) if v is bool else int(v)
	return out


# =====================================================================
# minify —— 闸二 2a 的另一半。**独立实现**：不许转调 load/dump（纪律 3 的同一条理由）
# =====================================================================

func minify(spec: Dictionary) -> Dictionary:
	var out := {}
	for pair in [["radius", CWData.BOARD_RADIUS], ["round", 1], ["seat", 0], ["effector_round", -1]]:
		if spec.has(pair[0]) and int(spec[pair[0]]) != int(pair[1]):
			out[pair[0]] = int(spec[pair[0]])
	for pair in [["phase", "PlayerAction"], ["winner", ""], ["win_kind", ""]]:
		if spec.has(pair[0]) and str(spec[pair[0]]) != str(pair[1]):
			out[pair[0]] = str(spec[pair[0]])
	for name in ["chemo", "chemo_track"]:
		if spec.has(name):
			out[name] = _minify_chemo(spec[name], name)
	if spec.has("cancer_alarm") and int((spec["cancer_alarm"] as Dictionary).get("streak", 0)) != 0:
		out["cancer_alarm"] = { "streak": int(spec["cancer_alarm"]["streak"]) }
	var players: Array = []
	for p in spec.get("players", []):
		var immune := str(p.get("faction", "")) == "immune"
		var e := { "seat": int(p.get("seat", 0)), "faction": str(p.get("faction", "")) }
		if immune:
			if str(p.get("level", "I")) != "I":
				e["level"] = str(p["level"])
			if int(p.get("memory", 0)) != 0:
				e["memory"] = int(p["memory"])
		else:
			e["cancer_type"] = str(p.get("cancer_type", ""))
		players.append(e)
	out["players"] = players
	var tiles: Array = []
	for t in spec.get("tiles", []):
		var at := pos(str(t.get("at", "")))
		var e := { "at": at_text(at) }
		if str(t.get("state", "healthy")) != "healthy":
			e["state"] = str(t["state"])
		if t.has("type") and _special(str(t["type"])) != int(CWData.special_of(at)):
			e["type"] = str(t["type"])
		for pair in [["solid", 0], ["necrosis", 0], ["ossify_at", 0], ["store", 0],
				["cards", 0], ["prod", 0], ["toxin_round", 0]]:
			if int(t.get(pair[0], pair[1])) != int(pair[1]):
				e[pair[0]] = int(t[pair[0]])
		for name in ["mucus", "newborn"]:
			if bool(t.get(name, false)):
				e[name] = true
		if e.size() > 1:
			tiles.append(e)
	## 与 dump 同一个规范序（按 q 再按 r）—— 2a 是逐下标比的，spec 里格子的书写顺序不该让闸红
	tiles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := pos(str(a["at"]))
		var pb := pos(str(b["at"]))
		return pa.x < pb.x or (pa.x == pb.x and pa.y < pb.y))
	if not tiles.is_empty():
		out["tiles"] = tiles
	var cells: Array = []
	for c in spec.get("cells", []):
		var e := { "seat": int(c.get("seat", 0)), "type": str(c.get("type", "ImmuneBasic")),
			"at": at_text(pos(str(c.get("at", "")))) }
		if int(c.get("energy", DEFAULT_ENERGY)) != DEFAULT_ENERGY:
			e["energy"] = int(c["energy"])
		if not bool(c.get("alive", true)):
			e["alive"] = false
		if bool(c.get("marked", false)) or int(c.get("mark_left", 0)) != 0 or int(c.get("mark_round", -1)) != -1:
			e["marked"] = bool(c.get("marked", false))
			e["mark_left"] = int(c.get("mark_left", 0))
			e["mark_round"] = int(c.get("mark_round", -1))
		for name in ["hand", "equipped"]:
			if not (c.get(name, []) as Array).is_empty():
				e[name] = _strings(c[name])
		if not (c.get("mods", []) as Array).is_empty():
			var mods: Array = []
			for m in c["mods"]:
				mods.append({ "name": str(m.get("name", "")), "uses": int(m.get("uses", 0)),
					"until": str(m.get("until", "")), "seq": int(m.get("seq", 0)) })
			e["mods"] = mods
		for name in ["equip_seq", "fx_turn"]:
			if not (c.get(name, {}) as Dictionary).is_empty():
				e[name] = _str_int_map(c[name])
		if not (c.get("fx_round", []) as Array).is_empty():
			var fxr: Array = _strings(c["fx_round"])
			fxr.sort()
			e["fx_round"] = fxr
		for pair in [["play_n", 0], ["chemo_cd", 0], ["toxin_used", 0], ["antibody_used", 0],
				["jump_used", 0], ["draws_used", 0], ["attacks_used", 0], ["respawn_round", -1],
				["camp_round", -1], ["chain_left", 0], ["chain_bonus", 0], ["neutral_until", -1]]:
			if int(c.get(pair[0], pair[1])) != int(pair[1]):
				e[pair[0]] = int(c[pair[0]])
		for name in ["effector_used", "differentiated", "armor_used", "mutate_used",
				"metastasis_used", "chain_running"]:
			if bool(c.get(name, false)):
				e[name] = true
		if str(c.get("camp_pos", "0,0")) != "0,0":
			e["camp_pos"] = at_text(pos(str(c["camp_pos"])))
		cells.append(e)
	if not cells.is_empty():
		out["cells"] = cells
	if spec.has("events"):
		var ev: Dictionary = spec["events"]
		var e := {}
		var pl: Array = _strings(ev.get("pool", []))
		if not pl.is_empty():   ## 空表 = 缺省（与 _dump_events 同口径，否则 §0.6.5 往返自证红）
			e["pool"] = pl
		if bool(ev.get("double_next", false)):
			e["double_next"] = true
		var active: Array = []
		for x in ev.get("active", []):
			active.append({ "name": str(x.get("name", "")), "left": int(x.get("left", 0)),
				"stacks": int(x.get("stacks", 1)), "doubled": str(x.get("doubled", "")),
				"data": (x.get("data", {}) as Dictionary).duplicate(true) })
		if not active.is_empty():
			e["active"] = active
		if not e.is_empty():
			out["events"] = e
	var tn := _minify_tuning(spec.get("tuning", {}))
	if not tn.is_empty():
		out["tuning"] = tn
	return out


func _minify_chemo(raw: Variant, which: String) -> Dictionary:
	var d: Dictionary = raw
	if which == "chemo":
		return { "at": at_text(pos(str(d.get("at", "0,0")))), "left": int(d.get("left", 0)),
			"by": int(d.get("by", -1)), "cid": int(d.get("cid", -1)) }
	return { "cid": int(d.get("cid", -1)), "at": at_text(pos(str(d.get("at", "0,0")))), "left": int(d.get("left", 0)) }


func _minify_tuning(spec: Dictionary) -> Dictionary:
	var out := {}
	var def := CWTuning.new()
	for key in spec:
		var name := str(key)
		var v: Variant = spec[key]
		var iv := (1 if v else 0) if v is bool else int(v)
		if name.ends_with("]"):
			var lb := name.find("[")
			if lb < 0:
				continue
			var base := name.substr(0, lb)
			var idx_text := name.substr(lb + 1, name.length() - lb - 2)
			if not base in def:
				continue
			var d: Array = def.get(base)
			## B5-4：`name[]` 只在与**缺省长度**不同时出现（与 dump 同一条规则，独立实现）
			if idx_text == "":
				if iv != d.size():
					out[name] = iv
				continue
			var idx := int(idx_text)
			if idx >= 1 and idx <= d.size() and _is_num(d[idx - 1]) and int(d[idx - 1]) == iv:
				continue
			out[name] = iv
			continue
		if not name in def:
			continue
		var dv: Variant = def.get(name)
		if not (dv is bool) and not _is_num(dv):
			continue
		var div := (1 if dv else 0) if dv is bool else int(dv)
		if div == iv:
			continue
		out[name] = iv
	return out


# ---- 小工具 ----

func pos(text: String) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2:
		fail("坐标要写成 \"q,r\"，拿到的是 \"%s\"" % text)
		return Vector2i.ZERO
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


static func at_text(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]


static func _strings(list) -> Array:
	var out: Array = []
	for s in list:
		out.append(str(s))
	return out


static func _str_int_map(d: Dictionary) -> Dictionary:
	var out := {}
	var keys: Array = d.keys()
	keys.sort()
	for k in keys:
		out[str(k)] = int(d[k])
	return out


func _tissue(s: String) -> int:
	match s:
		"healthy": return CWData.Tissue.HEALTHY
		"cancer": return CWData.Tissue.CANCER
		"solid": return CWData.Tissue.SOLID
	fail("不认识的组织状态：%s" % s)
	return CWData.Tissue.HEALTHY


static func _tissue_name(v: int) -> String:
	match v:
		CWData.Tissue.CANCER: return "cancer"
		CWData.Tissue.SOLID: return "solid"
	return "healthy"


func _special(s: String) -> int:
	match s:
		"normal": return CWData.Special.NONE
		"core": return CWData.Special.CORE
		"marrow": return CWData.Special.MARROW
		"vessel": return CWData.Special.VESSEL
	fail("不认识的组织类型：%s" % s)
	return CWData.Special.NONE


static func _special_name(v: int) -> String:
	match v:
		CWData.Special.CORE: return "core"
		CWData.Special.MARROW: return "marrow"
		CWData.Special.VESSEL: return "vessel"
	return "normal"


func _level(s: String) -> int:
	match s:
		"I": return 0
		"II": return 1
		"III": return 2
		"X": return 3
	fail("不认识的免疫等级：%s" % s)
	return 0


static func _level_name(v: int) -> String:
	return ["I", "II", "III", "X"][clampi(v, 0, 3)]


static func _faction_of(kind: String) -> int:
	return CWData.Faction.CANCER if kind in CANCER_KINDS else CWData.Faction.IMMUNE


static func _itype(kind: String) -> int:
	match kind:
		"ImmuneBasic": return CWData.ImmuneType.BASIC
		"BCell": return CWData.ImmuneType.B_CELL
		"TCell": return CWData.ImmuneType.T_CELL
		"Macrophage": return CWData.ImmuneType.MACRO
		"Dendritic": return CWData.ImmuneType.DENDRITIC
	return -1


## 癌种词表（players[].cancer_type 与 cells[].type 共用；**没有 "none"**）。返回 -1 = 不是癌种
static func _ctype(kind: String) -> int:
	match kind:
		"Melanoma": return CWData.CancerType.MELANOMA
		"SignetRing": return CWData.CancerType.SIGNET
		"Osteosarcoma": return CWData.CancerType.OSTEO
		"SmallCellLung": return CWData.CancerType.SCLC
	return -1


static func _ctype_name(v: int) -> String:
	match v:
		CWData.CancerType.MELANOMA: return "Melanoma"
		CWData.CancerType.SIGNET: return "SignetRing"
		CWData.CancerType.OSTEO: return "Osteosarcoma"
		CWData.CancerType.SCLC: return "SmallCellLung"
	return ""


static func _kind_name(cell: Dictionary) -> String:
	if int(cell["faction"]) == CWData.Faction.CANCER:
		return _ctype_name(int(cell["ctype"]))
	match int(cell["itype"]):
		CWData.ImmuneType.B_CELL: return "BCell"
		CWData.ImmuneType.T_CELL: return "TCell"
		CWData.ImmuneType.MACRO: return "Macrophage"
		CWData.ImmuneType.DENDRITIC: return "Dendritic"
	return "ImmuneBasic"
