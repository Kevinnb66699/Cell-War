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
##
## **浮点的传输编码（R4，两侧同一套）**：`scalar` 的单位一律是**十分能量 / 千分率的整数**。
## 返回 float 的探针要在**表项里**按**千分位**冻成整数 `round(x * 1000)`（批 0 的 const 表立的口径，
## 批 2 的 `anaerobic_pool` 是第一个真用户）。runner 不做隐式转换 ——
## `_case_scalar` 见到 float 当场红，`cw_case_diff.gd` 见到浮点叶子也当场红。
extends SceneTree

const CASE_DIR := "res://tests/l0"
## 装盘面的活在 scripts/kernel/cw_world_loader.gd（键表也在那儿；2026-09-19 从 tests/cw_case_loader.gd 上提）：l0_pre_dump.gd 也用它 —— 闸二 2b 比的就是「同一个 loader 装出来的世界」
const Loader := preload("res://scripts/kernel/cw_world_loader.gd")
## 三类 expect 的判定在 cw_case_diff.gd（全局豁免表也在那儿，只许有那一份）
const Diff := preload("res://tests/cw_case_diff.gd")
## 三条启动断言的 GD 半边；两侧都读同一份 contract_ops.json，相等经表传递（§0.6.4 第 4 条）
const Gate := preload("res://tests/l0_contract_gate.gd")
const OPS_PATH := "res://tests/contract_ops.json"

## P 族分派表（§0.6.4 第 5 条）：15 真 + 2 空壳。集合 ≡ contract_ops.json 里
## `kind:"probe"` 且 status ∈ {OK, KNOWN_GAP, UNDEFINED} 的行；启动时由契约门双射校验。
## 空壳 = 本批未开工（NOTIMPL / OUT_OF_SCOPE 的行不进这张表）。
const PROBE_NAMES: Array[String] = [
	"move_cost", "anaerobic_share", "aerobic_share", "pressure_at",
	"proliferate_chance", "solidify_threshold", "overload_loss", "attack_outcome",
	"move_raw_cost", "pass_through_cost", "quote_path", "const",
	"move_legal", "anaerobic_pool", "split_share", "settle_loss",   ## §0.6.7 四条：Kevin 09-19 接受、C# 入口已开，探针面随各批定
	"antibody_damage",   ## 批 4（E-6 规矩 1）：GD 收细胞，C# 侧新开同形的具名重载，两侧探针都只转调一句
]
## S 族分派表：26 真（批 4 把 `damage_hit` 换成真转调；它住在 CWGame 上、四个代理够不着 ⇒ rec: manual，用例手写）。
## `execute` 是决策类 op（批 1 进表，§0.6.4 第 1 条按 GD 入口名）：两侧签名不同，args 走**席位 + 语义键**。
const STEP_NAMES: Array[String] = [
	"anaerobic", "cancer_upkeep", "pressure", "proliferate", "erosion", "resolve_camping",
	"solidify", "rooted", "ossify", "decay", "mark_adhesion", "tick_durations",
	"tick_necrosis", "tick_chemo_cd", "tick_chemo_track", "expire_marks", "clear_newborn",
	"cap_energy", "reset_round_flags", "tissue_production", "vessel_teleport",
	"aerobic", "overload", "enter_tile", "execute", "damage_hit",
]

var checks := 0
var fails := 0
## 装不进这套数据结构的单列一档（§0.6.1 第 7 条）：仓库用例集里不许有，出现一条整体红
var unloadable := 0
## `--selfcheck`：不跑探针，只跑闸二 2a —— 逐条 dump_world(load_world(spec)) ≡ minify(spec)。
## 「spec 里写了但 loader 没读」只有这一条闸抓得到（A-5 2a）。
var selfcheck := false


