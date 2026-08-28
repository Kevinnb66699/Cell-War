extends SceneTree
## 把某个场景渲染几帧后存成 PNG，用来把 Godot 里的真实画面和设计稿逐像素比对。
##
## 这不是测试，是给人看的工具 —— 界面是「照着定稿实现」的活，
## 光看代码看不出对没对上，得把图摆在一起看。所以不并进 headless_test.gd。
##
## **不能加 --headless**，需要真的渲染：
##   godot --path game --script res://tests/screenshot.gd --
##       <输出路径.png> [场景路径] [鼠标x,y] [等待秒数] [点击脚本]
##
## 第三个参数会先把鼠标挪过去再截图 —— 悬停态也是要跟设计稿对的，
## 没有它就只能截到静止态；不需要就填 -1,-1。
## 第四个参数是截图前先让场景自己跑多少秒，用来截对局进行中的画面
## （对局是异步跑的，只等那几帧固化只能截到开局）。
## **可以写成 `1.2,3.4,5.6` 连拍多帧**，文件名自动加后缀 `_1.2.png`。
## 动画（骰子、渐入、抽卡）非连拍不可 —— 一次一帧的话，起一次 Godot 要半分钟，
## 光是碰运气撞上那零点几秒的动画就能把时间耗光。
##
## 第五个参数是「操作脚本」，分号隔开，到点就执行：
##   `x,y@秒数`        在该位置点一下（先挪过去再按，悬停态才会触发）
##   `key:动作名@秒数`  按一次输入动作，如 `key:ui_cancel@7.5`（暂停菜单只能靠 Esc 唤出）
## 交互态（行动栏、目标选择、悬浮框）不点几下根本到不了，而这些恰恰是最需要
## 和设计稿比对的画面。例：`"420,240@1.2;640,500@4.0"`

const WARMUP_FRAMES := 10   ## 等字体光栅化、贴图上传、_ready() 里的布局都落定

var _out := "user://shot.png"
var _scene := "res://scenes/Main.tscn"
var _mouse := Vector2(-1, -1)
var _shots: Array = []   ## 还没拍的时间点，升序
var _steps: Array = []   ## [{ at:秒, pos 或 key }]，按时间顺序
var _frames := 0
var _elapsed := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_scene = args[1]
	if args.size() > 2:
		var xy := args[2].split(",")
		_mouse = Vector2(float(xy[0]), float(xy[1]))
	if args.size() > 3:
		for t in args[3].split(",", false):
			_shots.append(float(t))
	if _shots.is_empty():
		_shots.append(0.0)
	_shots.sort()
	if args.size() > 4 and args[4] != "":
		for step in args[4].split(";", false):
			var parts := step.split("@")
			var at: float = float(parts[1]) if parts.size() > 1 else 0.0
			if parts[0].begins_with("key:"):
				_steps.append({ "at": at, "key": parts[0].substr(4) })
			else:
				var xy := parts[0].split(",")
				_steps.append({ "at": at, "pos": Vector2(float(xy[0]), float(xy[1])) })
	root.add_child(load(_scene).instantiate())


func _process(delta: float) -> bool:
	_frames += 1
	_elapsed += delta
	if _frames == 1 and _mouse.x >= 0:
		## 走 parse_input_event 而不是 warp_mouse：要的是让控件收到 mouse_entered，
		## 光把光标挪过去不会触发。
		var move := InputEventMouseMotion.new()
		move.position = _mouse
		move.global_position = _mouse
		Input.parse_input_event(move)
	while not _steps.is_empty() and _elapsed >= _steps[0]["at"]:
		_do_step(_steps.pop_front())
	if _frames < WARMUP_FRAMES or _elapsed < _shots[0]:
		return false
	var at: float = _shots.pop_front()
	var path := _out
	if not _shots.is_empty() or at != 0.0:
		path = "%s_%s.png" % [_out.trim_suffix(".png"), str(at)]
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	print("截图 %dx%d @%.2fs -> %s (err=%d)"
		% [img.get_width(), img.get_height(), _elapsed, path, err])
	return _shots.is_empty()


func _do_step(step: Dictionary) -> void:
	if step.has("key"):
		for pressed in [true, false]:
			var act := InputEventAction.new()
			act.action = step["key"]
			act.pressed = pressed
			Input.parse_input_event(act)
		print("  按键 %s @ %.2fs" % [step["key"], _elapsed])
		return
	_click_at(step["pos"])


## 先挪过去再按下抬起 —— 只发按下事件的话，悬停态和按钮的 mouse_entered 都不会触发。
func _click_at(pos: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = pos
	move.global_position = pos
	Input.parse_input_event(move)
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		click.position = pos
		click.global_position = pos
		Input.parse_input_event(click)
	print("  点击 %s @ %.2fs" % [pos, _elapsed])
