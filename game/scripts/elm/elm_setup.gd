## elm_setup.gd —— SetupUpdater（迁移 cw_setup）：纯函数，父 update 的处理环节。
##
## 对应拍板 3：子 Updater 是父 update 处理环节的一部分（签名 (state,...) -> void，
## 改传入的副本）。由 elm_game._advance / _apply_decision 调用，不被外壳单独驱动。
## 逐行复刻 cw_setup.gd 的行为（含 make_cell 全字段，保证逐格对比等价）。
class_name ElmSetup
extends RefCounted


# ---- 建棋盘 ----
static func build_board(s: Dictionary, _effects: Array) -> void:
	for c in CWData.all_coords():
		s["tiles"][c] = make_tile(c)


static func make_tile(c: Vector2i) -> Dictionary:
	return {
		"tissue": CWData.Tissue.HEALTHY,
		"special": CWData.special_of(c),
		"solid": 0,      # 固化计数（总数）
		"sticky": 0,     # 固着点，永不自然衰减
		"newborn": false,
		"store": 0,      # 代谢核心存储
		"cards": 0,      # 骨髓存储卡牌数
		"prod": 0,       # 特殊组织产出周期计数器
	}


## 逐字段复刻 cw_setup.make_cell —— 缺一个字段，迁移对比就会误报不等
static func make_cell(id: int, pid: int, faction: int, pos: Vector2i,
		itype: int, ctype: int, energy: int = CWData.INIT_ENERGY) -> Dictionary:
	return {
		"id": id, "pid": pid, "faction": faction, "pos": pos,
		"itype": itype, "ctype": ctype, "energy": energy,
		"alive": true, "marked": false, "hand": 0, "differentiated": false,
		"escape_used": false, "invasive_used": 0, "remodel_used": false,
		"mutate_used": false, "unstable_used": false, "antibody_used": 0,
		"respawn_round": -1,
	}


# ---- 初始癌组织（BFS 自中央格向外铺，跳过特殊组织）----
static func place_initial_cancer(s: Dictionary, effects: Array) -> void:
	var target: int = s["tune"].init_cancer_tiles
	var chosen: Array[Vector2i] = [Vector2i.ZERO]
	var frontier: Array[Vector2i] = [Vector2i.ZERO]
	var seen := { Vector2i.ZERO: true }
	while chosen.size() < target and not frontier.is_empty():
		var cur: Vector2i = frontier.pop_front()
		for n in CWData.neighbors(cur):
			if chosen.size() >= target:
				break
			if seen.has(n):
				continue
			seen[n] = true
			if CWData.special_of(n) != CWData.Special.NONE:
				continue
			chosen.append(n)
			frontier.append(n)
	for c in chosen:
		s["tiles"][c]["tissue"] = CWData.Tissue.CANCER
	ElmGame.add_log(s, effects, "初始癌组织：自中央格向外铺 %d 格" % chosen.size())
	if CWData.special_of(Vector2i.ZERO) != CWData.Special.NONE:
		ElmGame.add_log(s, effects, "⚠ 中央格是特殊组织，与「癌组织不得与特殊组织重合」冲突（见说明 #34）")


# ---- 抽癌种类（每个癌症玩家独立抽、同局不重复，消耗 rng）----
static func assign_cancer_types(s: Dictionary, effects: Array) -> void:
	var pool: Array = CWData.CancerType.values()
	for pid in s["order"]:
		var p: Dictionary = ElmGame.player(s, pid)
		if p["faction"] != CWData.Faction.CANCER:
			continue
		var rr: Dictionary = ElmGame._pick_random(s["rng_state"], pool, 1)
		s["rng_state"] = rr["state"]
		var t: int = rr["picked"][0]
		pool.erase(t)
		p["cancer_type"] = t
		ElmGame.add_log(s, effects, "%s 抽到种类：%s" % [p["name"], CWData.CANCER_TYPE_NAMES[t]])


# ---- 落子选项（癌→癌组织 / 免疫→健康组织，不能与敌对细胞同格）----
static func place_options(s: Dictionary, p: Dictionary) -> Array:
	var opts: Array = []
	var faction: int = p["faction"]
	for c in s["tiles"].keys():
		var ok: bool
		if faction == CWData.Faction.CANCER:
			ok = s["tiles"][c]["tissue"] == CWData.Tissue.CANCER
		else:
			ok = s["tiles"][c]["tissue"] == CWData.Tissue.HEALTHY
		var enemy: int = 1 - faction
		if ok and ElmGame.cells_at(s, c, enemy).is_empty():
			opts.append({ "label": "落子 %s" % str(c), "data": { "to": c } })
	return opts


# ---- 应用落子（复刻 cw_setup._place_cells 的落子段）----
static func apply_place(s: Dictionary, idx: int, effects: Array) -> void:
	var pending: Dictionary = s["pending"]
	var pid: int = pending["pid"]
	var p: Dictionary = ElmGame.player(s, pid)
	var options: Array = place_options(s, p)
	var data: Dictionary = options[idx]["data"]
	var pos: Vector2i = data["to"]
	var ctype: int = p.get("cancer_type", -1)
	var itype: int = CWData.ImmuneType.BASIC if p["faction"] == CWData.Faction.IMMUNE else -1
	var energy: int = s["tune"].init_energy_immune if p["faction"] == CWData.Faction.IMMUNE \
		else s["tune"].init_energy_cancer
	s["cells"].append(make_cell(s["cells"].size(), pid, p["faction"], pos, itype, ctype, energy))
	ElmGame.add_log(s, effects, "%s 落子于 %s" % [p["name"], str(pos)])


# ---- 原发灶（癌出生格开局即固化，给癌方一次复活容错）----
static func place_primary_lesions(s: Dictionary, effects: Array) -> void:
	if not s["tune"].solid_at_cancer_spawn:
		return
	var marked := {}
	for cell in ElmGame.living_cells(s, CWData.Faction.CANCER):
		var c: Vector2i = cell["pos"]
		if marked.has(c):
			continue
		marked[c] = true
		var t: Dictionary = s["tiles"][c]
		t["tissue"] = CWData.Tissue.SOLID
		t["solid"] = s["tune"].solidify_threshold
	if not marked.is_empty():
		ElmGame.add_log(s, effects, "【原发灶】癌细胞出生的 %d 格转为固化癌组织" % marked.size())
