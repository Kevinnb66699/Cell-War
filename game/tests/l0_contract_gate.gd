## l0_contract_gate.gd —— 契约面的**启动闸**（测试迁移规格 §0.6.4 第 4 条）
##
## 三条启动断言的 **GD 半边**，C# 半边在 `core/CellWar.Core.Tests/L0/ContractGateTests.cs`。
## 两侧读的是**同一份** `game/tests/contract_ops.json` —— A-6 原来写的「两边各一条护栏读对方的表」
## 已按 §0.6.6 改成「两侧都与契约表双射，相等经表传递」，谁也不解析对方的源码。
##
##   ① 双射：分派表的名字集合 ≡ 表里 `status ∈ {OK, KNOWN_GAP, UNDEFINED}` 的 `op` 集合
##      （`NOTIMPL` / `OUT_OF_SCOPE` 不进分派；`cases: "deferred"` 的进分派但放空壳）。
##   ② 用例面：`required` 行 ≥1 条用例且每档 `boundaries` 正则 ≥1 条命中；`none` 行零用例；
##      用例引的 `probe` / `op` 都在表里且族对得上。
##   ③ 表本身：`kind` 只许 probe / step（**T 族不进契约面**）、`op` 名不重复、
##      `status` 五档之一、`cases` 三值之一。
##
## ⚠ 测试设施，不改任何游戏行为。不带 class_name（同 `xcheck_*` 的规矩），用 preload 取：
##   `preload("res://tests/l0_contract_gate.gd").check("res://tests/contract_ops.json", PROBE_NAMES + STEP_NAMES)`
## 返回空 = 过；非空 = 逐条打印并整体红。
extends RefCounted

const CASE_DIR := "res://tests/l0"

## 进分派表的三档（§0.6.4 第 4 条写死的判定子集）
const DISPATCH_STATUS := ["OK", "KNOWN_GAP", "UNDEFINED"]
const ALL_STATUS := ["OK", "KNOWN_GAP", "UNDEFINED", "NOTIMPL", "OUT_OF_SCOPE"]
const ALL_CASES := ["required", "deferred", "none"]
const ALL_KIND := ["probe", "step"]


## 契约表 → Array（读不出来返回空数组，由 check() 负责报错）
static func load_table(table_path: String) -> Array:
	if not FileAccess.file_exists(table_path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(table_path))
	if typeof(parsed) != TYPE_ARRAY:
		return []
	return parsed


## 录制代理的覆写集合（§0.6.4 第 4 条：分派子集里 `kind: "step"` 且 `rec != "manual"` 的行，共 24 条）。
## `rec: "manual"` 的那条（`damage_hit`）住在 CWGame 上，四个代理够不着，批 4 手写用例。
static func recorder_overrides(table_path: String) -> Array[String]:
	var out: Array[String] = []
	for row in load_table(table_path):
		if str(row.get("kind", "")) != "step":
			continue
		if not (str(row.get("status", "")) in DISPATCH_STATUS):
			continue
		if str(row.get("rec", "")) == "manual":
			continue
		out.append(str(row.get("gd", "")))
	return out


