## xcheck_export.gd —— 录 L1 轨迹：GD 当裁判，C# 当被测
##
##   <godot> --headless --path game --script res://tests/xcheck_export.gd -- \
##       players=4 seed=4242 out=D:/path/trace.jsonl steps=0
##
## 产物是 JSONL：第 1 行 header（开局前的 rng 段 + 初始视图），之后每行一步 = { n, asks, rng, post }。
## post 就是下一步的 pre，所以全量状态只写一份。最后一行 footer。
##
## **视图（view）不是快照**：`CWStateCodec.snapshot()` 是 GD 自己能装回来的全量；这里导的是
## **两边都能算出来的那部分**，字段名用 GD 的词、值用 GD 的枚举 —— C# 侧 `L1View.Of(WorldState)`
## 生成同一形状，然后 `DeepDiff` 逐字段比。**只在这里和 C# 的 L1View 里各写一份**，别再复制第三份。
##
## 有意不进视图的（两边形状不同、或一边根本没有）：
##   · `mods` 只带 {name, uses, until, seq}：GD 的效果元组住在 cw_cost.gd 的 TEMPLATES 表里，不在条目上；
##     C# 的 (target/stage/value/floor/req) 由 L0 的 move_cost 探针另行验证。
##   · GD 没有「挂起态」字段（弃置/突变二选一/连锁/趋化是协程内部状态），它们以**问答的 kind** 出现在 asks 里。
##   · `cancer_win_streak`（GD）与 `CancerAlarmRound`（C#）语义不同，都不导。
extends SceneTree

const Tape := preload("res://tests/xcheck_tape.gd")
const XBridge := preload("res://tests/xcheck_bridge.gd")

const PROTO := 2
## 与 C# `CanonCodec.TuneToCanon` 同一份键（22 个）；两边各自从自己的旋钮对象读
const TUNE_KEYS := [
	"cancer_move_cancerous", "cancer_move_healthy", "sclc_move_healthy", "pseudopod_cost",
	"mucus_move_surcharge", "metastasis_cost", "metastasis_max_per_round", "immune_respawn_delay", "macro_heal_purify", "counter_dmg_on_fail", "attack_max_per_turn", "anaerobic_solid_bonus", "anaerobic_floor",
	"anaerobic_cap", "anaerobic_split", "newborn_protect", "cancer_upkeep_pct", "energy_cap",
	"overload_threshold", "overload_div", "overload_exp", "overload_cap",
]

var players := 4
var seed_value := 4242
var out_path := "user://xcheck.jsonl"
var max_steps := 0
## 观测协议 v1 对拍（批 0 步 10）：每步顺带导一份全知 envelope 到另一个文件（{n, env} 一行一步）。
## 不进 trace 本体：那份是 L1 的夹具，字节不能动；env 文件另存、gzip 后进仓库（game/tests/l1/env_*.jsonl.gz）。
var env_out := ""
## `policy=chemo`：xcheck_bridge 的树突建源偏好（见那边文件头）；录到源消散 + 冷却归零之后再多录 12 步就收尾。
var policy := ""


func _initialize() -> void:
	_args()
	await _run()


func _args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"players": players = int(kv[1])
			"seed": seed_value = int(kv[1])
			"out": out_path = kv[1]
			"steps": max_steps = int(kv[1])
			"env_out": env_out = kv[1]
			"policy": policy = kv[1]


# ============ 视图 ============

static func pos(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]


## 流程位置压成两边都算得出的一个词。GD 的 stage 比 C# 的 Phase 细（S 阶段拆成三段），
## 但在**问答边界**上两边能对上的就是这五档。
static func phase_of(g: CWGame) -> String:
	if g.is_over():
		return "finished"
	match str(g.flow["stage"]):
		"init", "setup_place": return "setup"
		"round_start", "revive_immune", "revive_cancer": return "s"
		"turn": return "turn"
		"e_phase": return "e"
	return str(g.flow["stage"])


static func sorted_strings(a: Array) -> Array:
	var p := PackedStringArray(a)
	p.sort()
	return Array(p)


