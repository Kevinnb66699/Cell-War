## record_ai_baseline.gd —— 护栏⑦ 的基线录制器（口径二 · 批 1 步 6+8）
##
## **必须在动 match.gd / ui_bridge.gd 之前跑**：录的是「改动前」那份 AI 的决策结果。
## 跑法（Godot 绝对路径见 memory 的 godot-executable-path 那条）：
##   "<godot>" --headless --path game --script res://tests/record_ai_baseline.gd
## 产物：game/tests/baseline/ai_same_hash.json（**要进仓库**，t_ai_same_hash 读它）。
## 目录不存在时自己建。重录的唯一合法理由是「规则或 AI 本来就该变」，那时要在提交信息里写清楚。
extends SceneTree

const AI_CASE := preload("res://tests/ai_baseline_case.gd")
const OUT_DIR := "res://tests/baseline"
const OUT_PATH := "res://tests/baseline/ai_same_hash.json"


func _initialize() -> void:
	_record()


func _record() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var out := {
		"recorded": Time.get_datetime_string_from_system(),
		"max_steps": AI_CASE.MAX_STEPS,
		"cases": {},
	}
	for case in AI_CASE.CASES:
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = await AI_CASE.run_case(case)
		out["cases"][String(case["name"])] = r
		print("%-7s winner=%2d round=%3d steps=%3d %.1fs hash=%s"
			% [String(case["name"]), int(r["winner"]), int(r["round_no"]), int(r["steps"]),
				(Time.get_ticks_msec() - t0) / 1000.0, String(r["hash"])])
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		printerr("SCRIPT ERROR: 写不出 %s（%d）" % [OUT_PATH, FileAccess.get_open_error()])
		quit(1)
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	print("写入 %s" % OUT_PATH)
	quit(0)
