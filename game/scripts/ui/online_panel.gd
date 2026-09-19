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
##
## **局域网开服**（Kevin 2026-09-12，照 Minecraft「对局域网开放」）：连接页多一条「在本机开服」，第五页「局域网」
## 填端口、列出本机的局域网地址；`start_lan()` 在**本进程**里起一个 CWNetServer（和无头服务器跑的是同一份代码），
## 自己经 127.0.0.1 连上去走正常的大厅 / 建房流程，别人在「服务器」里填 本机地址:端口。`_process` 先轮询它再轮询
## 自己的客户端；离开联机页面（Esc / 离开 / 房间没了）就 `stop_lan()`，房里的人会收到断线。
## 不另开进程：热更补丁挂在本进程，子进程要自己挂一遍才不会跑旧规则；不开线程：服务器代码假定单线程。
## **自动发现**（同日追加）：房主开服后每秒往局域网广播一条（`scripts/net/cw_lan.gd`，UDP 8619），
## 连接页监听并列成「附近」名单，点一下就填地址连过去；离开连接页就停听。
class_name CWOnlinePanel
extends Control

## 界面音效（游戏外按钮的点击）。**preload 不给 class_name**：新类走不了热更，见那个文件的头注
const SFX := preload("res://scripts/ui/cw_sfx.gd")

signal cancelled                             ## 第一页 Esc：主菜单把自己淡回来
## 房间开局且第一份 sync 已排进 stream：main.gd 推镜头进棋盘。
## 批 1 步 8 起交出去的是**句柄**而不是客户端 —— 对局侧只认 CWKernel。
## 客户端本身仍归本面板管（回等待室 / 回大厅还要用这条连接），所以 CWMatch 拆联机局时只放手、不 close()
signal match_started(client: CWNetClient)   ## 句柄由 CWMatch.start_online 自建（客户端的生命周期仍归本面板）
signal match_lost(reason: String)            ## 对局中房间没了 / 令牌失效：main.gd 收摊回主菜单

enum Page { CONNECT, LOBBY, CREATE, ROOM, LAN }

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
## 等待室的聊天：**右栏**一张板（同 CWConfigPanel 席位表的位置与理由 ——
## 「放右侧而不是左栏往下加行」）。左栏已经被席位排满：
## 214..394 席位、398 未入座名单、438 按钮，中间没有一行的空。
const CHAT_X := 560.0
const CHAT_Y := 214.0
const CHAT_W := 340.0
const CHAT_ROWS := 7
const CHAT_ROW_H := 18.0
const CHAT_HEAD := "聊天　Tab 换频道"   ## 标题顺带当快捷键表（同对局里那份 CWChatBox.TITLE）
const CHAT_INPUT_H := CWChatBox.INPUT_H   ## 输入框同局内那只（Kevin 2026-09-17：换成局内那种效果）

const SEAT_Y0 := 214.0       ## 等待室席位第一行
const SEAT_H := 30.0
const RETRY_MS := 3000
## 大厅每隔这么久自己要一次房间表（Kevin 2026-09-13：「没有『进行中 · 可观战』这个栏目」）。
## 根因不是那一栏没做：大厅原来**只在进页 / 离房 / 报错时**问一次，别人开打是之后的事，
## 名单就一直停在「那会儿还没人在打」。报文只有几十字节，3 秒一次的代价比让人去点「刷新」小得多。
const LOBBY_POLL_MS := 3000
const ROW_LABEL := Color("9fb6bd")
const TIMER_TEXT := { 0: "不限", 30: "30 秒", 60: "60 秒", 90: "90 秒" }
const CREATE_ROWS := ["人数", "每步计时", "可见性", "观众视角"]
const N_CREATE_ROWS := 4
## 建房页的行距：这页曾要塞五行，只好压到 34（251 起五行到 413，离建房按钮 BTN_Y 438 还剩一行）。
## 2026-09-19 删掉「世界事件」行之后只剩四行，Kevin 同日「行间距可以调大一点」——
## 回到 ROW_H 42（与连接页 / 局域网页 / 配置页 / 主菜单项一致）：251 起四行到 377，末行底离按钮 40 多像素。
## 改这个数记得看图（preview_online_lan.gd 的 _create 那张）。
const CREATE_ROW_H := ROW_H
const LAN_PORT_MIN := 1024      ## 1023 以下是系统端口，Windows / macOS 都要管理员才绑得上
const LAN_PORT_MAX := 65535
const CWLan := preload("res://scripts/net/cw_lan.gd")   ## 局域网自动发现（没有 class_name：要走热更）
const FOUND_ROWS := 3            ## 连接页「附近」最多列几个（第三行下面到按钮只剩三行的空）
const FOUND_ROW_H := 20.0

var client: CWNetClient
var page := Page.CONNECT
var in_match := false        ## 面板藏着、对局在跑；此时 welcome/room 不再切页

