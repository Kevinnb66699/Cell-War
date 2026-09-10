extends SceneTree
## patch_probe.gd —— 发补丁前的**最后一道闸**：挂上补丁之后，代码真的换了吗？
##
## 只有它能拦住 2026-09-10 那种失败：每一步都报成功，而代码一个字节都没换
## （成因见 `scripts/patch_canary.gd` 的文件头）。
##
## **必须跑在真导出的包上**，不能跑在源码目录 —— 源码目录里本来就是纯文本 `.gd`、
## 没有 `.remap`，那正是被这个坑绕过去的那一档，跑了等于没跑。
##
## 用法（由 `tools/build_patch.sh` 调）：
##   godot --headless --main-pack <基线导出的.pck> --script res://scripts/patch_probe.gd -- <补丁.pck> <期望的补丁号>
##
## **挂载之前一个 `load()` 都不许有**：`load` 会把资源钉进缓存，之后补丁再也盖不上
## （`boot.gd` 那条纪律的反面）。真机上 Boot 也是先挂载、再碰任何游戏类 ——
## 这里的顺序必须和它一样，否则测的就不是同一件事。
##
## 它随客户端包一起发出去（`scripts/` 不在 `exclude_filter` 里），但游戏一次都不会调它。
## 二十行的代价，换的是「热更能不能信」这件事有人真的验过。
const CANARY := "res://scripts/patch_canary.gd"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("用法：--main-pack <基线.pck> --script res://scripts/patch_probe.gd -- <补丁.pck> <期望补丁号>")
		quit(2)
		return
	var patch: String = args[0]
	var want := int(args[1])
	## 基线包里必须**已经有**这个文件：补丁新加的路径在基线里没有 `.remap`，
	## 纯文本那份会被正常加载 —— 那样连坏掉的流水线也能过，这道闸就白设了
	if not (FileAccess.file_exists(CANARY) or FileAccess.file_exists(CANARY + ".remap")):
		printerr("[失败] 基线包里没有 ", CANARY, " —— 这个基线早于探针文件，验不了。")
		printerr("   要么换个更新的基线，要么先发一版完整客户端把探针带出去。")
		quit(3)
		return
	if not ProjectSettings.load_resource_pack(patch, true):
		printerr("[失败] 挂不上补丁包：", patch)
		quit(4)
		return
	var got := int(load(CANARY).BUILD)
	if got == want:
		print("[OK] 补丁真的生效了：探针读回 ", got)
		quit(0)
		return
	printerr("[失败] **补丁挂上了，但代码没换** —— 探针读回 %d，应该是 %d。" % [got, want])
	printerr("   十有八九是导出预设的 script_export_mode 又变回了 1/2（二进制 token）：")
	printerr("   那时包里只有 .gdc 和 .gd.remap，补丁塞的纯文本 .gd 根本没人看。")
	printerr("   见 scripts/patch_canary.gd 的文件头。")
	quit(5)