static func view(g: CWGame) -> Dictionary:
	## ---- 棋盘：按 (q, r) 排序，占位写席位 ----
	var keys: Array = g.tiles.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	var tiles: Array = []
	for c: Vector2i in keys:
		var t: Dictionary = g.tiles[c]
		var occ: Array = g.cells_at(c)
		var store: int = int(t["store"])
		if int(t["special"]) == CWData.Special.MARROW:
			store = int(t["cards"])   ## C# 的 Charge 在骨髓格上装的是卡牌数
		tiles.append({
			"at": pos(c), "tissue": int(t["tissue"]), "special": int(t["special"]),
			"solid": int(t["solid"]), "cell": (int(occ[0]["pid"]) if not occ.is_empty() else -1),
			"necrosis": int(t["necrosis"]), "mucus": bool(t["mucus"]), "newborn": bool(t["newborn"]),
			"ossify_at": int(t["ossify_at"]), "toxin_round": int(t["toxin_round"]),
			"store": store, "prod": int(t["prod"]),
		})
	## ---- 细胞：按席位排序 ----
	var cells: Array = []
	var order: Array = g.cells.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["pid"]) < int(b["pid"]))
	for cell: Dictionary in order:
		var mods: Array = []
		for m: Dictionary in cell["mods"]:
			mods.append({ "name": str(m["name"]), "uses": int(m.get("uses", 0)),
				"until": str(m.get("until", "")), "seq": int(m.get("seq", 0)) })
		mods.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["seq"] < b["seq"] or (a["seq"] == b["seq"] and a["name"] < b["name"]))
		var eq_seq := {}
		for k in cell["equip_seq"]:
			eq_seq[str(k)] = int(cell["equip_seq"][k])
		var fx_turn := {}
		for k in cell["fx_turn"]:
			fx_turn[str(k)] = int(cell["fx_turn"][k])
		cells.append({
			"pid": int(cell["pid"]), "pos": pos(cell["pos"]), "faction": int(cell["faction"]),
			"itype": int(cell["itype"]), "ctype": int(cell["ctype"]),
			"energy": int(cell["energy"]), "alive": bool(cell["alive"]),
			"attacks_used": int(cell["attacks_used"]), "draws_used": int(cell["draws_used"]),
			"toxin_used": int(cell["toxin_used"]), "mutate_used": bool(cell["mutate_used"]),
			"antibody_used": int(cell["antibody_used"]), "metastasis_used": bool(cell["metastasis_used"]),
			"jump_used": int(cell["jump_used"]), "armor_used": bool(cell["armor_used"]),
			"differentiated": bool(cell["differentiated"]), "effector_used": bool(cell["effector_used"]),
			"marked": bool(cell["marked"]), "mark_left": int(cell["mark_left"]), "mark_round": int(cell["mark_round"]),
			"respawn_round": int(cell["respawn_round"]),
			"camp_round": int(cell["camp_round"]),
			"camp_pos": (pos(cell["camp_pos"]) if int(cell["camp_round"]) >= 0 else ""),
			"play_n": int(cell["play_n"]),
			"neutral_until": int(cell.get("neutral_until", -1)), "chemo_cd": int(cell.get("chemo_cd", 0)),
			"chain_left": int(cell.get("chain_left", 0)), "chain_bonus": int(cell.get("chain_bonus", 0)),
			"hand": sorted_strings(cell["hand"]), "equipped": sorted_strings(cell["equipped"]),
			"equip_seq": eq_seq, "fx_turn": fx_turn,
			"fx_round": sorted_strings(cell["fx_round"].keys()),
			"mods": mods,
		})
	## ---- 全局 ----
	var chemo: Dictionary = g.chemo
	var track: Dictionary = g.chemo_track
	var events: Array = []
	for e: Dictionary in g.events["active"]:
		events.append({ "name": str(e["name"]), "left": int(e["left"]), "stacks": int(e.get("stacks", 1)) })
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["name"] < b["name"] or (a["name"] == b["name"] and a["left"] < b["left"]))
	var plist: Array = []
	for pid: int in g.order:
		## `alive` 对的是 C# 的 Player.IsAlive =「这一席还在局里」。开局落子之前 cells 还是空的
		## （header 的 pre 就取在这时候）：没落子 = 还在局里、还没死，所以是 true
		var placed: bool = pid < g.cells.size()
		## ctype 记在席位上而不是细胞上：落子之前细胞还不存在，C# 那边落子时要靠它定癌种
		plist.append({ "pid": pid, "faction": int(g.player(pid)["faction"]),
			"alive": (bool(g.cell_of(pid)["alive"]) if placed else true),
			"ctype": int(g.player(pid).get("cancer_type", -1)) })
	var tune := {}
	for k in TUNE_KEYS:
		var v: Variant = g.tune.get(k)
		tune[k] = (1 if v else 0) if v is bool else int(v)
	return {
		"board": { "radius": int(g.board_radius), "tiles": tiles },
		"cells": cells,
		"g": {
			"round_no": int(g.round_no), "phase": phase_of(g),
			## current_pid 换回合不清零（上一回合最后一席一直挂着）；只在玩家回合里两边才是同一个意思
			"current_pid": (int(g.current_pid) if phase_of(g) == "turn" else -1),
			"memory": int(g.memory), "immune_level": int(g.immune_level),
			"winner": int(g.winner), "effector_round": int(g.effector_round),
			"chemo_at": (pos(chemo["at"]) if chemo.has("at") else ""),
			"chemo_left": int(chemo.get("left", 0)), "chemo_by": int(chemo.get("by", -1)),
			"track_cid": int(track.get("cid", -1)),
			"track_at": (pos(track["at"]) if track.has("at") else ""),
			"track_left": int(track.get("left", 0)),
			"events": events,
		},
		"players": plist,
		"tune": tune,
	}


