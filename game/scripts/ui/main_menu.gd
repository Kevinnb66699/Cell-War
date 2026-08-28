extends Node2D
## 主菜单「活体棋盘」：背景不是插画，就是真正的那张棋盘。
##
## 构图 / 字号 / 机位全部照搬团队 2026-08-27 定稿的 HTML 原型（开局过场原型）。
## 原型画布是 960×540，本工程的设计分辨率就取同一个数，
## 于是原型里的 1cqw 正好是 9.6px，坐标乘过来即可，机位参数原样搬。
##
## **本节点自己不画棋盘。** 棋盘是同级的 Board 节点，相机也是同级的。
## 这么摆是因为「开始对局」的过场是同一个镜头往前推、不切场景，
## 菜单和棋盘必须活在同一棵树里，否则过场没法做。

## 「开始对局」被点了。对局配置面板和推进过场都还没做，先把口子留在这儿。
signal start_requested

## 棋盘和相机都是同级节点。写成可导出的路径而不是写死 get_node("../Board")，
## 是为了将来换树形（比如过场时把菜单挪进别的容器）只改场景不改代码。
@export var board_path: NodePath = ^"../Board"
@export var camera_path: NodePath = ^"../Camera2D"

@onready var board: Node2D = get_node(board_path)      ## 取格子坐标只能问它（架构约定 #10）
@onready var camera: Camera2D = get_node(camera_path)  ## 菜单机位就是对局用的那台相机


## 机位参数和换算都在 [CWView]。放那儿是因为对局机位要用同一套，
## 而「开始对局」的推进过场就是在这两组参数之间插值 —— 摆在一起才看得出关系。


## ── 装饰细胞 ──────────────────────────────────────────────────
## 菜单机位里看得见的几格上站着免疫细胞样本。轴坐标取自原型的 DECOR。
const DECOR := {
	Vector2i(0, -2): preload("res://assets/art/cells/immune.png"),
	Vector2i(2, -1): preload("res://assets/art/cells/bcell.png"),
	Vector2i(-1, 1): preload("res://assets/art/cells/tcell.png"),
	Vector2i(0, 2): preload("res://assets/art/cells/macrophage.png"),
	Vector2i(-2, 3): preload("res://assets/art/cells/dendritic.png"),
}

## 细胞脚底落在格子「顶面中心」再往下 6px —— 站在顶面偏前一点，和原型一致。
const CELL_FOOT_DY := 6.0


## ── 菜单项 ────────────────────────────────────────────────────
## node 是 Items 下的子节点名，顺序即上下顺序。
## enabled=false 的项按原型的 .mi.dim 画成灰色、不响应鼠标。
## 原型里灰掉的是「退出」（网页里退不出去），实装反过来：
## 退出能用，**中间三项因为还没做**才灰。三项做出来就把 enabled 翻回 true。
const ITEMS := [
	{"node": "Start", "enabled": true},
	{"node": "Continue", "enabled": false},
	{"node": "Rules", "enabled": false},
	{"node": "Settings", "enabled": false},
	{"node": "Quit", "enabled": true},
]

const COLOR_REST := Color("cfe2e6")
const COLOR_SELECTED := Color("eaf8fc")   ## 选中：字提亮 + 左边亮起菱形
const COLOR_HOVER := Color("ffffff")      ## 悬停：转纯白 + 描边发光 + 微微上浮
const COLOR_DISABLED := Color("7b929b")

## 20px 字号下 1 个字模像素 = 2 个屏幕像素，所以位移**必须取 2 的整数倍**，
## 否则点阵会落到半像素上被磨出灰边（和字间距只能取 2px 是同一个原因）。
const HOVER_LIFT := 2.0

const MARKER_X := 147.0   ## 菱形中心的横坐标（原型：菜单项左边 -2.6cqw 处）

var _labels: Array[Label] = []
var _rest_y: Array[float] = []   ## 各项的静止纵坐标，悬停上浮后要还原
var _selected := 0
var _hovered := -1
var _leave: Tween   ## 退场动画，快速点击要能一步到位

