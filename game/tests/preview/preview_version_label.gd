extends SceneTree
## 主菜单右下角那行版本号 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：2026-09-10 这一行从「v0.1.0」变成「v0.1.0 · 基线 + 补丁」，
## 盒子也跟着从 127 加宽到 217（`MainMenu.tscn` 的 `Ver`）。它是**右对齐**的，
## 装不下时不会截断、会直接往左溢出到画布外 —— 而右边正是版本号该待的角落，
## 左边还压着菜单项与装饰细胞。这种事测试只能量宽度，压没压到别人只有看图才知道。
##
## 出的是**真主菜单**（连装饰细胞、Logo、菜单项一起），不是平底色 ——
## 平底色的排版预览在这仓库骗过三次（见记忆「界面预览必须画全常驻件」）。
##
## 两张：装了补丁的最长一档、没装补丁的常态。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_version_label.gd -- <输出前缀>
const WARMUP := 24
## 最长的一档：基线 + 补丁都写满，补丁取当天最晚的 23:59
const LONGEST := ["0.1.0", 202609100730, 202609102359]

var _out := "user://version_label"
var _frames := 0
var _shot := 0
var _ver: Label


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(scene)
	_ver = scene.get_node("MainMenu/UI/Screen/Ver")


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 1:
		## `_ready` 已经按本机的真实基线写过一次；这儿改成最长的那一档
		_ver.text = (load("res://scripts/ui/main_menu.gd") as GDScript).version_text(
			String(LONGEST[0]), int(LONGEST[1]), int(LONGEST[2]))
		return false
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	## 右下角那块（连左边的菜单项一起裁进来，好看清有没有压上去），2× 放大
	var strip := img.get_region(Rect2i(480, 470, 480, 70))
	strip.resize(480 * 2, 70 * 2, Image.INTERPOLATE_NEAREST)
	img.blit_rect(strip, Rect2i(0, 0, strip.get_width(), strip.get_height()),
		Vector2i(0, 0))
	match _shot:
		0:
			img.save_png(_out + "_long.png")
			print("已保存 ", _out, "_long.png（最长一档：基线 + 补丁）")
			_ver.text = (load("res://scripts/ui/main_menu.gd") as GDScript).version_text(
				"0.1.0", 202609100730, 0)
		1:
			img.save_png(_out + "_plain.png")
			print("已保存 ", _out, "_plain.png（没装补丁：只有基线）")
			return true
	_shot += 1
	_frames = WARMUP - 3
	return false
