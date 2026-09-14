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
##   godot --headless --main-pack <基线导出的.pck> --script res://scripts/patch_probe.gd -- <补丁.pck> <期望的补丁号> [<资源清单>]
##
## **第三个参数是资源核对清单**（2026-09-14 加）：打包器写的 `<补丁.pck>.assets`，
## 一行「源路径|导入产物路径|产物SHA-256」。美术资源和代码是两条独立的通路 ——
## 代码换没换看探针文件，资源换没换只能逐个核对产物的字节，外加 `load()` 真读得出来。
## 少了这一档，美术那一半就回到了「每步报成功、画面没变」的老路。
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
	var assets_list: String = args[2] if args.size() > 2 else ""
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
	if got != want:
		printerr("[失败] **补丁挂上了，但代码没换** —— 探针读回 %d，应该是 %d。" % [got, want])
		printerr("   十有八九是导出预设的 script_export_mode 又变回了 1/2（二进制 token）：")
		printerr("   那时包里只有 .gdc 和 .gd.remap，补丁塞的纯文本 .gd 根本没人看。")
		printerr("   见 scripts/patch_canary.gd 的文件头。")
		quit(5)
		return
	## 资源那一半：逐条核对「产物的字节换了没有」+「源路径 load 得出来」。
	## 两条都要：只核字节的话，新增资源漏带 `.import` 也能过（产物在、没人找得到它）
	var bad := 0
	if assets_list != "":
		if not FileAccess.file_exists(assets_list):
			## 打包器**每次都写**这个文件（没有资源就是空的），所以读不到只有一种解释：流水线坏了
			printerr("[失败] 读不到资源核对清单 ", assets_list, " —— 打包那一步没写出来")
			quit(6)
			return
		for line in _lines(assets_list):
			var f := line.split("|")
			if f.size() != 3:
				continue
			var src: String = f[0]
			var made: String = f[1]
			var want_sha: String = f[2]
			var got_sha := _sha256(made)
			if got_sha != want_sha:
				printerr("[失败] 资源没换：%s 的产物 %s" % [src, made])
				printerr("   包里是 %s，补丁里应该是 %s" % [got_sha.substr(0, 16), want_sha.substr(0, 16)])
				bad += 1
				continue
			if load(src) == null:
				printerr("[失败] 产物换了、却读不出来：%s（多半是漏带了 .import）" % src)
				bad += 1
				continue
			print("  资源 OK ", src)
		if bad > 0:
			printerr("[失败] %d 份资源没生效 —— 包没上传。" % bad)
			quit(6)
			return
	if got == want:
		print("[OK] 补丁真的生效了：探针读回 ", got)
		quit(0)
		return
	quit(5)


## 清单文件的每一行（读的是**磁盘路径**：清单跟补丁包放在一起，不在 res:// 里）
func _lines(path: String) -> PackedStringArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedStringArray()      ## 存在性上面已经查过，这里只是兜底
	## 用 char(10) 而不是写转义：这个文件几次落盘都走 heredoc，而 heredoc 会吃掉反斜杠
	return f.get_as_text().strip_edges().split(char(10), false)


## 挂载之后，这个 res:// 路径上的文件的 SHA-256（读的是补丁盖过之后那一份）
func _sha256(res_path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	ctx.update(f.get_buffer(f.get_length()))
	return ctx.finish().hex_encode()
