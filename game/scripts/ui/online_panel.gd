## online_panel.gd —— 联机：主菜单同一槽位的左侧面板，四页：连接 / 大厅 / 建房 / 等待室
##
## 面板槽语法同对局配置面板（CWConfigPanel）：主菜单淡出后本面板在同一位置淡入，
## 眉题 / 标题 / 行 / 按钮的坐标照抄那边，拨值箭头也是固定位置那一套。
## 拍板与流程见 docs/联机设计_2026-09-02.md §七：主菜单「联机对战」→ 连接（昵称 / 地址）→ 大厅
## （公开房列表 / 建房 / 输房间码）→ 等待室（点空席坐下 / 准备 / 房主放 AI、踢人、开局）→ 对局 → 结算 → 等待室。
##
## CWNetClient 由本面板持有并每帧轮询。process_mode = ALWAYS：对局里暂停菜单会冻结整棵树，
## 心跳一停服务器 20 秒就判掉线。对局开始后面板隐藏但继续轮询，CWMatch 只消费 client.stream。
## 断线：等待室或对局中且手里有令牌 → 每 3 秒凭令牌重连，直到房间没了（match_lost）或玩家主动离开。
class_name CWOnlinePanel
extends Control

signal cancelled                             ## 第一页 Esc：主菜单把自己淡回来
signal match_started(client: CWNetClient)    ## 房间开局且第一份状态已排进 stream：main.gd 推镜头进棋盘
signal match_lost(reason: String)            ## 对局中房间没了 / 令牌失效：main.gd 收摊回主菜单

enum Page { CONNECT, LOBBY, CREATE, ROOM }

const SLOT_X := 120.0        ## 槽位左缘（同 CWConfigPanel）
const VALUE_X := 250.0
const ARROW_R_X := 500.0
const ROW_Y0 := 251.0
const ROW_H := 42.0
const BTN_Y := 438.0
const BTN_H := 38.0
const STATUS_Y := 484.0
const FADE_IN := 0.32
const PAGE_FADE := 0.2       ## 面板内切页（连接→大厅→建房→等待室）：新页淡入，别硬切
const LIST_Y0 := 296.0       ## 大厅列表第一行
const LIST_W := 400.0        ## 大厅房间行定宽（面板 538 − 槽位 120 − 余量）；超出的加省略号
const SEAT_NAME_W := 172.0   ## 等待室席位名定宽：SLOT_X+70 起、到状态列 SLOT_X+250 之前
const LIST_H := 26.0
const LIST_N := 5
const SEAT_Y0 := 214.0       ## 等待室席位第一行
const SEAT_H := 30.0
const RETRY_MS := 3000
const ROW_LABEL := Color("9fb6bd")
const TIMER_TEXT := { 0: "不限", 30: "30 秒", 60: "60 秒", 90: "90 秒" }
const CREATE_ROWS := ["人数", "每步计时", "可见性"]
const N_CREATE_ROWS := 3

var client: CWNetClient
var page := Page.CONNECT
var in_match := false        ## 面板藏着、对局在跑；此时 welcome/room 不再切页

var _nick: LineEdit
var _addr: LineEdit
var _code: LineEdit
var _roots := {}             ## Page -> 该页的根 Control
var _status: Label
var _title: Label
var _sub: Label
## 建房页的取值与焦点（与配置面板同一套键盘模型：上下选行、左右拨值）
var _create := { "players": 4, "timer": 60, "public": true }
var _create_sel := 0
var _create_names: Array[Label] = []
var _create_values: Array[Label] = []
var _create_arrows: Array = []
var _create_marker: Node2D
var _create_glow: Control    ## 建房页焦点行标题的辉光（同配置面板：CWPauseMenu.GLOW 四层白描边）
var _create_btn: Panel
var _hot_arrow: Label = null ## 正被鼠标悬停的拨值箭头；null = 没有
var _page_tween: Tween
## 大厅
var _lobby_rooms: Array = []
var _lobby_labels: Array[Label] = []
var _lobby_sel := -1
var _lobby_note: Label
## 等待室
var _seat_root: Control
var _members_label: Label
var _ready_btn: Panel
var _ready_text: Label
var _start_btn: Panel
var _stand_link: Label
var _leave_link: Label
var _want_reconnect := false
var _retry_at := 0
var _awaiting_state := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 整层接管：底下淡掉的菜单项收不到点击
	visible = false
	_build()


func open() -> void:
	in_match = false
	_nick.text = CWSettings.nick
	_addr.text = CWSettings.server
	_set_status("")
	_show_page(Page.ROOM if client != null and client.code != "" else
		(Page.LOBBY if client != null and client.status == "open" else Page.CONNECT))
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_IN)