var _nick: LineEdit
var _addr: LineEdit
var _code: LineEdit
## 局域网开服：本进程里的服务器（null = 没开）与它的端口；页上的端口框与本机地址
var lan: CWNetServer = null
var lan_port := 0
var _lan_port_edit: LineEdit
var _lan_ips: Label
var _lan_nick: LineEdit    ## 与连接页的昵称双向同步（Kevin 09-12：开服的人也要能在这页填昵称）
## 自动发现：房主那只广播、客户端那只监听（只在连接页期间活着）；「附近」三行与没听到时的说明
var _beacon = null         ## CWLan，开服期间每秒广播
var _scan = null           ## CWLan，连接页期间监听
var _found_labels: Array[Label] = []
var _found_note: Label
var _found_sel := -1        ## 键盘选中的那一行（-1 = 没选；回车走地址框那条路）；选中行带白光（Kevin 09-12）
var _lobby_polled := 0      ## 上一次自动要房间表的时刻（ms）
var _roots := {}             ## Page -> 该页的根 Control
var _status: Label
var _title: Label
var _sub: Label
## 建房页的取值与焦点（与配置面板同一套键盘模型：上下选行、左右拨值）
## 观众视角默认**背面**：不是保守，是「别让房主在不知情的情况下把自己的手牌公开出去」——
## 要露手牌得自己拨一下（Kevin 2026-09-13 定这一档可选）
var _create := { "players": 4, "timer": 60, "public": true, "watch_hands": false }
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
var _lobby_rooms: Array = []   ## 能坐进去的（服务器的 rooms）
var _lobby_live: Array = []    ## 正在打、可观战的（服务器的 live）
## 真正渲出来的那几行：房间行 { room = {...} } 或分隔行 { head = "…" }。
## 面板只有 5 行、下面 12px 就是按钮，塞不下两组表头 —— 所以「进行中」那组
## 只用一条分隔行开头，并且**永远至少留一行给它**（见 _compose_lobby）。
var _lobby_view_rows: Array = []
var _chat_rows: Array[Label] = []
var _chat_input: LineEdit
var _chat_scope: Label
var _chat_head: Label
var _chat_team := false      ## 这一句发给谁：false 全体 / true 己方
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
## **退出房间之后还回得去**（issue #46）。一局打到一半点「离开房间」，服务器那边
## 席位与令牌是留着的（`CWRoom.leave` 只在等待室清席位，对局中只标「已离开」）——
## 回不去的是**客户端**：`CWNetClient.leave()` 顺手把房间码和令牌一起清了（`_clear_room`），
## 连接本身又被 `leave_online()` 丢掉，于是那张回程票谁都不拿着了。
## 所以离开之前先把这一席抄在**面板**上：面板跟着主菜单活着，比那条连接长命。
## 字段 {code, token, url}；空 = 没有可回去的对局。**落盘**进 `CWSettings.resume`（Kevin 09-19「落盘吧」）：
## 面板比那条连接长命，却比不过一次运行 —— 关掉客户端再开票就没了，而服务器那一席还留着。
## 写票一律走 `_set_resume()`（抄席 / 用掉 / 作废三处），漏一处盘上就留着张过期票继续骗人。
## **连服务器地址一起抄**：房间码只在它自己那台服务器上唯一，判该不该拿票看 `_resume_here()`。
var _resume := {}
var _resume_tried := false   ## 上一次发出去的是「凭令牌回房」——错误报文该不该拿来作废 _resume，看它
var _want_reconnect := false
var _retry_at := 0
var _awaiting_state := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 整层接管：底下淡掉的菜单项收不到点击
	visible = false
	_build()
	## 上一次运行留下的回程票（issue #46 落盘）。面板是点「联机对战」才建的
	## （`CWMainMenu._open_online`），所以「进联机页」正是读盘这一下。
	_resume = CWSettings.resume.duplicate()


func open() -> void:
	in_match = false
	_nick.text = CWSettings.nick
	_addr.text = CWSettings.server
	_lan_nick.text = _nick.text
	_lan_port_edit.text = str(CWSettings.lan_port)
	_lan_ips.text = lan_address_text()
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
	_remember_seat()     ## 对局中退出（暂停菜单「离开房间」走的就是这条）：留一张回程票，issue #46
	if client != null:
		if client.code != "":
			client.leave()
		client.dispose()
		client = null
	stop_lan()
	_stop_scan()
	visible = false
	page = Page.CONNECT


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _beacon != null:
		## 广播里带上「这儿有几局能看」（观战 2026-09-13）：算的是**还进得去观众**的那些，
		## 满员的房标出来等于骗人白连一趟
		if lan != null:
			_beacon.set_live(watchable_of(lan))
		_beacon.poll_host(now)
	if _scan != null and _scan.poll_listen(now):
		_repaint_found()
	if lan != null:
		lan.poll()      ## 本机开的服务器先收发一轮，自己的客户端紧跟着轮询（同一帧内就能来回）
	if client == null:
		return
	client.poll()
	## 大厅停着的时候自己刷新：别人开打 / 打完了，这一栏才跟得上（Kevin 2026-09-13）
	if page == Page.LOBBY and not in_match and client.status == "open" \
			and now - _lobby_polled >= LOBBY_POLL_MS:
		_lobby_polled = now
		client.list_rooms()
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
			elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
				## 「附近」名单：上下选行，绕回；没听到人时上下键没事干
				var n := _found_count()
				if n > 0:
					get_viewport().set_input_as_handled()
					var d := 1 if event.is_action_pressed("ui_down") else -1
					_found_sel = posmod(_found_sel + d, n) if _found_sel >= 0 else (0 if d > 0 else n - 1)
					_repaint_found()
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				if _found_sel >= 0:
					_join_found(_found_sel)
				else:
					_connect()
		Page.LOBBY:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_disconnect()
			elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
				if _lobby_sel >= 0:
					var d := 1 if event.is_action_pressed("ui_down") else -1
					_lobby_sel = _next_room_row(_lobby_sel, d)   ## 分隔行跳过去
					_repaint_lobby()
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				var code := _row_code(_lobby_sel)
				if code != "":
					_lobby_join(code)
		Page.CREATE:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_show_page(Page.LOBBY)
			elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
				## 0..N_CREATE_ROWS 共 N+1 格（最后一格是「建房」按钮），绕回
				_create_sel = posmod(_create_sel
					+ (1 if event.is_action_pressed("ui_down") else -1), N_CREATE_ROWS + 1)
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
		Page.LAN:
			if event.is_action_pressed("ui_cancel"):
				get_viewport().set_input_as_handled()
				_show_page(Page.CONNECT)
			elif event.is_action_pressed("ui_accept"):
				get_viewport().set_input_as_handled()
				_host_lan()


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
	stop_lan()
	_show_page(Page.CONNECT)
	_set_status("")


