## guide_director.gd —— 教程逐关局面导演：把 CWGuideLevels 的声明装配成真实 CWGame
##
## 职责边界（16 关重构切片③起）：
## - 1–15 关：小半径棋盘 + fixture 细胞 / 组织，直接构造在对局状态上——
##   走的都是引擎公开字段与 CWSetup 的建造函数，不复制也不改写任何正式规则；
## - 第 16 关（毕业战）：正式 127 格四人初始化原样跑（与 CWMatch.start 同款调用序），
##   教程只叠加建议 / 预测 / 解释；
## - 装配不执行任何结算：fixture 关流程停在回合开头（round_start，首次 advance
##   才跑 S 阶段），第 16 关停在 init 走完整开局；推进都由 CWMatch 的询问循环驱动。
##
## 正式对局隔离：本类不持有全局状态、不动 CWData 常量；装配完的 CWGame
## 与一局正式对局在引擎眼里无差别。种子按关固定（教程可复现），
## 与正式对局的种子互不相干。
class_name CWGuideDirector

## 教程随机流只由章节决定；正式局永远从 CWMatch.match_seed 单独初始化。
const SEED_BASE := 20260910


## 装配第 level 关（0 起）的开局局面；带实验区的关用 zone 选区（默认 0）。
## 返回未推进流程的真实 CWGame。
static func assemble(level: int, zone: int = 0) -> CWGame:
	var fx := CWGuideLevels.raw(level)
	var formal := bool(fx.get("formal", false))
	## 实验区：分区关的局面字段在 zones[zone] 里，半径关级共享
	var zf: Dictionary = fx
	if fx.has("zones"):
		var zs: Array = fx["zones"]
		zf = zs[clampi(zone, 0, zs.size() - 1)] if not zs.is_empty() else {}
		zf["radius"] = fx.get("radius", CWGuideLevels.radius(level))
	var factions: Array = CWData.FACTION_ORDER[4] if formal else CWData.FACTION_ORDER[2]
	var g := CWGame.new()
	## 种子按关派生：同关可复现、异关不串线；正式对局的种子不经过这里
	g.init(factions, SEED_BASE + level)
	g.setup.build_board(int(zf.get("radius", CWData.BOARD_RADIUS)))
	if not formal:
		## 教学摆拍局不判胜负：癌方只有死亡占位、常常一块固化都没有，E 阶段一判就是免疫胜利
		## （Kevin 2026-09-12 截图：第一章过后直接弹结算）。毕业战是正式局，照常判。
		g.win_checks = false
		_apply_fixture(g, zf)
	return g


## 把 fixture 写进对局状态。小棋盘先清掉正式布局的特殊组织
## （半径 3 起会撞上 CORES/MARROWS 的内圈坐标），fixture 声明了再加。
## 最后把流程停在回合开头（round_start）：跳过 setup.begin() 的重建棋盘与
## 初始癌组织铺设（fixture 自带局面），也跳过落子询问（细胞已按 fixture 在场）。
static func _apply_fixture(g: CWGame, fx: Dictionary) -> void:
	for c in g.tiles:
		g.tiles[c]["special"] = CWData.Special.NONE
	if fx.has("memory"):
		g.memory = int(fx["memory"])   ## 抗原记忆（阵营共享）；等级由记忆推导，无需另设
	if fx.has("round"):
		g.round_no = int(fx["round"])  ## 开局世界回合（第 13 关事件回合 / 15C 最终回合）
	for c in fx.get("cancer_tiles", []):
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	for c in fx.get("tile_extras", {}):
		for k in fx["tile_extras"][c]:
			g.tiles[c][k] = fx["tile_extras"][c][k]
	_place_cells(g, fx)
	g.flow = { "stage": "round_start", "i": 0, "acts": 0 }


## 玩家主细胞与 pid 下标对齐（players[i].cell_id = i）：每方第一枚为主细胞，
## 配角排后；缺席方补一枚死亡占位（免疫视角关的癌方、第 5 关癌症视角的免方），
## 死亡占位站一枚无活细胞的格，正式的复活询问按引擎规则自然处理。
static func _place_cells(g: CWGame, fx: Dictionary) -> void:
	var principals: Array = []
	var extras: Array = []
	var seen := {}
	var live_pos: Array = []
	for cell in fx.get("cells", []):
		live_pos.append(cell["pos"])
		var pid := 1 if cell["faction"] == CWData.Faction.CANCER else 0
		if not seen.has(pid):
			seen[pid] = true
			principals.append(cell)
		else:
			extras.append(cell)
	var ordered: Array = []
	for pid in g.order:
		var picked: Dictionary = {}
		for cell in principals:
			if (1 if cell["faction"] == CWData.Faction.CANCER else 0) == pid:
				picked = cell
		if picked.is_empty():
			## 缺席玩家的死亡占位：站板外哨兵位（不占任何格子）——选项枚举当它透明，
			## 但迁移执行按「一细胞一格」会撞上它回滚（2026-09-10 探针实锤）。
			## 板外坐标对邻居枚举天然为空集，一切按位置的查询都安全。
			var ph := g.setup.make_cell(pid, pid, g.player(pid)["faction"],
				Vector2i(9999, 9999), -1, -1, 0)
			ph["alive"] = false
			ordered.append(ph)
		else:
			ordered.append(picked)
	for cell in extras:
		ordered.append(cell)
	g.cells.clear()
	var cid := 0
	for cell in ordered:
		var pid := 1 if cell["faction"] == CWData.Faction.CANCER else 0
		var it := int(cell.get("itype", -1))
		if cell["faction"] == CWData.Faction.IMMUNE and it < 0:
			it = CWData.ImmuneType.BASIC   ## 免疫主细胞默认未分化（BASIC）；-1 只留给缺席占位
		var nc := g.setup.make_cell(cid, pid, cell["faction"], cell["pos"],
			it, int(cell.get("ctype", -1)),
			int(cell.get("energy", CWData.INIT_ENERGY)))
		nc["alive"] = cell.get("alive", true)
		g.cells.append(nc)
		cid += 1
	## 玩家的癌种与主细胞一致（fixture 声明了就钉死、不随种子抽；免疫席 -1）
	## ——正式局这活由 setup._assign_cancer_types 干，fixture 关跳过了开局流程。
	for pid in g.order:
		var ct := -1
		if g.player(pid)["faction"] == CWData.Faction.CANCER:
			ct = int(g.cell_of(pid)["ctype"])
		g.players[pid]["cancer_type"] = ct