## 对局开始：面板藏起来，客户端继续在这里轮询
func hide_for_match() -> void:
	in_match = true
	visible = false


## 结算屏「回到等待室」：面板回来，对局流回到即时生效
func return_to_room() -> void:
	in_match = false
	if client != null:
		client.sequenced = false
		client.stream.clear()
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_IN)
	_set_status("")
	_show_page(Page.ROOM if client != null and client.code != "" else Page.LOBBY)
	if page == Page.LOBBY and client != null:
		client.list_rooms()


## 离开联机（结算屏返回主菜单 / 暂停菜单离开房间 / 房间没了）：告别服务器、丢掉客户端
func leave_online() -> void:
	in_match = false
	_want_reconnect = false
	_awaiting_state = false
	if client != null:
		if client.code != "":
			client.leave()
		client.dispose()
		client = null
	visible = false
	page = Page.CONNECT


func _process(_delta: float) -> void:
	if client == null:
		return
	client.poll()
	if _want_reconnect and client.status == "closed" and Time.get_ticks_msec() >= _retry_at:
		_retry_at = Time.get_ticks_msec() + RETRY_MS
		_set_status("连接断开，重连中…")
		client.connect_to(client.url, client.nick, client.code, client.token)


# ============ 键盘（由 CWMainMenu 路由）============

func handle_input(event: InputEvent) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit:
		if event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			focus.release_focus()
		return       ## 正在打字：字符归输入框，回车由 text_submitted 接
	match page:
		Page.CONNECT:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_back_to_menu()
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				_connect()
		Page.LOBBY:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_disconnect()
			elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
				if not _lobby_rooms.is_empty():
					var d := 1 if event.is_action_pressed("ui_down") else -1
					_lobby_sel = clampi(_lobby_sel + d, 0, _lobby_rooms.size() - 1)
					_repaint_lobby()
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				if _lobby_sel >= 0 and _lobby_sel < _lobby_rooms.size():
					client.join(_lobby_rooms[_lobby_sel]["code"])
		Page.CREATE:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_show_page(Page.LOBBY)
			elif event.is_action_pressed("ui_down"):
				_create_sel = mini(_create_sel + 1, N_CREATE_ROWS)
				_repaint_create()
			elif event.is_action_pressed("ui_up"):
				_create_sel = maxi(_create_sel - 1, 0)
				_repaint_create()
			elif event.is_action_pressed("ui_left"):
				_cycle_create(_create_sel, -1)
			elif event.is_action_pressed("ui_right"):
				_cycle_create(_create_sel, 1)
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				if _create_sel == N_CREATE_ROWS:
					_create_room()
				else:
					_cycle_create(_create_sel, 1)
		Page.ROOM:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_leave_room()
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				_toggle_ready()


# ============ 动作 ============

func _connect() -> void:
	var nick := CWNet.clean_nick(_nick.text)
	var addr := _addr.text.strip_edges()
	if addr == "":
		addr = "%s:%d" % [CWNet.DEFAULT_HOST, CWNet.DEFAULT_PORT]
	CWSettings.nick = nick
	CWSettings.server = addr
	CWSettings.save_prefs()
	if client != null:
		client.dispose()
	client = CWNetClient.new()
	client.message.connect(_on_message)
	client.disconnected.connect(_on_disconnected)
	var url := addr if addr.begins_with("ws://") or addr.begins_with("wss://") else "ws://" + addr
	if client.connect_to(url, nick) != OK:
		_set_status("地址不合法：%s" % addr)
		client = null
		return
	_set_status("连接 %s …" % addr)


func _disconnect() -> void:
	_want_reconnect = false
	if client != null:
		client.dispose()
		client = null
	_show_page(Page.CONNECT)
	_set_status("")


func _create_room() -> void:
	if client == null:
		return
	client.create_room(_create["players"], _create["timer"], _create["public"])
	_set_status("建房中…")


func _join_code() -> void:
	if client == null:
		return
	var code := _code.text.strip_edges().to_upper()
	if code.length() != CWNet.CODE_LEN:
		_set_status("房间码是 %d 位" % CWNet.CODE_LEN)
		return
	client.join(code)


func _leave_room() -> void:
	if client == null:
		return
	_want_reconnect = false
	client.leave()
	_show_page(Page.LOBBY)
	client.list_rooms()


func _toggle_ready() -> void:
	if client == null or client.my_seat < 0:
		return
	var me: Dictionary = client.room["seats"][client.my_seat]
	client.ready(not me["ready"])


