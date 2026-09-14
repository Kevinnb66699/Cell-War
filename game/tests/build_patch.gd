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
##   godot --headless --path game --script res://tests/build_patch.gd -- ##       [--base-classes=<清单文件>] <输出.pck> <res路径> <磁盘路径> ...
##
## `--base-classes` 是**目标基线包的全局类表**（一行一个类名，由 build_patch.sh
## 从那次发版 tag 的 git 树里扒出来）。不给就退回「拿本机项目的类表对照」——
## 那是个**会漏**的判据，见 _class_known 的注释。
##
## **美术资源也能打进补丁**（2026-09-14 验过才开的口子）：喂进来的是源文件
## （`assets/art/x.png`），打进包的是**导入产物** —— 包里真正被读的是
## `.godot/imported/x.png-<md5(源路径)>.ctex`，`res://…png` 靠同名的 `.import` 重定向过去。
## 所以 `_expand_assets()` 把每个源文件换成「产物 + `.import`」两条，源文件本身不进包（没人读它）。
## 实测三档都通（S0/S1/S2，见开发日志 2026-09-14）：换已有资源、新增资源、
## 补丁里的脚本 `preload` 新资源（解析期）；同一个补丁包 Windows / macOS 通用。
##
## ⚠ **仍然改不动这些**（要改就得全量发版）：
##   · 新增 `class_name`（全局类表在导出时烘死，补丁里的新类名解析不了）
##   · `project.godot` 的设置（引擎启动时就读完了）
##   · Godot 版本 / 导出模板
## 打包时会挡住前两类里能自动认出来的那部分，见 `_reject()`。


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	## 先把选项摘出去，剩下的才是「输出 + 若干对路径」
	var base_classes := {}
	var given := false          ## 给没给 --base-classes（和「给了但读出来是空的」是两回事）
	var build := 0              ## 本次补丁号，写进探针文件；0 = 没给（旧调用方）
	var rest: Array = []
	for a: String in args:
		if a.begins_with("--base-classes="):
			given = true
			base_classes = _read_class_list(a.substr(a.find("=") + 1))
			continue
		if a.begins_with("--build="):
			build = int(a.substr(a.find("=") + 1))
			continue
		rest.append(a)
	if rest.size() < 3 or (rest.size() - 1) % 2 != 0:
		printerr("用法：[--base-classes=<清单>] <输出.pck> <res路径> <磁盘路径> ...")
		quit(2)
		return
	## **给了却一个类名都没读出来 = 当场停。**
	## 上一版把它和「根本没给」归成一档，于是静默降级成本机类表 ——
	## 2026-09-09 那条 sed 坏掉之后，这道闸就是这么一天都没生效过的，
	## 而屏幕上只有一行警告、退出码还是 0。宁可不出包，也不要拿空表当判据。
	if given and base_classes.is_empty():
		printerr("✘ 给了 --base-classes，却一个类名都没读出来 —— 清单生成那一步坏了。")
		printerr("   拿空表当判据等于这道跨基线闸根本不存在，所以不出包。")
		quit(2)
		return
	if base_classes.is_empty():
		printerr("⚠ 没给 --base-classes：退回拿本机类表对照，")
		printerr("   本次新加的类在本机也已注册，这一档判据挡不住它。")
		for c in ProjectSettings.get_global_class_list():
			base_classes[String(c.get("class", ""))] = true
	var out: String = rest[0]
	var pairs: Array = []
	for i in range((rest.size() - 1) / 2):
		pairs.append([rest[1 + i * 2], rest[2 + i * 2]])
	## 每个补丁都夹带一张**探针**：把本次补丁号写进 patch_canary.gd。
	## 发之前 `scripts/patch_probe.gd` 在真导出的包上把它读回来 —— 读到补丁号才算
	## 「代码真的换了」。2026-09-10 之前没有这一步，于是每一个补丁都是白发的
	## 而全程无人察觉（成因见 scripts/patch_canary.gd 的文件头）。
	if build > 0:
		var canary := _write_canary(build)
		if canary == "":
			printerr("✘ 写不出探针文件 —— 没有它就没法验「补丁到底生效没有」，所以不出包。")
			quit(4)
			return
		pairs.append(["res://scripts/patch_canary.gd", canary])

	var bad := _reject(pairs, base_classes)
	if not bad.is_empty():
		printerr("✘ 这些改动热更不了，请走全量发版：")
		for b in bad:
			printerr("   ", b)
		quit(3)
		return

	## 美术资源：源文件换成「导入产物 + .import」。**必须在 _reject 之后** ——
	## 拒绝的判据说的是「你喂进来的东西」，展开之后再拒会答非所问
	var expanded := _expand_assets(pairs)
	if not expanded["errors"].is_empty():
		printerr("✘ 美术资源打不进补丁：")
		for b in expanded["errors"]:
			printerr("   ", b)
		quit(3)
		return
	pairs = expanded["pairs"]
	## 探针要拿的核对清单：一行「源路径|产物路径|产物SHA」。
	## 没有它，资源那一半就回到了「每步报成功、画面没变」的老路 —— 2026-09-10 的教训
	if not expanded["assets"].is_empty():
		var list_path: String = out + ".assets"
		var f := FileAccess.open(list_path, FileAccess.WRITE)
		if f == null:
			printerr("✘ 写不出资源核对清单 ", list_path)
			quit(4)
			return
		for line: String in expanded["assets"]:
			f.store_line(line)
		f.close()
		print("  资源核对清单 → ", list_path, "（%d 项）" % expanded["assets"].size())

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
##
## `base` = **目标基线包**的全局类表（类名 → true）。判据必须是它而不是本机项目：
## 本次新加的类在本机也已注册，拿本机对照等于让补丁自己给自己开绿灯。
static func _reject(pairs: Array, base: Dictionary) -> Array:
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
		## 要过导入的资源：**源文件本身确实白塞**（包里被读的是 `.godot/imported/…`），
		## 但 `_expand_assets()` 会把它换成导入产物再打包（2026-09-14 验过）。
		## 这里只挡一种情形：**还没导入过** —— 那时产物根本不存在，打了也是空的。
		if _needs_import(res):
			if not FileAccess.file_exists(disk + ".import"):
				bad.append("%s：没有 .import，说明这份资源还没导入过 —— 先跑一次 godot --headless --path game --import" % res)
			continue
		## 启动器自身**读在挂载之前**，所以补丁里的新版永远不会生效 ——
		## 打进去只会造成「更新了」的假象。这两个文件只能全量发版。
		## （这也正是安全模型成立的原因：补丁改不动验签公钥和基线号。）
		if res in ["res://scripts/boot.gd", "res://scripts/patch_state.gd"]:
			bad.append("%s：启动器在挂载补丁**之前**就读了它，补丁里的新版永远不生效" % res)
			continue
		if not res.ends_with(".gd"):
			continue
		var src := _read(disk)
		var cls := _class_name_of(src)
		if cls != "" and not base.has(cls):
			bad.append("%s：class_name %s 不在目标基线的类表里 —— 全局类表在导出时烘死，装上去认不出来"
				% [res, cls])
		## **光看「有没有新声明」不够**：真正会崩的是补丁里某个文件**引用**了
		## 老包没有的类。2026-09-09 加五只演出、发全量包之后，任何碰 match.gd 的补丁
		## 都会引用 CWChainFx —— 还停在更旧包上的玩家装了它就是当场报错。
		for miss: String in _missing_refs(src, base):
			bad.append("%s：引用了 %s，而目标基线的类表里没有它" % [res, miss])
	return bad


