## cw_case_diff.gd —— cwxcase/2 的 `delta` / `tree` 判定（测试迁移规格 A-1 / §0.6.2 的 GD 半边）
##
## 四件事，别处不许再写第二份：
##   · `normalize(env)`   —— `L1/EnvelopeNormalize.cs` 的 **GD 逐字版**，输入 `CWObsCodec.encode` 出来的整份
##     envelope，返回 `$` 根 = `{board, cells, g, ask}` 四件套（`state` 三件 + 兄弟 `ask`）。
##     **全局豁免表只有这一份**（§0.6.2）：元数据 + tier B + 观测协议 §八 五条（原 #3 `cancer_alarm.streak` 2026-09-19 收敛，进对拍）。C# 侧 `L0/Subset.cs`
##     调的是同一套裁剪 —— 两边不一致就是各比各的，闸一形同虚设。
##   · `diff(pre, post)`  —— 路径 → post 的值；pre 有 post 没有的记 `null`（整条消失）。
##   · `compare(a, b)`    —— tree 比法：两棵字面 JSON 树不同的**路径列表**，升序。
##   · `apply_ignore(d, ignore)` —— 单条用例的豁免（A-1）；一条 ignore 一个字段都没命中 = 硬错。
##
## ⚠ **整集合比，不是包含比**（A-1 最重要的单条判定规则）：包含比只钉「该变的变了」，
## 钉不住「不该变的没变」。C# 多改一个字段红，少改一个字段也红。
##
## 路径文法（§0.6.2 / A-1，两侧逐字同）：
##   `$.board.tiles@<q>,<r>.<键>` / `$.cells[<席位>].<键>` / `$.cells[<席位>].mods[<卡名>].<键>` /
##   `$.g.<键>` / `$.g.events.active[<事件名>].<键>` / `$.ask.kind` `$.ask.tag` `$.ask.seat`。
##   **只有上面这四个数组有语义键**（tiles / cells / cells[].mods / g.events.active）；
##   其余数组（`hand` / `equipped` / `fx_round` / `g.players` / `g.order` / `g.feed_log` / `events.pool` …）
##   整条当一个叶子比 —— 序号下标在「一席多细胞」那天会静默换靶，所以一个都不开。
##   `*` 只许出现在**倒数第二段**；同席多细胞取 `cells[<席位>]` = 硬错；`$.ask.options` 及子路径 = 硬错。
##
## 硬错走 `errors`（静态）：`diff()` 进来先清空，出错就返回 `{}`。
## 不带 class_name（同 xcheck_* 的规矩），用 preload 取。
extends RefCounted

const ROOT := "$"
## 形状路径（下标全抹掉）→ 该数组的语义键。**这张表就是全部**，没列的数组一律当叶子
const KEYED := {
	"$.cells": "pid",
	"$.cells[].mods": "name",
	"$.g.events.active": "name",
}
## 棋盘那条单列：写成 `tiles@q,r`（A-1 的文法就是这么定的）
const TILES_SHAPE := "$.board.tiles"
## 本批禁选（§0.6.2）：C# 侧 normalize 把 options 折叠成字典，GD 不移植折叠 ——
## 差分一旦命中这条或它的子路径，两侧比的就不是同一棵树，当场硬错
const ASK_OPTIONS := "$.ask.options"

static var errors: PackedStringArray = []


# =====================================================================
# normalize —— L1/EnvelopeNormalize.cs 的 GD 逐字版
# =====================================================================