# ============ 局域网开服 ============

## 端口文字 → 端口号；不是整数、不在 LAN_PORT_MIN ~ LAN_PORT_MAX 内 → 0（不开）。**纯函数**。
static func lan_port_of(text: String) -> int:
	var t := text.strip_edges()
	if not t.is_valid_int():
		return 0
	var p := int(t)
	return p if p >= LAN_PORT_MIN and p <= LAN_PORT_MAX else 0


## 本机的局域网 IPv4（10.x / 172.16~31.x / 192.168.x）—— 这是给别人填的地址，
## 所以回环、169.254 自动配置、公网地址、IPv6 都不要；顺序照系统给的。**纯函数**。
static func lan_addresses_of(all: Array) -> Array:
	var out: Array = []
	for a in all:
		var s := str(a)
		if s.contains(":") or not s.is_valid_ip_address():
			continue
		var b := s.split(".")
		if b.size() != 4:
			continue
		var b0 := int(b[0])
		var b1 := int(b[1])
		if b0 == 10 or (b0 == 172 and b1 >= 16 and b1 <= 31) or (b0 == 192 and b1 == 168):
			out.append(s)
	return out


static func lan_addresses() -> Array:
	return lan_addresses_of(Array(IP.get_local_addresses()))


func lan_address_text() -> String:
	var ips := lan_addresses()
	return " · ".join(PackedStringArray(ips)) if not ips.is_empty() else "没找到局域网地址（没连 Wi-Fi / 网线？）"


## 「地址:端口」一条，给大厅 / 等待室的副标题用；几个网卡就取第一个
func lan_where() -> String:
	var ips := lan_addresses()
	return "%s:%d" % [ips[0] if not ips.is_empty() else "127.0.0.1", lan_port]


## 在本进程里起服务器。OK 之外的错误码 = 端口被占用或没权限，由调用方告诉玩家
func start_lan(port: int, nick: String = "") -> Error:
	stop_lan()
	var s := CWNetServer.new()
	var err := s.start(port, "*")
	if err != OK:
		return err
	lan = s
	lan_port = port
	## 广播「我在这儿」：起不来（没网卡之类）不影响开服，别人手填地址照样进
	_beacon = CWLan.new()
	if _beacon.start_host(port, nick if nick != "" else CWSettings.nick) != OK:
		_beacon = null
	return OK


func stop_lan() -> void:
	if _beacon != null:
		_beacon.stop()
		_beacon = null
	if lan == null:
		return
	lan.stop()
	lan = null
	lan_port = 0


# ============ 局域网自动发现：连接页的「附近」名单 ============

## 进连接页开始听，离开就停：监听占着 8619，本机第二个客户端会绑不上（那就只能手填），别一直占着
func _start_scan() -> void:
	if _scan != null:
		return
	_scan = CWLan.new()
	if _scan.start_listen() != OK:
		_scan = null
	_repaint_found()


## 这台服务器上有几局**正在打、观众还没满**。**纯函数**（只读服务器的房间表），护栏直接核。
static func watchable_of(server: CWNetServer) -> int:
	var n := 0
	for r: CWRoom in server.rooms.values():
		if r.state == CWRoom.State.PLAYING and r.watchers() < CWRoom.MAX_WATCHERS:
			n += 1
	return n


func _stop_scan() -> void:
	if _scan != null:
		_scan.stop()
		_scan = null


## 「附近」一行的文案：昵称 · 地址:端口，协议号不对的标出来（连上去也会被拒，先说清楚）。
## 那台机器上有正在打的局就标出来（2026-09-13 观战开回来）—— 进去之后在大厅「进行中 · 可观战」那栏点它。
## 版本不符时**不标**：连都连不上，说「可观战」只会让人白点一次。
static func found_text(e: Dictionary) -> String:
	var who: String = e["nick"] if e["nick"] != "" else "房主"
	var bad: bool = int(e["ver"]) != CWNet.NET_VERSION
	var live: int = int(e.get("live", 0))
	var tail := "（版本不符）" if bad else ("  %d 局可观战" % live if live > 0 else "")
	return "%s · %s:%d%s" % [who, e["ip"], e["port"], tail]


func _found_count() -> int:
	return mini(_scan.entries().size(), FOUND_ROWS) if _scan != null else 0


func _repaint_found() -> void:
	var list: Array = _scan.entries() if _scan != null else []
	## 名单变了选中行要跟着钳：人走了就退到最后一行，全走了就没选
	_found_sel = mini(_found_sel, mini(list.size(), FOUND_ROWS) - 1)
	for i in _found_labels.size():
		var l: Label = _found_labels[i]
		if i < list.size():
			l.text = found_text(list[i])
			l.size = l.get_minimum_size()
			l.visible = true
			CWStyle.link_hot(l, i == _found_sel)     ## 选中行 = 悬停那一套白光（Kevin 09-12：选中要有辉光）
		else:
			l.text = ""
			l.visible = false
			CWStyle.link_hot(l, false)
	if _scan == null:
		_found_note.text = "没在听：8619 被占着（本机开着另一个客户端？），手填地址"
	elif list.is_empty():
		_found_note.text = "正在听局域网里的房主…（同一路由器下才收得到）"
	else:
		_found_note.text = ""


## 点「附近」的一行：地址填进去、直接连（和手填后按回车同一条路）
func _join_found(i: int) -> void:
	var list: Array = _scan.entries() if _scan != null else []
	if i >= list.size():
		return
	_addr.text = "%s:%d" % [list[i]["ip"], list[i]["port"]]
	_connect()


