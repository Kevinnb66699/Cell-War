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
##   ... --script tests/l0_runner.gd -- --selfcheck   （闸二 2a：装载往返自检，不跑探针）
##
## 退出码 0 = 全绿，1 = 有 FAIL 或用例本身坏了。
##
## ⚠ 这是**测试设施**，不改任何游戏行为。规则一行都不在这里写 ——
## 探针一律转调 `CWGame` / `CWWorld` / `CWActions` 上已有的入口，
## 这里多写一行算式，「两边算出同一个数」就变成了「两边各抄了一份同样的算式」。
extends SceneTree

const CASE_DIR := "res://tests/l0"
## 装盘面的活在 cw_case_loader.gd（键表也在那儿）：l0_pre_dump.gd 也用它 —— 闸二 2b 比的就是「同一个 loader 装出来的世界」
const Loader := preload("res://tests/cw_case_loader.gd")
## 三类 expect 的判定在 cw_case_diff.gd（全局豁免表也在那儿，只许有那一份）
const Diff := preload("res://tests/cw_case_diff.gd")
## 三条启动断言的 GD 半边；两侧都读同一份 contract_ops.json，相等经表传递（§0.6.4 第 4 条）
const Gate := preload("res://tests/l0_contract_gate.gd")
const OPS_PATH := "res://tests/contract_ops.json"

## P 族分派表（§0.6.4 第 5 条）：8 真 + 4 空壳。集合 ≡ contract_ops.json 里
## `kind:"probe"` 且 status ∈ {OK, KNOWN_GAP, UNDEFINED} 的行；启动时由契约门双射校验。
## 空壳 = 本批未开工（NOTIMPL / OUT_OF_SCOPE 的行不进这张表）。
const PROBE_NAMES: Array[String] = [
	"move_cost", "anaerobic_share", "aerobic_share", "pressure_at",
	"proliferate_chance", "solidify_threshold", "overload_loss", "attack_outcome",
	"move_raw_cost", "pass_through_cost", "quote_path", "const",
	"move_legal", "anaerobic_pool", "split_share", "settle_loss",   ## §0.6.7 四条：Kevin 09-19 接受、C# 入口已开，探针面随各批定
]
## S 族分派表：24 真 + 空壳 `damage_hit`（住在 CWGame 上，四个代理够不着，批 4 手写用例）
const STEP_NAMES: Array[String] = [
	"anaerobic", "cancer_upkeep", "pressure", "proliferate", "erosion", "resolve_camping",
	"solidify", "rooted", "ossify", "decay", "mark_adhesion", "tick_durations",
	"tick_necrosis", "tick_chemo_cd", "tick_chemo_track", "expire_marks", "clear_newborn",
	"cap_energy", "reset_round_flags", "tissue_production", "vessel_teleport",
	"aerobic", "overload", "enter_tile", "damage_hit",
]

var checks := 0
var fails := 0
## 装不进这套数据结构的单列一档（§0.6.1 第 7 条）：仓库用例集里不许有，出现一条整体红
var unloadable := 0
## `--selfcheck`：不跑探针，只跑闸二 2a —— 逐条 dump_world(load_world(spec)) ≡ minify(spec)。
## 「spec 里写了但 loader 没读」只有这一条闸抓得到（A-5 2a）。
var selfcheck := false


## 带子替身（A-7 / 规格 A-1 的 `rolls`）。**不用 tests/xcheck_tape.gd**：那只在带子放完时直接下标越界，
## 而 GD 运行时错误不中断执行 —— 崩在带子上会印出一片假 ok。这里少掷一次、多掷一次都当场记账。
class RollTape extends RefCounted:
	var inner := RandomNumberGenerator.new()
	var tape: Array = []
	var at := 0
	var overrun := 0
	var bad_range := 0

	var seed: int:
		set(v): inner.seed = v
		get: return inner.seed

	var state: int:
		set(v): inner.state = v
		get: return inner.state

	## 退化区间在 Godot 里消耗 0 个随机数（xcheck_tape.gd 头注的实测），带子上也不留痕 —— 两侧必须同口径
	func randi_range(from: int, to: int) -> int:
		if from == to:
			return from
		if at >= tape.size():
			overrun += 1
			return inner.randi_range(from, to)
		var e: Array = tape[at]
		at += 1
		if int(e[0]) != from or int(e[1]) != to:
			bad_range += 1
		inner.randi_range(from, to)   ## 照样推进内部状态：有人会偷看 rng.state
		return int(e[2])

	func randi() -> int:
		return inner.randi()


