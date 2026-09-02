## bench_mc.gd —— MC 的可复现工作量/耗时基准（不进断言套件）
##
## 固定种子覆盖早/中/晚三个行动局面；每个局面都会比较旧式无限预算（0）与
## 真人档固定预算。耗时仅供本机性能记录，选择和统计才是跨机器可比的产物。
##   <godot> --headless --path game --script res://tests/bench_mc.gd
extends SceneTree

const UI_SIM_STEP_BUDGET := 192
const STAGES := [
	{ "name": "早", "seed": 99, "advance": 0 },
	{ "name": "中", "seed": 99, "advance": 48 },
	{ "name": "晚", "seed": 99, "advance": 96 },
]


func _initialize() -> void:
	await _run()


func _run() -> void:
	print("MC %s：旧预算=0（无限），真人档=%d 模拟 step/决策" % [
		CWHeuristicBridge.AI_VERSION, UI_SIM_STEP_BUDGET])
	for stage: Dictionary in STAGES:
		var old := await _measure(stage, 0)
		var capped := await _measure(stage, UI_SIM_STEP_BUDGET)
		_print_pair(stage["name"], old, capped)
	for n in [2, 4, 6]:
		await _shallow_smoke(n)
	quit(0)


func _measure(stage: Dictionary, budget: int) -> Dictionary:
	var g := _game(2, int(stage["seed"]))
	await _advance_decisions(g, int(stage["advance"]))
	var pid := _immune_pid(g)
	var mc := CWMonteCarloBridge.new()
	mc.game = g
	mc.max_sim_steps = budget
	g.bridges[pid] = mc
	var req := await _to_action(g, pid)
	if req.is_empty():
		g.dispose()
		return { "missing": true }
	var t0 := Time.get_ticks_usec()
	var pick: int = await mc.ask(req)
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
	var out := mc.last_stats
	out["pick"] = pick
	out["choice"] = req["options"][pick]["label"]
	out["elapsed_ms"] = elapsed
	g.dispose()
	return out


func _print_pair(stage: String, old: Dictionary, capped: Dictionary) -> void:
	if old.get("missing", false) or capped.get("missing", false):
		print("%s局面：在目标行动前已结束，跳过" % stage)
		return
	print("%s局面 | 旧: 候选%d 快照%d 模拟%d %.1fms 选[%d] %s | 新: 候选%d 快照%d 模拟%d %.1fms 选[%d] %s | 选择%s" % [
		stage, old["candidates"], old["snapshots"], old["sim_steps"], old["elapsed_ms"], old["pick"], old["choice"],
		capped["candidates"], capped["snapshots"], capped["sim_steps"], capped["elapsed_ms"], capped["pick"], capped["choice"],
		"相同" if old["pick"] == capped["pick"] else "不同"])


func _shallow_smoke(n: int) -> void:
	var g := _game(n, 8000 + n)
	for pid in g.order:
		var mc := CWMonteCarloBridge.new()
		mc.game = g
		mc.rollouts = 1
		mc.horizon = 2
		mc.max_sim_steps = 24
		g.bridges[pid] = mc
	var t0 := Time.get_ticks_usec()
	var winner: int = await g.run_game()
	var elapsed := (Time.get_ticks_usec() - t0) / 1000000.0
	print("浅层冒烟 %d 人：胜方 %d，%d 世界回合，%.2fs（r=1 h=2 budget=24）" % [
		n, winner, g.round_no, elapsed])
	g.dispose()


func _game(n: int, seed_value: int) -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[n], seed_value)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	return g


func _immune_pid(g: CWGame) -> int:
	for pid in g.order:
		if g.player(pid)["faction"] == CWData.Faction.IMMUNE:
			return pid
	return -1


func _advance_decisions(g: CWGame, count: int) -> void:
	for i in count:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			return
		await g.step(await g.ask(req["pid"], req))


func _to_action(g: CWGame, pid: int) -> Dictionary:
	while true:
		var req: Dictionary = await g.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == pid):
			return req
		await g.step(await g.ask(req["pid"], req))
	return {}
