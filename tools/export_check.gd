## 导出版体检：在**导出的包**里把六关的 base world 各装一遍（走真 loader ⇒ 会读旋钮契约表）。
## 用法：<导出的 CellWar.exe> --headless --script <本文件绝对路径> [-- <补丁.pck>]
##   或  Godot_console.exe --headless --main-pack <CellWar.exe> --script <本文件绝对路径> [-- <补丁.pck>]
## 带上补丁 pck 就先挂上再检：模拟「线上老客户端 + 这个补丁」
extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and args[0] != "":
		var ok := ProjectSettings.load_resource_pack(args[0], true)
		print("PATCH %s mounted=%s" % [args[0], str(ok)])
	var d = load("res://scripts/kernel/cw_tutor_script.gd").new()
	var loader = load("res://scripts/kernel/cw_world_loader.gd").new()
	var bad: Array = []
	var tune_path: String = str(loader.TUNE_PATH)
	print("TUNE_PATH=%s exists=%s" % [tune_path, str(FileAccess.file_exists(tune_path))])
	print("tests dir present in pack: %s" % str(FileAccess.file_exists("res://tests/contract_tune.json")))
	for id in ["c1_l1", "c1_l2", "c1_l3", "c2_l4", "c2_l5", "c3_l6"]:
		var lv: Dictionary = d.load_level(id)
		if lv.is_empty():
			bad.append(id + ":no_level")
			continue
		var g = loader.load_world(d.resolve(lv, "base"))
		if g == null:
			bad.append(id + ":" + (str(loader.errors) if "errors" in loader else "load_world null"))
		else:
			print("  ok  %s (tuning keys %s)" % [id, str((d.resolve(lv, "base").get("tuning", {})).keys())])
	print("EXPORT_CHECK " + ("OK" if bad.is_empty() else "FAIL " + str(bad)))
	quit()
