## bench_mech.gd —— 服务器专家档（意图级 MechBridge）的单问耗时基准（不进断言套件）
##
## 服务器的 AI 在主线程**同步**跑（CWNetBridge 没起线程），一问的耗时 = 全服所有房间一起卡的时长，
## 所以要看的是整局里的**最大值**而不是均值。三个整局把每一席都换成 MechBridge、逐问计时；
## 最后一段拿同一批局面对比原来的专家档（扁平 MC rollouts=2 · horizon=40，同步路径 = 服务器原配置）。
##   <godot> --headless --path game --script res://tests/bench_mech.gd
extends SceneTree

const GAMES := [
	{ "n": 4, "seed": 99 },
	{ "n": 4, "seed": 7 },
	{ "n": 6, "seed": 99 },
]
const MAX_DECISIONS := 8000
## 与旧专家档对比的三个局面：从开局往后走多少个决策（陪练全是启发式）
const STAGES := [
	{ "name": "早", "advance": 0 },
	{ "name": "中", "advance": 60 },
	{ "name": "晚", "advance": 150 },
]


func _initialize() -> void:
	await _run()


func _run() -> void:
	print("MechBridge 单问耗时基准 | %s × %d 线程" % [OS.get_processor_name(), OS.get_processor_count()])
	for spec: Dictionary in GAMES:
		await _whole_game(int(spec["n"]), int(spec["seed"]))
	await _versus_mc(4, 99)
	quit(0)


## 整局：每一席都是 MechBridge，逐个 action 问计时
func _whole_game(n: int, seed_value: int) -> void:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[n], seed_value)
	for pid in g.order:
		var b := MechBridge.new()
		b.game = g
		b.delay_ms = 0
		g.bridges[pid] = b
	var times: Array = []
	var worst := { "ms": 0.0, "round": 0, "cands": 0, "pid": -1 }
	var t_all := Time.get_ticks_usec()
	for i in MAX_DECISIONS:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		var t0 := Time.get_ticks_usec()
		var idx: int = await g.ask(req["pid"], req)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		if req["kind"] == "action":
			times.append(ms)
			if ms > float(worst["ms"]):
				worst = { "ms": ms, "round": g.round_no, "cands": req["options"].size(), "pid": req["pid"] }
		await g.step(idx)
	var wall := (Time.get_ticks_usec() - t_all) / 1000000.0
	times.sort()
	var sum := 0.0
	for t in times:
		sum += float(t)
	var cnt := times.size()
	print("%d 人局 seed %d：%d 世界回合、行动问 %d 次、整局 %.1f s | 均值 %.0f ms · 中位 %.0f · p95 %.0f · 最大 %.0f ms（第 %d 回合、候选 %d、pid %d）；超过 200 ms 的问 %d 次" % [
		n, seed_value, g.round_no, cnt, wall,
		sum / maxf(cnt, 1), _pct(times, 0.5), _pct(times, 0.95), float(worst["ms"]),
		worst["round"], worst["cands"], worst["pid"], _over(times, 200.0)])
	g.dispose()


func _pct(sorted: Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	return float(sorted[clampi(int(floor(p * (sorted.size() - 1))), 0, sorted.size() - 1)])


func _over(times: Array, ms: float) -> int:
	var k := 0
	for t in times:
		if float(t) > ms:
			k += 1
	return k


## 同一局面：意图级 vs 旧专家档（扁平 MC，服务器原配置、同步路径）
func _versus_mc(n: int, seed_value: int) -> void:
	for stage: Dictionary in STAGES:
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[n], seed_value)
		for pid in g.order:
			var b := CWHeuristicBridge.new()
			b.game = g
			b.delay_ms = 0
			g.bridges[pid] = b
		for i in int(stage["advance"]):
			var req0: Dictionary = await g.pending()
			if req0.is_empty():
				break
			await g.step(await g.ask(req0["pid"], req0))
		var cp := -1
		for pid in g.order:
			if int(g.player(pid)["faction"]) == CWData.Faction.CANCER:
				cp = pid
				break
		var req := await _to_action(g, cp)
		if req.is_empty():
			print("%s局面：在癌方行动前已结束，跳过" % stage["name"])
			g.dispose()
			continue
		var mb := MechBridge.new()
		mb.game = g
		mb.delay_ms = 0
		var t0 := Time.get_ticks_usec()
		var pick_m: int = await mb.ask(req)
		var ms_m := (Time.get_ticks_usec() - t0) / 1000.0
		var mc := CWMonteCarloBridge.new()
		mc.game = g
		mc.delay_ms = 0
		mc.rollouts = 2
		mc.horizon = 40
		mc.use_threading = false
		t0 = Time.get_ticks_usec()
		var pick_c: int = await mc.ask(req)
		var ms_c := (Time.get_ticks_usec() - t0) / 1000.0
		print("%s局面（第 %d 回合、候选 %d）：意图级 %.0f ms 选[%d] %s | 旧专家档 MC %.0f ms 选[%d] %s" % [
			stage["name"], g.round_no, req["options"].size(),
			ms_m, pick_m, req["options"][pick_m]["label"],
			ms_c, pick_c, req["options"][pick_c]["label"]])
		g.dispose()


func _to_action(g: CWGame, pid: int) -> Dictionary:
	while true:
		var req: Dictionary = await g.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == pid):
			return req
		await g.step(await g.ask(req["pid"], req))
	return {}
