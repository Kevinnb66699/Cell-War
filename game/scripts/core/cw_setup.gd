## cw_setup.gd —— 开局流程：建棋盘、铺初始癌组织、抽癌细胞种类、按行动顺序落子
##
## 原型固定使用「中央格+第一环」作为初始 7 癌组织（说明 三、范围裁剪）。
class_name CWSetup
extends RefCounted

var game: CWGame


func run() -> void:
	build_board()
	_place_initial_cancer()
	_assign_cancer_types()
	await _place_cells()
	_place_primary_lesions()
	game.update_marks()
	game.log_msg("—— 开局完成，进入世界回合 ——")


func build_board() -> void:
	for c in CWData.all_coords():
		game.tiles[c] = make_tile(c)


static func make_tile(c: Vector2i) -> Dictionary:
	return {
		"tissue": CWData.Tissue.HEALTHY,
		"special": CWData.special_of(c),
		"solid": 0,      # 固化计数（总数）
		"sticky": 0,     # 其中的「固着点」，永不自然衰减（说明 #16）
		"newborn": false, # 本世界回合新转化的癌组织（不可固化）
		"store": 0,      # 代谢核心存储的十分能量
		"cards": 0,      # 骨髓存储的卡牌数
		"prod": 0,       # 特殊组织产出周期计数器
	}


static func make_cell(id: int, pid: int, faction: int, pos: Vector2i,
		itype: int, ctype: int, energy: int = CWData.INIT_ENERGY) -> Dictionary:
	return {
		"id": id, "pid": pid, "faction": faction, "pos": pos,
		"itype": itype,            # 免疫种类（癌细胞为 -1）
		"ctype": ctype,            # 癌细胞种类（免疫为 -1）
		"energy": energy,
		"alive": true,
		"marked": false,           # 树突【标记】
		"hand": 0,                 # 手牌数（原型为空白卡）
		"differentiated": false,   # 每细胞每局限一次【分化】
		# 以下计数每世界回合 S 阶段重置
		"escape_used": false, "invasive_used": 0, "remodel_used": false,
		"mutate_used": false, "unstable_used": false, "antibody_used": 0,
		"respawn_round": -1,       # 免疫细胞死亡后可复活的世界回合（-1 = 未死亡/不复活）
	}


## 原发灶：每个癌症玩家的出生格开局即为固化癌组织（2026-08-26 团队定案）
## 作用是给癌方一次复活容错，破解「复活需固化组织 → 固化需停留 2 回合 → 停留就被打死」的死循环。
## 注意：复活会消耗掉固化组织（降级为癌组织），所以每格只能救一次。
func _place_primary_lesions() -> void:
	if not game.tune.solid_at_cancer_spawn:
		return
	var marked := {}
	for cell in game.living_cells(CWData.Faction.CANCER):
		var c: Vector2i = cell["pos"]
		if marked.has(c):
			continue
		marked[c] = true
		var t: Dictionary = game.tile(c)
		t["tissue"] = CWData.Tissue.SOLID
		t["solid"] = game.tune.solidify_threshold
	if not marked.is_empty():
		game.log_msg("【原发灶】癌细胞出生的 %d 格转为固化癌组织" % marked.size())


## 初始癌组织：从中央格向外一圈圈铺，跳过特殊组织，直到达到目标格数。
## 满足规则三个约束：彼此连通 ✓、含中央格 ✓、不与特殊组织重合 ✓。
## （规则原文由癌方自选布局，原型固定用这个默认铺法——见 docs/规则电子化说明.md 裁剪项）
func _place_initial_cancer() -> void:
	var target: int = game.tune.init_cancer_tiles
	var chosen: Array[Vector2i] = [Vector2i.ZERO]
	var frontier: Array[Vector2i] = [Vector2i.ZERO]
	var seen := { Vector2i.ZERO: true }
	# 广度优先向外扩，保证每一格都与已选区域相邻（连通性）
	while chosen.size() < target and not frontier.is_empty():
		var cur: Vector2i = frontier.pop_front()
		for n in CWData.neighbors(cur):
			if chosen.size() >= target:
				break
			if seen.has(n):
				continue
			seen[n] = true
			if CWData.special_of(n) != CWData.Special.NONE:
				continue  # 癌组织不能与特殊组织重合
			chosen.append(n)
			frontier.append(n)
	for c in chosen:
		game.tiles[c]["tissue"] = CWData.Tissue.CANCER  # 开局即有，不算「新生」
	game.log_msg("初始癌组织：自中央格向外铺 %d 格" % chosen.size())


## 每个癌症玩家独立抽种类，同局不重复（说明 #12）
func _assign_cancer_types() -> void:
	var pool: Array = CWData.CancerType.values()
	for pid in game.order:
		var p: Dictionary = game.player(pid)
		if p["faction"] != CWData.Faction.CANCER:
			continue
		var t: int = game.pick_random(pool, 1)[0]
		pool.erase(t)
		p["cancer_type"] = t
		game.log_msg("%s 抽到种类：%s" % [p["name"], CWData.CANCER_TYPE_NAMES[t]])


## 按行动顺序落子：癌细胞只能放癌组织，免疫只能放健康组织；同格仅限同阵营（说明 #4）
func _place_cells() -> void:
	for pid in game.order:
		var p: Dictionary = game.player(pid)
		var faction: int = p["faction"]
		var options: Array = []
		for c in game.tiles.keys():
			var ok: bool
			if faction == CWData.Faction.CANCER:
				ok = game.tiles[c]["tissue"] == CWData.Tissue.CANCER
			else:
				ok = game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY
			# 不能与敌对细胞同格
			var enemy: int = 1 - faction
			if ok and game.cells_at(c, enemy).is_empty():
				options.append({ "label": "落子 %s" % str(c), "data": { "to": c } })
		var idx: int = await game.ask(pid, {
			"kind": "setup_place", "prompt": "%s 选择初始位置" % p["name"], "options": options,
		})
		var pos: Vector2i = options[idx]["data"]["to"]
		var ctype: int = p.get("cancer_type", -1)
		var itype: int = CWData.ImmuneType.BASIC if faction == CWData.Faction.IMMUNE else -1
		var energy: int = game.tune.init_energy_immune if faction == CWData.Faction.IMMUNE \
			else game.tune.init_energy_cancer
		var cell := make_cell(game.cells.size(), pid, faction, pos, itype, ctype, energy)
		game.cells.append(cell)
		game.log_msg("%s 落子于 %s" % [p["name"], str(pos)])