@onready var _decor_root: Node2D = $Decor
@onready var _items: Control = $UI/Screen/Items
@onready var _marker: Node2D = $UI/Screen/Items/Marker
@onready var _glow: Control = $UI/Screen/Items/Glow
@onready var _version: Label = $UI/Screen/Ver
@onready var _ui: CanvasLayer = $UI


func _ready() -> void:
	_place_camera()
	_spawn_decor()
	_setup_items()
	## 版本号读工程设置，别在界面里写死第二份
	_version.text = "v" + str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	_repaint()


## 过场退场：菜单文字淡出，装饰细胞沿着**离棋盘中心的方向**往外漂散再淡掉。
## 不做生硬淡出是团队的要求 —— 读起来像「样本正在让位」，实现上只多一个位移。
##
## 装饰细胞**不留下当开局棋子**，三条都对不上：稿子里是 5 个免疫细胞，
## 真实开局双方都有；数量跟人数走（2/4/6 人局不同）；位置由玩家落子决定。
func dismiss(seconds: float, drift: float) -> void:
	set_process_unhandled_input(false)   ## 过场里别再响应上下键
	## 淡出**一开始**就得停止吃鼠标：Control 的 modulate 归零只是看不见，
	## 照样挡点击；而「开始对局」那一行正压在棋盘上方，不摘掉的话过场结束后
	## 点那块棋盘会毫无反应，还查不出原因（2026-08-27 端到端跑出来的）。
	for label in _labels:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var origin: Vector2 = board.tile_center(Vector2i.ZERO)
	_leave = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_leave.tween_property($UI/Screen, "modulate:a", 0.0, seconds)
	for cell in _decor_root.get_children():
		var away: Vector2 = (cell.position - origin).normalized() * drift
		_leave.parallel().tween_property(cell, "position", cell.position + away, seconds)
		_leave.parallel().tween_property(cell, "modulate:a", 0.0, seconds * 0.8)
	## CanvasLayer **不跟随**父 Node2D 的可见性，得单独关
	_leave.finished.connect(func() -> void:
		visible = false
		_ui.visible = false)


## 从对局回到主菜单：把 dismiss() 改过的东西**逐样还原**再淡回来。
## 装饰细胞是漂散出去又淡掉的，位置和透明度都变了，所以直接重新生成一批 ——
## 它们本来就是纯装饰，位置由 DECOR 常量决定，重建比记账便宜也不会记漏。
func appear(seconds: float) -> void:
	if _leave != null:
		_leave.kill()
	visible = true
	_ui.visible = true
	for cell in _decor_root.get_children():
		_decor_root.remove_child(cell)
		cell.queue_free()
	_spawn_decor()
	for i in _labels.size():
		_labels[i].mouse_filter = Control.MOUSE_FILTER_STOP if ITEMS[i]["enabled"] 			else Control.MOUSE_FILTER_IGNORE
	set_process_unhandled_input(true)
	_hovered = -1
	_selected = 0
	_repaint()
	var screen: Control = $UI/Screen
	screen.modulate.a = 0.0
	create_tween().tween_property(screen, "modulate:a", 1.0, seconds)


## 过场进行中再点一次 → 立即到位（团队要求，别等做完再补）
func skip_dismiss() -> void:
	if _leave != null and _leave.is_running():
		_leave.custom_step(3600.0)


func _place_camera() -> void:
	CWView.apply(camera, board, CWView.MENU_ZOOM, CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR)


func _spawn_decor() -> void:
	for at: Vector2i in DECOR:
		var tex: Texture2D = DECOR[at]
		var top: Vector2 = board.tile_center(at)
		var cell := Sprite2D.new()
		cell.texture = tex
		cell.offset = Vector2(0, -tex.get_height() / 2.0)   ## 锚点从贴图中心挪到脚底中心
		cell.position = top + Vector2(0, CELL_FOOT_DY)
		## 和组织块共用一套画家算法（board.gd 拿贴图中心的 y 当 z_index），
		## +1 是为了压在自己脚下那一格上面。
		cell.z_index = int(top.y + board.TOP_FACE_DY) + 1
		_decor_root.add_child(cell)


