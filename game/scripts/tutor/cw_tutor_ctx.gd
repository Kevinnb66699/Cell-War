## cw_tutor_ctx.gd —— 钩子 → 导演 的**唯一接口**（docs/新手引导v2_实现方案.md §3.7，S8，2026-09-19）
##
## 九个方法：`beat` / `until` / `read` / `alive` / `frame` / `rng` / `state` / `log` / `fail`。
## **签名逐字照 §3.7**，一个字都不许改 —— 护栏 `t_tutor_hooks` 把那九行签名当字面量核。
##
## 三条纪律（护栏逐条扫）：
## ① `ctx` **不暴露 kernel / mirror / game / view / stage 任何原始句柄**：成员全是私有的（下划线开头），
##    九个公开方法的返回类型只有 void / bool / Variant / Dictionary / RandomNumberGenerator 五种；
## ② 钩子文件**零成员变量**（状态只能进 `ctx.state()`，随代际一起清空）；
## ③ 钩子里**每个 `while` 的条件都含 `ctx.alive()`**。
##
## **取消语义**（方案 §3.7，搬乙的 epoch）：GDScript 的协程杀不掉，只能让它**永挂**。
## 每个 await 原语返回前都过一次代际闸 `_gate()`：代际变了就 `await director.dead`（那条信号永不 emit），
## 旧协程停在那儿、随导演一起被回收。`alive()` 是同一件事的非阻塞版，让钩子自己从循环里退出来，
## 把「永挂」压到最少的那几个 await 上。
##
## **不带 class_name，调用方 preload**（方案 §1.5）：钩子是会反复改的东西，要能走热更。
extends RefCounted

## 坐标解析只有数据门面一处（`parse_at`，同导演，不再抄第二份）
const SCRIPT_DATA := preload("res://scripts/kernel/cw_tutor_script.gd")

## 导演（`cw_tutor_director.gd`）。**不标类型**：它没有 class_name（要走热更）。
## **私有**：九个公开方法一个都不返回它 —— 钩子经 ctx 够不着导演的内部（方案 §1.3 第 3 条）
var _dir = null
## 这一代的代际号（建 ctx 那一刻 `director.epoch` 的快照）
var _ep := 0
## `flow[].hook.args`：钩子的入参，同时是 `rng()` 的**种子来源**（种子来自数据）
var _args := {}
## 演出随机（懒建，一只 ctx 一只）。**绝不碰内核 rng** —— 内核 rng 此刻是带子，
## 多掷一次整条错位，而 `cw_roll_tape.gd` 的 `overrun` 是**静默**回落真 rng，错了不报
var _rng_inst: RandomNumberGenerator = null


func _init(dir, ep: int, args: Dictionary = {}) -> void:
	_dir = dir
	_ep = ep
	_args = args.duplicate(true)


# =====================================================================
# 九个方法（§3.7，签名一字不改）
# =====================================================================

## ① 跑一条声明式条目 —— 与 `flow[]` 完全同构的九个动词（say / point / unlock / play / wait /
##    player / npc / state / hook）。钩子不自己说话、不自己画，一切经这里回到导演
func beat(row: Dictionary) -> void:
	if _dir != null and is_instance_valid(_dir):
		await _dir.run_beat(row, _ep)
	await _gate()


## ② 等一个谓词（§3.3 的三类，**同一张表、同一个基线**）。`timeout_secs > 0` 时超时返回 false
func until(pred: Dictionary, timeout_secs := 0.0) -> bool:
	var hit := false
	if _dir != null and is_instance_valid(_dir):
		hit = await _dir.run_until(pred, _ep, timeout_secs)
	await _gate()
	return hit


## ③ 只读查询（白名单八项，返回派生量的**副本**，绝不返回镜像本身）：
##    "cells" -> [{seat, at:Vector2i, type, alive, energy}]   "tile" (arg: Vector2i) -> {state, type, solid}
##    "dist"  (arg: [a, b]) -> int                            "beside" (arg: [seatA, seatB]) -> bool
##    "alive_count" (arg: "immune"|"cancer") -> int           "round" -> int
##    "energy" (arg: seat) -> int                             "active" -> [Vector2i]
##
## `state` / `type` 给的是**枚举整数**（`CWData.Tissue` / `CWData.Special`），与镜像同口径；
## 细胞的 `type` 给中文名（`CWData.IMMUNE_TYPE_NAMES` / `CANCER_TYPE_NAMES`），钩子的兜底文案要能直接用。
## 没有镜像时一律给**最保守**的那一边（查不到 = 别动），不是给 null 让钩子自己崩
func read(q: String, arg = null) -> Variant:
	var m := _m()
	match q:
		"cells":
			return _cells(m)
		"tile":
			return _tile(m, _at_of(arg))
		"dist":
			if not (arg is Array) or (arg as Array).size() != 2:
				return -1
			return CWData.hex_dist(_at_of((arg as Array)[0]), _at_of((arg as Array)[1]))
		"beside":
			if not (arg is Array) or (arg as Array).size() != 2:
				return false
			var a := _cell_of(m, int((arg as Array)[0]))
			var b := _cell_of(m, int((arg as Array)[1]))
			if a.is_empty() or b.is_empty():
				return false
			return CWData.hex_dist(Vector2i(a["pos"]), Vector2i(b["pos"])) == 1
		"alive_count":
			if m == null:
				return 0
			var f: int = CWData.Faction.CANCER if str(arg) == "cancer" else CWData.Faction.IMMUNE
			return m.living_cells(f).size()
		"round":
			return int(m.round_no) if m != null else 0
		"energy":
			var c := _cell_of(m, int(arg if arg != null else -1))
			return int(c["energy"]) if not c.is_empty() else 0
		"active":
			if _dir == null or not is_instance_valid(_dir) or not _dir.active_of.is_valid():
				return []
			return (_dir.active_of.call() as Array).duplicate()
	push_warning("ctx.read 的「%s」不在白名单八项里（cells / tile / dist / beside / alive_count / round / energy / active）" % q)
	return null