## 「开服并进入大厅」：起服务器 → 自己经回环连上（和 _connect 同一条路，只是地址不经过设置里的服务器项）
func _host_lan() -> void:
	var port := lan_port_of(_lan_port_edit.text)
	if port == 0:
		_set_status("端口要是 %d ~ %d 之间的整数" % [LAN_PORT_MIN, LAN_PORT_MAX])
		return
	var nick := CWNet.clean_nick(_lan_nick.text)
	CWSettings.nick = nick
	CWSettings.lan_port = port
	CWSettings.save_prefs()
	var err := start_lan(port, nick)
	if err != OK:
		_set_status("端口 %d 开不起来（%s），多半已被占用，换一个" % [port, error_string(err)])
		return
	if client != null:
		client.dispose()
	client = CWNetClient.new()
	client.message.connect(_on_message)
	client.disconnected.connect(_on_disconnected)
	if client.connect_to("ws://127.0.0.1:%d" % port, nick) != OK:
		client = null
		stop_lan()
		_set_status("连不上本机刚开的服务器")
		return
	_set_status("已在本机开服 · 局域网地址 %s:%d" % [lan_address_text(), port])


func _create_room() -> void:
	if client == null:
		return
	client.create_room(_create["players"], _create["timer"], _create["public"], 0,
		_create["watch_hands"])
	_set_status("建房中…")


func _join_code() -> void:
	if client == null:
		return
	var code := _code.text.strip_edges().to_upper()
	if code.length() != CWNet.CODE_LEN:
		_set_status("房间码是 %d 位" % CWNet.CODE_LEN)
		return
	_lobby_join(code)


func _leave_room() -> void:
	if client == null:
		return
	_want_reconnect = false
	_remember_seat()     ## issue #46
	client.leave()
	_show_page(Page.LOBBY)
	client.list_rooms()


## 离开一个**正在打的**房间之前，把自己那一席抄下来（issue #46）。
## 三个条件缺一不可：局在打、我有席位、手里有令牌 —— 观众和等待室里的人没有可回去的对局
## （等待室的规矩本来就是「掉线 = 起身」，`CWRoom.leave` 在那一档直接把席位清空）。
func _remember_seat() -> void:
	if client == null or client.code == "" or client.token == "" or client.my_seat < 0:
		return
	if str(client.room.get("state", "")) != "playing":
		return
	_set_resume({ "code": client.code, "token": client.token, "url": client.url })


## 写票的唯一入口：面板上那份与 `settings.cfg` 的 `[online] resume` 得始终是同一张（issue #46 落盘）。
## 抄席 / 用掉 / 作废三处都走这儿 —— 漏一处，下次开客户端就会照着盘上那张过期票预填房间码。
func _set_resume(ticket: Dictionary) -> void:
	_resume = ticket
	CWSettings.resume = ticket
	CWSettings.save_prefs()


## 手里那张回程票是不是**这台服务器**上的。
## 离开 A 服的对局改连 B 服，B 服上碰巧同号的房间既不是我那一局、令牌也对不上：
## 照样预填 + 「点加入回去接着打」就是骗人，点下去被答 no_room 还会把 A 服那张好端端的票一并作废。
## 地址对不上就**当没有票**：不预填、不改行文案、也不作废（票留着，回 A 服还能用）。
func _resume_here() -> bool:
	return not _resume.is_empty() and client != null \
		and str(_resume.get("url", "")) == client.url


## 大厅里点一间房（列表行 / 房间码 + 「加入」都走这儿）：**自己那一局凭令牌回去，别的照旧加入**。
## 差的不只是一个报文 —— `join` 进去是**观众**：看得见盘面、没有席位、一问都答不了，
## 而那一局的座位明明还给我留着。只有 `reconnect` 才是「接着打」（issue #46）。
func _lobby_join(code: String) -> void:
	if client == null or code == "":
		return
	if _resume_here() and code == str(_resume.get("code", "")):   ## 地址也要对得上，见 _resume_here
		_resume_tried = true
		_set_status("回到房间 %s…" % code)
		client.reconnect(code, str(_resume["token"]))
		return
	_resume_tried = false
	client.join(code)


