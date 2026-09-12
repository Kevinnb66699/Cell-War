extends SceneTree
## 配置面板的排版对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：测试只守得住「按钮不出屏、不压到最后一行」这两条硬约束，
## 守不住「看起来挤不挤」。2026-09-08 加「世界事件」行时行距由 32 收到 28、
## 普通局按钮由 438 挪到 480，这类改动只能把图摆出来看。
##
## 两张：普通对局（左栏 N_ROWS 行）与 6 人自定义（多 3 个癌席，最挤的一档）。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_config.gd -- <输出.png>
const WARMUP := 14

var _out := "user://config.png"
var _panel: CWConfigPanel
var _frames := 0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_panel = CWConfigPanel.new()
	root.add_child(_panel)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_panel.open()
	## **等淡入真的走完再拍**，别数帧：`open()` 是 0.32 秒的**时间**补间，
	## 而这个循环不吃 vsync，一帧可能只有几毫秒 —— 数十几帧只等到 0.1 秒，
	## 拍下来整块 `modulate.a` 才 0.3，图里的字全是半透明的
	## （2026-09-09 Kevin 一句「为什么这图片里面的字这么淡」才揭穿）
	if _frames < WARMUP or _panel.modulate.a < 1.0:
		return false
	var img := root.get_texture().get_image()
	if _shot == 0:
		img.save_png(_out)
		print("已保存 ", _out, "（普通对局）")
		## 第二张：6 人自定义 —— 左栏 N_ROWS 行 + 3 个癌席，行距被屏高逼到最紧
		_panel.custom = true
		_panel.open()
		_panel._players = 6
		_panel._repaint()
		_shot += 1
		_frames = WARMUP - 4     ## 再等几帧让布局落定
		return false
	img.save_png(_out.get_basename() + "_custom6.png")
	print("已保存 ", _out.get_basename() + "_custom6.png（6 人自定义）")
	return true
