extends SceneTree
## 把一批改动过的文件打成热更补丁包（`PCKPacker`）。开发工具，不是测试。
##
## 放在 `tests/` 下是因为导出预设的 `exclude_filter="tests/*"` —— 这个目录里的东西
## 天然不进客户端包，和 `preview_*.gd` / `screenshot.gd` 同一条路子。
##
## **包里的路径 = 它要覆盖的 `res://` 路径**，运行时 `load_resource_pack()`
## 就是按这个路径盖过去的。所以喂进来的每个文件都必须给出它在项目里的位置。
##
## 用法（一般由 `tools/build_patch.sh` 调，它负责从 git 算出改了哪些文件）：
##   godot --headless --path game --script res://tests/build_patch.gd -- <输出.pck> <res路径> <磁盘路径> ...
##
## ⚠ **能打进补丁的只有资源，改不动这些**（要改就得全量发版）：
##   · 新增 `class_name`（全局类表在导出时烘死，补丁里的新类名解析不了）
##   · `project.godot` 的设置（引擎启动时就读完了）
##   · Godot 版本 / 导出模板
## 打包时会挡住前两类里能自动认出来的那部分，见 `_reject()`。


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3 or (args.size() - 1) % 2 != 0:
		printerr("用法：<输出.pck> <res路径> <磁盘路径> [<res路径> <磁盘路径> ...]")
		quit(2)
		return
	var out: String = args[0]
	var pairs: Array = []
	for i in range((args.size() - 1) / 2):
		pairs.append([args[1 + i * 2], args[2 + i * 2]])

	var bad := _reject(pairs)
	if not bad.is_empty():
		printerr("✘ 这些改动热更不了，请走全量发版：")
		for b in bad:
			printerr("   ", b)
		quit(3)
		return

	var packer := PCKPacker.new()
	var err := packer.pck_start(out)
	if err != OK:
		printerr("✘ pck_start: ", error_string(err))
		quit(4)
		return
	for p in pairs:
		err = packer.add_file(p[0], p[1])
		if err != OK:
			printerr("✘ add_file %s: %s" % [p[0], error_string(err)])
			quit(4)
			return
	err = packer.flush(false)
	if err != OK:
		printerr("✘ flush: ", error_string(err))
		quit(4)
		return

	print("✔ 补丁包 %s（%d 个文件，%d 字节）" % [out, pairs.size(), _size_of(out)])
	print("  SHA-256 ", _sha256(out))
	for p in pairs:
		print("    ", p[0])
	quit(0)


## 挡住已知打不进补丁的改动。**宁可拦错也别放过** —— 放过的后果是玩家那边
## 报 `Identifier "X" not declared` 或者干脆挂死，而那时补丁已经发出去了。
func _reject(pairs: Array) -> Array:
	var bad: Array = []
	for p in pairs:
		var res: String = p[0]
		var disk: String = p[1]
		if not FileAccess.file_exists(disk):
			bad.append("%s：文件不存在（删除文件也无法用补丁表达）" % res)
			continue
		if res.ends_with("project.godot") or res.ends_with(".import"):
			bad.append("%s：项目设置 / 导入配置在引擎启动时就读完了，补丁盖不住" % res)
			continue
		if res.ends_with(".gd"):
			var cls := _class_name_of(disk)
			if cls != "" and not _class_known(cls):
				bad.append("%s：新增了 class_name %s —— 全局类表在导出时烘死，补丁里认不出来"
					% [res, cls])
	return bad


## 这个 class_name 在**当前项目**里已经注册过吗。
## 导出包里的全局类表就是从这儿烘出去的，所以「本地已注册」≈「老客户端认得」。
## 反过来不成立：本次新加的类在本地也已注册 —— 所以打包**必须在加类之前的那次发版包**
## 上做对照，见 tools/build_patch.sh 的 --base 参数。
func _class_known(cls: String) -> bool:
	for c in ProjectSettings.get_global_class_list():
		if String(c.get("class", "")) == cls:
			return true
	return false


func _class_name_of(disk: String) -> String:
	var f := FileAccess.open(disk, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("class_name "):
			f.close()
			return line.substr(11).split(" ")[0].strip_edges()
		## class_name 只能出现在文件头部（注释与 @tool 之后、任何声明之前）
		if line.begins_with("func ") or line.begins_with("var ") or line.begins_with("const "):
			break
	f.close()
	return ""


func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


func _sha256(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var chunk := f.get_buffer(1 << 20)
		if chunk.size() > 0:
			ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()
