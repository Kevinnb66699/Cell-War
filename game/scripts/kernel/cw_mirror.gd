## cw_mirror.gd —— 观测协议 v1 envelope 的 GD 解码结果（口径二 · 批 0 步 8；规格 A-2）
##
## 不是「CWGame 剥成只有状态的壳」：flow / pending / rng 是引擎私货，C# 天然产不出。它只做三件事：
##   1. 装载一份 envelope（一次一份、绝不合并 —— 传送溶解演出靠 UI 自己差分，压掉中间态就静默失效）；
##   2. 按 UI 今天的形状把字段摆好（cells 稠密数组下标即 id 含死者；tiles 是 Dictionary[Vector2i]；pos / camp_pos 是 Vector2i）；
##   3. 提供与 CWGame **同名同签名**的查询（批 1 的切换是 `game.` → `mirror.` 的机械改动）。
## 装载时**未知键 = 硬错、tier A 缺键 = 硬错**（键表 cw_obs_proto.gd）；tier B 缺席合法，读它的查询各有兜底。
## `sync_from(game)` 每次都重新装一份、不做别名（cw_state_codec.restore 每步都换新对象，别名会静默悬空）。
class_name CWMirror
extends RefCounted

var envelope := {}
var viewer := CWObsProto.VIEWER_OMNISCIENT
var produced_tiers: Array = []
var board_radius := CWData.BOARD_RADIUS
var tiles := {}          ## Vector2i → 格字典（协议 14 键；at 也留着，是 Vector2i）
var cells: Array = []    ## 稠密，下标即 id，含死者
var g := {}
var ask := {}            ## {} = 现在没有人被问
var logs := {}
## 与 CWGame 同名的顶层量
var round_no := 1
var phase := ""          ## 机器词 setup / s / turn / e / finished；中文串在 g.d.phase_text
var current_pid := -1
var asking_pid := -1
var memory := 0
var immune_level := 0
var effector_round := -1
var differentiated: Array = []
var winner := -1
var win_reason := ""
var win_kind := ""
var players: Array = []
var order: Array = []
var events := {}
var chemo := {}
var chemo_track := {}
var feed_log: Array = []
var feed_seq := 0
var aborted := false
var tune := {}


## 装载（名字不叫 load：那是 GDScript 的全局函数）。返回 "" = 成功；否则一句错误（协议外的键 / 缺键 / p 不对 / 出现小数 / cells 不稠密）
func load_from(raw: Dictionary) -> String:
	var e: Dictionary = _normalize(raw)
	var err := _validate(e)
	if err != "":
		return err
	envelope = e
	viewer = int(e["viewer"])
	produced_tiers = Array(e["produced_tiers"])
	var st: Dictionary = e["state"]
	board_radius = int(st["board"]["radius"])
	tiles = {}
	for t: Dictionary in st["board"]["tiles"]:
		tiles[t["at"]] = t
	cells = []
	for c: Dictionary in st["cells"]:
		if c["camp_pos"] == null:
			c["camp_pos"] = Vector2i.ZERO   ## make_cell 的形状：没在蹲 = ZERO
		cells.append(c)
	g = st["g"]
	round_no = int(g["round_no"])
	phase = str(g["phase"])
	current_pid = int(g["current_pid"])
	asking_pid = int(g["asking_pid"])
	memory = int(g["memory"])
	immune_level = int(g["immune_level"])
	effector_round = int(g["effector_round"])
	differentiated = Array(g["differentiated"])
	winner = int(g["winner"])
	win_reason = str(g["win_reason"])
	win_kind = str(g["win_kind"])
	players = Array(g["players"])
	order = Array(g["order"])
	events = g["events"]
	chemo = g["chemo"] if g["chemo"] != null else {}
	chemo_track = g["chemo_track"] if g["chemo_track"] != null else {}
	feed_log = Array(g["feed_log"])
	feed_seq = int(g["feed_seq"])
	aborted = bool(g["aborted"])
	tune = g["tune"]
	ask = e["ask"] if e["ask"] != null else {}
	logs = e["logs"]
	return ""


## InProc 用：现编一份再装（每次全量重绑）
func sync_from(game: CWGame, ctx: Dictionary = {}) -> String:
	return load_from(CWObsCodec.encode(game, ctx))


# ---- 与 CWGame 同名同签名的查询（规格 A-2.4）----
func cell_of(pid: int) -> Dictionary:
	return cells[int(players[pid]["cell_id"])]


