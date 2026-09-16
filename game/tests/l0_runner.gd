## l0_runner.gd —— L0「契约靶场」的 **GDScript runner**
##
## 读 `res://tests/l0/*.json`，逐条装盘面、调探针、比数。
## **和 C# 那个 runner 读的是同一份 JSON**（`core/CellWar.Core.Tests/L0/L0RunnerTests.cs`）——
## 这正是迁移计划闸一的全部内容：
##
##   > 同一份 JSON，**GD runner 与 C# runner 都要绿**。
##   > GD 绿 = 用例忠实于原断言；C# 绿 = 真的等价。
##   > **只做 C# 那一半就是把靶画在自己身上。**
##
## 跑法：
##   Godot_v4.5-stable_win64_console.exe --headless --path game --script tests/l0_runner.gd
##
## 退出码 0 = 全绿，1 = 有 FAIL 或用例本身坏了。
##
## ⚠ 这是**测试设施**，不改任何游戏行为。规则一行都不在这里写 ——
## 探针一律转调 `CWGame` / `CWWorld` / `CWActions` 上已有的入口，
## 这里多写一行算式，「两边算出同一个数」就变成了「两边各抄了一份同样的算式」。
extends SceneTree

const CASE_DIR := "res://tests/l0"

var checks := 0
var fails := 0


## 走 `_initialize()` 而不是 `_init()`：`SceneTree` 的 `_init()` 在主循环起来**之前**跑，
## 那里调 `quit(code)` 不生效 —— 退出码永远是 1，CI 上「全绿」和「有 FAIL」分不开。
## 既有的 headless_test.gd 也是挂在 `_initialize()` 上的。
func _initialize() -> void:
	var files := _case_files()
	if files.is_empty():
		_fail("找不到任何用例：%s 下一个 .json 都没有 —— runner 空转就是假绿灯" % CASE_DIR)
		quit(1)
		return

	for path in files:
		_run_file(path)

	print("\nL0（GD 侧）：%d 条，%d 条不过" % [checks, fails])
	## 机器读的那一行。调用方**还要**自己 grep SCRIPT ERROR —— 见文件头注。
	print("L0-RESULT: %s" % ("PASS" if fails == 0 else "FAIL %d" % fails))
	quit(1 if fails > 0 else 0)


func _case_files() -> Array:
	var out: Array = []
	var dir := DirAccess.open(CASE_DIR)
	if dir == null:
		return out
	for name in dir.get_files():
		if name.ends_with(".json"):
			out.append("%s/%s" % [CASE_DIR, name])
	out.sort()
	return out


func _run_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var cases: Variant = JSON.parse_string(text)
	if typeof(cases) != TYPE_ARRAY:
		_fail("%s 解不出用例数组" % path)
		return
	print("[%s]" % path.get_file())
	for c in cases:
		_run_case(c)


func _run_case(c: Dictionary) -> void:
	checks += 1
	var id: String = c.get("id", "(无 id)")
	var probe: String = c.get("probe", "")
	var expect: int = int(c.get("expect", 0))

	var g := _load_world(c.get("world", {}))
	if g == null:
		return   ## _load_world 已经报过错了

	var actual: Variant = _probe(g, probe, c.get("args", {}))
	if actual == null:
		return   ## _probe 已经报过错了

	if int(actual) == expect:
		print("  ok  %s" % id)
	else:
		fails += 1
		print("  FAIL %s（探针 %s）：期望 %d，GD 算出 %d" % [id, probe, expect, int(actual)])
		var source: String = c.get("source", "")
		if source != "":
			print("       出处：%s" % source)


