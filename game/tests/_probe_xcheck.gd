extends SceneTree

class CountBridge extends CWHeuristicBridge:
	var counts := {}
	var total := 0
	var opt_sizes := {}
	func ask(req: Dictionary) -> int:
		var k: String = str(req.get("kind", "?"))
		counts[k] = int(counts.get(k, 0)) + 1
		opt_sizes[k] = int(opt_sizes.get(k, 0)) + int(req["options"].size())
		total += 1
		return await super.ask(req)


func _init() -> void:
	print("=== RNG ===")
	var r := RandomNumberGenerator.new()
	r.seed = 4242
	print("seed=4242 -> state=", r.state)
	var vals := []
	for i in 8:
		vals.append(r.randi_range(0, 9))
	print("randi_range(0,9) x8 = ", vals, "  state_after=", r.state)
	r.state = 0
	r.seed = 4242
	print("re-seed -> state=", r.state)
	var v2 := []
	for i in 8:
		v2.append(r.randi_range(0, 9))
	print("repeat = ", v2)
	var r2 := RandomNumberGenerator.new()
	r2.state = r.state
	print("state-only clone next 4 = ", [r2.randi_range(0,9), r2.randi_range(0,9), r2.randi_range(0,9), r2.randi_range(0,9)])
	print("orig          next 4 = ", [r.randi_range(0,9), r.randi_range(0,9), r.randi_range(0,9), r.randi_range(0,9)])
	var r3 := RandomNumberGenerator.new()
	r3.seed = 1
	print("seed=1 -> state=", r3.state, " first randi_range(1,6) x6 = ",
		[r3.randi_range(1,6), r3.randi_range(1,6), r3.randi_range(1,6), r3.randi_range(1,6), r3.randi_range(1,6), r3.randi_range(1,6)])

	print("=== round / int ===")
	print("round(0.5)=", round(0.5), " round(1.5)=", round(1.5), " round(2.5)=", round(2.5), " round(-0.5)=", round(-0.5))
	print("int(round(2.5))=", int(round(2.5)), " int(round(3.5))=", int(round(3.5)))
	print("pow(10,0.3)=", String.num(pow(10.0, 0.3), 15), " pow(40,0.3)=", String.num(pow(40.0, 0.3), 15), " pow(97,0.3)=", String.num(pow(97.0, 0.3), 15))
	print("pow(3,0.3)=", String.num(pow(3.0, 0.3), 15))

	print("=== tiles key order ===")
	var coords := CWData.all_coords(CWData.BOARD_RADIUS)
	print("all_coords(6).size()=", coords.size())
	print("first 10 = ", coords.slice(0, 10))
	print("last 3  = ", coords.slice(coords.size() - 3, coords.size()))

	print("=== full game ask census ===")
	for np in [2, 4, 6]:
		for sd in [4242, 7]:
			var g := CWGame.new()
			g.init(CWData.FACTION_ORDER[np], sd)
			g.record_replay = true
			var b := CountBridge.new()
			b.game = g
			for pid in g.order:
				g.bridges[pid] = b
			var w: int = await g.run_game()
			print("players=%d seed=%d -> asks=%d rounds=%d winner=%d kinds=%s avg_opts=%s hash=%s" % [
				np, sd, b.total, g.round_no, w, str(b.counts),
				str(_avg(b.opt_sizes, b.counts)), g.state_hash().substr(0, 12)])
			g.dispose()
	quit()


func _avg(sizes: Dictionary, counts: Dictionary) -> Dictionary:
	var out := {}
	for k in sizes:
		out[k] = int(round(float(sizes[k]) / float(counts[k])))
	return out