func player(pid: int) -> Dictionary:
	return players[pid]


func tile(c: Vector2i) -> Dictionary:
	return tiles[c]


func cells_at(at: Vector2i, faction: int = -1) -> Array:
	var out: Array = []
	for c: Dictionary in cells:
		if bool(c["alive"]) and c["pos"] == at and (faction < 0 or int(c["faction"]) == faction):
			out.append(c)
	return out


func living_cells(faction: int = -1) -> Array:
	var out: Array = []
	for c: Dictionary in cells:
		if bool(c["alive"]) and (faction < 0 or int(c["faction"]) == faction):
			out.append(c)
	return out


func is_cancerous(c: Vector2i) -> bool:
	return int(tiles[c]["tissue"]) != CWData.Tissue.HEALTHY


func is_over() -> bool:
	return bool(g["is_over"])


func chemo_track_at() -> Vector2i:
	return chemo_track["at"] if not chemo_track.is_empty() else Vector2i.MAX


## 下面这些读 d（值由内核算好、镜像只转手）；tier B 缺席时按状态兜底
func count_tissue(t: int) -> int:
	var key: String = { CWData.Tissue.HEALTHY: "count_healthy", CWData.Tissue.CANCER: "count_cancer", CWData.Tissue.SOLID: "count_solid" }.get(t, "")
	if g["d"].has(key):
		return int(g["d"][key])
	var n := 0
	for tl: Dictionary in tiles.values():
		if int(tl["tissue"]) == t:
			n += 1
	return n


func count_necrosis() -> int:
	if g["d"].has("count_necrosis"):
		return int(g["d"]["count_necrosis"])
	var n := 0
	for tl: Dictionary in tiles.values():
		if int(tl["necrosis"]) > 0:
			n += 1
	return n


func solidify_threshold() -> int:
	return int(g["d"]["solid_threshold"])


## 0 基（I/II/III = 0/1/2），与 CWGame.tumor_stage 同义；协议的 d.tumor_stage 是 1 基的显示值
func tumor_stage() -> int:
	return int(g["d"]["cancer_phase"])


func neutralized(cell: Dictionary) -> bool:
	if cell["d"].has("neutralized"):
		return bool(cell["d"]["neutralized"])
	return round_no <= int(cell["neutral_until"])


func type_ability_on(cell: Dictionary) -> bool:
	if cell["d"].has("type_ability_on"):
		return bool(cell["d"]["type_ability_on"])
	return not neutralized(cell)


func cancer_weighted() -> int:
	if g["d"].has("cancer_weighted"):
		return int(g["d"]["cancer_weighted"])
	return count_tissue(CWData.Tissue.CANCER) + 2 * count_tissue(CWData.Tissue.SOLID)


func pressure_at(c: Vector2i) -> int:
	return int(tiles[c]["d"]["pressure"])


func income_of(cell: Dictionary) -> int:
	return int(cell["d"]["income"])


func action_kinds_of(cell: Dictionary) -> Array:
	return Array(cell["d"].get("action_kinds", []))


func status_rows_of(cell: Dictionary) -> Array:
	return Array(cell["d"].get("status_rows", []))


