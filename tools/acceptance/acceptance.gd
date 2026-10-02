## tools/acceptance/acceptance.gd —— 真机验收驱动：在**导出的发布包**里跑真产品代码，逐项报通过 / 失败
##
##   <导出的可执行文件> --headless --script <本文件的绝对路径> -- [steps=a,b,c] [server=ws://HOST:PORT] [out=<结果文件>]
##
## 跑法与 tools/export_check_sidecar.gd 相同（导出包认 --headless --script 绝对路径）。用法细节见同目录 README.md。
## 三条约束：
##   · 导出预设排除了 res://tests/*（game/export_presets.cfg）——这里**一个 res://tests 都不许 load**；
##     要用的测试辅助逻辑抄进本目录（见 step_tutorial.gd 头注），本目录的文件按本文件的位置用绝对路径 load；
##   · 不加 class_name：这几个文件不在工程里，导出包的全局类表里没有它们；
##   · 用户目录换到 CellWar-acceptance/（同 tools/patch_sidecar_probe.gd），开跑前清空 —— 不碰本机真玩家的存档 / 进度 / 解包目录，
##     sidecar 也就每次都从 pck 现解一遍（unpack 那一项验的就是这一步）。
##     本文件因此**不直接写任何产品类名**：脚本一编译就会把那些类 load 进来，得等用户目录换好之后再碰它们（都在步骤文件里）。
## 每一项一行「[通过] step …」或「[失败] step …: 原因」，最后一行「ACCEPTANCE: PASS x/y」或「ACCEPTANCE: FAIL x/y」，退出码 0 / 1。
## 给了 out= 就把这些行同样写进那个文件 —— Windows 的发布版 exe 是窗口程序、没有控制台，结果只能从这个文件看。
## 每一项开跑前文件里先落一行「# 开始 step …」：**发布包里 GDScript 不做大部分运行时检查**（越界、缺键静默，
## 对 null 调方法直接段错误退出），进程崩了就没有最后那行 ACCEPTANCE —— 看最后一行「# 开始」就知道崩在哪一项。
extends SceneTree

const USER_DIR_NAME := "CellWar-acceptance"
const DEFAULT_STEPS := ["unpack", "hotseat", "solo_normal", "solo_intent", "solo_search", "spectate", "save_continue", "tutorial"]
const NET_STEPS := ["online", "web_solo"]
## 步骤名 → [步骤文件, 上限秒数]。上限按 Mac 实测的五到十倍给：Windows 11 ARM 上 x64 包是模拟跑的，慢几倍也不该误报
const STEPS := {
	"unpack": ["steps_local.gd", 180],
	"hotseat": ["steps_local.gd", 240],
	"solo_normal": ["steps_local.gd", 300],
	"solo_intent": ["steps_local.gd", 300],
	"solo_search": ["steps_local.gd", 420],
	"spectate": ["steps_local.gd", 300],
	"save_continue": ["steps_local.gd", 420],
	"tutorial": ["step_tutorial.gd", 900],
	"online": ["steps_net.gd", 300],
	"web_solo": ["steps_net.gd", 300],
}
## 判了超时之后再给这一项多久自己收手（它的每个等待都看 ctx 的截止时刻，一般一帧就停）
const GRACE_MS := 3000


## 每一项里出的 SCRIPT ERROR / ERROR 记到这儿（Godot 4.5 的 Logger；引擎可能从别的线程报，所以上锁）。
## 发布包里 SCRIPT ERROR 多半报不出来（见头注），能稳定抓到的是产品代码的 push_error 与引擎自己的 ERROR
class ErrorTap extends Logger:
	var _lock := Mutex.new()
	var _rows: Array = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_lock.lock()
		_rows.append({ "type": error_type, "text": rationale if rationale != "" else code, "at": "%s:%d %s" % [file, line, function],
			"pushed": function == "push_error" })
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	## 取走到此刻为止记下的（取完清空）
	func take() -> Array:
		_lock.lock()
		var out := _rows
		_rows = []
		_lock.unlock()
		return out