# ---- 装盘面 ----
## **先铺满整块棋盘，再拿用例列的格子覆盖上去** —— 与 C# 侧的 loader 同口径。
##
## 第一版反过来做（清空 tiles、只铺列到的几格），结果 `neighbors()` 按 `board_radius`
## 返回的坐标在 `tiles` 里取不到，`is_cancerous` 当场报 SCRIPT ERROR ——
## 而 GDScript 的运行时错误**不中断执行**：函数带着错误跑完、返回值还碰巧对上，
## 印出一片假 ok。铺满也更贴近真实对局：棋盘本来就是满的。
func _load_world(spec: Dictionary) -> CWGame:
	var players: Array = spec.get("players", [])
	if players.is_empty():
		_fail("用例没写 players")
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
		var at := _pos(t.get("at", ""))
		if not g.tiles.has(at):
			_fail("这一格在半径 %d 的棋盘外：%s" % [g.board_radius, t.get("at", "")])
			return null
		var tile := CWSetup.make_tile(at)
		tile["tissue"] = _tissue(t.get("state", "healthy"))
		tile["special"] = _special(t.get("type", "normal"))
		tile["solid"] = int(t.get("solid", 0))
		tile["mucus"] = bool(t.get("mucus", false))
		tile["necrosis"] = int(t.get("necrosis", 0))
		tile["ossify_at"] = int(t.get("ossify_at", 0))
		g.tiles[at] = tile

	## ⚠ **两边的形状不一样**：抗原记忆与免疫等级在 GD 这头是**阵营共享的全局量**
	## （`game.memory` / `game.immune_level`），C# 那头挂在每个 Player 上。
	## L0 用例里写成「每个玩家一条」是照 C# 的形状；GD 这边取**免疫方那一条**灌进全局。
	## 一局里只有一个免疫席位时两者等价；多免疫席位的用例要先把这条形状差异拉平再写。
	for p in players:
		if p.get("faction", "") != "immune":
			continue
		g.memory = int(p.get("memory", 0))
		g.immune_level = _level(p.get("level", "I"))

	## 席位 → 细胞 id = 席位 + 1 的约定是**C# 那边**的（EntityId 0 是 Invalid）；
	## GD 这边 id 就是 cells 的下标。用例里的 `cell` 参数一律是**席位**，两边各自换算。
	for c in spec.get("cells", []):
		var pid := int(c.get("seat", 0))
		var kind: String = c.get("type", "ImmuneBasic")
		var cell := CWSetup.make_cell(g.cells.size(), pid, _faction_of(kind), _pos(c.get("at", "")),
			_itype(kind), _ctype(kind), int(c.get("energy", 300)))
		cell["marked"] = bool(c.get("marked", false))
		cell["differentiated"] = bool(c.get("differentiated", false))
		for s in c.get("equipped", []):
			cell["equipped"].append(s)
		g.cells.append(cell)

	for key in spec.get("tuning", {}):
		if not key in g.tune:
			_fail("CWTuning 上没有这个旋钮：%s" % key)
			return null
		g.tune.set(key, spec["tuning"][key])

	return g


# ---- 探针表：名字与 C# 侧 Probes.cs 一一对应 ----
func _probe(g: CWGame, name: String, args: Dictionary) -> Variant:
	match name:
		"move_cost":
			## GD 没有单一的公开入口：基准价与修饰管线是分开的两步
			## （`_move_base_cost` 里含借道前进，`_move_cost_mod` 跑 CWCost）。
			## 下划线只是命名习惯，测试设施照常调得到。
			var cell: Dictionary = _cell(g, args)
			var to: Vector2i = _pos(args.get("to", ""))
			return g.actions._move_cost_mod(cell, to, g.actions._move_base_cost(cell, to))
		"anaerobic_share":
			return g.world.anaerobic_gain_for(_cell(g, args))
		"aerobic_share":
			return g.world.aerobic_income(_cell(g, args))
		"pressure_at":
			return g.world.pressure_at(_pos(args.get("at", "")))
		"proliferate_chance":
			return g.world.proliferate_chance(_pos(args.get("at", "")))
		"solidify_threshold":
			return g.solidify_threshold()
		"overload_loss":
			return g.world.overload_loss(_cell(g, args))
		"attack_outcome":
			return _outcome_code(g, int(args.get("roll", 0)), _cell(g, args))
	_fail("不认识的探针：%s" % name)
	return null


## 攻击判词编码成 0/1/2，与 C# 侧同一套（L0 的 expect 统一是整数）
func _outcome_code(g: CWGame, roll: int, cell: Dictionary) -> int:
	var word: String = g.actions.attack_outcome(roll, cell)
	match word:
		"fail": return 0
		"success": return 1
		"crit": return 2
	_fail("不认识的攻击判词：%s" % word)
	return -1


# ---- 小工具 ----
func _cell(g: CWGame, args: Dictionary) -> Dictionary:
	var seat := int(args.get("cell", 0))
	for c in g.cells:
		if int(c["pid"]) == seat:
			return c
	_fail("要的细胞（席位 %d）不在这个盘面上" % seat)
	return {}


func _pos(text: String) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2:
		_fail("坐标要写成 \"q,r\"，拿到的是 \"%s\"" % text)
		return Vector2i.ZERO
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


func _tissue(s: String) -> int:
	match s:
		"healthy": return CWData.Tissue.HEALTHY
		"cancer": return CWData.Tissue.CANCER
		"solid": return CWData.Tissue.SOLID
	_fail("不认识的组织状态：%s" % s)
	return CWData.Tissue.HEALTHY


func _special(s: String) -> int:
	match s:
		"normal": return CWData.Special.NONE
		"core": return CWData.Special.CORE
		"marrow": return CWData.Special.MARROW
		"vessel": return CWData.Special.VESSEL
	_fail("不认识的组织类型：%s" % s)
	return CWData.Special.NONE


func _level(s: String) -> int:
	match s:
		"I": return 0
		"II": return 1
		"III": return 2
		"X": return 3
	_fail("不认识的免疫等级：%s" % s)
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


func _fail(msg: String) -> void:
	fails += 1
	print("  FAIL %s" % msg)