# ---- 装载细节 ----
## JSON.parse 出来的数字全是 float：整数化；{q, r} 两键字典 → Vector2i；其余递归
static func _normalize(v: Variant) -> Variant:
	if v is float:
		return int(v) if v == floor(v) else v
	if v is Dictionary:
		if v.size() == 2 and v.has("q") and v.has("r") and (v["q"] is int or v["q"] is float) and (v["r"] is int or v["r"] is float):
			return Vector2i(int(v["q"]), int(v["r"]))
		var out := {}
		for k in v:
			out[k] = _normalize(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for x in v:
			arr.append(_normalize(x))
		return arr
	return v


static func _validate(e: Dictionary) -> String:
	var err := CWObsProto.check(e, CWObsProto.ENVELOPE, [], "envelope")
	if err != "":
		return err
	if int(e["p"]) != CWObsProto.P:
		return "协议版本不对：p=%s，本机只认 %d" % [str(e["p"]), CWObsProto.P]
	err = _no_float(e, "envelope")
	if err != "":
		return err
	err = CWObsProto.check(e["ruleset"], CWObsProto.RULESET, [], "ruleset")
	if err != "":
		return err
	var st: Dictionary = e["state"]
	err = CWObsProto.check(st, CWObsProto.STATE, [], "state")
	if err != "":
		return err
	err = CWObsProto.check(st["board"], CWObsProto.BOARD, [], "state.board")
	if err != "":
		return err
	for t: Dictionary in st["board"]["tiles"]:
		err = CWObsProto.check(t, CWObsProto.TILE, [], "tile %s" % str(t.get("at", "?")))
		if err == "":
			err = CWObsProto.check(t["d"], CWObsProto.TILE_D_A, CWObsProto.TILE_D_B, "tile %s .d" % str(t["at"]))
		if err != "":
			return err
	var i := 0
	for c: Dictionary in st["cells"]:
		err = CWObsProto.check(c, CWObsProto.CELL, [], "cell #%d" % i)
		if err == "":
			err = CWObsProto.check(c["d"], CWObsProto.CELL_D_A, CWObsProto.CELL_D_B, "cell #%d .d" % i)
		if err == "" and int(c["id"]) != i:
			err = "cells 不是稠密的：第 %d 个的 id 是 %s" % [i, str(c["id"])]
		if err == "":
			for m: Dictionary in c["mods"]:
				err = CWObsProto.check(m, CWObsProto.MOD, [], "cell #%d mods" % i)
				if err != "":
					break
		if err != "":
			return err
		i += 1
	var g: Dictionary = st["g"]
	err = CWObsProto.check(g, CWObsProto.G, [], "state.g")
	if err == "":
		err = CWObsProto.check(g["d"], CWObsProto.G_D_A, CWObsProto.G_D_B, "state.g.d")
	if err == "":
		err = CWObsProto.check(g["cancer_alarm"], CWObsProto.CANCER_ALARM, [], "g.cancer_alarm")
	if err == "" and g["chemo"] != null:
		err = CWObsProto.check(g["chemo"], CWObsProto.CHEMO, [], "g.chemo")
	if err == "" and g["chemo_track"] != null:
		err = CWObsProto.check(g["chemo_track"], CWObsProto.TRACK, [], "g.chemo_track")
	if err == "":
		err = CWObsProto.check(g["events"], CWObsProto.EVENTS, [], "g.events")
	if err == "":
		for ev: Dictionary in g["events"]["active"]:
			err = CWObsProto.check(ev, CWObsProto.EFFECT, [], "g.events.active %s" % str(ev.get("name", "?")))
			if err == "":
				err = CWObsProto.check(ev["d"], CWObsProto.EFFECT_D, [], "g.events.active .d")
			if err != "":
				break
	if err == "":
		for f: Dictionary in g["feed_log"]:
			err = CWObsProto.check(f, CWObsProto.FEED, [], "g.feed_log")
			if err != "":
				break
	if err == "":
		for p: Dictionary in g["players"]:
			err = CWObsProto.check(p, CWObsProto.PLAYER, [], "g.players")
			if err == "":
				err = CWObsProto.check(p["d"], CWObsProto.PLAYER_D, [], "g.players .d")
			if err != "":
				break
	if err == "":
		err = CWObsProto.check(g["tune"], CWObsProto.TUNE, [], "g.tune")
	if err != "":
		return err
	if e["ask"] != null:
		var a: Dictionary = e["ask"]
		err = CWObsProto.check(a, CWObsProto.ASK, [], "ask")
		if err == "":
			for o: Dictionary in a["options"]:
				err = CWObsProto.check(o, CWObsProto.OPTION, [], "ask.options")
				if err == "":
					for r: Dictionary in o["cost_rows"]:
						err = CWObsProto.check(r, CWObsProto.COST_ROW, [], "ask.options cost_rows")
						if err != "":
							break
				if err != "":
					break
		if err != "":
			return err
	return CWObsProto.check(e["logs"], CWObsProto.LOGS, [], "logs")


## 零浮点：_normalize 之后还剩的 float 就是真小数
static func _no_float(v: Variant, path: String) -> String:
	if v is float:
		return "%s 出现小数 %s（协议零浮点）" % [path, str(v)]
	if v is Dictionary:
		for k in v:
			var err := _no_float(v[k], "%s.%s" % [path, str(k)])
			if err != "":
				return err
	elif v is Array:
		for i in v.size():
			var err := _no_float(v[i], "%s[%d]" % [path, i])
			if err != "":
				return err
	return ""
