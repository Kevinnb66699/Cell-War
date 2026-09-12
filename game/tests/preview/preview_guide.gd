extends SceneTree
## 把新手引导面板的几个关键状态各渲染一张 PNG，给「面板好不好看」这种只能看图的问题用。
##
## 不是测试（headless_test.gd 盯结构），是和 tests/screenshot.gd 同路的渲图工具 ——
## **不能加 --headless**，需要真的渲染：
##   godot --path game --script res://tests/preview/preview_guide.gd -- <输出前缀>
##
## 一口气管五个状态（不改进度文件，面板章节直接拨）：
##   s0 欢迎（讲解页：行动框里是桥喂的落子提示、无代做尾巴）
##   s1 第一步：落子（行动框 + 代做尾巴 + 棋盘可落子格的六边形提亮）
##   s2 能量就是生命（通用迁移提示 + 右栏能量行提亮）
##   s3 s1 状态下主按钮的悬停态（描边 1.0 + 提白）
##   s4 第 2 关「进癌组织＝净化」（标题最长的一步，看标题行装不装得下）

const WARMUP := 3.0      ## 开局过场（相机推进 1.55 + 绽开 0.75）+ 字体布局落定
const GAP := 0.6         ## 每个状态：拨完面板等几帧（提亮层每帧现算）再拍

var _prefix := "user://guide_preview"
var _m: CWMatch
var _t := 0.0
var _queue: Array = []   ## [{ at, fn }]，按时间升序


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_prefix = args[0]
	## 渲的是「新玩家的第一观感」：清掉本机引导进度，让面板从第 1 关讲起
	## （真实进度文件由运行方自行备份 / 恢复，见仓库协作约定）
	CWGuideProgress.clear()
	_call(0.0, func() -> void:
		var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
		root.add_child(main_scene)
		## 走真实入口：菜单收起、相机推进、癌组织绽开、教程局装配全套照常
		_m = main_scene.match_node
		main_scene._begin_tutorial(CWData.CancerType.OSTEO))
	_call(WARMUP, func() -> void: _shot("s0"))
	_call(WARMUP + 0.1, func() -> void: _dial(0, 1))
	_call(WARMUP + GAP, func() -> void: _shot("s1"))
	_call(WARMUP + GAP + 0.1, func() -> void: _dial(0, 2))
	_call(WARMUP + GAP * 2, func() -> void: _shot("s2"))
	_call(WARMUP + GAP * 2 + 0.1, func() -> void: _dial(0, 1))
	_call(WARMUP + GAP * 2 + 0.2, func() -> void: _hover_primary())
	_call(WARMUP + GAP * 3, func() -> void: _shot("s3"))
	_call(WARMUP + GAP * 3 + 0.1, func() -> void: _move(Vector2(20, 400)))
	_call(WARMUP + GAP * 3 + 0.2, func() -> void: _dial(1, 0))
	_call(WARMUP + GAP * 4, func() -> void: _shot("s4"))
	_call(WARMUP + GAP * 4 + 0.3, func() -> void: quit())


func _call(at: float, fn: Callable) -> void:
	_queue.append({ "at": at, "fn": fn })
	_queue.sort_custom(func(a, b) -> bool: return a["at"] < b["at"])


func _process(delta: float) -> bool:
	_t += delta
	while not _queue.is_empty() and _t >= _queue[0]["at"]:
		var step: Dictionary = _queue.pop_front()
		step["fn"].call()
	return false


## 拨到第 ch 关第 st 步（只动面板，不写进度、不碰对局）
func _dial(ch: int, st: int) -> void:
	_m._guide._chapter = ch
	_m._guide._step = st
	_m._guide._render()


## 主按钮悬停：给视口喂一条鼠标移动（warp 不触发 mouse_entered）
func _hover_primary() -> void:
	_move(_m._guide._btn.get_global_rect().get_center())


## 只挪鼠标：走 parse_input_event，控件才收得到 mouse_entered / 棋盘才收得到悬停。
## 事件坐标是**窗口系**：渲染窗口（如 1280×720）被拉伸显示 960×540 逻辑画布时按比例放大，
## 直接喂逻辑坐标会落到别的点上——穿到棋盘上还会带出一张格子详情卡（2026-09-10 踩过）
func _move(c: Vector2) -> void:
	var s: Vector2 = Vector2(root.size) / CWView.screen_size()
	var move := InputEventMouseMotion.new()
	move.position = c * s
	move.global_position = c * s
	Input.parse_input_event(move)


func _shot(tag: String) -> void:
	var img := root.get_texture().get_image()
	var path := "%s_%s.png" % [_prefix, tag]
	print("截图 %dx%d -> %s (err=%d)" % [img.get_width(), img.get_height(), path, img.save_png(path)])