## 输入 CWObsCodec.encode 出来的整份 envelope（不改原件），输出 `$` 根四件套。
## `ask` 只留 kind / tag / seat 这类标量：`options`（C# 折叠、GD 不折叠）与 `stop_key` / `stop_index`（两侧串不同）
## 在这一层整个摘掉，C# `L0/Subset.Normalize` 同 —— S 族步产生询问时两侧差分形状才一样；手写路径选到它们 = 命中零个字段（硬错）。
static func normalize(env: Dictionary) -> Dictionary:
	var e: Dictionary = env.duplicate(true)
	## 元数据：构造 `$` 根时本来也进不来，照 C# 原样先剥一遍
	for k in ["p", "ruleset", "rev", "obs_seq", "viewer", "open_hands", "produced_tiers", "full", "base"]:
		e.erase(k)
	var state: Dictionary = e["state"]
	var board: Dictionary = state["board"]
	for t in board["tiles"]:
		for k in CWObsProto.TILE_D_B:
			((t as Dictionary)["d"] as Dictionary).erase(k)
	for c in state["cells"]:
		var cell: Dictionary = c
		## §八 #1：三个数组两侧生成序不同，比之前各自排序
		for k in ["hand", "equipped", "fx_round"]:
			var xs: Array = (cell[k] as Array).duplicate()
			xs.sort()
			cell[k] = xs
		for k in CWObsProto.CELL_D_B:
			(cell["d"] as Dictionary).erase(k)
	var g: Dictionary = state["g"]
	for k in CWObsProto.G_D_B:
		(g["d"] as Dictionary).erase(k)
	## §八 #6：文案不比
	(g["d"] as Dictionary)["phase_text"] = ""
	g["win_reason"] = ""
	var diffs: Array = (g["differentiated"] as Array).duplicate()
	diffs.sort()
	g["differentiated"] = diffs
	## §八 #5：玩家昵称不比
	for p in g["players"]:
		(p as Dictionary).erase("name")
	## §八 #6：日志只比「有没有」。`$` 根里没有 logs 这一支，这一行只为与 C# 版逐条对得上
	e["logs"] = "present" if (e["logs"] as Dictionary)["lines"] is Array else null
	var ask: Variant = e.get("ask", null)
	if ask is Dictionary:
		var a: Dictionary = ask
		a.erase("ask_id")
		a.erase("rev")
		a["prompt"] = ""
		for k in ["options", "stop_key", "stop_index"]:
			a.erase(k)
	return { "board": board, "cells": state["cells"], "g": g, "ask": ask }


# =====================================================================
# diff —— 差分集合
# =====================================================================

## 路径 → post 的值。pre 有、post 没有的记 null（事件到期 / 修饰条目用完）——
## envelope 里**天然是 null 的那三个**（g.chemo / g.chemo_track / cells[].camp_pos）都不是数组元素，
## 永远不会以「整条消失」的形式出现，所以 null 在这里不歧义。
## 硬错（同席多细胞 / 命中 $.ask.options）时返回 {}，原因在 errors 里。
static func diff(pre: Dictionary, post: Dictionary) -> Dictionary:
	errors = PackedStringArray()
	var a := flatten(pre)
	var b := flatten(post)
	if not errors.is_empty():
		return {}
	var out := {}
	for p in b:
		if not a.has(p) or not _same(a[p], b[p]):
			out[p] = b[p]
	for p in a:
		if not b.has(p):
			out[p] = null
	for p in out:
		var path := str(p)
		if path == ASK_OPTIONS or path.begins_with(ASK_OPTIONS + "."):
			errors.append("差分命中 %s —— 本批禁选 ask.options 及其子路径（§0.6.2：C# 折叠、GD 不折叠），只许 $.ask.kind / $.ask.tag / $.ask.seat" % path)
	if not errors.is_empty():
		return {}
	return out


## `$` 根 → {路径: 叶子值}
static func flatten(root: Dictionary) -> Dictionary:
	var out := {}
	_walk(root, ROOT, ROOT, out)
	return out


static func _walk(node: Variant, path: String, shape: String, out: Dictionary) -> void:
	if node is Dictionary:
		var d: Dictionary = node
		if d.is_empty():
			out[path] = {}
			return
		var keys: Array = d.keys()
		keys.sort()
		for k in keys:
			_walk(d[k], "%s.%s" % [path, str(k)], "%s.%s" % [shape, str(k)], out)
		return
	if node is Array:
		var arr: Array = node
		if shape == TILES_SHAPE:
			for t in arr:
				var at: Dictionary = (t as Dictionary)["at"]
				_walk(t, "%s@%d,%d" % [path, int(at["q"]), int(at["r"])], shape + "[]", out)
			return
		if KEYED.has(shape):
			var field: String = KEYED[shape]
			var seen := {}
			for item in arr:
				var k := _key_text((item as Dictionary)[field])
				if seen.has(k):
					errors.append("%s[%s] 歧义：同一个 %s 出现两次 —— 语义键下标会静默换靶，本批不定第二级键" % [path, k, field])
					return
				seen[k] = true
			for item in arr:
				var k := _key_text((item as Dictionary)[field])
				_walk(item, "%s[%s]" % [path, k], shape + "[]", out)
			return
		## 没有语义键的数组整条当一个叶子
		out[path] = arr.duplicate(true)
		return
	out[path] = node


# =====================================================================
# 判定
# =====================================================================