var _args := {}
var _lines: PackedStringArray = []
var _tap := ErrorTap.new()
var _modules := {}       ## 步骤文件名 → 实例（同一个文件的几项共用一个）
var _passed := 0
var _total := 0


func _initialize() -> void:
	_args = _parse_args(OS.get_cmdline_user_args())
	if not _isolate_user_dir():
		_emit("[失败] step setup: 换不到独立的用户目录（现在是 %s）—— 不往下跑，免得碰到真玩家的数据" % OS.get_user_data_dir())
		_emit("ACCEPTANCE: FAIL 0/1")
		quit(1)
		return
	OS.add_logger(_tap)
	_run.call_deferred()


func _run() -> void:
	await process_frame   ## _initialize 里 root 还不在树里：先让一帧，挂上去的主场景才拿得到视口、补间才会走
	var steps := _steps_wanted()
	_emit("# Cell War 验收 · %s · %s · %s · 用户目录 %s" % [OS.get_name(), Engine.get_architecture_name(),
		"导出包" if OS.has_feature("template") else "编辑器", OS.get_user_data_dir()])
	if OS.get_environment("CW_KERNEL") == "gd":
		_emit("# 注意：环境变量 CW_KERNEL=gd 把新开局强制到 GD 内核上，要验 sidecar 的那几项会失败")
	for name in steps:
		if not STEPS.has(name):
			_record(name, false, "没有这一项（可选：%s）" % ", ".join(PackedStringArray(STEPS.keys())), [])
			continue
		if name in NET_STEPS and String(_args.get("server", "")) == "":
			_record(name, false, "要给 server=ws://HOST:PORT", [])
			continue
		await _run_step(name)
	_sidecar_class().shutdown_idle_links()
	var ok := _passed == _total
	_emit("ACCEPTANCE: %s %d/%d" % ["PASS" if ok else "FAIL", _passed, _total])
	quit(0 if ok else 1)