## 带子替身住在 scripts/kernel/cw_roll_tape.gd（2026-09-19 从这里的内部类上提，教程 S0）；
## 「少掷一次、多掷一次都当场记账」的口径没变。
const RollTape := preload("res://scripts/kernel/cw_roll_tape.gd")


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
	## R4 硬闸：C# 的 `Convert.ToInt64(double)` 是**银行家舍入**、这边的 `int(float)` 是**截断** ——
	## 同一个 48.93 一边 49 一边 48，两侧会在没人看的地方分叉。要冻就在**探针表项**里按千分位冻
	if typeof(actual) == TYPE_FLOAT:
		_fail("%s（探针 %s）：探针返回浮点：scalar 的单位一律是十分能量 / 千分率的整数，float 要在探针表项里冻成整数（R4）" % [id, op])
		return
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
	var asking_before: int = g.asking_pid
	if not await _step(g, op, c.get("args", {})):
		return
	## `asking_pid` 是**瞬态**演出量（观测协议 §6.1「不在 GD 快照里」）：GD `game.ask()` 写了就不擦，
	## C# 那边是 `Simulation.Input?.PlayerSeat ?? -1`、问答摘干净就回 −1。一条中途问过的 op 在 GD 侧
	## 会多留一条 `$.g.asking_pid` 差分、C# 侧没有。契约步跑完没有人在被问 —— 原样放回
	## （与批 3 B1「为了 dump 现补的字段取完原样放回」是同一条纪律）。
	g.asking_pid = asking_before
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
		"antibody_damage":
			## 【抗体】这一次打多少（十分能量）。GD 这边收细胞、自己从细胞上读用过几次与
			## 【抗体亲和力成熟】；C# 那边按 E-6 规矩 1「GD 边界权威、C# 挪」新开了同形的具名重载
			## `RulePolicies.AntibodyDamage(s, c)` —— 两侧探针都只转调一句，
			## 「哪两个量喂进这条公式」的绑定留在各自的生产代码里，不搬进靶场（纪律 3）
			return g.actions.antibody_damage(_cell(g, args))
		"const":
			## 一个探针管一整张常量表（规格 §B 批 0：**不要一个常量一个探针**）。表在 _build_consts()
			return _const_value(g, args)
		"settle_loss":
			## 纯静态五进一出；C# 侧 Settlement.SettleLoss 是 §0.6.7 开的同一个入口，两边都只转调、不重写算式
			return CWGame.settle_loss(_arg_int(args, "base"), _arg_int(args, "add"), \
				_arg_int(args, "mult"), _arg_int(args, "div"), _arg_int(args, "cut"))
		"move_raw_cost":
			## 一步的**起价**（修饰之前）。借道前进不走这里 —— 那是 pass_through_cost
			return g.actions._one_step_base(_cell(g, args), _pos(str(args.get("to", ""))))
		"pass_through_cost":
			## 借道落点的**整价** = 沿途每格 _one_step_base 之和（修饰之前，修饰只在落点跑一遍）。
			## 两侧都**没有**「不在表里」的返回值（GD 索引出错、C# KeyNotFound）——
			## 不许在这儿编一个哨兵（E-6 规矩 3），写错落点的用例当场报清楚
			var pt_cell: Dictionary = _cell(g, args)
			var pt_to: Vector2i = _pos(str(args.get("to", "")))
			var pt_map: Dictionary = g.actions.pass_through_map(pt_cell)
			if not pt_map.has(pt_to):
				_fail("借道表里没有 %s —— 它不是这只细胞的借道落点（相邻格与走不到的格都不在表里）" % str(pt_to))
				return null
			return pt_map[pt_to][0]
		"quote_path":
			## 第一条 tree。**tree 没有 ignore**，所以投影成同一张键表的活在两侧探针身上（见 _quote_path_tree）
			return _quote_path_tree(g, args)
		"move_legal":
			## bool → scalar 的 1 / 0：两侧表项各自冻，不靠 runner 的隐式转换
			return 1 if g.actions._is_move_legal_now(_cell(g, args), _pos(str(args.get("to", "")))) else 0
		## §0.6.7 四条里批 2 的那两条：批 2 第一段由空壳转真（op 名集合不动 ⇒ 双射不变）
		"anaerobic_pool":
			## 返回 float（十分能量）。**千分位冻成整数**，与批 0 的 const 表同一套传输编码（R4）；
			## 算式一行不写 —— 池子本身由 cw_world.gd:_anaerobic_pool 算
			return int(round(g.world._anaerobic_pool(_positions(str(args.get("block", "")))) * 1000.0))
		"split_share":
			## pool 走十进制字符串（L0Case.Args 是 <string,string>），count 走整数；返回值本来就是 int
			return g.world._split_share(float(str(args.get("pool", "0"))), _arg_int(args, "count"))
	_fail("不认识的探针：%s" % name)
	return null


