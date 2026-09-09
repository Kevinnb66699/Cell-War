## guide_director.gd —— 教程逐关局面导演：把 CWGuideLevels 的声明装配成真实 CWGame
##
## 职责边界（16 关重构切片③起）：
## - 1–15 关：小半径棋盘 + fixture 细胞 / 组织，直接构造在对局状态上——
##   走的都是引擎公开字段与 CWSetup 的建造函数，不复制也不改写任何正式规则；
## - 第 16 关（毕业战）：正式 127 格四人初始化原样跑（与 CWMatch.start 同款调用序），
##   教程只叠加建议 / 预测 / 解释；
## - 装配不推进流程（flow 停在 init）：推进仍由 CWMatch 的正常询问循环驱动。
##
## 正式对局隔离：本类不持有全局状态、不动 CWData 常量；装配完的 CWGame
## 与一局正式对局在引擎眼里无差别。种子按关固定（教程可复现），
## 与正式对局的种子互不相干。
class_name CWGuideDirector


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
	g.init(factions, 20260910 + level)
	g.setup.build_board(int(zf.get("radius", CWData.BOARD_RADIUS)))
	if not formal:
		_apply_fixture(g, zf)
	return g


## 把 fixture 写进对局状态。小棋盘先清掉正式布局的特殊组织
## （半径 3 起会撞上 CORES/MARROWS 的内圈坐标），fixture 声明了再加。
static func _apply_fixture(g: CWGame, fx: Dictionary) -> void:
	for c in g.tiles:
		g.tiles[c]["special"] = CWData.Special.NONE
	if fx.has("memory"):
		g.memory = int(fx["memory"])   ## 抗原记忆（阵营共享）；等级由记忆推导，无需另设
	for c in fx.get("cancer_tiles", []):
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	for c in fx.get("tile_extras", {}):
		for k in fx["tile_extras"][c]:
			g.tiles[c][k] = fx["tile_extras"][c][k]
	var cid := 0
	for cell in fx.get("cells", []):
		var pid := 1 if cell["faction"] == CWData.Faction.CANCER else 0
		g.cells.append(g.setup.make_cell(cid, pid, cell["faction"], cell["pos"],
			int(cell.get("itype", -1)), int(cell.get("ctype", -1)),
			int(cell.get("energy", CWData.INIT_ENERGY))))
		cid += 1