func _seat_click(i: int) -> void:
	if client == null or client.room.is_empty():
		return
	var s: Dictionary = client.room["seats"][i]
	if s["kind"] == "":
		client.sit(i)
	elif i == client.my_seat:
		client.stand()


func _cycle_create(row: int, dir: int) -> void:
	match row:
		0:
			var i := CWNet.PLAYER_CHOICES.find(_create["players"])
			_create["players"] = CWNet.PLAYER_CHOICES[(i + dir + CWNet.PLAYER_CHOICES.size()) % CWNet.PLAYER_CHOICES.size()]
		1:
			var i := CWNet.TIMER_CHOICES.find(_create["timer"])
			_create["timer"] = CWNet.TIMER_CHOICES[(i + dir + CWNet.TIMER_CHOICES.size()) % CWNet.TIMER_CHOICES.size()]
		2:
			_create["public"] = not _create["public"]
		_:
			return
	_repaint_create()


# ============ 客户端事件 ============

func _on_message(m: Dictionary) -> void:
	match m["t"]:
		"welcome":
			_want_reconnect = false
			if in_match:
				return
			if client.code == "":
				_show_page(Page.LOBBY)
				client.list_rooms()
			_set_status("维护中：暂不能建新房" if m.get("maintenance", false) else "")
		"lobby":
			_lobby_rooms = m.get("rooms", [])
			_lobby_sel = 0 if not _lobby_rooms.is_empty() else -1
			_lobby_note.text = "服务器维护中，暂不能建房" if m.get("maintenance", false) else ""
			_repaint_lobby()
		"room":
			if in_match:
				return
			if page != Page.ROOM:
				_show_page(Page.ROOM)
				_set_status("")
			_repaint_room()
			## 开局：从这一刻起对局流排队，等第一份状态到了再进棋盘
			if m.get("state", "") == "playing" and m.get("you_seat", -1) >= 0 and not client.sequenced:
				client.sequenced = true
				_awaiting_state = true
		"state":
			if _awaiting_state and client.sequenced:
				_awaiting_state = false
				hide_for_match()
				match_started.emit(client)
		"left":
			if not in_match and page == Page.ROOM:
				_show_page(Page.LOBBY)
				client.list_rooms()
		"error":
			var code: String = m.get("code", "")
			_set_status(m.get("msg", code))
			if code in ["room_closed", "kicked", "no_room", "bad_token"]:
				_want_reconnect = false
				_awaiting_state = false
				if in_match:
					match_lost.emit(m.get("msg", code))
				elif page == Page.ROOM:
					_show_page(Page.LOBBY)
					client.list_rooms()
			elif code == "version":
				_want_reconnect = false


func _on_disconnected(_code: int, _reason: String) -> void:
	if client == null:
		return
	if client.token != "" and (page == Page.ROOM or in_match):
		_want_reconnect = true
		_retry_at = Time.get_ticks_msec()     ## 立刻试第一次
		_set_status("连接断开，重连中…")
		return
	if in_match:
		match_lost.emit("连接已断开")
		return
	_show_page(Page.CONNECT)
	_set_status("连接失败或已断开" if page == Page.CONNECT else "")


# ============ 搭建 ============