## `quote_path` 的**投影**（批 1）。tree 没有 ignore，所以「把两侧的返回值投影成同一张键表」
## 这件事落在两侧探针身上（规格 §0.6.2 + 批 1 简报）。**只投影，一行算式都不写**（纪律 3）。
##
## 键表（与 C# 侧 `Probes.cs:QuotePathTree` **逐字相同**，人工核，没有机器闸）：
##   { ok, stop, total, left, gained, steps: [ { to, cost, mid, afford, blocked, gain } ] }
##   · `ok` / `afford` → 1 / 0；`to` / `mid` → "q,r"，
##     `mid` 不是借道走法时写 ""（GD 的 Vector2i.MAX ↔ C# 的 null，两侧都投影成空串）；
##   · `blocked` → **1 / 0**（有没有原因）。文案两侧只有「被占据」那一支逐字相同，
##     其余各拼各的（GD 走 move_block_reason 的六种文案 / C# 恒「走不到这一格」）⇒ 不进键表，
##     指着文案的那三条断言逐条留 GD（`xcheck/COVERAGE.md` 记空档）；
##   · **不收 `legal`**：GD 的 `legal` 不看余额（付不起时仍是 true），
##     C# 的 `legal` 恒等于 `afford`（reason 把「付不起」也算进去）—— 两侧不是同一个量，
##     收进来 `stops_on_budget` 那一档必然假红。要守的那条判据由 `afford` + `stop` 表达。
func _quote_path_tree(g: CWGame, args: Dictionary) -> Variant:
	var q: Dictionary = g.actions.quote_path(_cell(g, args), _pos_list(str(args.get("path", ""))))
	var steps: Array = []
	for s in q["steps"]:
		steps.append({
			"to": _pos_text(s["to"]),
			"cost": int(s["cost"]),
			"mid": _pos_text(s["mid"]),
			"afford": 1 if s["afford"] else 0,
			"blocked": 1 if str(s["blocked"]) != "" else 0,
			"gain": int(s["gain"]),
		})
	return {
		"ok": 1 if q["ok"] else 0,
		"stop": int(q["stop"]),
		"total": int(q["total"]),
		"left": int(q["left"]),
		"gained": int(q["gained"]),
		"steps": steps,
	}


# ---- 常量表（探针 const）----
## **一个探针管一整张表**（规格 §B 批 0：「不要一个常量一个探针」）：`args.name` 是 GD 全名。
## 表项只**转调 / 取值，一行算式都不写**（纪律 3）—— 写了就从「两边算出同一个数」
## 变成「两边各抄了一份同样的算式」，那种绿灯不作数。
##
## 键集合与 C# 侧 `core/CellWar.Core.Tests/L0/Probes.cs:ConstTable` **逐字相同**（人工核，没有机器闸）。
## 其中 21 个符号 C# 那边没有对应物（或只有 private）：C# 表项抛 NotSupportedException，
## 对应断言**留在 GD 的老 check() 里、用例不进仓库**（清单见 contract_ops.json 的 `const` 行 note）。
##
## **传输形状**（两侧表项逐字同一套，C# 侧 Probes.cs 上有同一段注释）：
##   * int    → `scalar`，裸整数原样；
##   * bool   → `scalar`，写 1 / 0；
##   * float  → 按**千分位**冻成整数 `round(x * 1000)` —— 批 0 一个都没有，批 2 的探针 `anaerobic_pool` 是第一个真用户；
##   * Array / Dictionary → `tree`：Vector2i 写 "q,r"、枚举写整数值。
##     GD 这边由 runner 的 _to_json() 收口（它已经做 Vector2i → "q,r" 与 float 取整），
##     C# 那边由表项自己调 WorldLoader.At —— 两侧出来的字符串逐字相同。
##
## `args` 文法：`{"name": <GD 全名>}`；静态函数的位置参数写 "a" / "b" / "c"，一律字符串，
## 表项自己解析（整数 / 坐标 "q,r" / 枚举名）。
var _consts: Dictionary = _build_consts()