## ④ 代际闸：这一代还活着吗（重置 / 目录跳关 / 换局后为 false）。
##    **护栏硬要求：钩子里每个 while 的条件都必须含 `ctx.alive()`**
func alive() -> bool:
	return _dir != null and is_instance_valid(_dir) and _dir.alive(_ep)


## ⑤ 让一帧（内含代际闸）
func frame() -> void:
	if _dir != null and is_instance_valid(_dir):
		await _dir.next_frame()
	await _gate()


## ⑥ 钩子自己的演出随机数（**种子来自数据**：`hook.args.seed`，没写就按关 id 定死）
func rng() -> RandomNumberGenerator:
	if _rng_inst == null:
		_rng_inst = RandomNumberGenerator.new()
		_rng_inst.seed = _seed()
	return _rng_inst


## ⑦ 钩子唯一合法的状态落点（钩子文件不许有成员变量；重置时随代际一起清空）
func state() -> Dictionary:
	if _dir == null or not is_instance_valid(_dir):
		return {}
	return _dir.hook_state()


## ⑧ 记一笔（进无头流水账，不上屏）。账本是 `director.hook_log`，控制台只在 `--verbose` 下出声 ——
##    第七关的钩子一帧一笔，真打出来会把套件输出淹了。
##    **旧代一笔都不记**：`invalidate()` 之后挂死的协程万一在两个 await 之间跑了一段，也不许再出账
func log(msg: String) -> void:
	if not alive():
		return
	_dir.hook_log.append(msg)
	print_verbose("[教程钩子] %s" % msg)


## ⑨ 剧本写不下去了：warning + **挂起**（不静默继续、不替玩家乱答）。
##    出路是常驻「重置 / 目录」—— 它们各自把导演重新打开。
##    → **钩子里必须写 `await ctx.fail(...)`**：不等它挂住，钩子自己就返回了，
##    导演的 `_hook_depth` 归零、主游标把 `hook` 那一条翻过去 —— 恰好是“静默继续”那一种死法
func fail(why: String) -> void:
	if _dir == null or not is_instance_valid(_dir):
		return
	_dir.hook_fail(why)
	await _dir.dead


# =====================================================================
# 私有（钩子够不着）
# =====================================================================

## 每个 await 原语的结尾统一这一句（§3.7）：代际变了就永挂
func _gate() -> void:
	if _dir == null or not is_instance_valid(_dir):
		return
	if _ep != _dir.epoch:
		await _dir.dead


## 此刻那一份镜像。**只在本文件内部用**：九个公开方法一个都不返回它
func _m() -> CWMirror:
	if _dir == null or not is_instance_valid(_dir) or not _dir.mirror_of.is_valid():
		return null
	return _dir.mirror_of.call() as CWMirror


## `read("cells")`：逐只拷出五个字段。**含死者**（下标即 id 的稠密表，`alive` 自己带着）
func _cells(m: CWMirror) -> Array:
	var out: Array = []
	if m == null:
		return out
	for c in m.cells:
		out.append({ "seat": int(c["pid"]), "at": Vector2i(c["pos"]), "type": _type_name(c),
			"alive": bool(c["alive"]), "energy": int(c["energy"]) })
	return out


func _type_name(c: Dictionary) -> String:
	if int(c["faction"]) == CWData.Faction.CANCER:
		return str(CWData.CANCER_TYPE_NAMES.get(int(c["ctype"]), ""))
	return str(CWData.IMMUNE_TYPE_NAMES.get(int(c["itype"]), ""))


## `read("tile")`：三个字段的副本。`state` = 组织（`CWData.Tissue`）、`type` = 特殊组织（`CWData.Special`）
func _tile(m: CWMirror, at: Vector2i) -> Dictionary:
	if m == null or not m.tiles.has(at):
		return {}
	var t: Dictionary = m.tiles[at]
	return { "state": int(t["tissue"]), "type": int(t["special"]), "solid": int(t["solid"]) }


## 某一席此刻活着的那只细胞（没有就空字典）
func _cell_of(m: CWMirror, seat: int) -> Dictionary:
	if m == null:
		return {}
	for c in m.cells:
		if int(c["pid"]) == seat and bool(c["alive"]):
			return c
	return {}


## 坐标入参两种写法都认：`Vector2i` 或数据里那种 `"q,r"`
func _at_of(arg) -> Vector2i:
	if arg is Vector2i:
		return arg
	return SCRIPT_DATA.parse_at(str(arg))


## `rng()` 的种子：数据里写了就用数据的，没写按**关 id** 定死 —— 两种都与运行期无关，
## 所以「同一关跑两遍逐帧复现」成立
func _seed() -> int:
	if _args.has("seed"):
		return int(_args["seed"])
	var id := ""
	if _dir != null and is_instance_valid(_dir):
		id = str((_dir.level as Dictionary).get("id", ""))
	return hash(id)