## 回到大厅就把「你还有一局没打完」摆在眼前：房间码直接填进输入框，状态行写清按哪儿回去。
## **私密房在大厅列表里根本不出现**（`CWNetServer.lobby_view` 只列公开房），这条预填是它唯一的入口。
func _hint_resume() -> void:
	if not _resume_here() or _code == null:   ## 别在 B 服预填 A 服的房间码，见 _resume_here
		return
	_code.text = str(_resume["code"])
	_set_status("你还有一局没打完（房间 %s）—— 点「加入」回去接着打" % _resume["code"])


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
		3:
			_create["watch_hands"] = not _create["watch_hands"]
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
			_hint_resume()     ## 重新连上服务器正是回去的必经之路（issue #46）：别让那句话被冲掉
		"lobby":
			_lobby_rooms = m.get("rooms", [])
			## 观战（`CWMatch.WATCH_ON`，2026-09-13 开回来）：`live` 是正在打、可以观战的房。
			## 开关留着 —— 哪天再要收，改那一个常量就够：`live` 空了，`_compose_lobby`
			## 连「进行中 · 可观战」那条小标题都不会摆，也没有行可选
			_lobby_live = m.get("live", []) if CWMatch.WATCH_ON else []
			_compose_lobby()          ## 先合成，_first_room_row 才有得挑
			_lobby_sel = _first_room_row()
			_lobby_note.text = "服务器维护中，暂不能建房" if m.get("maintenance", false) else ""
			_repaint_lobby()
		"room":
			if in_match:
				return
			if page != Page.ROOM:
				_show_page(Page.ROOM)
				_set_status("")
			_repaint_room()
			## 回到自己那一席了：回程票用掉（issue #46）。判「有没有席位」而不是「进没进这间房」——
			## 以观众身份进同一间房不算回来，那时票还得留着
			if _resume_here() and str(m.get("code", "")) == str(_resume.get("code", "")) \
					and int(m.get("you_seat", -1)) >= 0:
				_set_resume({})
				_resume_tried = false
			## 开局：从这一刻起对局流排队，等第一份状态到了再进棋盘。
			## **不看有没有席位**（2026-09-09）：没坐下的人进去就是观众，
			## `CWMatch.start_online` 见 `my_seat < 0` 就把 human_players 留空 = 纯看，
			## 日志面板也跟着关过滤走全看视角。中途进来的人同样走这条路 ——
			## `CWRoom.join` 见到 PLAYING 会立刻给他推一份状态。
			if m.get("state", "") == "playing" and not client.sequenced:
				client.sequenced = true
				_awaiting_state = true
		"chat":
			_repaint_chat()
		"sync":
			if _awaiting_state and client.sequenced:
				_awaiting_state = false
				hide_for_match()
				## sequenced 仍是 true：对局流照旧排队；CWKernelRemote 由 CWMatch.start_online 自建、镜像从 stream 里的 sync 条目装出来
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
				## 刚才那一下就是「凭令牌回房」而它被拒了 ⇒ 那一席没了（局打完腾席 / 关房 / 令牌作废）。
				## 票作废掉，别让预填的房间码和「点加入回去接着打」继续骗人（issue #46）。
				## 只认**自己发起的那一次**：随手输错一个房间码同样答 no_room，不能连坐
				if _resume_tried and not in_match:
					_set_resume({})
					_resume_tried = false
					_set_status("那一局已经结束，或席位已被收回")
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
	_build_lan(_roots[Page.LAN])     ## 要在连接页之后：它把昵称框和连接页的接在一起
	_build_lobby(_roots[Page.LOBBY])
	_build_create(_roots[Page.CREATE])
	_build_room(_roots[Page.ROOM])


## 连接页退回主菜单：Esc 与「返回主菜单」链接共用一条路；主菜单收到 cancelled 后把自己淡回来
func _back_to_menu() -> void:
	stop_lan()
	_stop_scan()
	visible = false
	cancelled.emit()


func _build_connect(root: Control) -> void:
	_row_label(root, "昵称", 0)
	_nick = _edit(root, Vector2(VALUE_X, ROW_Y0 - 4), 200, "玩家", CWNet.NICK_MAX)
	_row_label(root, "服务器", 1)
	_addr = _edit(root, Vector2(VALUE_X, ROW_Y0 + ROW_H - 4), 250, "地址:端口", 64)
	_nick.text_submitted.connect(func(_t: String) -> void: _connect())
	_addr.text_submitted.connect(func(_t: String) -> void: _connect())
	## 「默认」：填过局域网房主的地址之后一键回公网服务器（Kevin 2026-09-12 局域网联机顺带）。
	## 和大厅页输入框旁的「加入」同一套：正文字号、行基线、悬停白光（_clicky 自带，Kevin 特意叮嘱过要有）
	## **走 CWSettings.default_server() 而不是自己拼** —— 网页版的默认地址是
	## wss://（见那个函数），原来这里硬写桌面那套，网页上点「默认」等于填一个
	## 必然被浏览器拦掉的 ws://
	_clicky(root, "默认", Vector2(ARROW_R_X + 10, ROW_Y0 + ROW_H), func() -> void:
		_addr.text = CWSettings.default_server())
	## 第三行：局域网开服的入口（Kevin 2026-09-12）—— 端口与本机地址在下一页填
	_row_label(root, "局域网", 2)
	_clicky(root, "在本机开服", Vector2(VALUE_X, ROW_Y0 + ROW_H * 2), func() -> void: _show_page(Page.LAN))
	## 第四行「附近」：自动发现听到的房主，最多三行（到按钮只剩这点空），点一行就连
	_row_label(root, "附近", 3)
	_found_note = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_found_note.position = Vector2(VALUE_X, ROW_Y0 + ROW_H * 3 + 3)
	root.add_child(_found_note)
	for i in FOUND_ROWS:
		var row := _clicky(root, "", Vector2(VALUE_X, ROW_Y0 + ROW_H * 3 + i * FOUND_ROW_H),
			func() -> void: _join_found(i), CWStyle.SIZE_LABEL)
		row.visible = false
		## _clicky 的悬停白光移开就收；键盘选中的那一行要留着 —— 接在它后面再点一次
		row.mouse_exited.connect(func() -> void:
			if i == _found_sel:
				CWStyle.link_hot(row, true))
		_found_labels.append(row)
	_solid_button(root, "进入大厅", Vector2(SLOT_X, BTN_Y), 182, _connect)
	## 「返回主菜单」（2026-09-03 Kevin 要的）：此前连接页只能按 Esc 退出，鼠标玩家没有出口。
	## 与建房页「返回大厅」同位（按钮右侧 200）、同一套链接语言，走的就是 Esc 那条路。
	_clicky(root, "返回主菜单", Vector2(SLOT_X + 200, BTN_Y + 5), _back_to_menu)


