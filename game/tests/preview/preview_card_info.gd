extends SceneTree
## 卡面分档写法高亮的预览图 —— 给人看的工具，不是测试。
##
## 亮字 + 色板在像素字体上好不好看、色板的透明度合不合适，只有真渲染才看得出来。
## 画法：深色底上摆几只手牌详情框 —— 第一行同一张卡（GLUT1）三期各一只，看高亮怎么挪；
## 第二行三张写法各异的卡（带正号 / 带空格与小数 / 多行正文里的一档）；
## 第三行两张对照：【代谢耦联】（自由选择，不标）与【DNA损伤修复】。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_card_info.gd -- <输出.png>
const WARMUP := 10

## [卡名, 分期, 摆放位置]
const SHOW: Array = [
	["GLUT1高表达", 0, Vector2(8, 8)], ["GLUT1高表达", 1, Vector2(324, 8)], ["GLUT1高表达", 2, Vector2(640, 8)],
	["基质硬化", 0, Vector2(8, 120)], ["肿瘤血管生成", 2, Vector2(324, 120)], ["癌症干性", 1, Vector2(640, 120)],
	["代谢耦联", 1, Vector2(8, 300)], ["DNA损伤修复", 1, Vector2(324, 300)],
]

var _out := "user://card_info.png"
var _boxes: Array = []
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	for s in SHOW:
		var box := CWCardInfo.new()
		root.add_child(box)
		box.on_hover(s[0])
		_boxes.append(box)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		## sync 一次让它搭好内容（DELAY 之后才浮出），再各自挪到展示位 —— 之后不再 sync，位置就不会被摆位逻辑抢回去
		for i in SHOW.size():
			var box: CWCardInfo = _boxes[i]
			box.sync(CWCardInfo.DELAY + 0.1, CWData.Faction.CANCER, false, int(SHOW[i][1]))
			box.position = SHOW[i][2]
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