## tree 比法：两棵字面 JSON 树不同的路径列表，升序。路径格式照 C# `L1/DeepDiff.Compare`：`$[ok]` / `$[steps][2][cost]`（全中括号）。数组按**序号**下标 ——
## 这里比的不是 envelope，序号下标才报得出「steps[2].cost 错了」这种话。
static func compare(a: Variant, b: Variant) -> PackedStringArray:
	var x := {}
	var y := {}
	_walk_tree(a, ROOT, x)
	_walk_tree(b, ROOT, y)
	var bad := {}
	for p in y:
		if not x.has(p) or not _same(x[p], y[p]):
			bad[p] = true
	for p in x:
		if not y.has(p):
			bad[p] = true
	var paths: Array = bad.keys()
	paths.sort()
	return PackedStringArray(paths)


static func _walk_tree(node: Variant, path: String, out: Dictionary) -> void:
	if node is Dictionary:
		var d: Dictionary = node
		if d.is_empty():
			out[path] = {}
			return
		var keys: Array = d.keys()
		keys.sort()
		for k in keys:
			_walk_tree(d[k], "%s[%s]" % [path, str(k)], out)   ## 中括号：与 C# L1/DeepDiff.Compare 同格式（裁决 R1 Q2）
		return
	if node is Array:
		var arr: Array = node
		if arr.is_empty():
			out[path] = []
			return
		for i in arr.size():
			_walk_tree(arr[i], "%s[%d]" % [path, i], out)
		return
	out[path] = node


## 单条用例的豁免（A-1）：命中的路径整条剔掉。一条 ignore 一个字段都没命中 = 硬错，
## 一条路径写错了字也就当场红，而不是悄悄放行。
static func apply_ignore(d: Dictionary, ignore: Array) -> Dictionary:
	## 先把模式编一遍：写错位置的通配只报一条，不跟着路径数翻倍
	var rx: Array = []
	for p in ignore:
		rx.append(_compile(str(p)))
	var out := {}
	var hit := {}
	for p in d:
		var i := _match_any(rx, str(p))
		if i >= 0:
			hit[i] = true
			continue
		out[p] = d[p]
	for i in ignore.size():
		if rx[i] != null and not hit.has(i):
			errors.append("ignore 里的 %s 一个字段都没命中 —— 空豁免是硬错，不是通过" % str(ignore[i]))
	return out


## 命中返回 ignore 里的下标（查「这条 ignore 一个字段都没命中」用），没命中返回 -1
static func _match_any(compiled: Array, path: String) -> int:
	for i in compiled.size():
		var rx: RegEx = compiled[i]
		if rx != null and rx.search(path) != null:
			return i
	return -1


## `*` 只许出现在**倒数第二段**（A-1）。写错位置 = 硬错，不当成「没命中」
static func _compile(pattern: String) -> RegEx:
	if pattern.begins_with("$.ask.") and not (pattern in ["$.ask.kind", "$.ask.tag", "$.ask.seat"]):
		errors.append("路径 %s：本批 ask 下只许选 $.ask.kind / $.ask.tag / $.ask.seat（§0.6.2）" % pattern)
		return null
	var parts: PackedStringArray = pattern.split(".")
	var stars := 0
	for i in parts.size():
		var n := parts[i].count("*")
		stars += n
		if n > 0 and i != parts.size() - 2:
			errors.append("路径 %s 里的 * 不在倒数第二段 —— 只许那一段用通配" % pattern)
			return null
	if stars > 1:
		errors.append("路径 %s 里有 %d 个 * —— 只许一个" % [pattern, stars])
		return null
	var esc := ""
	for i in pattern.length():
		var ch := pattern[i]
		if ch == "*":
			esc += "[^.]*"
		elif "\\.^$|()[]{}+?/-".contains(ch):
			esc += "\\" + ch
		else:
			esc += ch
	var rx := RegEx.new()
	rx.compile("^" + esc + "$")
	return rx


## 数字一律按数值比：Godot 的 JSON 把所有数都解成 float，用例里的 5 与 envelope 里的 5 是两种类型
static func _same(x: Variant, y: Variant) -> bool:
	if _is_num(x) and _is_num(y):
		return is_equal_approx(float(x), float(y))
	if x is Array and y is Array:
		var a: Array = x
		var b: Array = y
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if x is Dictionary and y is Dictionary:
		var da: Dictionary = x
		var db: Dictionary = y
		if da.size() != db.size():
			return false
		for k in da:
			if not db.has(k) or not _same(da[k], db[k]):
				return false
		return true
	if typeof(x) != typeof(y):
		return false
	return x == y


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## 语义键的字面写法：席位 / 事件名 / 卡名。数字一律按整数写 —— Godot 的 JSON 把 `1` 解成 1.0，
## 直接 str() 会写出 `cells[1.0]`，与 C# 侧（JsonNode 拿到的是整数）当场岔开
static func _key_text(v: Variant) -> String:
	return str(int(v)) if _is_num(v) else str(v)
