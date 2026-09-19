## cw_tutor_script.gd —— 新手教程 v2 关卡数据 `cwtut/2` 的门面：读 JSON / resolve(继承) / validate
## （docs/新手引导v2_实现方案.md §2，S1，2026-09-19）
##
## 它替掉 `cw_tutorial_data.gd`（`cwtut/1` 整份作废）。三件事：
## ① 读 `res://data/tutorial/` 下的关表与关卡；
## ② 按 `world_id` **resolve** 出一份完整的 cwxworld/3（`from` + `patch` 继承在这儿做完，
##    装载器永远拿到完整 spec —— `cw_world_loader.gd:15-18`「loader 不编数据」一个字不动）；
## ③ 把方案 §2.3 的九条数据纪律摊成一张能跑的清单（`validate`）。
##    剧本写错的代价是「真机上静默错到底」，所以纪律要有执行机构。
##
## **为什么住 scripts/kernel/ 而不是 tests/**：`game/export_presets.cfg` 四个预设全写着
## `exclude_filter="tests/*"`，产品侧 preload("res://tests/…") 一导出就白屏。数据同理放 `game/data/tutorial/`。
##
## **不带 class_name，调用方 preload**（方案 §1.5）：剧本是天天在改的东西，
## 补丁里新增的 `class_name` 进不了热更（全局类表导出时烘死）。
##
## **校验只读**：`validate` 一个字节都不改数据 —— 传给装载器的是 `duplicate(true)`，
## 因为 `load_world` 会把 spec 里的 tiles/cells 拿去建局。
##
## 十三条判据的落点见 `validate()`：①②顶层 ③④⑤⑪ 不依赖条目文法，
## ⑥动词表 / ⑦谓词表 / ⑧allow 语义键 / ⑨unlock 归宿 / ⑩fx 与 hook 点名 / ⑬prd 对账
## 走 `cw_tutor_beats.gd`（同一张表，导演与校验器共读）。
## ⑫`rolls` 双向归零是**运行期**的事（带子跑完 `at == 0`），落在 `t_tutor_c1` 那边。
extends RefCounted

const SCHEMA := "cwtut/2"
const DIR := "res://data/tutorial/"
const INDEX_PATH := DIR + "index.json"
const CODEX_MAP := DIR + "codex_map.json"

## 正本装载器（S0 上提到 scripts/kernel/）。键表只有它与 L0/CaseModel.cs 两份，这里绝不再抄一份
const LOADER := preload("res://scripts/kernel/cw_world_loader.gd")
## 条目文法（九个动词 + 三类谓词 + allow 前缀匹配）。**导演读的是同一份**
const BEATS := preload("res://scripts/kernel/cw_tutor_beats.gd")

## 一关的顶层键（方案 §2.2 的 16 键白名单）。
## `chapter_title` 是**章**的名字（PRD:35 的全屏提示读它），`title` 是**关**的名字，
## `subtitle` 是关的一句概括（目录里那行小字），三者不是一回事，别再互相顶替。
## `chapter_kind`（Kevin 2026-09-19）：`"main"` / `"interlude"` —— 间章不是主章节的附属，
## 目录里与三个主章节平级单列；章节提示比的是 `(chapter_kind, chapter)` 这个二元组
const LEVEL_KEYS := ["schema", "id", "chapter", "chapter_kind", "chapter_title", "title",
	"subtitle", "seats", "human_seat", "worlds", "active_tiles", "rolls", "hook",
	"flow", "on_done", "_doc"]

## `chapter_kind` 的两档。缺省是 `main`
const KIND_MAIN := "main"
const KIND_INTERLUDE := "interlude"

## `worlds.*.patch` 里按哪个字段 upsert（方案 §2.4）
const PATCH_BY := { "tiles": "at", "cells": "seat", "players": "seat" }

## 继承链的深度上限：`from` 写成环时不至于把栈吃光，报一条错就收
const MAX_INHERIT := 8

