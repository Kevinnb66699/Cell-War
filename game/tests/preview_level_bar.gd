extends SceneTree
## 右栏「免疫等级」块的升级进度条 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这一块高度写死 44px（文件头那条「一个数都别改」是硬的，
## 6 人局五块合计 530、只余 10px），条只能长在文字**墨迹**底下那道缝里。
## 缝有多宽、条压没压到字，只能把三档摆出来看。
##
## 三块面板并排（都用 6 人局，那是最挤的一档）：
##   I 级 3/10（刚开局）· II 级 18/20（快升了）· X 级（没有下一级，条收起）
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_level_bar.gd -- <输出.png>
const WARMUP := 20
const STATES := [
	{ "lv": 0, "mem": 3, "cap": "I 级 · 3 / 10（刚开局）" },
	{ "lv": 1, "mem": 18, "cap": "II 级 · 18 / 20（快升了）" },
	{ "lv": 3, "mem": 25, "cap": "X 级 · 没有下一级，条收起" },
]

var _out := "user://level_bar.png"
var _frames := 0
var _panels: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	for i in STATES.size():
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[6], 1)
		g.setup.build_board()
		g.round_no = 12
		g.immune_level = int(STATES[i]["lv"])
		g.memory = int(STATES[i]["mem"])
		var p := CWMatchPanel.new()
		root.add_child(p)
		p.refresh(g)
		_panels.append(p)


func _process(_d: float) -> bool:
	_frames += 1
	## 位置每帧摆：`_ready` 会把面板钉回 RECT（696,0），而这儿要三块并排
	for i in _panels.size():
		(_panels[i] as Control).position = Vector2(i * 320.0, 0)
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	## 三块的「免疫等级」区各裁一条，竖着摞起来放大，好逐像素看条压没压到字
	var y0 := int((_panels[0] as CWMatchPanel)._level_y) - 4
	var zoom := Image.create(264 * 2, STATES.size() * 52 * 2, false, img.get_format())
	for i in _panels.size():
		var one := img.get_region(Rect2i(i * 320, y0, 264, 52))
		one.resize(264 * 2, 52 * 2, Image.INTERPOLATE_NEAREST)
		zoom.blit_rect(one, Rect2i(0, 0, one.get_width(), one.get_height()),
			Vector2i(0, i * 52 * 2))
	## 放大图摆右上：三块面板的「免疫等级」在 y 418，摆下面会把它自己盖住
	img.blit_rect(zoom, Rect2i(0, 0, zoom.get_width(), zoom.get_height()),
		Vector2i(960 - zoom.get_width(), 0))
	img.save_png(_out)
	print("已保存 ", _out)
	return true
