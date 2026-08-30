## cw_setup.gd —— 开局流程：建棋盘、铺初始癌组织、抽癌细胞种类、按行动顺序落子
##
## 初始癌组织 15 格由系统按确定性随机铺（PRD 游戏开始 1.）；规则原文由癌方共同选择，
## 电子版先用「自中央格向外铺」的默认布局，三条约束都满足（见 _place_initial_cancer）。
class_name CWSetup
extends RefCounted

var game: CWGame


## 开局的**无决策部分**：建棋盘、铺初始癌组织、抽癌细胞种类。
## 落子要玩家决定，交给流程状态机（见 CWGame.advance 的 setup_place 阶段）。
func begin() -> void:
	build_board()
	_place_initial_cancer()
	_assign_cancer_types()


## 落子完成后的收尾：原发灶、刷新标记。
func finish() -> void:
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
		"necrosis": 0,   # 「坏死」还剩几个世界回合（>0 时不为免疫【有氧呼吸】供能）
		"mucus": false,  # 印戒【黏液破裂】留下的「黏液侵染」；被免疫细胞踩到即消失
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
		"mark_left": 0,            # 【标记】还能翻倍几次（普通 1；呈递强化树突施加的 2）
		"hand": [],                # 手牌里的卡名（上限 CWData.HAND_MAX）
		"equipped": [],            # 已装备的永久技能名（打出即装备，死亡不掉）
		"mods": [],                # 修饰卡条目 {name, uses, until, seq, data}，见 CWGame.add_mod
		# 「数值修正按打出先后结算」（PRD 通则，2026-08-30 定案）要求即时卡与永久技能
		# 能比较先后，而两者分住 mods / equipped 两个数组 —— 用一个**每细胞**的计数器
		# 给双方盖同一把戳。只在同一个细胞内部比较，所以不必做成全局计数器。
		"play_n": 0,               # 这个细胞打出过几张卡（含装备），单调递增
		"equip_seq": {},           # 永久技能名 -> 装备时的 play_n
		"fx_turn": {},             # 永久技能「每行动回合第一次」的闸门，begin_turn 清
		"fx_round": {},            # 永久技能「每世界回合第一次」的闸门，S 阶段重置清
		"differentiated": false,   # 每细胞每局限一次【分化】
		# 以下计数每世界回合 S 阶段重置
		"armor_used": false,       # 印戒【囊性护甲】
		"mutate_used": false,      # 【突变】1 次/世界回合
		"antibody_used": 0,        # B【抗体】2 次/世界回合
		"toxin_used": 0,           # T【细胞毒素】3 次/世界回合
		"metastasis_used": false,  # 黑色素瘤【早期血行转移】1 次/世界回合
		# 下面这个每**行动回合**重置（见 CWTurn），不是每世界回合
		"draws_used": 0,           # 【基因表达】3 次/行动回合
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
##
## 注意后两条约束天然互斥：一旦中央格是特殊组织，「必须含中央格」与「不得与特殊组织重合」
## 就无法同时成立。127 格地图初版曾把骨髓放在中央格，2026-08-27 已把它移走（说明 #34）。
## 下面保留了一个运行时提醒，万一将来又有人往中央格放特殊组织，日志会立刻喊出来。
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
	if CWData.special_of(Vector2i.ZERO) != CWData.Special.NONE:
		game.log_msg("! 中央格是特殊组织，与「癌组织不得与特殊组织重合」冲突（见说明 #34）")


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


## 落子的候选格：癌细胞只能放癌组织，免疫只能放健康组织，
## 且**同一组织格仅能放一个细胞**（PRD 游戏开始 2.3）。
func place_options(pid: int) -> Array:
	var faction: int = game.player(pid)["faction"]
	var options: Array = []
	for c in game.tiles.keys():
		var ok: bool
		if faction == CWData.Faction.CANCER:
			ok = game.tiles[c]["tissue"] == CWData.Tissue.CANCER
		else:
			ok = game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY
		if ok and game.cells_at(c).is_empty():
			options.append({ "label": "落子 %s" % str(c), "data": { "to": c } })
	return options


## 真正落子。**同步、无询问** —— 决定是流程状态机问来的。
func place(pid: int, pos: Vector2i) -> void:
	var p: Dictionary = game.player(pid)
	var faction: int = p["faction"]
	var ctype: int = p.get("cancer_type", -1)
	var itype: int = CWData.ImmuneType.BASIC if faction == CWData.Faction.IMMUNE else -1
	var energy: int = game.tune.init_energy_immune if faction == CWData.Faction.IMMUNE \
		else game.tune.init_energy_cancer
	var cell := make_cell(game.cells.size(), pid, faction, pos, itype, ctype, energy)
	game.cells.append(cell)
	game.log_msg("%s 落子于 %s" % [p["name"], str(pos)])

