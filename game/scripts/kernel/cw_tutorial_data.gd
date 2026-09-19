## cw_tutorial_data.gd —— 新手引导关卡数据 `cwtut/1` 的读取与校验（docs/新手引导_实现方案.md S2，2026-09-19）
##
## **这一片还不接线**：舞台（S3）才会真拿它开局。现在它只做三件事 ——
## 读 `res://data/tutorial/` 下的关表与关卡、按 `world_id` 取出一份 cwxworld/3、把方案 §1.2 的**九条数据纪律**
## 摊成一张能跑的清单（`validate`）。剧本写错的代价是「真机上静默错到底」（附 C 第 8 条），所以纪律要有执行机构。
##
## **为什么住 scripts/kernel/ 而不是 tests/**：`game/export_presets.cfg` 四个预设全写着 `exclude_filter="tests/*"`，
## 产品侧 preload("res://tests/…") 一导出就白屏（同 S0 把装载器上提的理由）。数据同理放 `game/data/tutorial/`。
##
## **不带 class_name，调用方 preload**：引导剧本是天天在改的东西，补丁里新增的 class_name 认不出来
## （`guide.gd:60-62` / `guide_watch.gd:10-13` 的先例与理由）。
##
## **校验只读**：`validate` 一个字节都不改数据 —— 传给装载器的是 `duplicate(true)`，
## 因为 `load_world` 会把 spec 里的 tiles/cells 拿去建局，留一手比事后查便宜。
##
## 本片的 `worlds` 每一份都是**完整的** cwxworld/3，`resolve` 不做继承（方案 §1.4 的继承等真有第二份差分世界再说）。
extends RefCounted

const SCHEMA := "cwtut/1"
const DIR := "res://data/tutorial/"
const INDEX_PATH := DIR + "index.json"

## 正本装载器（S0 上提到 scripts/kernel/）。键表只有它与 L0/CaseModel.cs 两份，这里绝不再抄一份。
const LOADER := preload("res://scripts/kernel/cw_world_loader.gd")
## 完成判据表（`guide_watch.gd:27` 的 KEYS）。`watch` / `reset_when` / `advise_when` 只许写表里的键。
const WATCH := preload("res://scripts/ui/guide_watch.gd")

## 一关的顶层键（方案 §1.2 骨架 + 纪律 8 的 `expect_level_tiers`）
## `subtitle` 是**关**的一句概括（目录里那行小字，S4 补）——
## `chapter_title` 是**章**的名字（PRD:35 的全屏提示读它），两者不是一回事，别再互相顶替
const LEVEL_KEYS := ["schema", "id", "chapter", "chapter_title", "title", "subtitle",
	"codex_page", "ui_stage", "seats", "human_seat", "expect_level_tiers",
	"worlds", "active_tiles", "rolls", "steps", "on_done"]
## 一步的键（方案 §1.2 表尾 + §1.10）。
## `reset_when` 自动把关卡退回关首；`advise_when` / `advise` 只**提示**玩家自己重置
## （PRD:251 第二条，Kevin 2026-09-19：提示、不自动重置），S5b 补
const STEP_KEYS := ["step_of", "load", "ui_layers", "t", "b", "unlock",
	"flag", "hex", "player", "allow", "watch", "act", "reveal", "fx",
	"reset_when", "advise_when", "advise"]

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


## 关表：`{ "_doc": [九条纪律的一句话版], "levels": [{id, chapter, chapter_title, title, file} …] }`
func load_index() -> Dictionary:
	return _read_json(INDEX_PATH)


## 按关表里那一行的 `file` 读一关；关表里没有这个 id 就返回 `{}`
func load_level(id: String) -> Dictionary:
	for row in load_index().get("levels", []):
		if str((row as Dictionary).get("id", "")) == id:
			return _read_json(DIR + str((row as Dictionary).get("file", "")))
	return {}


## 取一关里名为 `world_id` 的那份 cwxworld/3（深拷贝，调用方随便改）。没有就返回 `{}`
func resolve(level: Dictionary, world_id: String) -> Dictionary:
	var worlds: Dictionary = level.get("worlds", {})
	if not worlds.has(world_id):
		return {}
	return (worlds[world_id] as Dictionary).duplicate(true)


