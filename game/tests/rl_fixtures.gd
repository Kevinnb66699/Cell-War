## 环境验证的稀有决策局面。每例使用独立的四人 CWGame 与调用方安装的桥。
## 只装配局面；候选和追加询问始终由生产规则产生，不手写 req。
## 配合完整对局中的 action 覆盖全部 10 种 kind；pick 覆盖弃牌、骰面、能量方向与数额，
## effector_target 覆盖细胞与方向，全身免疫动员覆盖非当前席的追加决策。
extends RefCounted


static func cases() -> Array[String]:
	return ["setup", "revivals", "recruit", "infiltration", "storms", "mobilize",
		"genome", "chemotaxis", "couple", "remodel", "hand_limit", "chemo",
		"hunt", "excalibur", "chain"]


static func run_case(name: String, game: CWGame) -> void:
	if name == "setup":
		game.stop_at = "round_start"
		for _seat in game.order:
			await _answer_pending(game, "setup_place")
		return
	_prepare(game)
	var immune: Array = game.living_cells(CWData.Faction.IMMUNE)
	var cancer: Array = game.living_cells(CWData.Faction.CANCER)
	var cell: Dictionary = immune[0]
	match name:
		"revivals":
			CWTissue.to_solid(game.tile(Vector2i(2, 0)))
			game.tile(Vector2i(2, 0))["solid"] = game.tune.solidify_threshold
			game.kill(cell)
			game.kill(cancer[0])
			game.round_no = int(cell["respawn_round"])
			game.flow = { "stage": "revive_immune", "i": 0, "acts": 0 }
			game.current_pid = -1
			await _answer_pending(game, "immune_revive")
			await _answer_pending(game, "revive")
		"recruit":
			await game.card_fx.resolve_event(cell, "趋化募集")
		"infiltration":
			CWTissue.to_cancer(game.tile(Vector2i(1, 0)), false)
			await game.card_fx.resolve_event(cell, "效应细胞浸润")
		"storms":
			await game.card_fx.resolve_event(cell, "炎症风暴")
			await game.card_fx.resolve_event(cell, "免疫风暴")
		"mobilize":
			## 抽牌者是当前行动席，但第二个免疫细胞必须由自己的桥回答。
			await game.card_fx.resolve_event(cell, "全身免疫动员")
		"genome":
			game.current_pid = int(cancer[0]["pid"])
			game.flow["i"] = game.order.find(game.current_pid)
			_seek_mutation_rolls(game)
			await game.card_fx.resolve_event(cancer[0], "基因组不稳定")
		"chemotaxis":
			await _play_first(game, cell, "炎症性趋化")
		"couple":
			await _play_first(game, cell, "代谢耦联")
		"remodel":
			for at: Vector2i in [Vector2i(1, 0), Vector2i(0, 2)]:
				CWTissue.to_solid(game.tile(at))
				game.tile(at)["solid"] = game.tune.solidify_threshold
			CWTissue.to_cancer(game.tile(Vector2i(2, 0)), false)
			await _play_first(game, cell, "基质重塑")
		"hand_limit":
			## 模拟一次抽牌后、弃牌检查前的边界，不把事件卡塞进手牌。
			for card: String in CWCardData.CARDS:
				var info: Dictionary = CWCardData.CARDS[card]
				if info["kind"] != CWCardData.Kind.EVENT and info["immune"].max() > 0:
					cell["hand"].append(card)
				if cell["hand"].size() == CWData.HAND_MAX + 1:
					break
			await game.cards.discard_to_limit(cell)
		"chemo":
			_differentiate(game, cell, CWData.ImmuneType.DENDRITIC)
			await _execute_first(game, cell, "chemo")
		"hunt":
			_differentiate(game, cell, CWData.ImmuneType.DENDRITIC)
			await _execute_first(game, cell, "effector")
		"excalibur":
			_differentiate(game, cell, CWData.ImmuneType.T_CELL)
			await _execute_first(game, cell, "effector")
		"chain":
			_differentiate(game, cell, CWData.ImmuneType.MACRO)
			for at: Vector2i in [Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, -1)]:
				CWTissue.to_cancer(game.tile(at), false)
			await _execute_first(game, cell, "effector")
			for option: Dictionary in game.actions.build_options(cell):
				var data: Dictionary = option["data"]
				if data.get("act") == "move" and data.get("to") == Vector2i(1, 0):
					await game.actions.execute(cell, data)
					return
			assert(false, "连续吞噬 fixture 没有进入癌组织的合法迁移")
		_:
			assert(false, "未知 RL fixture: " + name)


static func _prepare(game: CWGame) -> void:
	game.setup.begin()
	for pid: int in game.order:
		game.setup.place(pid, game.setup.place_options(pid)[0]["data"]["to"])
	game.setup.finish()
	for at: Vector2i in game.tiles:
		CWTissue.to_healthy(game.tile(at))
	var immune_positions: Array[Vector2i] = [Vector2i.ZERO, Vector2i(0, 3)]
	var cancer_positions: Array[Vector2i] = [Vector2i(4, 0), Vector2i(4, 1)]
	var immune_i := 0
	var cancer_i := 0
	for cell: Dictionary in game.cells:
		cell["energy"] = 60
		if cell["faction"] == CWData.Faction.IMMUNE:
			cell["pos"] = immune_positions[immune_i]
			immune_i += 1
		else:
			cell["pos"] = cancer_positions[cancer_i]
			CWTissue.to_cancer(game.tile(cell["pos"]), false)
			cancer_i += 1
	game.current_pid = int(game.living_cells(CWData.Faction.IMMUNE)[0]["pid"])
	game.flow = { "stage": "turn", "i": game.order.find(game.current_pid), "acts": 0 }
	game.phase = "玩家回合"
	game.update_marks()


static func _answer_pending(game: CWGame, kind: String) -> void:
	var req: Dictionary = await game.pending()
	assert(req.get("kind") == kind, "fixture 预期 " + kind + "，实际 " + str(req))
	var choice: int = await game.ask(int(req["pid"]), req)
	await game.step(choice)


static func _play_first(game: CWGame, cell: Dictionary, card: String) -> void:
	cell["hand"] = [card]
	for option: Dictionary in game.actions.build_options(cell):
		var data: Dictionary = option["data"]
		if data.get("act") == "play" and data.get("card") == card:
			await game.actions.execute(cell, data)
			return
	assert(false, "fixture 没有合法出牌选项: " + card)


static func _execute_first(game: CWGame, cell: Dictionary, act: String) -> void:
	for option: Dictionary in game.actions.build_options(cell):
		var data: Dictionary = option["data"]
		if data.get("act") == act:
			await game.actions.execute(cell, data)
			return
	assert(false, "fixture 没有合法行动选项: " + act)


static func _differentiate(game: CWGame, cell: Dictionary, kind: int) -> void:
	cell["itype"] = kind
	cell["differentiated"] = true
	game.differentiated.append(kind)
	game.immune_level = 3
	game.memory = 100


static func _seek_mutation_rolls(game: CWGame) -> void:
	## 只定位合法 RNG 状态；仍让生产 roll_shown 真正掷骰。选 1/3 避免额外抽牌。
	for _attempt in 10000:
		var state: int = game.rng.state
		var first: int = game.rng.randi_range(1, 3)
		var second: int = game.rng.randi_range(1, 3)
		if first == 1 and second == 3:
			game.rng.state = state
			return
	assert(false, "fixture 未找到基因组不稳定所需骰序列")
