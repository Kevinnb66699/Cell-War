## tools/patch_sidecar_probe.gd —— 补丁探针的 sidecar 一档（换内核 P7，tools/build_patch.sh 调）：
## 挂上补丁之后，**真会被起起来的那份规则 dll** 是不是这次打的？
##
##   godot --headless --main-pack <基线导出的.pck> --script <本文件的绝对路径> -- <补丁.pck> <期望的 core_build>
##
## 走玩家那条真路：挂补丁 → 用（补丁里的）定位器把 pck 里的运行时与载荷解到一个临时用户目录 →
## 拿解出来的 dotnet 跑 `--version` 读回 core_build，再跑 `--selftest` 打一小局。
## 读回的不是这次的 = 压进了旧 dll / 补丁没盖住载荷 —— 退出码非 0，build_patch.sh 停在上传之前。
##
## 与 scripts/patch_probe.gd 同一条纪律：**挂载之前一个 load() 都不许有**（load 会把资源钉进缓存，补丁再也盖不上）。
## 用户目录改到 CellWar-patch-probe/，跑完删掉 —— 不碰本机真玩家的 user://sidecar/。
extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("用法：--main-pack <基线.pck> --script <本文件> -- <补丁.pck> <期望的 core_build>")
		quit(2)
		return
	var want: String = args[1]
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", "CellWar-patch-probe")
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	if not ProjectSettings.load_resource_pack(args[0], true):
		_fail(4, "挂不上补丁包：%s" % args[0])
		return
	var Loc = load("res://scripts/kernel/cw_sidecar_locator.gd")
	if Loc == null:
		_fail(3, "基线包里没有 sidecar 定位器 —— 这个基线还没带 sidecar，验不了")
		return
	Loc._rm_rf(Loc.USER_DIR)
	var r: Dictionary = Loc.unpack()
	if r.has("error"):
		_fail(5, "挂上补丁后解包失败：%s" % String(r["error"]))
		return
	var got := _core_build(String(r["dotnet"]), String(r["dll"]))
	if got != want:
		_fail(6, "**补丁挂上了，但跑起来的规则 dll 不是这次的** —— 读回 core_build「%s」，应该是「%s」。" % [got, want]
			+ "\n   多半是 game/sidecar/payload/ 里留着上一次的 dll（打包那步没重编），或补丁没带上 payload/。")
		return
	var out: Array = []
	var code := OS.execute(String(r["dotnet"]), ["exec", String(r["dll"]), "--selftest"], out, true)
	if code != 0:
		_fail(7, "新载荷的 --selftest 没过（退出码 %d）：%s" % [code, "".join(out).strip_edges().right(400)])
		return
	Loc._rm_rf(Loc.USER_DIR)
	print("[通过] 补丁里的规则 dll 跑得起来：core_build %s，--selftest 通过" % got)
	quit(0)


## 跑 `--version`，取 JSON 里的 core_build（读不出返回空串）
func _core_build(dotnet: String, dll: String) -> String:
	var out: Array = []
	if OS.execute(dotnet, ["exec", dll, "--version"], out, true) != 0:
		return ""
	for line in "".join(out).split("\n"):
		var v = JSON.parse_string(line) if line.strip_edges().begins_with("{") else null
		if v is Dictionary:
			return String(v.get("core_build", ""))
	return ""


func _fail(code: int, msg: String) -> void:
	printerr("[失败] ", msg)
	quit(code)