## 局域网页：端口 / 本机地址 / 两行提示；「开服并进入大厅」与连接页「进入大厅」同位同宽
func _build_lan(root: Control) -> void:
	## 昵称和连接页是同一个人的：两个框双向同步（text_changed 只在玩家敲字时发，程序赋值不会来回弹）
	_row_label(root, "昵称", 0)
	_lan_nick = _edit(root, Vector2(VALUE_X, ROW_Y0 - 4), 200, "玩家", CWNet.NICK_MAX)
	_lan_nick.text_changed.connect(func(t: String) -> void: _nick.text = t)
	_nick.text_changed.connect(func(t: String) -> void: _lan_nick.text = t)
	_lan_nick.text_submitted.connect(func(_t: String) -> void: _host_lan())
	_row_label(root, "端口", 1)
	_lan_port_edit = _edit(root, Vector2(VALUE_X, ROW_Y0 + ROW_H - 4), 120, str(CWNet.DEFAULT_PORT), 5)
	_lan_port_edit.text_submitted.connect(func(_t: String) -> void: _host_lan())
	_row_label(root, "本机地址", 2)
	_lan_ips = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_lan_ips.position = Vector2(VALUE_X, ROW_Y0 + ROW_H * 2)
	root.add_child(_lan_ips)
	var hint := CWStyle.label("开服后其他玩家的连接页会自动列出你（同一路由器下），也可手填 本机地址:端口。\n首次开服 Windows 会问防火墙，选「允许」；你退出联机页面，服务就停。",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	hint.position = Vector2(SLOT_X, ROW_Y0 + ROW_H * 3)
	root.add_child(hint)
	_solid_button(root, "开服并进入大厅", Vector2(SLOT_X, BTN_Y), 182, _host_lan)
	_clicky(root, "返回", Vector2(SLOT_X + 200, BTN_Y + 5), func() -> void: _show_page(Page.CONNECT))


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
				var code := _row_code(i)
				if code != "":
					_lobby_join(code))
		row.mouse_entered.connect(func() -> void:
			if _row_code(i) != "":
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
	_create_marker = CWStyle.focus_marker()
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
		var y := ROW_Y0 + i * CREATE_ROW_H
		var nm := CWStyle.label(CREATE_ROWS[i], CWStyle.SIZE_BODY, ROW_LABEL)
		nm.position = Vector2(SLOT_X, y)
		root.add_child(nm)
		_create_names.append(nm)
		var hit := Control.new()
		hit.position = Vector2(SLOT_X - 30, y - 8)
		hit.size = Vector2(420, CREATE_ROW_H - 4)
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
	## 聊天总开关 `CWMatch.CHAT_ON`（2026-09-10 关、09-16 开回来）。关着时**整块不建**，
	## 收在这一处就够 —— `_repaint_chat()` 开头判 `_chat_scope == null` 就返回，
	## 两个调用点（收到 chat 报文、切到等待室页）都会安静地什么都不做。
	if CWMatch.CHAT_ON:
		_build_chat(root)


## 等待室的聊天板。**约人、分阵营这些话都发生在开局之前** ——
## 对局里那套（回车唤出的标签页）在这儿用不上：等待室没有棋盘要让，
## 右栏本来就空着，常驻显示比按键唤出更顺手。
func _build_chat(root: Control) -> void:
	## **底板不能省**：槽位那层暗罩只覆到 x 538 左右就淡没了，
	## 而联机面板是开在菜单场景里的 —— 菜单淡出的只有那层字，**棋盘装饰一直在**。
	## 没有板的话右栏的字直接压在亮棋盘上，根本读不清（Kevin 2026-09-09 问「会不会遮挡地图」，
	## 出图才发现真正的问题是这个）。样式照 CWConfigPanel 的席位表那张板。
	var plate := Panel.new()
	var box := CWStyle.box(0.42, Color(CWStyle.PANEL, 0.92))
	box.set_corner_radius_all(6)
	plate.add_theme_stylebox_override("panel", box)
	plate.position = Vector2(CHAT_X - 16, CHAT_Y - 40)
	## 竖向：标题 40 + 消息行 + 8 + 输入框 + 12。输入框 09-17 从正文字号那档（写 34、实为 36）换成局内那只（22 高、标签字号），板子跟着收
	plate.size = Vector2(CHAT_W + 32, CHAT_ROWS * CHAT_ROW_H + 40 + 8 + CHAT_INPUT_H + 12)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(plate)
	_chat_head = CWStyle.label(CHAT_HEAD, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_chat_head.position = Vector2(CHAT_X, CHAT_Y - 18)
	root.add_child(_chat_head)
	## 发给谁：点一下换，或者按 Tab（Kevin 2026-09-17：等待室也要）。同对局里那套 —— 用颜色说话，不写「[全体]」前缀
	_chat_scope = _clicky(root, "", Vector2(CHAT_X + CHAT_W - 60, CHAT_Y - 18), _toggle_chat_scope, CWStyle.SIZE_LABEL)
	for i in CHAT_ROWS:
		var l := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
		l.position = Vector2(CHAT_X, CHAT_Y + i * CHAT_ROW_H)
		l.size = Vector2(CHAT_W, CHAT_ROW_H)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		root.add_child(l)
		_chat_rows.append(l)
	_chat_input = _edit(root, Vector2(CHAT_X, CHAT_Y + CHAT_ROWS * CHAT_ROW_H + 8),
		CHAT_W, "说点什么…", CWNet.CHAT_MAX, true)
	_chat_input.text_submitted.connect(func(t: String) -> void:
		if client != null:
			client.say(t, _chat_team)
		_chat_input.text = "")
	## Tab **必须在输入框自己这一层截**：焦点导航（`ui_focus_next`）就绑在 Tab 上、排在 `_unhandled_input` 前面，
	## 不 accept 的话这一下被拿去切焦点，输入框还丢焦点（对局里那份 09-10 踩过）
	_chat_input.gui_input.connect(func(e: InputEvent) -> void:
		if CWChatBox.is_tab(e):
			_chat_input.accept_event()
			_toggle_chat_scope())


## 全体 ⇄ 己方。标签点一下、按 Tab，两条路同一个出口
func _toggle_chat_scope() -> void:
	_chat_team = not _chat_team
	_repaint_chat()


## 把客户端收到的聊天铺到板上。**每次收到就重铺**，不做增量 ——
## 七行而已，比维护游标便宜
func _repaint_chat() -> void:
	if _chat_scope == null:
		return
	_chat_scope.text = "己方" if _chat_team else "全体"
	## **定静止色一律走 `paint_link`**（issue #51）。这一条就写在 CWStyle.link_hot 头上，
	## 这儿原来漏了：标签是 `_clicky` 建的，身上挂着悬停白光。鼠标移上去时
	## `link_hot(true)` 把**当时**的字色（全体 = TEXT_HI）记进 meta "rest"；接着点一下换到「己方」，
	## 这里直写 font_color 着上阵营色（看着是对的），可 meta 里还是 TEXT_HI ——
	## 鼠标一移开，`link_hot(false)` 就把它还成白字，而且再也回不来了
	## （5yntaxEr 报的「切到己方是蓝的，移开鼠标变白，再移回也是白」）。
	## paint_link 改的是静止色本身，正悬停着就只记下来、等移开再生效。
	CWStyle.paint_link(_chat_scope,
		CWChatBox.faction_color(_my_faction()) if _chat_team else CWStyle.TEXT_HI)
	var log: Array = client.chat_log if client != null else []
	for i in CHAT_ROWS:
		var idx: int = log.size() - CHAT_ROWS + i
		var l: Label = _chat_rows[i]
		if idx < 0:
			l.text = ""
			continue
		l.text = CWChatBox.line_text(log[idx])
		l.add_theme_color_override("font_color", CWChatBox.line_color(log[idx]))


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
	## 本机开着服的话，大厅 / 建房页的副标题一直写着地址 —— 房主等人的时候要念给别人听
	_sub.text = "局域网开服中 · %s" % lan_where() if lan != null else ""
	if p == Page.CONNECT:
		_found_sel = -1
		_start_scan()
	else:
		_stop_scan()
	match p:
		Page.CONNECT:
			_title.text = "联机对战"
		Page.LAN:
			_title.text = "局域网联机"
			_lan_ips.text = lan_address_text()   ## 每次进页重扫：Wi-Fi 刚连上地址才有
		Page.LOBBY:
			_title.text = "大厅"
			_hint_resume()     ## issue #46：有没打完的对局就预填房间码、把话说在前头
			_repaint_lobby()
		Page.CREATE:
			_title.text = "建房"
			_repaint_create()
		Page.ROOM:
			_repaint_room()
			_repaint_chat()


## 把两栏拼成要渲的那几行。**给「进行中」留位**：只要有可观战的房，
## 能坐的那组最多占 LIST_N − 2 行（一行分隔 + 至少一行进行中），
## 否则五个待开的房就会把观战入口整个挤没。
func _compose_lobby() -> void:
	_lobby_view_rows = []
	var join_cap: int = LIST_N if _lobby_live.is_empty() else LIST_N - 2
	for r: Dictionary in _lobby_rooms:
		if _lobby_view_rows.size() >= join_cap:
			break
		_lobby_view_rows.append({ "room": r })
	if _lobby_live.is_empty():
		return
	_lobby_view_rows.append({ "head": "进行中 · 可观战" })
	for r: Dictionary in _lobby_live:
		if _lobby_view_rows.size() >= LIST_N:
			break
		_lobby_view_rows.append({ "room": r })


## 第一个能选的行（分隔行不能选）；没有就 -1
func _first_room_row() -> int:
	for i in _lobby_view_rows.size():
		if _lobby_view_rows[i].has("room"):
			return i
	return -1


## 从 i 往 d 方向找下一个能选的行，找不到就留在原地
## 下一个**真房间行**（分隔行跳过去），到头绕回
func _next_room_row(i: int, d: int) -> int:
	return CWStyle.step_wrap(i, d, _lobby_view_rows.size(),
		func(j: int) -> bool: return _lobby_view_rows[j].has("room"))


## 这一行对应的房间码；分隔行返回空串
func _row_code(i: int) -> String:
	if i < 0 or i >= _lobby_view_rows.size() or not _lobby_view_rows[i].has("room"):
		return ""
	return str(_lobby_view_rows[i]["room"]["code"])


func _repaint_lobby() -> void:
	_compose_lobby()          ## 只有 5 行，就地合成比让每个调用方记得调便宜
	for i in LIST_N:
		var l: Label = _lobby_labels[i]
		## **先把裁剪关掉再往下走**（Kevin 2026-09-13 截图：「这里没有『可观战』的 title」）。
		## 这一行上一轮很可能画的是房间行，那一支把 `clip_text` 和省略号打开了 ——
		## 而 Label 一旦开着裁剪，`get_minimum_size()` 的**宽度就是 1 px**（它不再向父级要位置）。
		## 小标题和「（暂无公开房间）」都照着最小尺寸定宽，于是被塞进 1 px 宽的框里：
		## 字一直在，屏幕上什么都没有。房间行那一支下面自己会再打开。
		l.clip_text = false
		l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		if i >= _lobby_view_rows.size():
			l.text = "（暂无公开房间）" if i == 0 and _lobby_view_rows.is_empty() else ""
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			l.add_theme_color_override("font_color", CWStyle.TEXT_OFF)
			l.size = l.get_minimum_size()
			continue
		var row: Dictionary = _lobby_view_rows[i]
		if row.has("head"):
			## 分隔行：只是一句小标题，点不了也选不上
			l.text = str(row["head"])
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			l.add_theme_color_override("font_color", CWStyle.TEXT_DIM)
			l.size = l.get_minimum_size()
			continue
		var r: Dictionary = row["room"]
		## 房主昵称放**最后**：昵称最长 12 字，一行定宽 400 加省略号，被截的只会是昵称尾巴，
		## 房间码 / 人数 / 计时这些要拿来做决定的字段永远看得见（2026-09-03 排版体检）
		if str(r.get("state", "waiting")) == "playing":
			## 进行中的房：坐不进去，写的是**观众满没满**——那才是这一行要拿来做的决定
			## 全见的房要标出来：观众进去**看得到所有人手牌**，这是决定进不进的信息之一
			if _resume_here() and str(r["code"]) == str(_resume.get("code", "")):
				## 我自己那一局（issue #46）：点它是**回去接着打**，不是进去当观众 ——
				## 写「观众 2/8」会让人以为自己的席位已经没了。
				## **别往后加解释**：这一行定宽 LIST_W 400 px 加省略号，再多一句就被截掉
				## （真渲染图 `截图_2026-09-19_issues_net/lobby_after.png` 第一版就是这么截的），
				## 该说的话由状态行那一句承担
				l.text = "%s  %d 人局  ← 回到对局" % [r["code"], r["players"]]
			else:
				l.text = "%s  %d 人局  观众 %d/%d%s  %s 的房间" % [r["code"], r["players"],
					int(r.get("watchers", 0)), int(r.get("watch_max", 0)),
					"  全见" if bool(r.get("watch_hands", false)) else "", r["host"]]
		else:
			l.text = "%s  %d 人局 %d/%d  %s  %s 的房间" % [r["code"], r["players"],
				r["seated"], r["players"], TIMER_TEXT.get(r["timer"], "%d 秒" % r["timer"]), r["host"]]
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		CWStyle.paint_link(l, Color.WHITE if i == _lobby_sel else CWStyle.TEXT_HI)
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
		3:
			## 观众看不看得到手牌（Kevin 2026-09-13）。写清楚代价：全见 = 连你自己的手牌也露给观众
			## 值要短到 VALUE_X(250)~ARROW_R_X(500) 这 240px 里 —— 长了会盖住右边那枚拨值箭头
			return "全见（含所有人手牌）" if _create["watch_hands"] else "背面（看不到手牌）"
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
		_create_glow.position = Vector2(SLOT_X, ROW_Y0 + _create_sel * CREATE_ROW_H)
		for layer in _create_glow.get_children():
			(layer as Label).text = CREATE_ROWS[_create_sel]
		_create_marker.position = Vector2(SLOT_X - 18, ROW_Y0 + _create_sel * CREATE_ROW_H + 13)
	else:
		_create_marker.position = Vector2(SLOT_X - 18, BTN_Y + BTN_H / 2.0)
	_btn_focus(_create_btn, _create_sel == N_CREATE_ROWS)


## 等待室整页按最新的 room 视图重画（席位行每次重建：行数、按钮集合都随视图变）
## 我坐在哪个阵营：「己方」标签的颜色跟它走（Kevin 2026-09-17：癌症方要黄）；没入座 = 观众 = -1
func _my_faction() -> int:
	if client == null or client.my_seat < 0 or client.room.is_empty():
		return -1
	var seats: Array = client.room.get("seats", [])
	return int(seats[client.my_seat]["faction"]) if client.my_seat < seats.size() else -1


func _repaint_room() -> void:
	if client == null or client.room.is_empty():
		return
	_repaint_chat()   ## 换了席位「己方」要跟着换色；关着时它自己判空返回
	var v: Dictionary = client.room
	_title.text = "房间 %s" % v["code"]
	_sub.text = "%s · 每步 %s · %d 人局 · 房主 %s%s" % ["公开" if v["public"] else "私密",
		TIMER_TEXT.get(v["timer"], "%d 秒" % v["timer"]), v["players"], v["host"],
		"（对局进行中）" if v["state"] == "playing" else ""]
	## 本机开着服：地址跟在后面，除非那一行长到要压进右栏的聊天板（长昵称 + 6 人局就会）
	if lan != null:
		var base := _sub.text
		_sub.text = base + " · 局域网 " + lan_where()
		if _sub.get_minimum_size().x > CHAT_X - SLOT_X - 10.0:
			_sub.text = base
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
		_set_status("对局进行中，正在进入观战…")


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
	CWStyle.paint_link(occupant, who_color)
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
## small = 局内聊天框那种小输入框（标签字号 10、22 高、内边距 6）；默认是表单那种（正文字号 20、36 高）
func _edit(root: Control, at: Vector2, w: float, placeholder: String, max_len: int, small := false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.max_length = max_len
	e.context_menu_enabled = false
	e.add_theme_font_override("font", CWStyle.FONT)
	e.add_theme_font_size_override("font_size", CWStyle.SIZE_LABEL if small else CWStyle.SIZE_BODY)
	e.add_theme_color_override("font_color", CWStyle.TEXT_HI)
	e.add_theme_color_override("font_placeholder_color", CWStyle.TEXT_OFF)
	e.add_theme_color_override("caret_color", CWStyle.IMMUNE)
	var pad_h := 6 if small else 8   ## 内边距随字号折半，同 CWChatBox
	e.add_theme_stylebox_override("normal", CWStyle.box(0.45, CWStyle.BTN_BG, 2, pad_h))
	e.add_theme_stylebox_override("focus", CWStyle.box(1.0, CWStyle.BTN_BG, 2, pad_h))
	root.add_child(e)
	## 尺寸在**进树之后**设（同 CWChatBox 那条，2026-09-17）：进树前会被默认主题的最小高 31 钳住，
	## 22 那档当场就会被撑成 31。表单那档写 36 = 20px 字的行框 32 + 上下内边距 2×2 —— 以前写的 34
	## 进树后照样被真实最小高顶成 36（探针量过），从来就是 36，写成真值免得再骗一次
	e.position = at
	e.size = Vector2(w, CHAT_INPUT_H if small else 36.0)
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
			SFX.click()
			on_click.call())
	if hover:
		label.mouse_entered.connect(func() -> void: CWStyle.link_hot(label, true))
		label.mouse_exited.connect(func() -> void: CWStyle.link_hot(label, false))
	root.add_child(label)
	return label


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
			SFX.click()
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


func _px20() -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = CWStyle.FONT
	fv.spacing_glyph = 2
	return fv