## 表项签名 `func(g: CWGame, a: Dictionary) -> Variant`，与 C# 的 `(WorldState s, Args a)` 一一对应。
func _build_consts() -> Dictionary:
	return {
		## ---- CWData · 常量（int → scalar）----
		"CWData.BOARD_RADIUS": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.BOARD_RADIUS,
		"CWData.TOTAL_TILES": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.TOTAL_TILES,
		"CWData.ANAEROBIC_BLOCK_EXP": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.ANAEROBIC_BLOCK_EXP,
		"CWData.ANAEROBIC_BLOCK_COEF": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.ANAEROBIC_BLOCK_COEF,
		"CWData.ANAEROBIC_SOLID_BONUS": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.ANAEROBIC_SOLID_BONUS,
		"CWData.NECROSIS_AEROBIC_PCT": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.NECROSIS_AEROBIC_PCT,
		"CWData.DIFFERENTIATE_MIN_LEVEL": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.DIFFERENTIATE_MIN_LEVEL,
		"CWData.HAND_MAX": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.HAND_MAX,
		"CWData.PSEUDOPOD_COST": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.PSEUDOPOD_COST,
		"CWData.EMT_MOVE_COST": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.EMT_MOVE_COST,
		"CWData.MUTATE_EXTRA_LOSS": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.MUTATE_EXTRA_LOSS,
		"CWData.MUTATE_MEMORY_CUT": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.MUTATE_MEMORY_CUT,
		"CWData.ATTACK_MAX_PER_TURN": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.ATTACK_MAX_PER_TURN,
		"CWData.MACRO_MOVE_NET_MIN": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.MACRO_MOVE_NET_MIN,
		"CWData.CHEMO_IMMUNE_PCT": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.CHEMO_IMMUNE_PCT,
		"CWData.CHEMO_SELF_PCT": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.CHEMO_SELF_PCT,
		"CWData.MARK_RANGE": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.MARK_RANGE,
		"CWData.HUNT_CHEMO_ROUNDS": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.HUNT_CHEMO_ROUNDS,
		## ---- CWData · 常量表（Array / Dictionary → tree）----
		"CWData.LEVEL_MIN_MEMORY": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.LEVEL_MIN_MEMORY,
		"CWData.AEROBIC_BY_LEVEL": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.AEROBIC_BY_LEVEL,
		"CWData.PROLIFERATE_BASE_BY_STAGE": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.PROLIFERATE_BASE_BY_STAGE,
		"CWData.PROLIFERATE_SOLID_BY_STAGE": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.PROLIFERATE_SOLID_BY_STAGE,
		"CWData.VESSELS": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.VESSELS,   ## Vector2i 表 —— _to_json() 把它冻成 ["6,0", "-6,0"]
		"CWData.EFFECTOR_NAMES": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.EFFECTOR_NAMES,   ## 键是 ImmuneType 枚举 —— _to_json() 冻成 "0"…"4"
		"CWData.IMMUNE_TYPE_TEXT": func(_g: CWGame, _a: Dictionary) -> Variant: return CWData.IMMUNE_TYPE_TEXT,
		## ---- CWData · 静态函数（位置参数 a / b / c，一律字符串，表项自己解析）----
		"CWData.init_cancer_tiles": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.init_cancer_tiles(_arg_int(a, "a")),
		"CWData.aerobic_level_base": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.aerobic_level_base(_arg_int(a, "a")),
		"CWData.anaerobic_cells_k": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.anaerobic_cells_k(_arg_int(a, "a")),
		"CWData.level_min_memory": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.level_min_memory(_arg_int(a, "a")),
		"CWData.antibody_no_target_x": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.antibody_no_target_x(_arg_int(a, "a")),
		"CWData.skill_text": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.skill_text(str(a.get("a", "")), _arg_int(a, "b"), int(a.get("c", -1))),   ## c = itype，缺省 -1（同 GD 的默认实参）
		"CWData.all_coords": func(g: CWGame, _a: Dictionary) -> Variant: return CWData.all_coords(g.board_radius),
		"CWData.ring": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.ring(_arg_pos(a, "a"), _arg_int(a, "b")),
		"CWData.neighbors": func(g: CWGame, a: Dictionary) -> Variant: return CWData.neighbors(_arg_pos(a, "a"), g.board_radius),   ## 半径走盘面的 board_radius —— C# 侧 GdNeighbors 是按 s.Board 裁的，不传就会在非 6 半径的盘面上分叉
		"CWData.hex_dist": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.hex_dist(_arg_pos(a, "a"), _arg_pos(a, "b")),
		"CWData.dir_toward": func(_g: CWGame, a: Dictionary) -> Variant: return CWData.dir_toward(_arg_pos(a, "a"), _arg_pos(a, "b")),   ## a = dest，b = from（同 GD 的形参序）
		## ---- CWCardData ----
		"CWCardData.CARDS": func(_g: CWGame, _a: Dictionary) -> Variant: return CWCardData.CARDS,
		"CWCardData.cancer_phase": func(_g: CWGame, a: Dictionary) -> Variant: return CWCardData.cancer_phase(_arg_int(a, "a")),
		"CWCardData.effect_of": func(_g: CWGame, a: Dictionary) -> Variant: return CWCardData.effect_of(str(a.get("a", "")), _arg_int(a, "b")),
	}