## 这个路径是不是「要过导入」的资源。**宁可多列几种也别漏** ——
## 漏掉的后果是发出去一个换不动东西的哑弹补丁，而且全程报成功。
## 把「源资源」换成「导入产物 + .import」。返回 { pairs, assets, errors }：
## `assets` 是给探针的核对清单（源路径|产物路径|产物SHA-256）。
##
## **产物路径不自己算**：读 `.import` 里的 `path=` —— 那是引擎自己写的去处，
## 比我们照 md5 规则推更靠得住（导入器换了写法也跟着变）。
static func _expand_assets(pairs: Array) -> Dictionary:
	var out_pairs: Array = []
	var assets: Array = []
	var errors: Array = []
	for p in pairs:
		var res: String = p[0]
		var disk: String = p[1]
		if not _needs_import(res):
			out_pairs.append(p)
			continue
		var imp_disk: String = disk + ".import"
		var made: String = _remap_of(imp_disk)
		if made == "":
			errors.append("%s：`.import` 里读不到 path= —— 先重新导入一次" % res)
			continue
		var made_disk := ProjectSettings.globalize_path(made)
		if not FileAccess.file_exists(made_disk):
			errors.append("%s：导入产物不存在（%s）—— 先跑 --import" % [res, made])
			continue
		## 产物 + .import 都要进包：**新增**资源在基线里没有 `.import`，光有产物没人知道去哪读
		out_pairs.append([made, made_disk])
		out_pairs.append([res + ".import", imp_disk])
		assets.append("%s|%s|%s" % [res, made, _sha256_of(made_disk)])
	return { "pairs": out_pairs, "assets": assets, "errors": errors }