func _build() -> void:
	## 槽位自带一份左侧暗罩（同配置面板：菜单的 Scrim 跟着菜单整层淡走了）
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.44, 1.0])
	grad.colors = PackedColorArray([Color(0.078431, 0.121569, 0.180392, 0.96),
		Color(0.078431, 0.121569, 0.180392, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_to = Vector2(1, 0)
	var scrim := TextureRect.new()
	scrim.texture = tex
	scrim.size = Vector2(538, 540)
	scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var eyebrow := CWStyle.label("ONLINE", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	eyebrow.add_theme_font_override("font", _px20())
	eyebrow.position = Vector2(SLOT_X, 127)
	add_child(eyebrow)
	_title = CWStyle.label("联机对战", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	_title.position = Vector2(SLOT_X, 160)
	add_child(_title)
	_sub = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_sub.position = Vector2(SLOT_X, 200)
	add_child(_sub)
	var rule := ColorRect.new()
	rule.position = Vector2(SLOT_X, 230)
	rule.size = Vector2(288, 1)
	rule.color = Color(CWStyle.LINE, 0.42)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rule)
	_status = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_status.position = Vector2(SLOT_X, STATUS_Y)
	_status.size = Vector2(400, 16)
	add_child(_status)

	for p in Page.values():
		var root := Control.new()
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.visible = false
		add_child(root)
		_roots[p] = root
	_build_connect(_roots[Page.CONNECT])
	_build_lobby(_roots[Page.LOBBY])
	_build_create(_roots[Page.CREATE])
	_build_room(_roots[Page.ROOM])


## 连接页退回主菜单：Esc 与「返回主菜单」链接共用一条路；主菜单收到 cancelled 后把自己淡回来
func _back_to_menu() -> void:
	visible = false
	cancelled.emit()


func _build_connect(root: Control) -> void:
	_row_label(root, "昵称", 0)
	_nick = _edit(root, Vector2(VALUE_X, ROW_Y0 - 4), 200, "玩家", CWNet.NICK_MAX)
	_row_label(root, "服务器", 1)
	_addr = _edit(root, Vector2(VALUE_X, ROW_Y0 + ROW_H - 4), 250, "地址:端口", 64)
	_nick.text_submitted.connect(func(_t: String) -> void: _connect())
	_addr.text_submitted.connect(func(_t: String) -> void: _connect())
	_solid_button(root, "进入大厅", Vector2(SLOT_X, BTN_Y), 182, _connect)
	## 「返回主菜单」（2026-09-03 Kevin 要的）：此前连接页只能按 Esc 退出，鼠标玩家没有出口。
	## 与建房页「返回大厅」同位（按钮右侧 200）、同一套链接语言，走的就是 Esc 那条路。
	_clicky(root, "返回主菜单", Vector2(SLOT_X + 200, BTN_Y + 5), _back_to_menu)


func _build_lobby(root: Control) -> void:
	var l := CWStyle.label("房间码", CWStyle.SIZE_BODY, ROW_LABEL)
	l.position = Vector2(SLOT_X, ROW_Y0)
	root.add_child(l)
	_code = _edit(root, Vector2(VALUE_X, ROW_Y0 - 4), 120, "ABCDEF", CWNet.CODE_LEN)
	_code.text_submitted.connect(func(_t: String) -> void: _join_code())
	_clicky(root, "加入", Vector2(VALUE_X + 132, ROW_Y0), _join_code)
	var head := CWStyle.label("公开房间", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	head.position = Vector2(SLOT_X, LIST_Y0 - 16)
	root.add_child(head)
	_lobby_note = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.CANCER)
	_lobby_note.position = Vector2(SLOT_X + 80, LIST_Y0 - 16)
	root.add_child(_lobby_note)
	for i in LIST_N:
		var row := _clicky(root, "", Vector2(SLOT_X, LIST_Y0 + i * LIST_H),
			func() -> void:
				if i < _lobby_rooms.size():
					client.join(_lobby_rooms[i]["code"]))
		row.mouse_entered.connect(func() -> void:
			if i < _lobby_rooms.size():
				_lobby_sel = i
				_repaint_lobby())
		_lobby_labels.append(row)
	_solid_button(root, "建房", Vector2(SLOT_X, BTN_Y), 120, func() -> void:
		_create_sel = 0
		_show_page(Page.CREATE))
	_clicky(root, "刷新", Vector2(SLOT_X + 140, BTN_Y + 5), func() -> void:
		if client != null:
			client.list_rooms())
	_clicky(root, "断开", Vector2(SLOT_X + 220, BTN_Y + 5), _disconnect)


func _build_create(root: Control) -> void:
	_create_marker = _marker()
	root.add_child(_create_marker)
	## 焦点行标题的辉光（先建，压在文字底下；层数与 alpha 即 CWPauseMenu.GLOW，和主菜单 / 配置面板同一套光）
	_create_glow = Control.new()
	_create_glow.size = Vector2(200, 28)
	_create_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_create_glow)
	for layer in CWPauseMenu.GLOW:
		var g := CWStyle.label("", CWStyle.SIZE_BODY, Color(1, 1, 1, 0))
		g.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		g.add_theme_constant_override("outline_size", layer[0])
		g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_create_glow.add_child(g)
	for i in N_CREATE_ROWS:
		var y := ROW_Y0 + i * ROW_H
		var nm := CWStyle.label(CREATE_ROWS[i], CWStyle.SIZE_BODY, ROW_LABEL)
		nm.position = Vector2(SLOT_X, y)
		root.add_child(nm)
		_create_names.append(nm)
		var hit := Control.new()
		hit.position = Vector2(SLOT_X - 30, y - 8)
		hit.size = Vector2(420, ROW_H - 4)
		hit.mouse_filter = Control.MOUSE_FILTER_PASS
		hit.mouse_entered.connect(func() -> void:
			_create_sel = i
			_repaint_create())
		root.add_child(hit)
		## 拨值箭头与值：悬停反馈由 _repaint_create 统一画（_hot_arrow 记着谁在被悬停），不走 _clicky 的通用悬停
		var left := _clicky(root, "<", Vector2(VALUE_X - 22, y), func() -> void: _cycle_create(i, -1), CWStyle.SIZE_BODY, false)
		var value := _clicky(root, "", Vector2(VALUE_X, y), func() -> void: _cycle_create(i, 1), CWStyle.SIZE_BODY, false)
		var right := _clicky(root, ">", Vector2(ARROW_R_X, y), func() -> void: _cycle_create(i, 1), CWStyle.SIZE_BODY, false)
		for arrow: Label in [left, right]:
			arrow.mouse_entered.connect(func() -> void:
				_hot_arrow = arrow
				_repaint_create())
			arrow.mouse_exited.connect(func() -> void:
				if _hot_arrow == arrow:
					_hot_arrow = null
				_repaint_create())
		_create_values.append(value)
		_create_arrows.append([left, right])
	_create_btn = _solid_button(root, "建房", Vector2(SLOT_X, BTN_Y), 182, _create_room)
	_clicky(root, "返回大厅", Vector2(SLOT_X + 200, BTN_Y + 5), func() -> void: _show_page(Page.LOBBY))


func _build_room(root: Control) -> void:
	_seat_root = Control.new()
	_seat_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seat_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_seat_root)
	_members_label = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_members_label.position = Vector2(SLOT_X, SEAT_Y0 + 6 * SEAT_H + 4)
	## 未入座的人数没有上限，名单一长就出面板 → 定宽 + 省略号（2026-09-03 排版体检）
	_members_label.clip_text = true
	_members_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_members_label.size = Vector2(LIST_W, 16)
	root.add_child(_members_label)
	_ready_btn = _solid_button(root, "准备", Vector2(SLOT_X, BTN_Y), 120, _toggle_ready)
	_ready_text = _ready_btn.get_child(0) as Label
	_start_btn = _solid_button(root, "开局", Vector2(SLOT_X + 132, BTN_Y), 100, func() -> void:
		if client != null:
			client.start())
	_stand_link = _clicky(root, "起身", Vector2(SLOT_X + 250, BTN_Y + 5), func() -> void:
		if client != null:
			client.stand())
	_leave_link = _clicky(root, "离开房间", Vector2(SLOT_X + 320, BTN_Y + 5), _leave_room)


# ============ 呈现 ============

func _show_page(p: Page) -> void:
	## 面板开着的时候切页：新页从透明淡入（同一槽位换内容的节拍，和菜单↔面板一致，只是更短）
	var fade := visible and page != p
	page = p
	for k in _roots:
		_roots[k].visible = k == p
	var shown: Control = _roots[p]
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	if fade:
		shown.modulate.a = 0.0
		_page_tween = create_tween()
		_page_tween.tween_property(shown, "modulate:a", 1.0, PAGE_FADE)
	else:
		shown.modulate.a = 1.0
	_sub.text = ""
	match p:
		Page.CONNECT:
			_title.text = "联机对战"
		Page.LOBBY:
			_title.text = "大厅"
			_repaint_lobby()
		Page.CREATE:
			_title.text = "建房"
			_repaint_create()
		Page.ROOM:
			_repaint_room()


func _repaint_lobby() -> void:
	for i in LIST_N:
		var l: Label = _lobby_labels[i]
		if i >= _lobby_rooms.size():
			l.text = "（暂无公开房间）" if i == 0 and _lobby_rooms.is_empty() else ""
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			l.add_theme_color_override("font_color", CWStyle.TEXT_OFF)
			l.size = l.get_minimum_size()
			continue
		var r: Dictionary = _lobby_rooms[i]
		## 房主昵称放**最后**：昵称最长 12 字，一行定宽 400 加省略号，被截的只会是昵称尾巴，
		## 房间码 / 人数 / 计时这些要拿来做决定的字段永远看得见（2026-09-03 排版体检）
		l.text = "%s  %d 人局 %d/%d  %s  %s 的房间" % [r["code"], r["players"],
			r["seated"], r["players"], TIMER_TEXT.get(r["timer"], "%d 秒" % r["timer"]), r["host"]]
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		_paint_link(l, Color.WHITE if i == _lobby_sel else CWStyle.TEXT_HI)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.size = Vector2(LIST_W, l.get_minimum_size().y)


func _create_value_text(i: int) -> String:
	match i:
		0:
			@warning_ignore("integer_division")
			var half: int = _create["players"] / 2
			return "%d 人（%d 免疫 · %d 癌症）" % [_create["players"], half, half]
		1:
			return TIMER_TEXT.get(_create["timer"], "%d 秒" % _create["timer"])
		2:
			return "公开（进大厅列表）" if _create["public"] else "私密（凭房间码）"
	return ""


func _repaint_create() -> void:
	for i in N_CREATE_ROWS:
		var on := i == _create_sel
		_create_names[i].add_theme_color_override("font_color", Color.WHITE if on else ROW_LABEL)
		_create_values[i].text = _create_value_text(i)
		_create_values[i].size = _create_values[i].get_minimum_size()
		_create_values[i].add_theme_color_override("font_color", Color.WHITE if on else CWStyle.TEXT_HI)
		## 箭头只在焦点行亮出来；被悬停的那枚转白发光（同 CWConfigPanel._repaint）
		for arrow: Label in _create_arrows[i]:
			arrow.visible = on
			var hovering := arrow == _hot_arrow
			arrow.add_theme_color_override("font_color", Color.WHITE if hovering else CWStyle.IMMUNE)
			arrow.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
			arrow.add_theme_constant_override("outline_size", 8 if hovering else 0)
	## 焦点行标题的辉光跟焦点走（在按钮上时收起——按钮有自己的高亮语言）
	_create_glow.visible = _create_sel < N_CREATE_ROWS
	if _create_sel < N_CREATE_ROWS:
		_create_glow.position = Vector2(SLOT_X, ROW_Y0 + _create_sel * ROW_H)
		for layer in _create_glow.get_children():
			(layer as Label).text = CREATE_ROWS[_create_sel]
		_create_marker.position = Vector2(SLOT_X - 18, ROW_Y0 + _create_sel * ROW_H + 13)
	else:
		_create_marker.position = Vector2(SLOT_X - 18, BTN_Y + BTN_H / 2.0)
	_btn_focus(_create_btn, _create_sel == N_CREATE_ROWS)


## 等待室整页按最新的 room 视图重画（席位行每次重建：行数、按钮集合都随视图变）
func _repaint_room() -> void:
	if client == null or client.room.is_empty():
		return
	var v: Dictionary = client.room
	_title.text = "房间 %s" % v["code"]
	_sub.text = "%s · 每步 %s · %d 人局 · 房主 %s%s" % ["公开" if v["public"] else "私密",
		TIMER_TEXT.get(v["timer"], "%d 秒" % v["timer"]), v["players"], v["host"],
		"（对局进行中）" if v["state"] == "playing" else ""]
	_sub.size = _sub.get_minimum_size()
	for c in _seat_root.get_children():
		_seat_root.remove_child(c)
		c.queue_free()
	var seats: Array = v["seats"]
	var host: bool = v["you_host"]
	var me: int = v["you_seat"]
	for i in seats.size():
		_build_seat_row(i, seats[i], host, me, v["state"] == "waiting")
	var watching: Array = []
	var seated_names := {}
	for s in seats:
		if s["kind"] == "human":
			seated_names[s["nick"]] = true
	for n in v["members"]:
		if not seated_names.has(n):
			watching.append(n)
	_members_label.text = "未入座：%s" % "、".join(watching) if not watching.is_empty() else ""
	var waiting: bool = v["state"] == "waiting"
	_ready_btn.visible = waiting and me >= 0
	if me >= 0:
		_ready_text.text = "取消准备" if seats[me]["ready"] else "准备"
	_start_btn.visible = waiting and host
	_stand_link.visible = waiting and me >= 0
	if waiting:
		var missing := 0
		var unready := 0
		for s in seats:
			if s["kind"] == "":
				missing += 1
			elif s["kind"] == "human" and not s["ready"]:
				unready += 1
		if missing > 0:
			_set_status("还有 %d 个空席：点空席坐下，房主可给空席放 AI" % missing)
		elif unready > 0:
			_set_status("等 %d 位玩家准备" % unready)
		else:
			_set_status("全员就绪，等房主开局" if not host else "全员就绪，可以开局")
	elif me < 0:
		_set_status("对局进行中，你未入座；可以离开房间")


func _build_seat_row(i: int, s: Dictionary, host: bool, me: int, waiting: bool) -> void:
	var y := SEAT_Y0 + i * SEAT_H
	var immune: bool = s["faction"] == CWData.Faction.IMMUNE
	var fac := ColorRect.new()
	fac.position = Vector2(SLOT_X, y + 4)
	fac.size = Vector2(4, 22)
	fac.color = CWStyle.IMMUNE if immune else CWStyle.CANCER
	fac.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seat_root.add_child(fac)
	var seat_name := CWStyle.label(seat_label(i, s["faction"]), CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	seat_name.position = Vector2(SLOT_X + 12, y + 10)
	_seat_root.add_child(seat_name)
	var who := ""
	var who_color := CWStyle.TEXT_HI
	match s["kind"]:
		"":
			who = "空席 · 点击坐下" if waiting else "空席"
			who_color = CWStyle.TEXT_OFF
		"ai":
			who = s["nick"]
			who_color = CWStyle.TEXT
		_:
			who = s["nick"] + ("（你）" if i == me else "")
	var occupant := _clicky(_seat_root, who, Vector2(SLOT_X + 70, y + 4), func() -> void: _seat_click(i))
	_paint_link(occupant, who_color)
	## 12 字昵称 +「（你）」= 300px，会压到 SLOT_X+250 的状态列 → 定宽 + 省略号（2026-09-03 排版体检）
	occupant.clip_text = true
	occupant.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	occupant.size = Vector2(SEAT_NAME_W, occupant.size.y)
	if not (waiting and (s["kind"] == "" or i == me)):
		occupant.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var state := ""
	var state_color := CWStyle.TEXT_DIM
	if s["kind"] == "human":
		if not s["online"]:
			state = "离线"
			state_color = CWStyle.CANCER
		elif waiting:
			state = "已准备" if s["ready"] else "未准备"
			state_color = CWStyle.IMMUNE if s["ready"] else CWStyle.TEXT_DIM
	var st := CWStyle.label(state, CWStyle.SIZE_LABEL, state_color)
	st.position = Vector2(SLOT_X + 250, y + 10)
	_seat_root.add_child(st)
	if not (host and waiting):
		return
	var x := SLOT_X + 310
	match s["kind"]:
		"":
			_clicky(_seat_root, "新手AI", Vector2(x, y + 10), func() -> void: client.set_ai(i, "heur"), CWStyle.SIZE_LABEL)
			_clicky(_seat_root, "专家AI", Vector2(x + 60, y + 10), func() -> void: client.set_ai(i, "mc"), CWStyle.SIZE_LABEL)
		"ai":
			_clicky(_seat_root, "撤掉", Vector2(x, y + 10), func() -> void: client.set_ai(i, ""), CWStyle.SIZE_LABEL)
		_:
			if i != me:
				_clicky(_seat_root, "踢出", Vector2(x, y + 10), func() -> void: client.kick(i), CWStyle.SIZE_LABEL)


## 席位名 = 引擎给玩家起的名（免疫A / 癌症A …），按阵营各自编号，和对局里的名字对得上
static func seat_label(i: int, faction: int) -> String:
	var order: Array = CWData.FACTION_ORDER[6]
	var n := 0
	for k in i:
		if k < order.size() and order[k] == faction:
			n += 1
	return ("免疫" if faction == CWData.Faction.IMMUNE else "癌症") + char(65 + n)


func _set_status(s: String) -> void:
	_status.text = s


# ============ 小部件 ============

func _row_label(root: Control, text: String, row: int) -> Label:
	var l := CWStyle.label(text, CWStyle.SIZE_BODY, ROW_LABEL)
	l.position = Vector2(SLOT_X, ROW_Y0 + row * ROW_H)
	root.add_child(l)
	return l


## 输入框：点阵字 20px、和按钮同一套描边；焦点时描边全亮
func _edit(root: Control, at: Vector2, w: float, placeholder: String, max_len: int) -> LineEdit:
	var e := LineEdit.new()
	e.position = at
	e.size = Vector2(w, 34)
	e.placeholder_text = placeholder
	e.max_length = max_len
	e.context_menu_enabled = false
	e.add_theme_font_override("font", CWStyle.FONT)
	e.add_theme_font_size_override("font_size", CWStyle.SIZE_BODY)
	e.add_theme_color_override("font_color", CWStyle.TEXT_HI)
	e.add_theme_color_override("font_placeholder_color", CWStyle.TEXT_OFF)
	e.add_theme_color_override("caret_color", CWStyle.IMMUNE)
	e.add_theme_stylebox_override("normal", CWStyle.box(0.45, CWStyle.BTN_BG, 2, 8))
	e.add_theme_stylebox_override("focus", CWStyle.box(1.0, CWStyle.BTN_BG, 2, 8))
	root.add_child(e)
	return e


## 可点击的文字（同配置面板的 _clicky：命中框贴着字、手型光标、左键回调并标记已处理）。
## hover = 通用悬停反馈：转白 + 白光描边，移开还原（2026-09-03 Kevin：联机各页也要有和主菜单一样的辉光）；
## 拨值箭头与值传 false，它们的悬停由 _repaint_create 统一画。
func _clicky(root: Control, text: String, at: Vector2, on_click: Callable, size: int = CWStyle.SIZE_BODY,
		hover: bool = true) -> Label:
	var label := CWStyle.label(text, size, CWStyle.TEXT_HI)
	label.position = at
	label.size = label.get_minimum_size()
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	if hover:
		label.mouse_entered.connect(func() -> void: _link_hot(label, true))
		label.mouse_exited.connect(func() -> void: _link_hot(label, false))
	root.add_child(label)
	return label


## 文字链接的悬停态：白字 + 白光描边（正文 8 / 小字 6）；静止色记在 meta 里，移开时还原
func _link_hot(label: Label, hot: bool) -> void:
	label.set_meta("hot", hot)
	if hot:
		if not label.has_meta("rest"):
			label.set_meta("rest", label.get_theme_color("font_color"))
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
		label.add_theme_constant_override("outline_size",
			8 if label.get_theme_font_size("font_size") >= CWStyle.SIZE_BODY else 6)
	else:
		label.add_theme_color_override("font_color", label.get_meta("rest", CWStyle.TEXT_HI))
		label.add_theme_constant_override("outline_size", 0)


## 给链接定静止色：正在悬停就只记下来，等移开再生效（重画不该把悬停的白光盖掉）
func _paint_link(label: Label, color: Color) -> void:
	label.set_meta("rest", color)
	if not label.get_meta("hot", false):
		label.add_theme_color_override("font_color", color)


## 键盘焦点停在实心按钮上：按钮变白（同配置面板「进入棋盘」的键盘高亮）；鼠标移开也不掉
func _btn_focus(p: Panel, on: bool) -> void:
	if p == null:
		return
	p.set_meta("focus", on)
	p.add_theme_stylebox_override("panel", p.get_meta("hot") if on else p.get_meta("rest"))


## 实心按钮（配置面板「进入棋盘」同款：青底圆角 5，悬停转白带白光）
func _solid_button(root: Control, text: String, at: Vector2, w: float, on_click: Callable) -> Panel:
	var rest := _btn_box(CWStyle.IMMUNE, 0.0)
	var hot := _btn_box(Color.WHITE, 0.5)
	var p := Panel.new()
	p.position = at
	p.size = Vector2(w, BTN_H)
	p.add_theme_stylebox_override("panel", rest)
	p.set_meta("rest", rest)
	p.set_meta("hot", hot)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.mouse_entered.connect(func() -> void: p.add_theme_stylebox_override("panel", hot))
	p.mouse_exited.connect(func() -> void:
		p.add_theme_stylebox_override("panel", hot if p.get_meta("focus", false) else rest))
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	root.add_child(p)
	var t := CWStyle.label(text, CWStyle.SIZE_BODY, Color("0d1620"))
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(t)
	return p


func _btn_box(bg: Color, glow: float) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.set_corner_radius_all(5)
	if glow > 0.0:
		b.shadow_color = Color(1, 1, 1, glow)
		b.shadow_size = 10
	return b


## 菱形焦点标（参数同 CWConfigPanel._build_marker）
func _marker() -> Node2D:
	var marker := Node2D.new()
	var halo_grad := Gradient.new()
	halo_grad.offsets = PackedFloat32Array([0.0, 0.34, 1.0])
	halo_grad.colors = PackedColorArray([Color(CWStyle.IMMUNE, 0.44),
		Color(CWStyle.IMMUNE, 0.2), Color(CWStyle.IMMUNE, 0.0)])
	var halo_tex := GradientTexture2D.new()
	halo_tex.gradient = halo_grad
	halo_tex.fill = GradientTexture2D.FILL_RADIAL
	halo_tex.fill_from = Vector2(0.5, 0.5)
	halo_tex.fill_to = Vector2(1, 0.5)
	halo_tex.width = 48
	halo_tex.height = 48
	var halo := Sprite2D.new()
	halo.texture = halo_tex
	marker.add_child(halo)
	var core := ColorRect.new()
	core.position = Vector2(-7, -7)
	core.size = Vector2(14, 14)
	core.rotation = PI / 4
	core.pivot_offset = Vector2(7, 7)
	core.color = CWStyle.IMMUNE
	core.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.add_child(core)
	return marker


func _px20() -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = CWStyle.FONT
	fv.spacing_glyph = 2
	return fv
