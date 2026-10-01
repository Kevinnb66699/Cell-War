## cw_sidecar_locator.gd —— 找 sidecar 的 dotnet 宿主与 dll（换内核 P7，docs/内核替换_重启计划.md §五 第 2 条「运行时压进游戏包」）
##
## 三种来源，按序：
##   ① 环境变量 CW_SIDECAR_DLL（+ CW_DOTNET）：测试 / 服务器 run.sh 显式指定；
##   ② **导出包**（feature `template`）：`res://sidecar/`（tools/build_sidecar.sh 生成、导出时进 pck）里有载荷与本平台的运行时 zip，
##      首次用时解到 `user://sidecar/` —— 运行时按「平台 + 版本 + sha」、载荷按 sha 各占一个目录，先解到 `.tmp` 再改名（解一半崩了不会留半份），
##      已经在的直接用；mac / Linux 上给宿主补可执行位（zip 解出来没有）；
##   ③ 开发期：本机装的 dotnet + 仓库里 core/CellWar.Sidecar 的 Debug 产物。
## 返回 `{dotnet, dll}`，找不到就 `{error}` —— 调用方转 UNAVAILABLE（与补丁系统隔离，绝不计 STRIKES）。
## 不碰 boot.gd / patch_state.gd（硬不变量①）：解包是第一次开局时由句柄做的，不在启动路径上。
extends RefCounted

const PACK_DIR := "res://sidecar"
const USER_DIR := "user://sidecar"


static func locate() -> Dictionary:
	var env_dll := OS.get_environment("CW_SIDECAR_DLL")
	if env_dll != "":
		var env_dotnet := OS.get_environment("CW_DOTNET")
		return { "dotnet": env_dotnet if env_dotnet != "" else dev_dotnet(), "dll": env_dll }
	if OS.has_feature("template"):
		return unpack()
	return { "dotnet": dev_dotnet(), "dll": dev_dll() }


## 本机装的 dotnet：环境变量 CW_DOTNET 优先，其次几个常见安装位置（Mac 上是 ~/.dotnet）
static func dev_dotnet() -> String:
	var env := OS.get_environment("CW_DOTNET")
	if env != "" and FileAccess.file_exists(env):
		return env
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	for p in [home.path_join(".dotnet/dotnet"), home.path_join(".dotnet/dotnet.exe"), "/usr/local/share/dotnet/dotnet",
			"/opt/homebrew/bin/dotnet", "/usr/share/dotnet/dotnet", "/usr/lib/dotnet/dotnet", "C:/Program Files/dotnet/dotnet.exe"]:
		if FileAccess.file_exists(p):
			return p
	return ""


## 开发期：仓库里 core/CellWar.Sidecar 的 Debug 产物（game/ 的上一层）
static func dev_dll() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../core/CellWar.Sidecar/bin/Debug/net10.0/CellWar.Sidecar.dll").simplify_path()


## 这台机器的 .NET 运行时标识（与 tools/build_sidecar.sh 的 rid 同一套）
static func host_rid() -> String:
	var arch := Engine.get_architecture_name()
	match OS.get_name():
		"macOS":
			return "osx-arm64" if arch == "arm64" else "osx-x64"
		"Windows":
			return "win-x64"
		"Linux", "FreeBSD":
			return "linux-x64" if arch == "x86_64" else "linux-arm64"
	return ""


## 导出包：把 pck 里的运行时与载荷解到用户目录（已在就不解）
static func unpack() -> Dictionary:
	var mtext := FileAccess.get_file_as_string(PACK_DIR + "/manifest.json")
	var manifest = JSON.parse_string(mtext) if mtext != "" else null
	if not (manifest is Dictionary):
		return { "error": "这个包没带 sidecar（res://sidecar/manifest.json 不在）" }
	var rid := host_rid()
	var rt: Dictionary = (manifest.get("runtimes", {}) as Dictionary).get(rid, {})
	if rt.is_empty():
		return { "error": "这个包没带 %s 的 .NET 运行时" % rid }
	var rt_dir := "%s/runtime-%s-%s-%s" % [USER_DIR, rid, String(rt["version"]), String(rt["sha256"]).substr(0, 12)]
	var err := _extract_zip_once(PACK_DIR + "/" + String(rt["file"]), rt_dir)
	if err != "":
		return { "error": err }
	var host := ProjectSettings.globalize_path(rt_dir.path_join(String(rt["host"])))
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", host])   ## zip 解出来没有可执行位
	var payload: Dictionary = manifest.get("payload", {})
	var pl_dir := "%s/payload-%s" % [USER_DIR, String(payload.get("sha256", "")).substr(0, 16)]
	err = _copy_once(PACK_DIR + "/" + String(payload.get("dir", "payload")), Array(payload.get("files", [])), pl_dir)
	if err != "":
		return { "error": err }
	return { "dotnet": host, "dll": ProjectSettings.globalize_path(pl_dir.path_join("CellWar.Sidecar.dll")) }


static func _extract_zip_once(zip_path: String, dest: String) -> String:
	if FileAccess.file_exists(dest.path_join(".ok")):
		return ""
	var tmp := dest + ".tmp"
	_rm_rf(tmp)
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return "运行时包打不开：%s" % zip_path
	for f in zr.get_files():
		if f.ends_with("/"):
			continue
		var out := tmp.path_join(f)
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var w := FileAccess.open(out, FileAccess.WRITE)
		if w == null:
			zr.close()
			return "写不了 %s" % out
		w.store_buffer(zr.read_file(f))
		w.close()
	zr.close()
	return _commit(tmp, dest)


static func _copy_once(src_dir: String, files: Array, dest: String) -> String:
	if FileAccess.file_exists(dest.path_join(".ok")):
		return ""
	var tmp := dest + ".tmp"
	_rm_rf(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	for f in files:
		var bytes := FileAccess.get_file_as_bytes(src_dir.path_join(String(f)))
		if bytes.is_empty():
			return "载荷缺文件：%s" % String(f)
		var w := FileAccess.open(tmp.path_join(String(f)), FileAccess.WRITE)
		if w == null:
			return "写不了 %s" % tmp.path_join(String(f))
		w.store_buffer(bytes)
		w.close()
	return _commit(tmp, dest)


## 解好的临时目录改名成正式目录，最后写 .ok 标记（没有标记 = 半份，下次重解）
static func _commit(tmp: String, dest: String) -> String:
	_rm_rf(dest)
	if DirAccess.rename_absolute(tmp, dest) != OK:
		return "改不了名：%s → %s" % [tmp, dest]
	var ok := FileAccess.open(dest.path_join(".ok"), FileAccess.WRITE)
	if ok == null:
		return "写不了标记：%s" % dest
	ok.store_string("ok")
	ok.close()
	return ""


static func _rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	## 点开头的文件（我们自己的 .ok、运行时里的 .version、mac 的 .DS_Store）默认不列出来：
	## 不带上，目录删不掉、旧的 .ok 留着，下次就把半份当成好的用（2026-10-01 测试重跑撞到）
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)