# =====================================================================
# 校验（方案 §1.2 的九条纪律 + S2 的十条判据）
# =====================================================================

func validate(level: Dictionary) -> PackedStringArray:
	errors = PackedStringArray()
	_id = str(level.get("id", "(无 id)"))
	_check_schema(level)
	var seats := _check_seats(level)
	var radius := _check_worlds(level, seats)
	_check_active(level, radius)
	_check_steps(level, radius)
	_check_text(level)
	return errors


func _bad(msg: String) -> void:
	errors.append("%s：%s" % [_id, msg])


func _only_keys(d: Dictionary, allowed: Array, where: String) -> void:
	for k in d.keys():
		if not (k in allowed):
			_bad("%s 里有不认识的顶层键「%s」（许可：%s）" % [where, str(k), ", ".join(allowed)])


## 判据 ① schema 键合法
func _check_schema(level: Dictionary) -> void:
	if str(level.get("schema", "")) != SCHEMA:
		_bad("schema 要写 \"%s\"，拿到的是「%s」" % [SCHEMA, str(level.get("schema", ""))])
	_only_keys(level, LEVEL_KEYS, "关卡")
	var worlds: Dictionary = level.get("worlds", {})
	if worlds.is_empty():
		_bad("worlds 是空的 —— 一关至少要有一份开局盘面")
	if (level.get("steps", []) as Array).is_empty():
		_bad("steps 是空的 —— 一关至少要有一步")
	for i in (level.get("steps", []) as Array).size():
		var step: Dictionary = level["steps"][i]
		_only_keys(step, STEP_KEYS, "steps[%d]" % i)
		if step.has("load") and not worlds.has(str(step["load"])):
			_bad("steps[%d].load 指到不存在的 world「%s」" % [i, str(step["load"])])


## 判据 ⑧ 纪律 8：席位数是设计量
func _check_seats(level: Dictionary) -> int:
	var seats := int(level.get("seats", -1))
	var human := int(level.get("human_seat", -1))
	if seats <= 0:
		_bad("没写 seats（纪律 8：席位数是设计量，不是副产品）")
	if human < 0 or human >= seats:
		_bad("human_seat = %d 不在 [0, seats) 里（seats = %d）" % [human, seats])
	if level.has("expect_level_tiers"):
		var want: Array = CWData.level_min_memory(seats)
		var got: Array = []
		for v in level["expect_level_tiers"]:
			got.append(int(v))
		if got != want:
			_bad("expect_level_tiers %s 与 CWData.level_min_memory(%d) = %s 不符" % [str(got), seats, str(want)])
	return seats


## 判据 ② 每份 world 过 load_world 且 dump_world ≡ minify；③ 每席恰好一只细胞；⑧ seats 与 players 条数相符。
## 返回所有 world 里最小的那个半径（活跃格 / reveal 要在每一份盘面上都站得住）
func _check_worlds(level: Dictionary, seats: int) -> int:
	var radius := CWData.BOARD_RADIUS
	var ids: Array = (level.get("worlds", {}) as Dictionary).keys()
	ids.sort()
	for wid in ids:
		var spec: Dictionary = level["worlds"][wid]
		radius = mini(radius, int(spec.get("radius", CWData.BOARD_RADIUS)))
		var players: Array = spec.get("players", [])
		if players.size() != seats:
			_bad("world「%s」的 players 有 %d 条，seats 与 players 条数不符（seats = %d）" % [str(wid), players.size(), seats])
		## 纪律 4 的后半条：装载器只拦同格，同席两只是**后写的静默盖掉**，只有这条闸看得见
		var per_seat := {}
		for c in spec.get("cells", []):
			var s := int((c as Dictionary).get("seat", -1))
			per_seat[s] = int(per_seat.get(s, 0)) + 1
		for s in range(seats):
			var n := int(per_seat.get(s, 0))
			if n != 1:
				_bad("world「%s」的席位 %d 有 %d 只细胞 —— 每席恰好一只（缺席阵营写 alive:false 的死细胞，方案附 D 的 B）" % [str(wid), s, n])
		_roundtrip(str(wid), spec)
	return radius