func _setup_items() -> void:
	for i in ITEMS.size():
		var label: Label = _items.get_node(ITEMS[i]["node"])
		_labels.append(label)
		_rest_y.append(label.position.y)
		label.size = label.get_minimum_size()   ## 命中框贴着字，别把右边的空白也算进去
		if not ITEMS[i]["enabled"]:
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			continue
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		label.mouse_entered.connect(_on_item_entered.bind(i))
		label.mouse_exited.connect(_on_item_exited.bind(i))
		label.gui_input.connect(_on_item_input.bind(i))


## 三种状态叠在一起画：静止 / 选中（菱形）/ 悬停（发光上浮）。
## 鼠标划过会顺手把选中也带过去，键盘上下则只改选中——
## 于是「菱形跟着焦点走」这件事在两种输入下是一致的。
func _repaint() -> void:
	for i in _labels.size():
		var label: Label = _labels[i]
		var hot := i == _hovered
		var color := COLOR_DISABLED
		if ITEMS[i]["enabled"]:
			color = COLOR_HOVER if hot else (COLOR_SELECTED if i == _selected else COLOR_REST)
		label.add_theme_color_override("font_color", color)
		label.position.y = _rest_y[i] - (HOVER_LIFT if hot else 0.0)
	var sel: Label = _labels[_selected]
	_marker.position = Vector2(MARKER_X, sel.position.y + sel.size.y / 2.0)
	_move_glow()


## 悬停光晕：Items/Glow 里几层描边由外到内叠出来的，近似 CSS 里那两道高斯阴影。
## 全菜单共用这一套、跟着悬停项走 —— 同时只可能有一项悬停，不必每项各备一份。
##
## 为什么不用引擎的辉光后期：开 hdr_2d 会把整张画布的颜色都改掉，
## 而棋盘配色本来和设计稿是逐像素一致的，代价太大（2026-08-27 试过，回退了）。
## 为什么层数要密：只叠三层时最外那圈会露出一条硬边，读起来就是团队否掉的「垫块」；
## 加密之后每级的 alpha 落差都很小，台阶就看不出来了。
## 各层的尺寸与 alpha 都在场景里，要调手感直接在编辑器里改，不用碰代码。
func _move_glow() -> void:
	_glow.visible = _hovered >= 0
	if not _glow.visible:
		return
	var hot: Label = _labels[_hovered]
	_glow.position = hot.position
	for layer in _glow.get_children():
		(layer as Label).text = hot.text


func _on_item_entered(i: int) -> void:
	_hovered = i
	_selected = i
	_repaint()


func _on_item_exited(i: int) -> void:
	if _hovered == i:
		_hovered = -1
		_repaint()


func _on_item_input(event: InputEvent, i: int) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_activate(i)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_down"):
		_step_selection(1)
	elif event.is_action_pressed("ui_up"):
		_step_selection(-1)
	elif event.is_action_pressed("ui_accept"):
		_activate(_selected)


## 从 from 往 dir 方向找下一个可用项，跳过灰掉的；到头就停在原地，不绕回。
## 抽成 static 是为了让无头测试能直接查这条跳转规则（现在中间三项都是灰的，
## 「开始对局」往下一步必须直接落到「退出」）。
static func next_enabled(from: int, dir: int) -> int:
	var i := from + dir
	while i >= 0 and i < ITEMS.size():
		if ITEMS[i]["enabled"]:
			return i
		i += dir
	return from


func _step_selection(dir: int) -> void:
	var next := next_enabled(_selected, dir)
	if next == _selected:
		return
	_selected = next
	_repaint()


func _activate(i: int) -> void:
	if i < 0 or not ITEMS[i]["enabled"]:
		return
	match ITEMS[i]["node"]:
		"Start":
			print("[主菜单] 开始对局 —— 对局配置与推进过场尚未实现")
			start_requested.emit()
		"Quit":
			get_tree().quit()