## 走 `_initialize()` 而不是 `_init()`：`SceneTree` 的 `_init()` 在主循环起来**之前**跑，
## 那里调 `quit(code)` 不生效 —— 退出码永远是 1，CI 上「全绿」和「有 FAIL」分不开。
## 既有的 headless_test.gd 也是挂在 `_initialize()` 上的。
func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--selfcheck" or a == "selfcheck":
			selfcheck = true
	## 契约门（§0.6.4 第 4 条）：双射 / `cases` 三档 / T 族不出现。非空 = 打印每条并整体红
	var gate: PackedStringArray = Gate.check(OPS_PATH, dispatch_names())
	for m in gate:
		_fail("契约门：%s" % m)
	var files := _case_files()
	if files.is_empty():
		_fail("找不到任何用例：%s 下一个 .json 都没有 —— runner 空转就是假绿灯" % CASE_DIR)
		quit(1)
		return

	for path in files:
		await _run_file(path)

	print("\nL0（GD 侧%s）：%d 条，%d 条不过，其中 %d 条装不出来（UNLOADABLE）" % [
		"·装载往返自检" if selfcheck else "", checks, fails, unloadable])
	## 机器读的那一行。调用方**还要**自己 grep SCRIPT ERROR —— 见文件头注。
	print("L0-RESULT: %s" % ("PASS" if fails == 0 else "FAIL %d" % fails))
	quit(1 if fails > 0 else 0)


## 两张分派表并成一份传给契约门（双射的判定子集）
func dispatch_names() -> Array:
	var out: Array = []
	out.append_array(PROBE_NAMES)
	out.append_array(STEP_NAMES)
	return out


func _case_files() -> Array:
	var out: Array = []
	_scan_cases(CASE_DIR, out)
	out.sort()
	return out