# ============ 驱动 ============

func _run() -> void:
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写 ", out_path, " err=", FileAccess.get_open_error())
		quit(1)
		return
	var g := CWGame.new()
	var tape: Object = Tape.new()
	g.rng = tape                      ## 靠 cw_game.gd 那行 `var rng: Object`；有护栏测试盯着
	g.tune = CWTuning.new()
	g.init(CWData.FACTION_ORDER[players], seed_value)
	var bridge = XBridge.new()   ## 一个桥装给所有席位：LCG 是一条，两边才同步（不标 CWBridge 类型：要读 policy / goal_done）
	bridge.game = g
	bridge.seed_policy(seed_value)
	bridge.policy = policy
	for pid: int in g.order:
		g.bridges[pid] = bridge

	var first: Dictionary = await g.pending()
	f.store_line(JSON.stringify({
		"t": "header", "proto": PROTO, "players": players, "seed": seed_value,
		"ruleset": "gd-main", "policy": "lcg-sorted-uniq-key" + ("" if policy == "" else "+" + policy),
		"boot_rng": tape.take(),      ## init + setup.begin() 消耗的那一段
		"pre": view(g),
	}))

	var envf: FileAccess = null
	if env_out != "":
		envf = FileAccess.open(env_out, FileAccess.WRITE)
	var n := 0
	var kinds := {}
	var goal_n := 0   ## policy=chemo：源消散 + 冷却归零那一步；再录 12 步收尾
	while not first.is_empty():
		var req: Dictionary = first
		var idx: int = await g.ask(int(req["pid"]), req)   ## 顶层那一问也走桥：它就被录进 log 了
		var ask_rng: Array = tape.take()                   ## 问本身不该掷骰；真掷了就原样记下来，别吞
		await g.step(idx)
		n += 1
		var asks: Array = bridge.take()
		for a in asks:
			kinds[a["kind"]] = int(kinds.get(a["kind"], 0)) + 1
		var line := { "t": "step", "n": n, "asks": asks, "rng": tape.take(), "post": view(g) }
		if not ask_rng.is_empty():
			line["ask_rng"] = ask_rng
		f.store_line(JSON.stringify(line))
		if envf != null:   ## post 时刻 _pending 已经是下一问（step 末尾 advance 到了决策点）
			envf.store_line(JSON.stringify({ "n": n, "env": CWObsCodec.encode(g, { "viewer": CWObsProto.VIEWER_OMNISCIENT, "ask": g._pending, "ask_id": n, "rev": n }) }))
		if max_steps > 0 and n >= max_steps:
			break
		if g.is_over():
			break
		if bridge.goal_done and goal_n == 0:
			goal_n = n
		if goal_n > 0 and n >= goal_n + 12:
			break
		first = await g.pending()

	f.store_line(JSON.stringify({
		"t": "footer", "steps": n, "rounds": int(g.round_no),
		"winner": int(g.winner), "draws": tape.tape.size(),
		"kinds": kinds, "state_hash": g.state_hash(),
	}))
	f.close()
	if envf != null:
		envf.close()
	print("轨迹写入 %s：%d 步，%d 次抽取，%d 世界回合，胜方 %d" % [
		out_path, n, tape.tape.size(), g.round_no, g.winner])
	print("询问分布 ", kinds)
	print("L1-EXPORT: OK %d" % n)
	g.dispose()
	quit(0)
