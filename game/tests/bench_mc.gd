## bench_mc.gd —— 蒙特卡洛桥的手动基准：一次决策多少毫秒、整局多少秒
##
## 不进测试套件（毫秒数随机器浮动，做断言没有意义）。要看性能手动跑：
##   <godot> --headless --path game --script res://tests/bench_mc.gd
extends SceneTree


func _initialize() -> void:
	await _run()


func _run() -> void:
	## 单次决策：默认参数（人机对战档）
	var g := _game(2, 99)
	var ip := _immune_pid(g)
	var mc := CWMonteCarloBridge.new()
	mc.game = g
	g.bridges[ip] = mc
	var req := await _to_action(g, ip)
	var t0 := Time.get_ticks_usec()
	await mc.ask(req)
	var t1 := Time.get_ticks_usec()
	print("单次决策（%d 个候选，rollouts=%d horizon=%d）：%.1f ms" % [
		req["options"].size(), mc.rollouts, mc.horizon, (t1 - t0) / 1000.0])
	g.dispose()

	## 整局：免疫 = 蒙特卡洛（默认参数），癌症 = 启发式
	g = _game(2, 7)
	ip = _immune_pid(g)
	mc = CWMonteCarloBridge.new()
	mc.game = g
	g.bridges[ip] = mc
	t0 = Time.get_ticks_usec()
	var w: int = await g.run_game()
	t1 = Time.get_ticks_usec()
	print("整局（2 人，免疫走蒙特卡洛）：%.2f s，%d 世界回合，胜方 %d" % [
		(t1 - t0) / 1000000.0, g.round_no, w])
	g.dispose()
	quit(0)


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


## 推进到 pid 的第一个行动询问（沿途别人的决策由各自的桥作答）
func _to_action(g: CWGame, pid: int) -> Dictionary:
	while true:
		var req: Dictionary = await g.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == pid):
			return req
		await g.step(await g.ask(req["pid"], req))
	return {}