## `.import` 里 `[remap]` 那段的 `path=`（导入产物在 res:// 下的去处）；读不到给空串
static func _remap_of(imp_disk: String) -> String:
	var f := FileAccess.open(imp_disk, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("path="):
			return line.substr(5).strip_edges().trim_prefix('"').trim_suffix('"')
	return ""


static func _sha256_of(disk: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(disk, FileAccess.READ)
	if f == null:
		return ""
	ctx.update(f.get_buffer(f.get_length()))
	return ctx.finish().hex_encode()


static func _needs_import(res: String) -> bool:
	for ext in [".png", ".jpg", ".jpeg", ".webp", ".svg", ".ttf", ".otf",
			".ogg", ".wav", ".mp3", ".glb", ".gltf", ".obj"]:
		if res.ends_with(ext):
			return true
	return false


## 源码里出现、但目标基线不认识的全局类名。
## 认得出的类名以本机项目的类表为词表 —— 只有本机有、基线没有的那批才是危险的。
## 注释里提一句也算（宁可拦错也别放过：真要豁免就把那句话改掉）。
static func _missing_refs(src: String, base: Dictionary) -> Array:
	var out: Array = []
	for c in ProjectSettings.get_global_class_list():
		var cls := String(c.get("class", ""))
		if cls == "" or base.has(cls):
			continue
		var re := RegEx.new()
		## 词边界故意不写 `\b`：这份源码几经 heredoc 转手，反斜杠被吃掉过好几次，
		## 而 GDScript 里 "\b" 是**退格符**不是边界 —— 被吃掉之后正则**静默**匹配不到
		## 任何东西，整道闸看着在跑其实全放行。前后各一个「不是标识符字符」的断言，
		## 效果一样且不含转义，谁也吃不掉。
		re.compile("(?<![A-Za-z0-9_])" + cls + "(?![A-Za-z0-9_])")
		if re.search(src) != null and not out.has(cls):
			out.append(cls)
	out.sort()
	return out


## 把本次补丁号写成一份探针源码，返回它的磁盘路径（写不出就返回空串）。
## 内容必须**长得像仓库里那份**（同一个常量名），只是数不同 —— 探针读的就是这个数。
static func _write_canary(build: int) -> String:
	var path := "user://patch_canary_%d.gd" % build
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string("## 由 tests/build_patch.gd 随补丁生成 —— 见 scripts/patch_canary.gd 的文件头。\n")
	f.store_string("const BUILD := %d\n" % build)
	f.close()
	return ProjectSettings.globalize_path(path)


## 一行一个类名的清单（build_patch.sh 从目标 tag 的 git 树里扒出来）
static func _read_class_list(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("✘ 读不到类表清单：", path)
		return out
	## **只收长得像类名的行**。上一版只判非空，于是一堆控制字符
	## 也能冒充类表（那正是 2026-09-09 那条坏 sed 吐出来的东西）
	var ok := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$")
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if ok.search(line) != null:
			out[line] = true
	f.close()
	return out


static func _read(disk: String) -> String:
	var f := FileAccess.open(disk, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


## 这份源码声明的 class_name（没有就是空串）
static func _class_name_of(src: String) -> String:
	for line in src.split("
"):
		var t := line.strip_edges()
		if t.begins_with("class_name "):
			return t.substr(11).split(" ")[0].strip_edges()
		## class_name 只能出现在文件头部（注释与 @tool 之后、任何声明之前）
		if t.begins_with("func ") or t.begins_with("var ") or t.begins_with("const "):
			break
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