## 按名字取一个静态符号的值。名字不在表里 = 硬错：**不许**默默返回 null 让它当 0 比过去。
func _const_value(g: CWGame, args: Dictionary) -> Variant:
	var key := str(args.get("name", ""))
	if not _consts.has(key):
		_fail("常量表里没有「%s」—— 两侧表的键集合必须逐字相同（l0_runner.gd:_build_consts ↔ Probes.cs:ConstTable）" % key)
		return null
	return (_consts[key] as Callable).call(g, args)


## 位置参数缺了当场记账 —— C# 侧 `Probes.Args.Take` 是同一个规矩（写错键名的用例不许悄悄绿）。
func _arg_int(args: Dictionary, key: String) -> int:
	if not args.has(key):
		_fail("探针参数缺 %s（拿到的是 %s）" % [key, str(args)])
		return 0
	return int(args[key])


func _arg_pos(args: Dictionary, key: String) -> Vector2i:
	return _pos(str(args.get(key, "")))


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
		"erosion": await g.world._erosion(_positions(str(args.get("fresh", ""))))
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
		## ⚠ 参数名是 `dest`（契约表 args 的第二项、C# `a.Pos("dest")`）——
		##    批 1 之前这里写的是 `to`，因为 `cases: deferred`（零用例）一直没人踩到
		"enter_tile": await g.actions.enter_tile(_cell(g, args), _pos(str(args.get("dest", ""))), int(args.get("paid", -1)))
		"execute":
			return await _execute(g, args)
		## 伤害管线的单点入口（批 4 换真，两端签名已按 C-2 步 1 逐参数核过）。
		## args 四个键由硬约定定死：`target`（席位）/ `base`（十分能量）/ `source`（四个字面词）/ `ability`。
		## **不收 `attacker`**：C# 的 `CellRules.Damage` 没有这个形参，这边一律传 `{}` ——
		## 空字典让 `_queue_triggers` 的 `src.get("id", -1)` / `src.get("itype", -1)` 落空、
		## `_queue_execution` 的 `src.has("equipped")` 为假，吸血与斩杀都不触发，与 C# 逐条一致；
		## 要验吸血 / 斩杀 / 抗原记忆走 `execute` 的攻击分支。
		## **不收 `add`**（GD 在 `_calculate` 第一步就把它加进 base，用例折进 `base`）、
		## **不收 `direct`**（GD 那边是同批第二条事件，靶场造它等于重写攻击流程）。
		"damage_hit":
			var hit_target: Dictionary = _cell(g, args, "target")
			if hit_target.is_empty():
				return false
			var hit_base := int(args.get("base", 0))
			var hit_ability := str(args.get("ability", ""))
			match str(args.get("source", "")):
				"immune_attack":
					## `immune_hit` 的 ability 是**硬编码**的（attack=true 恒「攻击」）——
					## 用例写别的词，两侧的 ability 就不是同一个值了（【缺氧适应】【耗竭抵抗】都判它）
					if hit_ability != "攻击":
						_fail("damage_hit：source=immune_attack 的 ability 只能是「攻击」（GD immune_hit 写死），拿到「%s」" % hit_ability)
						return false
					g.immune_hit(hit_target, hit_base, {}, true)
				"immune_effect":
					if hit_ability != "技能":
						_fail("damage_hit：source=immune_effect 的 ability 只能是「技能」（GD immune_hit 写死），拿到「%s」" % hit_ability)
						return false
					g.immune_hit(hit_target, hit_base, {}, false)
				"cancer_skill":
					g.cancer_hit(hit_target, hit_base, hit_ability, true)
				"world":
					g.cancer_hit(hit_target, hit_base, hit_ability, false)
				var other:
					_fail("damage_hit 的 source 只认四个字面词（immune_attack / immune_effect / cancer_skill / world），拿到「%s」" % str(other))
					return false
		_:
			_fail("不认识的契约步：%s" % op)
			return false
	return true