## 上一次 validate 的错误清单（也由 validate 返回）
var errors: PackedStringArray = []

var _id := ""


# =====================================================================
# 读
# =====================================================================

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return raw as Dictionary if raw is Dictionary else {}


## 关表：`{ "_doc": [九条纪律的一句话版], "levels": [{id, chapter, chapter_kind, chapter_title, title, file} …] }`
func load_index() -> Dictionary:
	return _read_json(INDEX_PATH)


## 按关表里那一行的 `file` 读一关；关表里没有这个 id 就返回 `{}`
func load_level(id: String) -> Dictionary:
	for row in load_index().get("levels", []):
		if str((row as Dictionary).get("id", "")) == id:
			return _read_json(DIR + str((row as Dictionary).get("file", "")))
	return {}


## 关表里的第一关（教程从这里起跑）
func first_level_id() -> String:
	var rows: Array = load_index().get("levels", [])
	return str((rows[0] as Dictionary).get("id", "")) if not rows.is_empty() else ""


# =====================================================================
# resolve：`from` + `patch` 继承（方案 §2.4，这次真实现）
# =====================================================================

## 取一关里名为 `world_id` 的那份 cwxworld/3，**继承展开成完整 spec**（深拷贝，调用方随便改）。
## 没有这份 world / 继承链有环 → 返回 `{}`。
##
## `patch` 的语义只四条：
##   · `tiles` 按 `at`、`cells` / `players` 按 `seat` **upsert**（逐字段合并，字段写 `null` = 删这个字段）；
##   · 顶层标量直接盖；顶层键写 `null` = 删这一段；
##   · 其余数组**整段替换**，不合并；
##   · `from` / `patch` 两个键自己不进结果。
## ⚠ 「删掉整只细胞 / 整格」今天没有关卡需要，写法等 S10 真用上再定 —— 眼下 upsert 只加不减。
func resolve(level: Dictionary, world_id: String) -> Dictionary:
	return _resolve(level, world_id, 0)


func _resolve(level: Dictionary, world_id: String, depth: int) -> Dictionary:
	var worlds: Dictionary = level.get("worlds", {})
	if not worlds.has(world_id) or depth > MAX_INHERIT:
		return {}
	var w: Dictionary = (worlds[world_id] as Dictionary).duplicate(true)
	if not w.has("from"):
		w.erase("patch")   ## 没有 from 却写了 patch 是剧本写错，validate 单列一条
		return w
	var base := _resolve(level, str(w["from"]), depth + 1)
	if base.is_empty():
		return {}
	return _patch(base, w.get("patch", {}) as Dictionary)


