extends RefCounted
## agree_rng.gd —— AI 对拍模式（换内核 P3）：GD 参照与 C# `CellWar.Ai` 共用的那一小块「约定」
##
## 不带 class_name、按路径 preload（同 mech_dist.gd 的理由：热更依赖旧客户端的全局类表，新类名进不去）。
##
## **为什么要有对拍模式**（docs/内核替换_重启计划.md §五 第 1 条，Kevin 10-01）：AI 三档要搬进 C#，验收是
## 「同一份局面语料上两边逐决策比答案」。GD 参照里有四处会让同一局面答出不同结果、或者两边根本对不上：
##   ① 意图 / 搜索档的试走直接拷真局的 rng —— 等于偷看真局接下来的骰子（C# 版改用独立随机流）；
##   ② 启发式分化的并列决胜读 `game.rng.state` 做 GD `hash()` —— C# 没有 GD 的 hash；
##   ③ mech_dist 的距离场缓存键不含组织状态、跨局共享（脏读；2026-10-01 键已补全，对拍模式照旧旁路，语料录制条件不变）；
##   ④ `sort_custom` 不稳定，并列候选的次序随实现漂；外加两个内核的**选项生成次序**本来就不同。
## 对拍模式（`on = true`）把这四处换成两边逐位相同的做法；**默认关**，关着时线上行为一行不变
## （护栏 t_ai_agree_default_off 钉 t_ai_same_hash 的基线不动）。C# 那边**总是**用这一套。
##
## 本文件三样东西，C# 侧 `core/CellWar.Ai/SplitMix64Rng.cs` / `OptionView.cs` 是逐位镜像：
##   · SplitMix64 随机流（`randi_range` / `randf` 映射），装进 image 当 `game.rng`（鸭子类型，同 xcheck_tape.gd）；
##   · `tie_index(state, pid, n)`：启发式分化的并列决胜，替掉 GD `hash([rng.state, pid])`；
##   · 选项规范序 `canon_req`：语义键去重 → 「停 / 放弃」排最前（GD「可以不做的询问下标 0」约定）→ 其余按键的字典序。

## 对拍模式总开关。只有 tests/ai_agree_export.gd 与对拍护栏会拨它。
static var on := false
## 当前这一问的**推演种子**：试走副本的 rng 从它起步；顶层启发式的并列决胜也读它
## （C# 侧 `IPolicy.Choose` 收到的那条 rng 的初始状态就是它）。
static var decision_seed := 0
## 对拍模式下意图 / 搜索档把候选读数、叶值记在这里（导出器每问清一次）。关着时谁也不写。
static var trace := {}
## 排查用：非 null 时，每一问（含试走副本里陪练答的）记一条 [席位, 键, 作答时 rng 状态] —— 与 C# 侧
## RolloutCursor.DebugStep 逐条比，定位试走在哪一步分叉。只有手动排查脚本会拨它。
static var step_log = null

const GOLDEN := -7046029254386353131      ## 0x9E3779B97F4A7C15（GDScript 的 int 是有符号 64 位，十六进制字面量超界，写成十进制）
const MIX1 := -4658895280553007687        ## 0xBF58476D1CE4E5B9
const MIX2 := -7723592293110705685        ## 0x94D049BB133111EB

## SplitMix64 的状态（有符号 64 位视图；C# 侧是同一串比特的 ulong）。
var state := 0

## GD `RandomNumberGenerator.seed` 的替身（CWGame.init / restore 会写它）：直接把种子当状态
## （C# `new SplitMix64Rng(seed)` 同口径）。
var seed: int:
	set(v):
		state = v
	get:
		return state


## 逻辑右移：GDScript 的 `>>` 是算术右移，负数会补 1。掩掉高位就是无符号右移。
static func shr(z: int, k: int) -> int:
	return (z >> k) & ((1 << (64 - k)) - 1)


## SplitMix64 的输出混合（int64 加乘在 Godot 4.5 里按二补码回绕，10-01 实测与 C# ulong 逐位相同；护栏 t_ai_agree_rng 钉金值）。
static func mix(z: int) -> int:
	z = (z ^ shr(z, 30)) * MIX1
	z = (z ^ shr(z, 27)) * MIX2
	return z ^ shr(z, 31)


func next_u64() -> int:
	state += GOLDEN
	return mix(state)


