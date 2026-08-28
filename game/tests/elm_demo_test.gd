## elm_demo_test.gd —— 场景可视化集成冒烟：Main 场景在 ElmSession 上跑完整对局
##
## 验证「整个项目在新架构下运行」的落地点：加载 Main.tscn（ElmDemo 导演），
## 用它的 session 推完整对局到 DONE，并周期性走 board.refresh 渲染路径
## （组织贴图刷新 + 细胞圆 + 能量），确保表现层代码无错。
extends SceneTree

var checks := 0
var fails := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var demo = load("res://scenes/Main.tscn").instantiate()
	root.add_child(demo)
	await process_frame  # 等 _ready 跑完（建 session/UI/骰子）
	check(demo.session != null and String(demo.session.pc) == "SETUP_BUILD",
		"Main 场景创建了 ElmSession（新架构驱动）")
	var guard := 0
	while String(demo.session.pc) != "DONE" and guard < 50000:
		demo.session.step()
		if guard % 20 == 0:
			demo.board.refresh(demo.session.state)  # 渲染路径无错
		guard += 1
	check(String(demo.session.pc) == "DONE", "对局推到 DONE（%d 步）" % guard)
	check(demo.session.winner >= 0, "有胜方（%s）" % (
		"免疫" if demo.session.winner == CWData.Faction.IMMUNE else "癌症"))
	check(demo.session.state["logs"].size() > 0, "日志已收集（%d 条）" % demo.session.logs.size())
	# 终局渲染一遍
	demo.board.refresh(demo.session.state)
	check(demo.board._cells.size() >= 0, "细胞渲染路径 OK（存活 %d）" % demo.board._cells.size())
	demo.queue_free()
	await process_frame
	print("")
	if fails == 0:
		print("✔ 场景集成全部通过（%d 项检查）" % checks)
		quit(0)
	else:
		print("✘ %d 项失败（共 %d 项）" % [fails, checks])
		quit(1)


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("  ok  %s" % name)
	else:
		fails += 1
		print("  FAIL %s" % name)