## 契约步 `execute`（决策类 op，§0.6.4 第 1 条：名字用 GD 入口名）。
##
## **两侧不是同一个签名**：GD `execute(cell, data)` 收一个自带 `cost` 的 data 字典
## （调用方先报价），C# 收一个已经生成好的 IDecision、费用由它自己 QuoteMove。
## 所以 args 只能是**席位 + 语义键**，两侧各自从自己的选项表里按键找回那一条
## （这边 `build_options` + `CWSemKey.key`，C# 那边 `GetAvailableDecisions` + `SemanticKey.Of`）。
## 语义键的规矩 1 已经把 `cost` 剔出键外 —— 所以「C# 算费不同」不会伪装成「动作不同」，
## 它会原样落在 delta 的 energy 上。
##
## 批 4 起这条路上也走攻击：**攻击与移动是同一个键形**（`act=move`，落点上有活癌细胞才成为攻击，
## 见 `immune_move_options` —— 只有 label 不同，data 不变），掷骰念的是上面装好的那条带子。
func _execute(g: CWGame, args: Dictionary) -> bool:
	var cell: Dictionary = _cell(g, args, "seat")
	if cell.is_empty():
		return false
	var want := str(args.get("key", ""))
	## 中途询问按语义键作答（`answers` = ";" 分隔的键串；缺省 = 这一步不该问）。
	## 装给 `g.order` 里所有席位：【代谢耦联】那类会问到**别人**（cw_game.gd:ask 按 pid 取桥）。
	var bridge = load("res://tests/l0_answer_bridge.gd").new()
	bridge.game = g
	var ans := str(args.get("answers", ""))
	if ans != "":
		bridge.answers = PackedStringArray(ans.split(";"))
	for pid in g.order:
		g.bridges[pid] = bridge
	var keys := PackedStringArray()
	for o in g.actions.build_options(cell):
		var k := CWSemKey.key({ "kind": "action" }, o["data"])
		if k == want:
			await g.actions.execute(cell, o["data"])
			g.bridges.clear()
			for e in bridge.errors:
				_fail("execute 的中途询问：%s" % e)
			if bridge.used < bridge.answers.size():
				_fail("execute 的 answers 有 %d 条没用上（只问了 %d 次）" % [
					bridge.answers.size() - bridge.used, bridge.asked.size()])
			return bridge.errors.is_empty() and bridge.used == bridge.answers.size()
		keys.append(k)
	g.bridges.clear()
	keys.sort()
	_fail("席位 %d 的选项表里没有语义键「%s」。已有：%s" % [int(args.get("seat", -1)), want, " / ".join(keys)])
	return false


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
## `key` = 席位参数的**键名**：P 族与多数 S 族写 `cell`，`execute` 写 `seat`
## （C# 那边 `GetAvailableDecisions(s, seat)` 收的是席位，不是细胞）。
func _cell(g: CWGame, args: Dictionary, key: String = "cell") -> Dictionary:
	var seat := int(args.get(key, 0))
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


## 列表参数一律 `"q,r;q,r"` 一个串（空串 = 空表）—— C# 那头 `L0/CaseModel.cs` 的 `args` 是
## `Dictionary<string, string>`，写成数组整个用例文件都反序列化不了（不是单条红）。
func _positions(text: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if text.strip_edges() == "":
		return out
	for s in text.split(";"):
		out.append(_pos(str(s)))
	return out


## 坐标 → "q,r"；`Vector2i.MAX`（`pass_through_mid` 的「不是借道走法」哨兵）→ ""。
## C# 侧 `mid` 是 `HexPosition?`，null 同样投影成 "" —— 两侧出来的字符串逐字相同。
func _pos_text(v: Vector2i) -> String:
	return "" if v == Vector2i.MAX else ("%d,%d" % [v.x, v.y])


## `"q,r;q,r"` → 坐标表。用例的 `args` 值一律是**字符串**（C# 侧 `Args` 是 Dictionary<string,string>），
## 文法与 C# 侧 `Probes.Args.Positions` 同一套：分号分隔、空串 = 空表。
func _pos_list(text: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for part in text.split(";", false):
		out.append(_pos(part.strip_edges()))
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