## 全闭区间，与 GD `randi_range` 同口径。**`from == to` 零消耗**：Godot 的 PCG 在退化区间上不推进状态，
## 对拍带子上也不留痕（xcheck_tape.gd 头注）—— 两个内核都依赖这条，随机流必须照办，否则从第一个单选项起就错位。
## 取值只看跨度、与基数无关（`from + 63 位 % 跨度`）：C# 有几处 `NextInt(n)` 对 GD 的 `randi_range(1, n)`（L1 的 RNG_BASE），
## 两边抽到的偏移必须相同。
func randi_range(from: int, to: int) -> int:
	if from == to:
		return from
	if to < from:
		var t := from
		from = to
		to = t
	var span := to - from + 1
	return from + (shr(next_u64(), 1) % span)


## [0, 1)：高 53 位。引擎今天不调它（GD 只用 randi_range），C# 的 NextDouble 同式，留着两边口径一致。
func randf() -> float:
	return float(shr(next_u64(), 11)) / 9007199254740992.0


func randi() -> int:
	return shr(next_u64(), 32)


static func new_rng(start: int) -> RefCounted:
	var r = (load("res://scripts/ai/agree_rng.gd") as GDScript).new()
	r.state = start
	return r


## 启发式分化的并列决胜（替 GD `hash([rng.state, pid])`）：同状态同席位同答案，不消耗 rng。
static func tie_index(rng_state: int, pid: int, n: int) -> int:
	if n <= 0:
		return 0
	return shr(mix(rng_state + (pid + 1) * GOLDEN), 1) % n


## 一问的规范视图：返回 { req: 换了 options 的副本（带 `_canon` 标记），map: 规范下标 → 原下标 }。
## 键相同的选项只留第一条（癌方复活的多个依托剔掉 anchor 后就是同一个键；C# 那边一个键只有一条决策）。
static func canon_req(req: Dictionary) -> Dictionary:
	var seen := {}
	var rows: Array = []
	var opts: Array = req["options"]
	for i in opts.size():
		var k := CWSemKey.key(req, opts[i]["data"])
		if seen.has(k):
			continue
		seen[k] = true
		var d: Dictionary = opts[i]["data"]
		var first := 0 if (bool(d.get("stop", false)) or bool(d.get("skip", false))) else 1
		rows.append({ "k": k, "first": first, "i": i })
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["first"] != b["first"]:
			return a["first"] < b["first"]
		return a["k"] < b["k"])
	var canon := req.duplicate()
	var copts: Array = []
	var map: Array[int] = []
	for r in rows:
		copts.append(opts[r["i"]])
		map.append(int(r["i"]))
	canon["options"] = copts
	canon["_canon"] = true
	return { "req": canon, "map": map }


## 桥的对拍入口：把这一问换成规范视图再问一遍同一座桥，答案映射回原下标。
static func ask_canonical(bridge, req: Dictionary) -> int:
	var view := canon_req(req)
	var i: int = await bridge.ask(view["req"])
	var map: Array[int] = view["map"]
	if map.is_empty():
		return 0
	var picked: int = map[clampi(i, 0, map.size() - 1)]
	if step_log != null:
		step_log.append([int(req.get("pid", -1)), CWSemKey.key(req, req["options"][picked]["data"]), int(bridge.game.rng.state),
			_digest(bridge.game)])
	return picked


## 排查用的局面摘要（与 C# 侧 AgreementTests 的 Digest 同式）：记忆 / 等级 / 每只细胞的能量与位置 / 癌组织与固化数
static func _digest(g) -> String:
	var parts: PackedStringArray = ["m%d" % int(g.memory), "l%d" % int(g.immune_level),
		"c%d" % g.count_tissue(CWData.Tissue.CANCER), "s%d" % g.count_tissue(CWData.Tissue.SOLID)]
	for c in g.cells:
		parts.append("%d:%d@%d,%d%s%s" % [int(c["pid"]), int(c["energy"]), c["pos"].x, c["pos"].y, "" if c["alive"] else "x",
			("M%d/%d" % [int(c["mark_left"]), int(c["mark_round"])]) if bool(c["marked"]) else ""])
	return " ".join(parts)


## 把一列 {…, key_field: float} 按 key 稳定排序（GD `sort_custom` 不稳定，并列次序随实现漂；C# 的 OrderBy 是稳定的）。
static func stable_sort(rows: Array, key_field: String, descending: bool) -> Array:
	var tagged: Array = []
	for i in rows.size():
		tagged.append({ "row": rows[i], "i": i })
	tagged.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var qa: float = float(a["row"][key_field])
		var qb: float = float(b["row"][key_field])
		if qa != qb:
			return qa > qb if descending else qa < qb
		return a["i"] < b["i"])
	var out: Array = []
	for t in tagged:
		out.append(t["row"])
	return out
