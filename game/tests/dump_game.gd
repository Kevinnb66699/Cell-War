## dump_game.gd —— 导出单局完整日志，用于人工复盘平衡问题
##
## 运行：godot --headless --path game --script res://tests/dump_game.gd
extends SceneTree

const SEED := 20260801
const N_PLAYERS := 4


## 想复盘哪套平衡方案就改这里；CWTuning.new() 即按 PRD 跑，
## 换成 CWTuning.split_income() 可复盘「免疫收入按细胞数均分」的实验档。
static func tuning() -> CWTuning:
	return CWTuning.new()


func _initialize() -> void:
	_run()


func _run() -> void:
	var g := CWGame.new()
	g.tune = tuning()
	g.init(CWData.FACTION_ORDER[N_PLAYERS], SEED)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	await g.run_game()
	for line in g.logs:
		print(line)
	print("\n---- 终局统计 ----")
	print("回合 %d｜癌组织 %d｜固化 %d｜健康 %d｜抗原记忆 %d" % [
		g.round_no, g.count_tissue(CWData.Tissue.CANCER),
		g.count_tissue(CWData.Tissue.SOLID), g.count_tissue(CWData.Tissue.HEALTHY), g.memory])
	for c in g.cells:
		print("  %s：%s，能量 %s，位置 %s" % [g.cell_name(c),
			"存活" if c["alive"] else "死亡", CWData.fmt(c["energy"]), str(c["pos"])])
	g.dispose()
	quit(0)
