extends SceneTree
## 把某个场景渲染几帧后存成 PNG，用来把 Godot 里的真实画面和设计稿逐像素比对。
##
## 这不是测试，是给人看的工具 —— 界面是「照着定稿实现」的活，
## 光看代码看不出对没对上，得把图摆在一起看。所以不并进 headless_test.gd。
##
## **不能加 --headless**，需要真的渲染：
##   godot --path game --script res://tests/screenshot.gd -- <输出路径.png> [场景路径] [鼠标x,y]
##
## 第三个参数会先把鼠标挪过去再截图 —— 悬停态也是要跟设计稿对的，
## 没有它就只能截到静止态。

const WARMUP_FRAMES := 10   ## 等字体光栅化、贴图上传、_ready() 里的布局都落定

var _out := "user://shot.png"
var _scene := "res://scenes/Main.tscn"
var _mouse := Vector2(-1, -1)
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_scene = args[1]
	if args.size() > 2:
		var xy := args[2].split(",")
		_mouse = Vector2(float(xy[0]), float(xy[1]))
	root.add_child(load(_scene).instantiate())


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1 and _mouse.x >= 0:
		## 走 parse_input_event 而不是 warp_mouse：要的是让控件收到 mouse_entered，
		## 光把光标挪过去不会触发。
		var move := InputEventMouseMotion.new()
		move.position = _mouse
		move.global_position = _mouse
		Input.parse_input_event(move)
	if _frames < WARMUP_FRAMES:
		return false
	var img := root.get_texture().get_image()
	var err := img.save_png(_out)
	print("截图 %dx%d -> %s (err=%d)" % [img.get_width(), img.get_height(), _out, err])
	return true
