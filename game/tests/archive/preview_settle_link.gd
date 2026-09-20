extends SceneTree
## 结算屏底部那一行：小字 + 「看这局回放」链接 + 两颗按钮 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：issue #7（2026-09-10）报的就是这条链接「错位」——
## 它原来摆在按钮**下面** 8px，而按钮底边正是横幅留出的下内边距，
## 于是整条压在横幅那道底描边上，看着半截出了框。这种「差了一个内边距」
## 的毛病读代码看不出来，量坐标也只有摆出来才知道该量哪一条。
##
## 两张（本地局的按钮和联机局的**不一样宽**，链接得跟着让）：
##   <输出>_local.png　 再来一局 / 同样人数 · 新种子
##   <输出>_online.png　回到等待室 / 房主可再开一局
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/archive/preview_settle_link.gd -- <输出前缀>
const WARMUP := 10

var _out := "user://settle_link"
var _frames := 0
var _shot := 0
var _screen: CWSettleScreen
var _game: CWGame


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	## 造一个像样的终局：光 build_board() 是 127 格全健康，条会空着、数字全 0
	_game = CWGame.new()
	_game.init(CWData.FACTION_ORDER[4], 7)
	_game.setup.build_board()
	_game.winner = CWData.Faction.CANCER
	_game.win_kind = "cancer_weighted"
	_game.round_no = 12
	var coords := CWData.all_coords()
	for k in 47:
		_game.tiles[coords[k]]["tissue"] = CWData.Tissue.CANCER
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = CWView.screen_size()
	layer.add_child(bg)
	_screen = CWSettleScreen.new()
	layer.add_child(_screen)


func _process(_d: float) -> bool:
	_frames += 1
	## 摆状态要等第一帧：`_initialize` 跑在场景树立起来之前，`_ready` 还没轮到
	if _frames == 1:
		_screen.show_result(_game)
		_screen.skip()          ## 五拍演出一步到底，别跟它赛跑
		return false
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	## 只要底部那一条（横幅底边往上 90px），2× 放大好逐像素看有没有压到描边
	var y0 := int(CWSettleScreen.BANNER_Y + CWSettleScreen.BANNER_H) - 90
	var strip := img.get_region(Rect2i(0, y0, CWSettleScreen.BANNER_W, 96))
	strip.resize(CWSettleScreen.BANNER_W, 96 * 2, Image.INTERPOLATE_NEAREST)
	match _shot:
		0:
			img.blit_rect(strip, Rect2i(0, 0, strip.get_width(), strip.get_height()),
				Vector2i(0, 0))
			img.save_png(_out + "_local.png")
			print("已保存 ", _out, "_local.png（本地局：再来一局）")
			_screen.online = true
			_screen.show_result(_game)
			_screen.skip()
		1:
			img.blit_rect(strip, Rect2i(0, 0, strip.get_width(), strip.get_height()),
				Vector2i(0, 0))
			img.save_png(_out + "_online.png")
			print("已保存 ", _out, "_online.png（联机局：回到等待室，按钮更宽）")
			_game.dispose()
			return true
	_shot += 1
	_frames = WARMUP - 3
	return false
