## ai_agree_recorder.gd —— AI 对拍语料的录制桥（换内核 P3，docs/内核替换_重启计划.md §四 P3）
##
## 装在真局的**每一席**上：每来一问（顶层与结算中途的都算），三档 AI（普通 / 意图 / 搜索）各答一遍，
## 只把**本席指定那一档**的答案交回引擎；三档的答案、意图 / 搜索档的候选读数与叶值一起记成一条。
## C# 侧 core/CellWar.Core.Tests/Ai/AgreementTests.cs 装回来逐问比。
##
## 三档都在**对拍模式**下答（agree_rng.gd：独立推演流、规范选项序、稳定排序、无距离场缓存）。
## 三座桥彼此不共享状态（MechBridge 的计划缓存在 PLAN_HORIZON = 1 下从不改答案），轮流问不会互相干扰。
##
## 单独成文件是因为测试脚本的内部类不能 extends 全局类（同 xcheck_bridge.gd）。
extends CWBridge

const AGREE := preload("res://scripts/ai/agree_rng.gd")
const LOADER := preload("res://scripts/kernel/cw_world_loader.gd")

const TIERS := ["normal", "intent", "search"]

var heur: CWHeuristicBridge
var intent: MechBridge
var search: MechBridge
## 席位 → 这一席实际出手的档（"normal" / "intent" / "search"）
var seat_tier := {}
## 推演种子的基数：第 n 问的种子 = mix(base + n·GOLDEN)。只要两边读同一个数，怎么派生都行 —— C# 读语料里记下的那个
var base_seed := 1
## 导出循环在问顶层那一问时拨成 true（那一刻停在 pending 边界上，世界能导出来）；结算中途的追问是 false
var top_level := false
var n := 0
var out: FileAccess = null
var stats := { "asks": 0, "worlds": 0, "intent_runs": 0, "search_runs": 0 }
## 排查用（ai_agree_export.gd 的 debug= 参数）：第 debug_target 问时把 debug_tier 那一档的试走逐步记到 debug_out
## （AGREE.step_log：[席位, 键, rng 状态, 局面摘要]），与 C# 侧 AgreementTests.开发试走逐步 的输出逐行比，定位第一处分叉
var debug_target := -1
var debug_tier := "search"
var debug_out := ""


func setup(g: CWGame) -> void:
	game = g
	heur = CWHeuristicBridge.new()
	heur.game = g
	intent = MechBridge.new()
	intent.game = g
	search = MechBridge.new()
	search.game = g
	search.use_search = true
	search.use_fit_eval = true
	MechBridge._fit_linear_on = false


func ask(req: Dictionary) -> int:
	n += 1
	var pid: int = int(req["pid"])
	var kind: String = str(req.get("kind", ""))
	var seed_n: int = AGREE.mix(base_seed + n * AGREE.GOLDEN)
	AGREE.decision_seed = seed_n
	var row := {
		"t": "ask", "i": n, "seat": pid, "kind": kind, "tag": str(req.get("tag", "")),
		"seed": str(seed_n), "tier": seat_tier.get(pid, "normal"),
		"opts": _opts(req),
	}
	## 顶层的行动 / 落子问答：此刻在 pending 边界上，导世界 + 真局 rng 状态 = 一段的起点
	if top_level and (kind == "action" or kind == "setup_place"):
		var w: Dictionary = LOADER.new().dump_world(game)
		_normalize_events(w)
		if not w.is_empty():
			row["world"] = w
			row["rng"] = str(int(game.rng.state))
			## 本回合已执行的行动数（GD 行动次数护栏 80 的计数）：cwxworld/3 不带它，C# 装回世界后补上
			row["acts"] = int(game.flow["acts"])
			stats["worlds"] += 1
	if n == debug_target:
		await _debug_dump(req)
	var answers := {}
	var picks := {}
	for tier in TIERS:
		AGREE.trace = {}
		var b: CWBridge = heur if tier == "normal" else (intent if tier == "intent" else search)
		var idx: int = await b.ask(req)
		idx = clampi(idx, 0, req["options"].size() - 1)
		picks[tier] = idx
		answers[tier] = CWSemKey.key(req, req["options"][idx]["data"])
		if kind == "action" and tier != "normal":
			row[tier + "_trace"] = _trace(AGREE.trace)
			stats[tier + "_runs"] += 1
	AGREE.trace = {}
	row["ans"] = answers
	var taken: int = picks[row["tier"]]
	row["taken"] = answers[row["tier"]]
	stats["asks"] += 1
	if out != null:
		out.store_line(JSON.stringify(row, "", true, true))
	return taken


func _debug_dump(req: Dictionary) -> void:
	AGREE.step_log = []
	AGREE.trace = {}
	var b: CWBridge = heur if debug_tier == "normal" else (intent if debug_tier == "intent" else search)
	var idx: int = await b.ask(req)
	var f := FileAccess.open(debug_out, FileAccess.WRITE)
	for e in AGREE.step_log:
		f.store_line(JSON.stringify(e))
	f.close()
	print("AGREE-DEBUG: 第 %d 问 %s 档试走 %d 步 → %s，写入 %s" % [n, debug_tier, AGREE.step_log.size(),
		CWSemKey.key(req, req["options"][idx]["data"]), debug_out])
	AGREE.step_log = null
	AGREE.trace = {}


## 选项按引擎原序：{k: 语义键, d: GD 形状的 data（含 cost —— 键里剔掉的那些，C# 适配层要逐字段对上）}
func _opts(req: Dictionary) -> Array:
	var rows: Array = []
	for o in req["options"]:
		rows.append({ "k": CWSemKey.key(req, o["data"]), "d": plain(o["data"]) })
	return rows


static func plain(v: Variant) -> Variant:
	if v is Vector2i:
		return "%d,%d" % [v.x, v.y]
	if v is Dictionary:
		var d := {}
		for k in v:
			if str(k) == "state_hash":
				continue
			d[str(k)] = plain(v[k])
		return d
	if v is Array:
		var a: Array = []
		for x in v:
			a.append(plain(x))
		return a
	if v is float and (is_inf(v) or is_nan(v)):
		return str(v)
	return v


static func _trace(t: Dictionary) -> Dictionary:
	return plain(t)


## cw_world_loader.gd 的 `_dump_events` 把条目的 data 原样抄出：【TNF-α局部炎症】的冻结名单是 `{Vector2i: true}`，
## JSON 化之后成了 `"(0, 1)": true` —— C# 的 WorldEffects 认的是 `"q,r": 1`（TileKey）。只在语料这一侧换成 C# 的写法，
## 共用的 loader 不动（它装回 GD 时要的是 Vector2i 键；那一处 dump / load 不对称是另一件事，见开发日志 10-01）
static func _normalize_events(w: Dictionary) -> void:
	if not w.has("events"):
		return
	for e in w["events"].get("active", []):
		var data: Dictionary = e.get("data", {})
		var out := {}
		for k in data:
			var key: String = "%d,%d" % [k.x, k.y] if k is Vector2i else str(k)
			var v: Variant = data[k]
			out[key] = (1 if v else 0) if v is bool else v
		e["data"] = out
