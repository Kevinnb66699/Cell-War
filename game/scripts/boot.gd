extends Node
## 启动器 —— 先把补丁包挂上，再进主场景。这是 `run/main_scene`。
##
## ## 为什么非得有这一层
##
## 客户端包 94 MB，其中约 88 MB 是 Godot 运行时，几乎从不变；每天真正改的
## 只有几十 KB 的脚本。`ProjectSettings.load_resource_pack()` 能用一个补丁包
## **按 res:// 路径覆盖**原包里的文件，于是发版不必再重传整个运行时。
##
## ## 两条硬约束（都是实测出来的，不是查文档来的）
##
## ① **挂载必须早于游戏代码的首次 load。** GDScript 一旦 load 过就进缓存，
##    之后再挂包也换不掉 —— 实测「先 load 再挂」拿到的仍是旧版。
## ② **本文件与它引用的一切，都不许碰游戏里的类**（`CWData` / `CWStyle` / …）。
##    引用谁，谁就在挂载前被解析进缓存，等于把游戏本体钉死在旧版上。
##    第一次做实验时启动脚本引用了被补丁覆盖的类，Godot 直接**挂死**。
##    所以这里只 preload 一个同样自包含的 `patch_state.gd`，别的一律不碰。
##
## ## 补丁改不动什么（要动就得全量发版）
##
## · **新增 `class_name`** —— 全局类表在导出时就烘死了，补丁里新加的类名
##   会报 `Identifier "X" not declared`。新脚本想热更就别给 class_name，
##   改用 `preload("res://…gd")` 按路径引用。
## · `project.godot` 的设置（自动加载、输入映射、窗口）—— 引擎启动时就读完了。
## · Godot 版本 / 导出模板。
##
## 第一阶段（2026-09-09）**不联网**：补丁靠手工放进 `user://patch/current.pck`，
## 指纹记在 `state.cfg` 里。下载与 manifest 是第二阶段的事。

const PatchState := preload("res://scripts/patch_state.gd")
const MAIN_SCENE := "res://scenes/Main.tscn"

var _note: Label


func _ready() -> void:
	_build_note()
	var msg := _apply_patch()
	if msg != "":
		## 只在出岔子时露一句 —— 正常启动不该多一屏「正在检查更新」
		_note.text = msg
		await get_tree().create_timer(2.5).timeout
	get_tree().change_scene_to_file(MAIN_SCENE)


## 返回要给玩家看的话；空串 = 一切正常，别打扰他。
func _apply_patch() -> String:
	## 上次带着补丁启动却没活到 mark_good：那个补丁有问题（坏补丁会让 Godot **挂死**，
	## 不是抛异常，所以只能靠这面「上次没放下的旗子」认出来）。挪开跑原版。
	if PatchState.boot_failed():
		PatchState.quarantine()
		return "上次的更新没能正常启动，已回退到原版"
	if not FileAccess.file_exists(PatchState.PCK):
		return ""
	## 补丁是**可执行代码**：挂之前必须核对指纹，对不上就当它被换过
	var want := PatchState.installed_sha()
	var got := PatchState.sha256_of(PatchState.PCK)
	if want == "" or got != want:
		PatchState.quarantine()
		return "更新文件校验失败，已回退到原版"
	if not ProjectSettings.load_resource_pack(PatchState.PCK, true):
		PatchState.quarantine()
		return "更新包无法加载，已回退到原版"
	## 立旗 → 换场景 → 活过 PROVE_SEC 才由**静态**回调放下。
	## 不能绑在本节点上：换场景之后它就被释放了，实例回调不会触发。
	PatchState.mark_pending()
	get_tree().create_timer(PatchState.PROVE_SEC).timeout.connect(PatchState.mark_good)
	return ""


## 一行字，居中。**不用 CWStyle** —— 那是游戏里的类，见文件头第 ② 条。
func _build_note() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color("141f2e")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	_note = Label.new()
	_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_note.add_theme_font_override("font",
		load("res://assets/fonts/fusion_pixel_10px.ttf") as Font)
	_note.add_theme_font_size_override("font_size", 20)
	_note.add_theme_color_override("font_color", Color("eaf8fc"))
	layer.add_child(_note)
