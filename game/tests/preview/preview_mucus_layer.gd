extends SceneTree
## 自爆之后**地上留下的那层黏液** —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这一层是叠在组织贴图上的色标，而癌组织本身就是洋红、
## 固化会压暗、骨化在脉冲 —— 一个新色标读不读得出来、会不会和它们混成一片，
## 只有把真棋盘摆出来才知道。平底色预览在这仓库骗过三次
## （见记忆「界面预览必须画全常驻件」）。
##
## 跑的是**真对局**（Main.tscn + CWMatch.start），所以走的是线上那条
## `_process → _sync_tiles → board.set_marks` 的路，不是另搭一套。
##
## 两张：
##   <输出>_fresh.png　刚炸完：半径 2 一圈黏液，中间几格已转成癌组织
##   <输出>_mixed.png　黏液格上再叠一格骨化倒计时（两个状态撞在一起时谁压谁）
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_mucus_layer.gd -- <输出前缀>
const WARMUP := 90           ## 色标是排队淡入的（ring_delays），要等它整片铺完再拍
const CENTER := Vector2i(0, 0)

var _out := "user://mucus_layer"
var _frames := 0
var _shot := 0
var _scene: Node
var _match: CWMatch


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_scene = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_scene)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_match = _scene.get_node("Match")
		_match.human_players = []          ## 全交给 AI，别停在「请落子」那一问上
		_match.player_count = 4
		_match.start()
		_scene._look(1.0)                  ## 镜头推到对局机位（菜单机位看不到棋盘中央）
		## 菜单是和棋盘共用同一个场景的，不收掉的话 Logo 和菜单项直接压在棋盘上。
		## **CanvasLayer 不跟父节点的 visible 走**，那一层得单独关（第一版就栽在这儿）
		(_scene.get_node("MainMenu") as Node2D).visible = false
		(_scene.get_node("MainMenu/UI") as CanvasLayer).visible = false
		return false
	if _frames == 4:
		_paint()
		return false
	if _frames < WARMUP:
		return false
	var img := root.get_texture().get_image()
	## 只要棋盘中央那块，2× 放大好看清色标压没压住组织色
	var strip := img.get_region(Rect2i(230, 130, 320, 260))
	strip.resize(320 * 2, 260 * 2, Image.INTERPOLATE_NEAREST)
	match _shot:
		0:
			strip.save_png(_out + "_fresh.png")
			print("已保存 ", _out, "_fresh.png（刚炸完：一圈黏液 + 中间转癌）")
			## 再给一格挂上骨化倒计时，看两个状态撞在一起时谁压谁
			_match.game.tile(Vector2i(1, 0))["ossify_at"] = _match.game.round_no + 1
		1:
			strip.save_png(_out + "_mixed.png")
			print("已保存 ", _out, "_mixed.png（黏液格上再叠骨化倒计时）")
			return true
	_shot += 1
	_frames = WARMUP - 6
	return false


## 手摆一个「刚被印戒自爆过」的局面。**不真跑技能** —— 那要等 AI 攒够 2.0 能量、
## 还得正好站在这儿；这只预览要的是结果的样子，不是过程。
func _paint() -> void:
	var g: CWGame = _match.game
	var area: Array = []
	for c: Vector2i in g.tiles:
		if CWData.hex_dist(c, CENTER) <= CWData.MUCUS_RADIUS:
			area.append(c)
	area.sort()
	for c: Vector2i in area:
		g.tile(c)["mucus"] = true
	## 中间几格转成癌组织：黏液色标要压在癌组织的洋红上，那才是最难读的一档
	## **只转一半**：另一半留着健康组织。黏液色标压在洋红和压在暗绿上是两种读法，
	## 一张图里两种都要有，否则「在癌组织上看不看得出来」这一问就没答案
	for i in mini(CWData.MUCUS_MAX_CONVERT, area.size()):
		var t: Dictionary = g.tile(area[i])
		if int(t["tissue"]) == CWData.Tissue.HEALTHY and i % 2 == 0:
			CWTissue.to_cancer(t, true)