## 闸二 2a 的比法：`dump_world(load_world(spec)) ≡ minify(spec)`。
## minify 是装载器里的独立实现，所以「spec 里写了但 loader 没读」在这儿当场现形。
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
	if not _deep_eq(back, loader.minify(spec.duplicate(true))):
		_bad("world「%s」装载往返不齐：dump_world(load_world(spec)) 跟 minify(spec) 对不上" % wid)


## 判据 ④ 活跃格 ⊆ 半径；⑤ 活跃格里压到 11 个特殊格的都显式写了 type（纪律 2）
func _check_active(level: Dictionary, radius: int) -> void:
	for s in level.get("active_tiles", []):
		var at := parse_at(str(s))
		if not CWData.is_on_board(at, radius):
			_bad("活跃格 %s 在半径 %d 的棋盘外" % [str(s), radius])
			continue
		if int(CWData.special_of(at)) == CWData.Special.NONE:
			continue
		for wid in (level.get("worlds", {}) as Dictionary).keys():
			if not _has_explicit_type(level["worlds"][wid], at):
				_bad("活跃格 %s 是特殊组织，world「%s」里没有显式写 type —— 白送一个收入格（纪律 2）" % [str(s), str(wid)])


static func _has_explicit_type(spec: Dictionary, at: Vector2i) -> bool:
	for t in spec.get("tiles", []):
		var d: Dictionary = t
		if parse_at(str(d.get("at", ""))) == at:
			return d.has("type")
	return false


## 判据 ⑥ watch / reset_when / advise_when 的键在 CWGuideWatch.KEYS 里；⑩ reveal 的格必须已经在盘面上
func _check_steps(level: Dictionary, radius: int) -> void:
	for i in (level.get("steps", []) as Array).size():
		var step: Dictionary = level["steps"][i]
		## 判据成立时要贴的那句话不写就是个静默的空操作（浮层提示行换成空串）——当场拦下
		if step.has("advise_when") and str(step.get("advise", "")) == "":
			_bad("steps[%d] 写了 advise_when 却没有 advise（命中时提示行会变成空串）" % i)
		for field in ["watch", "reset_when", "advise_when"]:
			if not step.has(field):
				continue
			## 判据带参数时写成 `键:参数`，表里查的是冒号前那一截
			var key := str(step[field]).split(":")[0]
			if not WATCH.KEYS.has(key):
				_bad("steps[%d].%s 写的「%s」不在 CWGuideWatch.KEYS 里（表：%s）"
					% [i, field, str(step[field]), ", ".join(PackedStringArray(WATCH.KEYS.keys()))])
		for s in step.get("reveal", []):
			if not CWData.is_on_board(parse_at(str(s)), radius):
				_bad("steps[%d] 的 reveal 的格不在盘上：%s（预置 + 遮罩揭示，不是凭空造格）" % [i, str(s)])


## 判据 ⑦ 文案占位 `{{tune.*}}` 都解析得出（纪律 6：数字不写死在文案里）
func _check_text(level: Dictionary) -> void:
	var props := {}
	for p in CWTuning.new().get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			props[str(p["name"])] = true
	var re := RegEx.create_from_string("\\{\\{tune\\.([^}]*)\\}\\}")
	for i in (level.get("steps", []) as Array).size():
		var step: Dictionary = level["steps"][i]
		var lines: Array = []
		if step.has("t"):
			lines.append(str(step["t"]))
		for line in step.get("b", []):
			lines.append(str(line))
		for line in lines:
			for m in re.search_all(line):
				if not props.has(m.get_string(1)):
					_bad("steps[%d] 的文案占位解析不出：{{tune.%s}} 不是 CWTuning 的属性" % [i, m.get_string(1)])


# ---- 小工具 ----

## 坐标解析只有这一处：数据里一律写 "q,r"。S3 起舞台（cw_tutorial_stage.coords_of）与数据门面也走它，所以是公开的
static func parse_at(text: String) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2:
		return Vector2i(9999, 9999)
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


## 逐层比。Dictionary 的书写次序不算差异（dump 与 minify 各按自己的顺序装键）
static func _deep_eq(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da:
			if not db.has(k) or not _deep_eq(da[k], db[k]):
				return false
		return true
	if a is Array and b is Array:
		var xa: Array = a
		var xb: Array = b
		if xa.size() != xb.size():
			return false
		for i in xa.size():
			if not _deep_eq(xa[i], xb[i]):
				return false
		return true
	return a == b
