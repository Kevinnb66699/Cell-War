## main.gd —— 入口：主菜单与对局共用同一台相机、同一张棋盘
##
## 「开始对局」的过场是同一个镜头从菜单机位往前推、**不切场景**，
## 所以菜单和对局必须活在同一棵树里，相机也只有一台。
##
## 开场三拍（团队 2026-08-27 定，来龙去脉见开发日志）：
##   ① 相机拉远铺满棋盘 1.55s，装饰细胞同时沿离心方向漂散淡出
##   ② 初始癌组织从正中绽开 0.75s，中央先翻、外圈绕一圈扫过去
##   ③ 停下来等玩家落子 —— **这一拍必须把控制权交还玩家**，落子是决策不是演出
##
## 时长常量集中放这里，别散进各个 Tween：手感是要反复微调的，
## 散开了改一次要翻好几个文件（参照 CWTuning 的做法）。
extends Node2D

const T_ENTER := 1.55       ## ① 相机推进。最初给 0.62s，团队试过原型后改成 1.55s
const T_BLOOM := 0.75       ## ② 癌组织绽开
const T_DECOR := 1.10       ## 装饰细胞漂散淡出，在推进途中就走完
const DECOR_DRIFT := 26.0   ## 漂散距离（棋盘像素）
const T_BACK := 1.55        ## 棋盘 → 主菜单。团队定了**和进场对称**
                            ##（本来按 0.75s 做的：进场是揭幕值得给分量，返回该干脆）
const T_MENU_IN := 0.32     ## 相机回位之后菜单再淡进来。两段刻意**不重叠**

@onready var camera: Camera2D = $Camera2D
@onready var board: Node2D = $Board
@onready var menu: Node2D = $MainMenu
@onready var match_node: CWMatch = $Match
@onready var pause: CWPauseMenu = $Match/UI/Pause

var _tween: Tween
var _entering := false


func _ready() -> void:
	menu.start_requested.connect(_begin)
	pause.chose.connect(_on_pause_chose)
	pause.action_bar = match_node.action_bar


func _begin() -> void:
	if _entering:
		return
	_entering = true
	menu.dismiss(T_DECOR, DECOR_DRIFT)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(camera, "position", _game_camera_pos(), T_ENTER)
	_tween.parallel().tween_property(camera, "zoom",
		Vector2(CWView.GAME_ZOOM, CWView.GAME_ZOOM), T_ENTER)
	await _tween.finished
	## 两段计时动画必须**前后相接**，不能挂在同一条时间轴上：原型里第一版共用
	## 一个进度值，相机走完那一帧的进度 1 被当成「绽开也走完了」，
	## 7 格癌组织一次全出、绽开整个被跳过（开发日志 2026-08-27）。
	await match_node.start_with_bloom(T_BLOOM)
	_entering = false    ## 三拍走完才算「不在过场中」——忘了置回，返回主菜单会永远进不去


func _on_pause_chose(action: String) -> void:
	match action:
		"menu":
			_back_to_menu()
		"quit":
			get_tree().quit()


## 返回主菜单：镜头原路退回，棋盘擦干净，菜单淡回来。
## 顺序不能颠倒 —— 棋盘和菜单共用同一张棋盘，得先擦掉上一局的癌组织，
## 否则镜头退到菜单机位时背景里还留着一片红。
func _back_to_menu() -> void:
	if _entering:
		return
	_entering = true
	match_node.teardown()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(camera, "position", _menu_camera_pos(), T_BACK)
	_tween.parallel().tween_property(camera, "zoom",
		Vector2(CWView.MENU_ZOOM, CWView.MENU_ZOOM), T_BACK)
	await _tween.finished
	menu.appear(T_MENU_IN)
	_entering = false


## 过场进行中再点一次 → 立即到位（团队要求：别等做完再补）
func _unhandled_input(event: InputEvent) -> void:
	if not _entering or _tween == null or not _tween.is_running():
		return
	if event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()
		menu.skip_dismiss()
		_tween.custom_step(3600.0)   ## 一步推到底，进场返场都适用


func _game_camera_pos() -> Vector2:
	return CWView.camera_pos_for(
		CWView.board_origin(board) + CWView.GAME_LOOK_AT,
		CWView.GAME_ANCHOR, CWView.GAME_ZOOM, CWView.screen_size())


func _menu_camera_pos() -> Vector2:
	return CWView.camera_pos_for(
		CWView.board_origin(board) + CWView.MENU_LOOK_AT,
		CWView.MENU_ANCHOR, CWView.MENU_ZOOM, CWView.screen_size())