## 跑一项：在协程里起这一项，自己按它的上限盯着；到点就判超时、让它收手。不管过没过，最后都把它建的场景与连接收干净
func _run_step(name: String) -> void:
	var spec: Array = STEPS[name]
	var mod = _module(String(spec[0]))
	var ctx := { "deadline": Time.get_ticks_msec() + int(spec[1]) * 1000, "cancelled": false, "notes": [],
		"main": null, "clients": [], "done": false, "why": "" }
	_emit("# 开始 step %s（上限 %d s）" % [name, int(spec[1])])
	_tap.take()
	var t0 := Time.get_ticks_msec()
	_launch(mod, "step_" + name, ctx)
	while not bool(ctx["done"]) and Time.get_ticks_msec() < int(ctx["deadline"]) + GRACE_MS:
		await process_frame
	var why := String(ctx["why"])
	if not bool(ctx["done"]):
		ctx["cancelled"] = true
		why = "超过 %d s 上限还没走完" % int(spec[1])
	## 判失败的两种：SCRIPT ERROR；产品代码自己 push_error 的（那十几处都是真故障：镜像装不进、sidecar 出错、
	## 掷骰等 ack 超时、教程关装不出来）。引擎内部的 ERROR（界面节点的 ERR_FAIL 之类）只记在说明里，不判失败
	var errors: Array = _tap.take()
	var fatal := errors.filter(func(e: Dictionary) -> bool:
		return int(e["type"]) == Logger.ERROR_TYPE_SCRIPT or (int(e["type"]) == Logger.ERROR_TYPE_ERROR and bool(e["pushed"])))
	var others := errors.filter(func(e: Dictionary) -> bool: return int(e["type"]) == Logger.ERROR_TYPE_ERROR and not bool(e["pushed"]))
	if why == "" and not fatal.is_empty():
		why = "出了 %d 条 SCRIPT ERROR / push_error，第一条：%s（%s）" % [fatal.size(), fatal[0]["text"], fatal[0]["at"]]
	var notes: Array = ctx["notes"]
	notes.append("%.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if not others.is_empty():
		notes.append("另有 %d 条引擎 ERROR，第一条：%s（%s）" % [others.size(), others[0]["text"], others[0]["at"]])
	_record(name, why == "", why, notes)
	await _cleanup(ctx)


## 起这一项的协程，结果写回 ctx（返回空串 = 通过）。判过超时之后才回来的结果不再算数
func _launch(mod: Object, method: String, ctx: Dictionary) -> void:
	var why: String = await mod.call(method, ctx)
	if bool(ctx["cancelled"]):
		return
	ctx["why"] = why
	ctx["done"] = true


## 收掉这一项留下的一切：对局拆掉、主场景释放、联机连接断开、树解冻、sidecar 空闲链路关掉。
## 「这一次运行里起不来过」的记忆也清掉 —— 不然前一项起不来，后面每一项都会静默走 GD，报出来的就不是它们自己的毛病
func _cleanup(ctx: Dictionary) -> void:
	paused = false
	var main_scene = ctx["main"]
	if main_scene != null and is_instance_valid(main_scene):
		var m = main_scene.match_node
		if m != null and m.kernel != null:
			m.teardown()
		main_scene.queue_free()
	for c in ctx["clients"]:
		c.dispose()
	await process_frame
	await process_frame
	var sc = _sidecar_class()
	sc.shutdown_idle_links()
	sc.start_failure = {}


func _record(name: String, ok: bool, why: String, notes: Array) -> void:
	_total += 1
	if ok:
		_passed += 1
	var tail := "（%s）" % "；".join(PackedStringArray(notes)) if not notes.is_empty() else ""
	_emit(("[通过] step %s%s" % [name, tail]) if ok else ("[失败] step %s: %s%s" % [name, why, tail]))


## 打到控制台、同时（给了 out= 的话）整份重写结果文件：中途崩了，文件里也留着已经跑完的那几行
func _emit(line: String) -> void:
	print(line)
	_lines.append(line)
	var out := String(_args.get("out", ""))
	if out == "":
		return
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		printerr("结果文件写不了：%s（%s）" % [out, error_string(FileAccess.get_open_error())])
		return
	f.store_string("\n".join(_lines) + "\n")
	f.close()


func _module(file: String) -> Object:
	if not _modules.has(file):
		var mod = load(get_script().resource_path.get_base_dir().path_join(file)).new()
		mod.t = self
		mod.server = String(_args.get("server", ""))
		_modules[file] = mod
	return _modules[file]


func _sidecar_class() -> Script:
	return load("res://scripts/kernel/cw_kernel_sidecar.gd")


## 要跑哪几项：steps= 点名就按点名的顺序，否则缺省那八项（给了 server= 再加联机两项）
func _steps_wanted() -> Array:
	var named := String(_args.get("steps", ""))
	if named != "":
		return Array(named.split(",", false)).map(func(s: String) -> String: return s.strip_edges())
	var out: Array = DEFAULT_STEPS.duplicate()
	if String(_args.get("server", "")) != "":
		out.append_array(NET_STEPS)
	return out


static func _parse_args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for a in raw:
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			out[kv[0].strip_edges()] = kv[1].strip_edges()
	return out


## user:// 换到 CellWar-acceptance/ 并清空（同 tools/patch_sidecar_probe.gd：运行时改工程设置即生效，目录自己建）。
## 清之前先核：真换过去了才清 —— 没换成功时 get_user_data_dir() 指的就是玩家自己的目录
func _isolate_user_dir() -> bool:
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", USER_DIR_NAME)
	var dir := OS.get_user_data_dir()
	if dir.get_file() != USER_DIR_NAME:
		return false
	_rm_rf(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	return DirAccess.dir_exists_absolute(dir)


## 连点开头的文件一起删（sidecar 解包目录里有 .ok / .version，见 cw_sidecar_locator.gd:_rm_rf 的注释）
static func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		if d.is_link(sub):
			d.remove(sub)   ## 软链只摘链接本身，不顺着删到这个目录外面去
			continue
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)