static func _patch(base: Dictionary, patch: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in patch:
		var key := str(k)
		var v: Variant = patch[k]
		if v == null:
			out.erase(key)
			continue
		if PATCH_BY.has(key) and v is Array:
			out[key] = _upsert(out.get(key, []) as Array, v as Array, str(PATCH_BY[key]))
			continue
		out[key] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	return out


## 按 `by` 这个字段对齐两张表：命中的**逐字段合并**（字段写 `null` = 删这个字段），没命中的追加
static func _upsert(base: Array, rows: Array, by: String) -> Array:
	var out: Array = base.duplicate(true)
	for r in rows:
		var row: Dictionary = r
		var at := -1
		for i in out.size():
			if str((out[i] as Dictionary).get(by, "")) == str(row.get(by, "")):
				at = i
				break
		if at < 0:
			out.append(row.duplicate(true))
			continue
		var merged: Dictionary = (out[at] as Dictionary).duplicate(true)
		for k in row:
			if row[k] == null:
				merged.erase(str(k))
			else:
				merged[str(k)] = row[k]
		out[at] = merged
	return out


# =====================================================================
# 校验（方案 §2.10 的十三条判据；S1 落 ①②③④⑤⑪，其余见文件头的 ⚠）
# =====================================================================

func validate(level: Dictionary) -> PackedStringArray:
	errors = PackedStringArray()
	_id = str(level.get("id", "(无 id)"))
	_check_schema(level)
	var seats := _check_seats(level)
	var radius := _check_worlds(level, seats)
	_check_active(level, radius)
	_check_flow_head(level)
	_check_flow(level, radius)
	return errors


func _bad(msg: String) -> void:
	errors.append("%s：%s" % [_id, msg])


func _only_keys(d: Dictionary, allowed: Array, where: String) -> void:
	for k in d.keys():
		if not (k in allowed):
			_bad("%s 里有不认识的键「%s」（许可：%s）" % [where, str(k), ", ".join(allowed)])


## 判据 ① schema；② 顶层键白名单 + chapter_kind 两档
func _check_schema(level: Dictionary) -> void:
	if str(level.get("schema", "")) != SCHEMA:
		_bad("schema 要写 \"%s\"，拿到的是「%s」" % [SCHEMA, str(level.get("schema", ""))])
	_only_keys(level, LEVEL_KEYS, "关卡")
	var kind := str(level.get("chapter_kind", KIND_MAIN))
	if kind != KIND_MAIN and kind != KIND_INTERLUDE:
		_bad("chapter_kind 只许 \"%s\" / \"%s\"，拿到的是「%s」" % [KIND_MAIN, KIND_INTERLUDE, kind])
	var worlds: Dictionary = level.get("worlds", {})
	if worlds.is_empty():
		_bad("worlds 是空的 —— 一关至少要有一份开局盘面")
	if (level.get("flow", []) as Array).is_empty():
		_bad("flow 是空的 —— 一关至少要有一条")
	for wid in worlds.keys():
		var w: Dictionary = worlds[wid]
		if w.has("patch") and not w.has("from"):
			_bad("world「%s」写了 patch 却没写 from（patch 只在继承时有意义）" % str(wid))
		if w.has("from") and resolve(level, str(wid)).is_empty():
			_bad("world「%s」的继承链解不开（from「%s」不存在，或成了环）" % [str(wid), str(w["from"])])


## 纪律 8：席位数是设计量，不是副产品
func _check_seats(level: Dictionary) -> int:
	var seats := int(level.get("seats", -1))
	var human := int(level.get("human_seat", -1))
	if seats <= 0:
		_bad("没写 seats（纪律 8：席位数是设计量，不是副产品）")
	if human < 0 or human >= seats:
		_bad("human_seat = %d 不在 [0, seats) 里（seats = %d）" % [human, seats])
	return seats


## 判据 ③ 每席恰好一只细胞 / `players[i].seat == i`；⑤ 每份 world 过装载往返。
## 返回所有 world 里最小的那个半径（活跃格要在每一份盘面上都站得住）
func _check_worlds(level: Dictionary, seats: int) -> int:
	var radius := CWData.BOARD_RADIUS
	var ids: Array = (level.get("worlds", {}) as Dictionary).keys()
	ids.sort()
	for wid in ids:
		var spec := resolve(level, str(wid))
		if spec.is_empty():
			continue   ## 继承解不开，上面已经报过一条
		radius = mini(radius, int(spec.get("radius", CWData.BOARD_RADIUS)))
		var players: Array = spec.get("players", [])
		if players.size() != seats:
			_bad("world「%s」的 players 有 %d 条，与 seats = %d 不符" % [str(wid), players.size(), seats])
		for i in players.size():
			if int((players[i] as Dictionary).get("seat", -1)) != i:
				_bad("world「%s」的 players[%d].seat 不等于 %d（纪律 4）" % [str(wid), i, i])
		## 纪律 4 的后半条：装载器只拦同格，**同席两只是后写的静默盖掉**，只有这条闸看得见
		var per_seat := {}
		for c in spec.get("cells", []):
			var s := int((c as Dictionary).get("seat", -1))
			per_seat[s] = int(per_seat.get(s, 0)) + 1
		for s in range(seats):
			var n := int(per_seat.get(s, 0))
			if n != 1:
				_bad("world「%s」的席位 %d 有 %d 只细胞 —— 每席恰好一只（缺席阵营写 alive:false 的死细胞，纪律 8）"
					% [str(wid), s, n])
		_roundtrip(str(wid), spec)
	return radius


## 判据 ⑤ 的比法：`dump_world(load_world(spec)) ≡ minify(spec)`。
## minify 是装载器里的独立实现，所以「spec 里写了但 loader 没读」在这儿当场现形
func _roundtrip(wid: String, spec: Dictionary) -> void:
	var loader = LOADER.new()
	var g: CWGame = loader.load_world(spec.duplicate(true))
	if g == null:
		var why: String = loader.errors[0] if not loader.errors.is_empty() else "（没写原因）"
		_bad("world「%s」装不出来：%s" % [wid, why])
		return
	var back: Dictionary = loader.dump_world(g)
	g.dispose()
	if not loader.errors.is_empty():
		_bad("world「%s」装出来了但 dump 报错：%s" % [wid, loader.errors[0]])
		return
	if not deep_eq(back, loader.minify(spec.duplicate(true))):
		_bad("world「%s」装载往返不齐：dump_world(load_world(spec)) 跟 minify(spec) 对不上" % wid)


## 判据 ④ 活跃格 ⊆ 半径；纪律 2：活跃格里压到 11 个特殊格的都显式写了 type
func _check_active(level: Dictionary, radius: int) -> void:
	for s in level.get("active_tiles", []):
		var at := parse_at(str(s))
		if not CWData.is_on_board(at, radius):
			_bad("活跃格 %s 在半径 %d 的棋盘外" % [str(s), radius])
			continue
		if int(CWData.special_of(at)) == CWData.Special.NONE:
			continue
		for wid in (level.get("worlds", {}) as Dictionary).keys():
			if not _has_explicit_type(resolve(level, str(wid)), at):
				_bad("活跃格 %s 是特殊组织，world「%s」里没有显式写 type —— 白送一个收入格（纪律 2）"
					% [str(s), str(wid)])


static func _has_explicit_type(spec: Dictionary, at: Vector2i) -> bool:
	for t in spec.get("tiles", []):
		var d: Dictionary = t
		if parse_at(str(d.get("at", ""))) == at:
			return d.has("type")
	return false


## 判据 ⑪ `flow[0].do == "state"` 且带 `load`（PRD:39「先结算界面与状态、再显示文本提示」）。
## **唯一例外**：`chapter_kind == "interlude"` 允许 `"load": null`，但必须**显式写出**
## —— 省略仍判红，免得「忘了写」冒充「有意不装」（方案 §2.5）
func _check_flow_head(level: Dictionary) -> void:
	var flow: Array = level.get("flow", [])
	if flow.is_empty():
		return
	var head: Dictionary = flow[0]
	if str(head.get("do", "")) != "state":
		_bad("flow[0].do 必须是 \"state\"（PRD:39：先结算界面与状态，再出文本）")
		return
	if head.has("load") and head["load"] != null:
		return
	if str(level.get("chapter_kind", KIND_MAIN)) == KIND_INTERLUDE and head.has("load"):
		return   ## 间章：显式写出来的 null，承接上一关的活局面
	_bad("flow[0] 没有带 load（只有 chapter_kind == \"interlude\" 才许显式写 \"load\": null）")


## 判据 ⑥ 动词在九个里、条目只许白名单键；⑦ 谓词在三张表里；⑧ `allow` 每条是合法语义键前缀；
## ⑨ `unlock.ids` 在 `codex_map.json` 里有归宿；⑩ `hook.call` 点名的关卡钩子文件真实存在；
## ⑬ `prd` 行号单调不减（对账闸）。另加两条形状闸：`reveal` 的格必须在盘上、`advise_when` 必须带 `advise`
func _check_flow(level: Dictionary, radius: int) -> void:
	var umap: Dictionary = _read_json(CODEX_MAP).get("unlocks", {})
	var hook_path := str(level.get("hook", ""))
	var last_prd := -1
	var flow: Array = level.get("flow", [])
	for i in flow.size():
		var row: Dictionary = flow[i]
		var v := str(row.get("do", ""))
		if not BEATS.is_verb(v):
			_bad("flow[%d].do 写的「%s」不在九个动词里（%s）"
				% [i, v, ", ".join(PackedStringArray(BEATS.VERBS.keys()))])
			continue
		var extra := BEATS.bad_keys(row)
		if not extra.is_empty():
			_bad("flow[%d]（%s）里有不认识的键：%s（许可：%s）"
				% [i, v, str(extra), ", ".join(BEATS.keys_of(v))])
		if int(row.get("prd", last_prd)) < last_prd:
			_bad("flow[%d].prd = %d 比上一条的 %d 小 —— PRD 行号必须单调不减（对账闸）"
				% [i, int(row.get("prd", last_prd)), last_prd])
		last_prd = maxi(last_prd, int(row.get("prd", last_prd)))
		for field in ["until", "reset_when", "advise_when"]:
			if row.has(field) and BEATS.pred_kind(row[field] as Dictionary) == "":
				_bad("flow[%d].%s 的谓词不在三张表里：%s" % [i, field, str(row[field])])
		if row.has("advise_when") and str(row.get("advise", "")) == "":
			_bad("flow[%d] 写了 advise_when 却没有 advise（命中时提示行会变成空串）" % i)
		if row.has("allow") and row["allow"] is Array:
			for a in row["allow"]:
				if not str(a).begins_with("k="):
					_bad("flow[%d].allow 的「%s」不是语义键前缀（文法 k=<kind>[|g=<tag>]|<字段>=<值>|…）"
						% [i, str(a)])
		for id in row.get("ids", []):
			if not umap.has(str(id)):
				_bad("flow[%d] 的 unlock「%s」在 codex_map.json 里没有归宿" % [i, str(id)])
		if str(row.get("who", "")) != "" and not BEATS.who_ok(str(row["who"])):
			_bad("flow[%d].who 写的「%s」不在四档里（player / narrator / seat:<n> / ui:<id>）"
				% [i, str(row["who"])])
		if row.has("mode") and not (str(row["mode"]) in BEATS.POINT_MODES):
			_bad("flow[%d].mode 写的「%s」不在三档里（%s）"
				% [i, str(row["mode"]), ", ".join(BEATS.POINT_MODES)])
		if v == "hook" and (hook_path == "" or not FileAccess.file_exists(hook_path)):
			_bad("flow[%d] 是 hook，可这一关的 hook 文件「%s」不在" % [i, hook_path])
		for s in row.get("reveal", []):
			if not CWData.is_on_board(parse_at(str(s)), radius):
				_bad("flow[%d] 的 reveal 的格不在盘上：%s（预置 + 遮罩揭示，不是凭空造格）" % [i, str(s)])
		for s in row.get("hex", []):
			if not CWData.is_on_board(parse_at(str(s)), radius):
				_bad("flow[%d] 的 hex 的格不在盘上：%s" % [i, str(s)])


# ---- 小工具 ----

## 坐标解析只有这一处：数据里一律写 "q,r"。舞台的 `coords_of` 与导演也走它，所以是公开的
static func parse_at(text: String) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2:
		return Vector2i(9999, 9999)
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


## 逐层比。Dictionary 的书写次序不算差异（dump 与 minify 各按自己的顺序装键）
static func deep_eq(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da:
			if not db.has(k) or not deep_eq(da[k], db[k]):
				return false
		return true
	if a is Array and b is Array:
		var xa: Array = a
		var xb: Array = b
		if xa.size() != xb.size():
			return false
		for i in xa.size():
			if not deep_eq(xa[i], xb[i]):
				return false
		return true
	return a == b
