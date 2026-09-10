extends SceneTree
## 设置页的「检查更新」那一块 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这一块和上面三行拨值行长得不一样（一行可点的字 + 一行状态小字，
## 没有箭头没有值），而面板高度、辉光位置、状态行会不会顶到底部提示，
## 都是算出来的数。三种状态的字长差很多，最长那句尤其容易溢出。
##
## 四张（都摆在真主菜单上，不是平底色 —— 见记忆「界面预览必须画全常驻件」）：
##   <输出>_idle.png     停在更新行上，还没点
##   <输出>_busy.png     正在下载
##   <输出>_ready.png    下好了，那行变成「立即重启」，小字在数秒
##   <输出>_toold.png    最长的一句：基线太老，要下完整包
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_settings_update.gd -- <输出前缀>
const WARMUP := 16

var _out := "user://settings_update"
var _frames := 0
var _shot := 0
var _page: CWSettingsPage


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(scene)
	_page = CWSettingsPage.new()
	_page.allow_update = true        ## 必须在进树之前置：_ready 按它决定建不建那一块
	(scene.get_node("MainMenu/UI") as CanvasLayer).add_child(_page)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_page.open()
		_page._sel = _page._rows().size()    ## 焦点停在更新行上
		_page._repaint()
		return false
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	## 面板宽 264、居中，四周各留一点看得见底下的菜单；2× 放大好读小字
	var strip := img.get_region(Rect2i(330, 150, 300, 240))
	strip.resize(600, 480, Image.INTERPOLATE_NEAREST)
	match _shot:
		0:
			strip.save_png(_out + "_idle.png")
			print("已保存 ", _out, "_idle.png（停在更新行上）")
			_page._say(CWSettingsPage.UPD_NOTES["downloading"])
		1:
			strip.save_png(_out + "_busy.png")
			print("已保存 ", _out, "_busy.png（正在下载）")
			_page._upd_ready = true
			_page._say(CWSettingsPage.UPD_NOTES["armed"] % [202609100826, CWSettingsPage.RESTART_DELAY])
		2:
			strip.save_png(_out + "_ready.png")
			print("已保存 ", _out, "_ready.png（下好了，正在数秒自动重启）")
			_page._upd_ready = false
			_page._say(CWSettingsPage.UPD_NOTES["too_old"])
		3:
			strip.save_png(_out + "_toold.png")
			print("已保存 ", _out, "_toold.png（最长的一句）")
			return true
	_shot += 1
	_frames = WARMUP - 3
	return false