## 三条断言。返回错误列表（空 = 过）。
static func check(table_path: String, dispatch_names: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	if not FileAccess.file_exists(table_path):
		errors.append("契约门：读不到契约表 %s —— 它是唯一的 op 白名单（规格 §0.6.4）" % table_path)
		return errors
	var table := load_table(table_path)
	if table.is_empty():
		errors.append("契约门：%s 解不出 op 数组（JSON.parse_string 不吃注释，表里不许有注释）" % table_path)
		return errors

	var by_op := {}
	_check_table(table, by_op, errors)
	_check_bijection(table, dispatch_names, errors)
	_check_cases(table, by_op, errors)
	return errors


# ---- ③ 表本身 ----
static func _check_table(table: Array, by_op: Dictionary, errors: PackedStringArray) -> void:
	for row in table:
		var op := str(row.get("op", ""))
		if op == "":
			errors.append("契约门③：有一行没写 op")
			continue
		if by_op.has(op):
			errors.append("契约门③：op 名重复「%s」" % op)
		by_op[op] = row
		var kind := str(row.get("kind", ""))
		if not (kind in ALL_KIND):
			errors.append("契约门③：%s 的 kind 只许 probe / step，拿到「%s」—— T 族不进契约面（规格 §0.3）" % [op, kind])
		var status := str(row.get("status", ""))
		if not (status in ALL_STATUS):
			errors.append("契约门③：%s 的 status「%s」不是五档之一（%s）" % [op, status, ", ".join(ALL_STATUS)])
		var cases := str(row.get("cases", ""))
		if not (cases in ALL_CASES):
			errors.append("契约门③：%s 的 cases「%s」不是 required / deferred / none 之一" % [op, cases])


# ---- ① 双射 ----
static func _check_bijection(table: Array, dispatch_names: Array, errors: PackedStringArray) -> void:
	var listed := {}
	for row in table:
		if str(row.get("status", "")) in DISPATCH_STATUS:
			listed[str(row.get("op", ""))] = true
	var mine := {}
	for name in dispatch_names:
		if mine.has(str(name)):
			errors.append("契约门①：分派表里「%s」出现了两次 —— P 族与 S 族撞名，runner 分派会歧义" % str(name))
		mine[str(name)] = true
	for op in listed.keys():
		if not mine.has(op):
			errors.append("契约门①：契约表有「%s」（status 在分派档），GD 分派表里没有" % op)
	for name in mine.keys():
		if not listed.has(name):
			errors.append("契约门①：GD 分派表有「%s」，契约表里没有它、或它的 status 不在分派档（NOTIMPL / OUT_OF_SCOPE 不进分派）" % name)


# ---- ② 用例面 ----
static func _check_cases(table: Array, by_op: Dictionary, errors: PackedStringArray) -> void:
	var used := {}   ## op 名 → 用例 id 数组
	for path in _case_files():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("schema"):
			continue   ## 同目录下的数据夹具（如 diff_fixture.json 的 cwxdiff/1），不是用例表
		if typeof(parsed) != TYPE_ARRAY:
			errors.append("契约门②：%s 解不出用例数组" % path)
			continue
		for c in parsed:
			var id := str(c.get("id", "(无 id)"))
			var has_probe: bool = c.has("probe")
			var has_op: bool = c.has("op")
			if has_probe == has_op:
				errors.append("契约门②：用例 %s 的 probe / op 要二选一（都写或都不写 = 硬错）" % id)
				continue
			var name := str(c.get("probe", "")) if has_probe else str(c.get("op", ""))
			var want := "probe" if has_probe else "step"
			if not by_op.has(name):
				errors.append("契约门②：用例 %s 引用了契约表里没有的 %s「%s」" % [id, want, name])
				continue
			var kind := str(by_op[name].get("kind", ""))
			if kind != want:
				errors.append("契约门②：用例 %s 写的是 %s「%s」，可它在契约表里是 kind=%s" % [id, want, name, kind])
				continue
			if not used.has(name):
				used[name] = []
			used[name].append(id)

	for row in table:
		var op := str(row.get("op", ""))
		var mine: Array = used.get(op, [])
		match str(row.get("cases", "")):
			"required":
				if mine.is_empty():
					errors.append("契约门②：required 的 %s 一条用例都没有" % op)
				for b in row.get("boundaries", []):
					var tag := str(b.get("tag", ""))
					var pattern := str(b.get("cases", ""))
					var rx := RegEx.new()
					if rx.compile(pattern) != OK:
						errors.append("契约门②：%s 档「%s」的正则编译不了：%s" % [op, tag, pattern])
						continue
					var hit := 0
					for id in mine:
						if rx.search(id) != null:
							hit += 1
					if hit == 0:
						errors.append("契约门②：required 的 %s 档「%s」（%s）零条用例命中" % [op, tag, pattern])
			"none":
				if not mine.is_empty():
					errors.append("契约门②：挂档 %s（cases: none）却有 %d 条用例：%s" % [op, mine.size(), ", ".join(mine)])


## `res://tests/l0/**/*.json`：照 `l0_runner.gd:_case_files` 的目录扫描，另外下钻子目录。
static func _case_files() -> Array:
	var out: Array = []
	_scan_dir(CASE_DIR, out)
	out.sort()
	return out


static func _scan_dir(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_files():
		if name.ends_with(".json"):
			out.append("%s/%s" % [dir_path, name])
	for sub in dir.get_directories():
		_scan_dir("%s/%s" % [dir_path, sub], out)
