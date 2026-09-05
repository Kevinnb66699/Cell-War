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

## 配置面板上按了「开始对局」。cfg 见 CWConfigPanel.config()：
## { players: 人数, faction: 人类阵营（-1=观战）, smart: AI 强度 }。
signal start_requested(cfg: Dictionary)
## 「继续对局」被点了（只在存在存档时可点，读档由 main.gd 做）
signal continue_requested
## 联机面板里房间开局了：main.gd 推镜头进棋盘，对局由服务器驱动
signal online_match_requested(client: CWNetClient)
## 联机对局中房间没了：main.gd 收摊回主菜单
signal online_lost(reason: String)
## 「新手引导」被点了：main.gd 开一局固定种子的教程对局
signal tutorial_requested

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
## 五项全亮（2026-08-29 深夜起）。「继续对局」的 enabled 是**基础开关**，
## 实际亮灭还要有存档才行 —— 动态部分见 _item_enabled()，键盘跳灰用
## enabled_mask() 现算。
## 「自定义对局」（2026-09-03 Kevin）= 同一张配置面板多出「癌症A/B/C 种类」几行，让人挑初始癌种；
## 「开始对局」照旧随机抽。七项行距 34（六项时 38），底边 532。
const ITEMS := [
	{"node": "Start", "enabled": true},
	{"node": "Custom", "enabled": true},
	{"node": "Online", "enabled": true},
	{"node": "Continue", "enabled": true},
	{"node": "Rules", "enabled": true},
	{"node": "Codex", "enabled": true},
	{"node": "Guide", "enabled": true},
	{"node": "Settings", "enabled": true},
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

## ── 退出确认 ──────────────────────────────────────────────────
## 暂停菜单里「返回主菜单 / 退出游戏」都要过一道确认（团队 2026-08-27 定），
## 主菜单的「退出游戏」当时漏了，2026-08-28 补上。
##
## 视觉语汇**照抄暂停菜单的确认页**：压暗层 + 264 宽的面板 + 两项，
## 默认停在「取消」，Esc / 右键 = 取消。连辉光都用 [CWPauseMenu] 的同一份参数 ——
## 两处确认长得不一样的话，玩家会以为是两种不同的东西。
##
## 为什么没抽成公共控件：现在只有两处，而暂停菜单那一套还绑着「暂停整棵树」
## 和「两页切换」。等第三处确认出现时再抽，那时才看得清共性在哪。
const CONFIRM_TITLE := "退出游戏？"
const CONFIRM_ITEMS := ["确定", "取消"]
const CONFIRM_W := 264
const CONFIRM_PAD := 16
const CONFIRM_ITEM_H := 36
const CONFIRM_TITLE_H := 42

var _labels: Array[Label] = []
var _rest_y: Array[float] = []   ## 各项的静止纵坐标，悬停上浮后要还原
var _selected := 0
var _hovered := -1
var _leave: Tween   ## 退场动画，快速点击要能一步到位
var _confirm: Control            ## 退出确认的整块覆盖层；null = 还没建过
var _confirm_labels: Array[Label] = []
var _confirm_bars: Array[ColorRect] = []
var _confirm_glow: Control
var _confirm_sel := 1            ## 默认停在「取消」，别让回车顺手就退了
var _config: CWConfigPanel       ## 对局配置面板；null = 还没建过
var _online: CWOnlinePanel       ## 联机面板（连接 / 大厅 / 等待室）；null = 还没建过
var _rules: CWRulesPage          ## 规则速查页；null = 还没建过
var _codex: CWCodex             ## 知识之书图鉴；null = 还没建过
var _settings: CWSettingsPage    ## 设置页；null = 还没建过
var _swap: Tween                 ## 菜单↔配置的槽位换面板动画（0.30s 出 / 0.32s 入）

## 面板槽换内容的节拍（开局过场原型定稿）：菜单淡出 0.30s，配置随后自己淡入 0.32s，
## 两段不重叠——两组字叠在一起会糊成一片
const T_SWAP_OUT := 0.30

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
	_respawn_decor()
	_apply_filters()   ## 「继续对局」的亮灭跟着存档有无走，回菜单时重新算
	set_process_unhandled_input(true)
	_hovered = -1
	_selected = 0
	_repaint()
	var screen: Control = $UI/Screen
	screen.modulate.a = 0.0
	create_tween().tween_property(screen, "modulate:a", 1.0, seconds)


## 联机结算后「回到等待室」：装饰细胞回来，但面板槽里放的是等待室，菜单项不出来
func appear_online(_seconds: float) -> void:
	_respawn_decor()
	for label in _labels:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_unhandled_input(true)
	_hovered = -1
	_selected = 0
	_repaint()
	($UI/Screen as Control).modulate.a = 0.0
	if _online != null:
		_online.return_to_room()


## 离开联机：面板和服务器告别；随后 main.gd 会演返场、菜单 appear()
func leave_online() -> void:
	if _online != null:
		_online.leave_online()


## 从对局回来时把 dismiss() 改过的东西逐样还原。装饰细胞是漂散出去又淡掉的，
## 位置和透明度都变了，所以直接重新生成一批 —— 纯装饰，重建比记账便宜也不会记漏。
func _respawn_decor() -> void:
	if _leave != null:
		_leave.kill()
	visible = true
	_ui.visible = true
	for cell in _decor_root.get_children():
		_decor_root.remove_child(cell)
		cell.queue_free()
	_spawn_decor()


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
			continue   ## 基础灰项（设置）连信号都不接
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		label.mouse_entered.connect(_on_item_entered.bind(i))
		label.mouse_exited.connect(_on_item_exited.bind(i))
		label.gui_input.connect(_on_item_input.bind(i))
	_apply_filters()


## 「此刻可不可点」：静态 enabled 之外，「继续对局」还要真的有存档
func _item_enabled(i: int) -> bool:
	if not ITEMS[i]["enabled"]:
		return false
	if ITEMS[i]["node"] == "Continue":
		return CWSave.can_continue()
	return true


## 键盘跳灰用的可用位图。next_enabled 保持静态纯函数——测试想摆什么局面摆什么局面。
func enabled_mask() -> Array:
	var mask := []
	for i in ITEMS.size():
		mask.append(_item_enabled(i))
	return mask


## 鼠标命中随「此刻可不可点」走：有没有存档只会在进出菜单之间变化，
## _ready 和 appear() 各刷一次就是准的。
func _apply_filters() -> void:
	for i in _labels.size():
		_labels[i].mouse_filter = Control.MOUSE_FILTER_STOP if _item_enabled(i) \
			else Control.MOUSE_FILTER_IGNORE


## 三种状态叠在一起画：静止 / 选中（菱形）/ 悬停（发光上浮）。
## 鼠标划过会顺手把选中也带过去，键盘上下则只改选中——
## 于是「菱形跟着焦点走」这件事在两种输入下是一致的。
func _repaint() -> void:
	for i in _labels.size():
		var label: Label = _labels[i]
		var hot := i == _hovered
		var color := COLOR_DISABLED
		if _item_enabled(i):
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
	if not _item_enabled(i):
		return   ## 灰项的过滤器本就是 IGNORE，这里是第二道保险
	_hovered = i
	_selected = i
	_repaint()


func _on_item_exited(i: int) -> void:
	if _hovered == i:
		_hovered = -1
		_repaint()


func _on_item_input(event: InputEvent, i: int) -> void:
	if not (event is InputEventMouseButton and event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	## **必须标记已处理**：Control 的 gui_input 不会自动吃掉事件，
	## 同一下点击会继续传到 main.gd 的 _unhandled_input，在那儿被
	## 「过场中点一下跳过」当成跳过指令 —— 于是「开始对局」那一下
	## **自己把开场过场跳掉了，从来没播出来过**
	## （团队反馈「开局动画不好看」的真正原因，2026-08-27 查到）。
	get_viewport().set_input_as_handled()
	_activate(i)


func _unhandled_input(event: InputEvent) -> void:
	## 槽位换面板的半秒里两边都不收键：菜单在淡、配置还没现身，
	## 这时回车可能把退出确认之类的东西莫名其妙敲出来
	if _swap != null and _swap.is_running():
		return
	## 覆盖层统一走菜单路由，谁开着路由给谁 —— 两个 _unhandled_input 抢事件的
	## 顺序问题从根上不存在（同暂停菜单对 Esc 归属的取舍）
	if _config != null and _config.visible:
		_config.handle_input(event)
		return
	if _online != null and _online.visible:
		_online.handle_input(event)
		return
	if _rules != null and _rules.visible:
		_rules.handle_input(event)
		return
	if _settings != null and _settings.visible:
		_settings.handle_input(event)
		return
	if _codex != null and _codex.visible:
		_codex.handle_input(event)
		return
	if _confirm != null and _confirm.visible:
		_confirm_input(event)
		return
	if event.is_action_pressed("ui_down"):
		_step_selection(1)
	elif event.is_action_pressed("ui_up"):
		_step_selection(-1)
	elif event.is_action_pressed("ui_accept"):
		_activate(_selected)


func _confirm_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close_confirm()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
		_confirm_sel = 1 - _confirm_sel
		_repaint_confirm()
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_pick_confirm(_confirm_sel)


# ── 退出确认 ──────────────────────────────────────────────────

func _open_confirm() -> void:
	if _confirm == null:
		_build_confirm()
	_confirm_sel = 1
	_confirm.visible = true
	_repaint_confirm()


func _close_confirm() -> void:
	if _confirm != null:
		_confirm.visible = false


func _pick_confirm(i: int) -> void:
	if i == 0:
		get_tree().quit()
	else:
		_close_confirm()


func _build_confirm() -> void:
	_confirm = Control.new()
	_confirm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm.mouse_filter = Control.MOUSE_FILTER_STOP   ## 盖住底下菜单项的点击
	_confirm.visible = false
	_ui.add_child(_confirm)

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm.add_child(scrim)

	var h: float = CONFIRM_PAD + CONFIRM_TITLE_H \
		+ CONFIRM_ITEMS.size() * CONFIRM_ITEM_H + CONFIRM_PAD
	var screen := CWView.screen_size()
	var panel := Control.new()
	panel.position = Vector2((screen.x - CONFIRM_W) / 2.0, (screen.y - h) / 2.0)
	panel.size = Vector2(CONFIRM_W, h)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm.add_child(panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	var title := CWStyle.label(CONFIRM_TITLE, CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(CONFIRM_PAD, CONFIRM_PAD)
	panel.add_child(title)

	## 辉光整套只备一份、跟着选中项走（同 CWPauseMenu）
	_confirm_glow = Control.new()
	_confirm_glow.size = Vector2(CONFIRM_W, 28)
	_confirm_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_confirm_glow)
	for layer in CWPauseMenu.GLOW:
		var g := CWStyle.label("", CWStyle.SIZE_BODY, Color(1, 1, 1, 0))
		g.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		g.add_theme_constant_override("outline_size", layer[0])
		g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_confirm_glow.add_child(g)

	for i in CONFIRM_ITEMS.size():
		var y: float = CONFIRM_PAD + CONFIRM_TITLE_H + i * CONFIRM_ITEM_H
		var mark := ColorRect.new()
		mark.position = Vector2(CONFIRM_PAD, y + 6)
		mark.size = Vector2(4, 22)
		mark.color = Color(CWStyle.IMMUNE, 0.0)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(mark)
		_confirm_bars.append(mark)
		var label := CWStyle.label(CONFIRM_ITEMS[i], CWStyle.SIZE_BODY, CWStyle.TEXT)
		label.position = Vector2(CONFIRM_PAD + 16, y + 5)
		label.size = label.get_minimum_size()   ## 命中框贴着字，别把右边空白也算进去
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		label.mouse_entered.connect(func() -> void:
			_confirm_sel = i
			_repaint_confirm())
		label.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				get_viewport().set_input_as_handled()   ## 理由同 _on_item_input
				_pick_confirm(i))
		panel.add_child(label)
		_confirm_labels.append(label)


func _repaint_confirm() -> void:
	for i in _confirm_labels.size():
		var on: bool = i == _confirm_sel
		_confirm_labels[i].add_theme_color_override("font_color",
			Color.WHITE if on else CWStyle.TEXT)
		_confirm_bars[i].color = Color(CWStyle.IMMUNE, 1.0 if on else 0.0)
	_confirm_glow.position = _confirm_labels[_confirm_sel].position
	for layer in _confirm_glow.get_children():
		(layer as Label).text = CONFIRM_ITEMS[_confirm_sel]


## 从 from 往 dir 方向找下一个可用项，跳过 mask 里灰掉的；到头停在原地，不绕回。
## mask 由 enabled_mask() 现算（「继续对局」随存档有无变），
## 保持 static 纯函数是为了让无头测试想摆什么局面摆什么局面。
static func next_enabled(from: int, dir: int, mask: Array) -> int:
	var i := from + dir
	while i >= 0 and i < mask.size():
		if mask[i]:
			return i
		i += dir
	return from


func _step_selection(dir: int) -> void:
	var next := next_enabled(_selected, dir, enabled_mask())
	if next == _selected:
		return
	_selected = next
	_repaint()


func _activate(i: int) -> void:
	if i < 0 or not _item_enabled(i):
		return
	match ITEMS[i]["node"]:
		"Start":
			_open_config(false)
		"Custom":
			_open_config(true)
		"Online":
			_open_online()
		"Continue":
			continue_requested.emit()
		"Rules":
			if _rules == null:
				_rules = CWRulesPage.new()
				_ui.add_child(_rules)
			_rules.open()
		"Codex":
			if _codex == null:
				_codex = CWCodex.new()
				_ui.add_child(_codex)
			_codex.open()
		"Guide":
			tutorial_requested.emit()
		"Settings":
			if _settings == null:
				_settings = CWSettingsPage.new()
				_ui.add_child(_settings)
			_settings.open()
		"Quit":
			_open_confirm()


## 「开始对局」/「自定义对局」→ 槽位换面板：菜单整层（含左侧暗罩）淡出，对局配置在同一位置淡入。
## 配置面板自带一份暗罩，所以菜单可以整层走——内容换、位置不换（原型的基本语法）。
## custom = 自定义对局：同一张面板多出癌种几行（CWConfigPanel.custom），取值局间各自保留。
func _open_config(custom: bool = false) -> void:
	if _swap != null and _swap.is_running():
		return
	if _config == null:
		_config = CWConfigPanel.new()
		_ui.add_child(_config)
		_config.confirmed.connect(func(cfg: Dictionary) -> void:
			start_requested.emit(cfg))
		_config.cancelled.connect(_close_config)
	_config.custom = custom
	## 淡到 0 的 Control 照样挡点击（dismiss 踩过的同一坑），先把菜单项摘掉
	for label in _labels:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_swap = create_tween()
	_swap.tween_property($UI/Screen, "modulate:a", 0.0, T_SWAP_OUT)
	_swap.tween_callback(_config.open)


## 「联机对战」→ 同一套槽位换面板：菜单淡出，联机面板在同一位置淡入
func _open_online() -> void:
	if _swap != null and _swap.is_running():
		return
	if _online == null:
		_online = CWOnlinePanel.new()
		_ui.add_child(_online)
		_online.cancelled.connect(_close_config)
		_online.match_started.connect(func(client: CWNetClient) -> void:
			online_match_requested.emit(client))
		_online.match_lost.connect(func(reason: String) -> void:
			online_lost.emit(reason))
	for label in _labels:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_swap = create_tween()
	_swap.tween_property($UI/Screen, "modulate:a", 0.0, T_SWAP_OUT)
	_swap.tween_callback(_online.open)


## 配置面板 / 联机面板 Esc 退回：原路把菜单淡回来
func _close_config() -> void:
	if _swap != null and _swap.is_running():
		_swap.kill()
	_apply_filters()
	_swap = create_tween()
	_swap.tween_property($UI/Screen, "modulate:a", 1.0, T_SWAP_OUT)
