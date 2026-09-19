## 估值体检 · 数据采集：每回合记录**完整全局杠杆向量** + 终局输赢 → JSONL。
## 设计：只记**原始杠杆**（pid 无关的位置量），不记任何固定标量公式 ——
## 离线可测任意标量化（现行固定权重 / 分相位权重 / 加阈值项），不必重跑对局。
## 运行：-- games=N players=4 seed= immune_ai=heu|mech cancer_ai=heu|mech out=<文件名>
extends SceneTree

var _lines: Array = []

func _initialize() -> void:
	await _run()
	quit(0)


## 位置级（pid 无关）杠杆向量：标量化只该用这些，actor 局部量属于"这步棋"不属于"这个局面"。
func _lever_vec(g: CWGame) -> Dictionary:
	var ct: int = g.count_tissue(CWData.Tissue.CANCER)
	var st: int = g.count_tissue(CWData.Tissue.SOLID)
	var ce := 0
	var ie := 0
	for c in g.living_cells(CWData.Faction.CANCER): ce += int(c["energy"])
	for c in g.living_cells(CWData.Faction.IMMUNE): ie += int(c["energy"])
	var ia: int = g.living_cells(CWData.Faction.IMMUNE).size()
	var ca: int = g.living_cells(CWData.Faction.CANCER).size()
	var hm := 0
	var cm := 0
	for m in CWData.MARROWS:
		var t: int = int(g.tiles[m]["tissue"])
		if t == CWData.Tissue.HEALTHY: hm += 1
		elif t == CWData.Tissue.CANCER or t == CWData.Tissue.SOLID: cm += 1
	var pt := 0
	var lc := 0
	var mie := 0
	var first := true
	for im in g.living_cells(CWData.Faction.IMMUNE):
		pt += g.world.pressure_at(im["pos"])
		if g.world.pressure_lethal(im): lc += 1
		var e: int = int(im["energy"])
		if first or e < mie: mie = e; first = false
	return {
		"round": g.round_no, "phase": CWCardData.cancer_phase(g.round_no),
		"level": g.immune_level, "mem": g.memory,
		"wp": ct + 2 * st, "ct": ct, "st": st, "supply": MechValue.total_supply(g),
		"ce": ce, "ie": ie, "ia": ia, "ca": ca,
		"hm": hm, "cm": cm, "pt": pt, "lc": lc, "mie": mie,
	}


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2: args[kv[0]] = kv[1]
	var games_n: int = int(args.get("games", 10))
	var players: int = int(args.get("players", 4))
	var seed_base: int = int(args.get("seed", 70000))
	var imm_ai: String = args.get("immune_ai", "heu")
	var can_ai: String = args.get("cancer_ai", "heu")
	var out_name: String = args.get("out", "eval_health.jsonl")
	var cfg: String = "%s/%s/%dp" % [imm_ai, can_ai, players]
	for gi in games_n:
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[players], seed_base + gi)
		g.sim_quiet = true
		for pid in g.order:
			var fac: int = g.player(pid)["faction"]
			var which: String = can_ai if fac == CWData.Faction.CANCER else imm_ai
			var b: CWHeuristicBridge = MechBridge.new() if which == "mech" else CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		var last_round := -1
		while true:
			var req: Dictionary = await g.pending()
			if req.is_empty(): break
			if g.round_no != last_round:
				last_round = g.round_no
				var v := _lever_vec(g)
				v["cfg"] = cfg
				v["gid"] = gi
				_lines.append(JSON.stringify(v))
			var idx: int = await g.ask(req["pid"], req)
			await g.step(idx)
		_lines.append(JSON.stringify({
			"cfg": cfg, "gid": gi, "outcome": true,
			"winner": g.winner, "win_kind": String(g.win_kind), "rounds": g.round_no,
		}))
		g.dispose()
	var path := "user://" + out_name
	var f := FileAccess.open(path, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()
	print("WROTE %s  (%d 行, %d 局)" % [ProjectSettings.globalize_path(path), _lines.size(), games_n])