## l0_pre_dump.gd —— 闸二 2b「装载自证」的 GD 半边（测试迁移规格 A-5 / C-1 步 5）
##
## 把 res://tests/l0/*.json 的每条用例用 scripts/kernel/cw_world_loader.gd 装成 CWGame，再用 CWObsCodec 编成全知 envelope，
## 一行一条 `{ "id", "env" }` 写到 out=。C# 侧 L0/PreParityTests.cs 用自己的 WorldLoader + ObservationV1Codec 产另一份，逐字段 diff ——
## 非零就是「两侧装出来的不是同一个世界」，探针再对也是假绿灯。
##
##   Godot_v4.5-stable_win64_console.exe --headless --path game --script res://tests/l0_pre_dump.gd -- out=D:/path/l0_pre.jsonl
##   gzip -9 -c D:/path/l0_pre.jsonl > game/tests/l0/pre_envelopes.jsonl.gz      （用例一动就重录）
extends SceneTree

const Loader := preload("res://scripts/kernel/cw_world_loader.gd")
const CASE_DIR := "res://tests/l0"

var out_path := "user://l0_pre.jsonl"


## 递归扫用例文件：跳过 cw_world_loader.gd:NON_CASE_FILES 里的数据夹具
func _scan(dir_path: String, files: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var names: Array = []
	for name in dir.get_files():
		if name.ends_with(".json") and not (name in Loader.NON_CASE_FILES):
			names.append(name)
	names.sort()
	for name in names:
		files.append("%s/%s" % [dir_path, name])
	var subs: Array = []
	for sub in dir.get_directories():
		subs.append(sub)
	subs.sort()
	for sub in subs:
		_scan("%s/%s" % [dir_path, sub], files)


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() == 2 and kv[0] == "out":
			out_path = kv[1]
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写 ", out_path, " err=", FileAccess.get_open_error())
		quit(1)
		return
	var files: Array = []
	_scan(CASE_DIR, files)   ## 递归：批次目录 l0/batch{n}/ 也要录（与 l0_runner.gd:_scan_cases、契约门同口径）
	files.sort()
	var n := 0
	var bad := 0
	for path in files:
		var cases: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(cases) != TYPE_ARRAY:
			printerr("%s 解不出用例数组" % path)
			bad += 1
			continue
		for c in cases:
			var loader = Loader.new()
			var g: CWGame = loader.load_world(c.get("world", {}))
			if g == null:
				printerr("%s 装不出来：%s" % [c.get("id", "?"), "; ".join(loader.errors)])
				bad += 1
				continue
			f.store_line(JSON.stringify({ "id": c["id"], "env": CWObsCodec.encode(g, { "viewer": CWObsProto.VIEWER_OMNISCIENT }) }))
			n += 1
			g.dispose()
	f.close()
	print("L0-PRE-DUMP: %d 条写到 %s，%d 条装不出来" % [n, out_path, bad])
	quit(1 if bad > 0 else 0)