## 递归：C-2 的批次目录 `l0/batch{n}/` 也要跑到（C# runner 与契约门同口径）
func _scan_cases(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_files():
		if name.ends_with(".json") and not (name in Loader.NON_CASE_FILES):
			out.append("%s/%s" % [dir_path, name])
	for sub in dir.get_directories():
		_scan_cases("%s/%s" % [dir_path, sub], out)


func _run_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var cases: Variant = JSON.parse_string(text)
	if typeof(cases) != TYPE_ARRAY:
		_fail("%s 解不出用例数组" % path)
		return
	print("[%s]" % path.get_file())
	for c in cases:
		if selfcheck:
			_selfcheck_case(c)
		else:
			await _run_case(c)


## 闸二 2a：dump_world(load_world(spec)) ≡ minify(spec)。
## minify 是 loader 里的**独立实现**（不转调 load/dump）—— 转调了就是自己比自己，
## 「spec 里写了但 loader 没读」永远抓不到。
func _selfcheck_case(c: Dictionary) -> void:
	checks += 1
	var id: String = c.get("id", "(无 id)")
	var loader = Loader.new()
	var spec: Dictionary = c.get("world", {})
	var g: CWGame = loader.load_world(spec)
	if g == null:
		_note_load_failure(loader, id)
		return
	var back: Dictionary = loader.dump_world(g)
	g.dispose()
	if not loader.errors.is_empty():
		_note_load_failure(loader, id)
		return
	var msgs: PackedStringArray = Diff.compare(back, loader.minify(spec))
	if msgs.is_empty():
		print("  ok  %s" % id)
		return
	fails += 1
	print("  FAIL %s 装载往返不齐（左 = dump(load(spec))，右 = minify(spec)）：" % id)
	for m in msgs:
		print("       %s" % m)


## UNLOADABLE 单列一档（§0.6.1 第 7 条），其余原样报；两种都计进 fails ⇒ 整体红
func _note_load_failure(loader, id: String) -> void:
	var first: String = loader.errors[0] if not loader.errors.is_empty() else "（没写原因）"
	if first.begins_with("UNLOADABLE: "):
		unloadable += 1
		_fail("%s %s" % [id, first])
		return
	for e in loader.errors:
		_fail("%s：%s" % [id, e])


func _run_case(c: Dictionary) -> void:
	checks += 1
	var id: String = c.get("id", "(无 id)")
	var loader = Loader.new()
	if not loader.only_keys(c, Loader.CASE_KEYS, "用例 %s" % id):
		_fail(loader.errors[0])
		return
	## cwxcase/2 的三条形状闸（§0.6.2）：schema 必填恒等、probe / op 二选一、名字在分派表里
	if str(c.get("schema", "")) != "cwxcase/2":
		_fail("用例 %s 的 schema 是「%s」—— 必填且恒 \"cwxcase/2\"" % [id, str(c.get("schema", ""))])
		return
	var is_probe := c.has("probe")
	if is_probe == c.has("op"):
		_fail("用例 %s 的 probe / op 二选一：都写或都不写都是硬错" % id)
		return
	var name := str(c["probe"]) if is_probe else str(c["op"])
	if is_probe and not (name in PROBE_NAMES):
		_fail("用例 %s 的 probe「%s」不在分派表里（PROBE_NAMES）" % [id, name])
		return
	if not is_probe and not (name in STEP_NAMES):
		_fail("用例 %s 的 op「%s」不在分派表里（STEP_NAMES）" % [id, name])
		return

	var g: CWGame = loader.load_world(c.get("world", {}))
	if g == null:
		_note_load_failure(loader, id)
		return

	## 带子：`rolls: []` = 断言「这一步不消耗 rng」（A-7）。装在探针之前 —— P 族里也有该断言不掷骰的
	var rolls: Array = c.get("rolls", [])
	var tape := RollTape.new()
	tape.tape = rolls
	tape.state = g.rng.state
	g.rng = tape

	var exp: Variant = c.get("expect", null)
	var kind := "scalar"
	if exp is Dictionary:
		kind = str((exp as Dictionary).get("kind", ""))
	if exp is Dictionary and kind == "scalar":
		## 裸整数就是 scalar（§0.6.2 第 2 条）：两侧都不接受 {kind:"scalar"} 这种写法
		_fail("用例 %s 的 expect 写成了 {kind:\"scalar\"} —— 裸整数才是 scalar" % id)
	elif is_probe:
		match kind:
			"scalar":
				_case_scalar(g, id, name, c, exp)
			"tree":
				_case_tree(g, id, name, c, exp)
			_:
				_fail("用例 %s 是 P 族，expect 只认裸整数与 {kind:\"tree\"}，拿到的是「%s」" % [id, kind])
	else:
		if kind == "delta":
			await _case_delta(g, id, name, c, exp)
		else:
			_fail("用例 %s 是 S 族，expect 只认 {kind:\"delta\"}，拿到的是「%s」" % [id, kind])
	_check_tape(id, tape, rolls)
	g.dispose()


func _check_tape(id: String, tape: RollTape, rolls: Array) -> void:
	if tape.overrun > 0:
		_fail("%s：带子只给了 %d 次点数，这一步却掷了 %d 次（rolls: [] = 断言这一步不消耗 rng）" % [id, rolls.size(), rolls.size() + tape.overrun])
	if tape.at < rolls.size():
		_fail("%s：带子上还剩 %d 次点数没用掉 —— 用例比实现多写了掷骰" % [id, rolls.size() - tape.at])
	if tape.bad_range > 0:
		_fail("%s：带子上有 %d 次的 [from, to] 与实际掷的区间对不上" % [id, tape.bad_range])


func _case_scalar(g: CWGame, id: String, op: String, c: Dictionary, exp: Variant) -> void:
	var want := int(exp)
	var actual: Variant = _probe(g, op, c.get("args", {}))
	if actual == null:
		return   ## _probe 已经报过错了
	if int(actual) == want:
		print("  ok  %s" % id)
	else:
		fails += 1
		print("  FAIL %s（探针 %s）：期望 %d，GD 算出 %d" % [id, op, want, int(actual)])
		_print_source(c)


func _case_tree(g: CWGame, id: String, op: String, c: Dictionary, exp: Dictionary) -> void:
	var actual: Variant = _probe(g, op, c.get("args", {}))
	if actual == null:
		return
	var msgs: PackedStringArray = Diff.compare(_to_json(actual), exp.get("value", null))
	if msgs.is_empty():
		print("  ok  %s" % id)
		return
	fails += 1
	print("  FAIL %s（探针 %s）：不同的路径" % [id, op])
	for m in msgs:
		print("       %s" % m)
	_print_source(c)


## delta = envelope 子集的差分**集合**（E-1 拍板）。**整集合比不是包含比**：
## 包含比只钉「该变的变了」，钉不住「不该变的没变」—— C# 多改一个字段也要红。
func _case_delta(g: CWGame, id: String, op: String, c: Dictionary, exp: Dictionary) -> void:
	var pre: Dictionary = Diff.normalize(_envelope(g))
	if not await _step(g, op, c.get("args", {})):
		return
	var post: Dictionary = Diff.normalize(_envelope(g))
	var got: Dictionary = Diff.diff(pre, post)
	if not Diff.errors.is_empty():
		for m in Diff.errors:
			_fail("%s：%s" % [id, m])
		return
	got = Diff.apply_ignore(got, exp.get("ignore", []))
	if not Diff.errors.is_empty():
		for m in Diff.errors:
			_fail("%s：%s" % [id, m])
		return
	## 一条手写的 changed 路径命中零个字段 = 硬错（A-1；C# Subset.Paths/Hits 同）：写歪的路径不能靠「整集合比」顺带报成「多一条」
	var known: Dictionary = Diff.flatten(pre)
	known.merge(Diff.flatten(post))
	for path in exp.get("changed", {}):
		if not known.has(str(path)):
			_fail("%s：changed 里的 %s 在 pre / post 上一个字段都命不中（路径写错了？）" % [id, str(path)])
			return
	var msgs := _delta_msgs(got, exp.get("changed", {}))
	if msgs.is_empty():
		print("  ok  %s" % id)
		return
	fails += 1
	print("  FAIL %s（契约步 %s）：" % [id, op])
	for m in msgs:
		print("       %s" % m)
	_print_source(c)


static func _envelope(g: CWGame) -> Dictionary:
	return CWObsCodec.encode(g, { "viewer": CWObsProto.VIEWER_OMNISCIENT })


## 整集合比：多改一条、少改一条、值不同，三样都报路径
func _delta_msgs(got: Dictionary, want: Dictionary) -> Array:
	var msgs: Array = []
	for p in got:
		if not want.has(p):
			msgs.append("多改了 %s → %s（expect 里没有这一条）" % [str(p), JSON.stringify(got[p])])
		elif not Diff.compare(got[p], want[p]).is_empty():
			msgs.append("%s：期望 %s，实际 %s" % [str(p), JSON.stringify(want[p]), JSON.stringify(got[p])])
	for p in want:
		if not got.has(p):
			msgs.append("少改了 %s（期望 %s，这一步根本没动它）" % [str(p), JSON.stringify(want[p])])
	return msgs


func _print_source(c: Dictionary) -> void:
	var source: String = c.get("source", "")
	if source != "":
		print("       出处：%s" % source)


# ---- 探针表（P 族）：名字与 C# 侧 Probes.cs、contract_ops.json 逐名相同 ----
## 显式 match，不用反射（A-6）：反射会在两边任何一侧改名时静默换靶。
## 分支集合 ≡ PROBE_NAMES，多一个少一个都由契约门当场抓住。
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
		## 八个空壳（§0.6.4 第 5 条 + §0.6.7 四条）：表里是 deferred，分派表里留位子，调用即报本批未开工
		"move_raw_cost", "pass_through_cost", "quote_path", "const", \
		"move_legal", "anaerobic_pool", "split_share", "settle_loss":
			_fail("探针 %s：本批未开工" % name)
			return null
	_fail("不认识的探针：%s" % name)
	return null


# ---- 契约步表（S 族）：名字与 tests/rec/ 的代理、C# 侧 L0/Steps.cs、contract_ops.json 逐名相同 ----
## `aerobic` / `overload` 调的是**下划线那一层**（`cw_world.gd:_aerobic` / `_overload`）——
## 薄壳 `aerobic()` 不是契约步（§0.6.4 第 2 条）。
## 五个协程步要 await：`erosion` / `resolve_camping` / `tissue_production` / `vessel_teleport` / `enter_tile`。
func _step(g: CWGame, op: String, args: Dictionary) -> bool:
	match op:
		"anaerobic": g.world._anaerobic()
		"cancer_upkeep": g.world._cancer_upkeep()
		"pressure": g.world._pressure()
		"proliferate": g.world._proliferate()
		"erosion": await g.world._erosion(_positions(args.get("fresh", [])))
		"resolve_camping": await g.world._resolve_camping()
		"solidify": g.world._solidify()
		"rooted": g.world._rooted()
		"ossify": g.world._ossify()
		"decay": g.world._decay()
		"mark_adhesion": g.world._mark_adhesion()
		"tick_durations": g.world_fx.tick_durations()
		"tick_necrosis": g.world._tick_necrosis()
		"tick_chemo_cd": g.world._tick_chemo_cd()
		"tick_chemo_track": g.world._tick_chemo_track()
		"expire_marks": g.world._expire_marks()
		"clear_newborn": g.world._clear_newborn()
		"cap_energy": g.world._cap_energy()
		"reset_round_flags": g.world._reset_round_flags()
		"tissue_production": await g.world._tissue_production()
		"vessel_teleport": await g.world._vessel_teleport()
		"aerobic": g.world._aerobic()
		"overload": g.world._overload()
		"enter_tile": await g.actions.enter_tile(_cell(g, args), _pos(str(args.get("to", ""))), int(args.get("paid", -1)))
		## 空壳（§0.6.4 第 2 条）：住在 CWGame 上、两端签名未核，批 4 手写用例
		"damage_hit":
			_fail("契约步 damage_hit：本批未开工")
			return false
		_:
			_fail("不认识的契约步：%s" % op)
			return false
	return true


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


func _positions(list: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for s in list:
		out.append(_pos(str(s)))
	return out


## 探针可能返回 Vector2i / PackedArray —— 统一成 JSON 能表达的形状再比。
## 坐标一律 "q,r"（与 spec 里 at / to 的写法同一套），C# 侧 Expect.cs 必须同口径。
func _to_json(v: Variant) -> Variant:
	if v is Vector2i:
		return "%d,%d" % [v.x, v.y]
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary):
			out[("%d,%d" % [k.x, k.y]) if k is Vector2i else str(k)] = _to_json(v[k])
		return out
	if v is Array or v is PackedInt32Array or v is PackedStringArray:
		var arr: Array = []
		for item in v:
			arr.append(_to_json(item))
		return arr
	if v is float:
		## L0 的单位一律是**十分能量 / 千分率的整数**（CaseModel.cs 的 Expect 注）——
		## 浮点进 JSON 就是风险 R4 那条「两侧 runner 会一起绿」
		return int(round(v))
	return v


func _fail(msg: String) -> void:
	fails += 1
	print("  FAIL %s" % msg)
