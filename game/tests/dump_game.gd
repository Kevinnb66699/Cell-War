## dump_game.gd —— 导出单局完整日志，用于人工复盘平衡问题
##
## 运行：godot --headless --path game --script res://tests/dump_game.gd
extends SceneTree

const SEED := 20260801
const N_PLAYERS := 4


## 想复盘哪套平衡方案就改这里；返回 CWTuning.new() 即为规则原文。
static func tuning() -> CWTuning:
	return CWTuning.recommended()


func _initialize() -> void:
	_run()


func _run() -> void:
	var s := ElmSession.new()
	s.init_game(CWData.FACTION_ORDER[N_PLAYERS], SEED, tuning())
	s.run_full()
	for line in s.logs:
		print(line)
	print("\n---- 终局统计 ----")
	print("回合 %d｜癌组织 %d｜固化 %d｜健康 %d｜抗原记忆 %d" % [
		s.round_no, s.count_tissue(CWData.Tissue.CANCER),
		s.count_tissue(CWData.Tissue.SOLID), s.count_tissue(CWData.Tissue.HEALTHY), s.memory])
	for c in s.cells:
		print("  %s：%s，能量 %s，位置 %s" % [s.cell_name(c),
			"存活" if c["alive"] else "死亡", CWData.fmt(c["energy"]), str(c["pos"])])
	s.dispose()
	quit(0)
