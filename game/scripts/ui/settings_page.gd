## settings_page.gd —— 设置：主菜单打开的小面板，改一下立即生效并落盘
##
## 视觉与键盘模型照抄对局配置面板（上下选行、左右拨值、Esc 返回）；
## 2026-08-30 起连拨值语汇也对齐它：箭头**固定位置**不随字宽跑、悬停亮白光、
## 选中行标题带主菜单同款辉光（对局内试玩第一轮要求「和配置面板一样」）。
## 两处值行面板仅共用 CWStyle.clickable_label 的点击底座：这边没有「开始」行、
## 值改动是**即时副作用**（写 CWSettings + 存盘），骨架和焦点仍各自维护。
class_name CWSettingsPage
extends Control

const W := 264
const PAD := 16
const TITLE_H := 42
const ROW_H := 36
const ARROW_L_X := 148   ## 拨值箭头的固定横坐标（不随值字宽跑，同配置面板）
const ARROW_R_X := 236
## 「检查更新」那一块：一行可点的字 + 一行状态小字
const UPDATE_H := 44

## 启动器与热更状态。**按路径 preload，不靠 class_name** —— 那两个文件刻意没有
## class_name（它们要在挂载补丁之前跑，不能进全局类表），见 boot.gd 文件头。
## 这里只用它们的**静态判据**（decide / pinned / verify_manifest / record），
## 白名单、验签、SHA 这几关只能有一处实现，不在这儿重抄一份。
const Boot := preload("res://scripts/boot.gd")
const PatchState := preload("res://scripts/patch_state.gd")

## 「检查更新」这一行只给**主菜单**那份设置页（由 CWMainMenu 置 true）。
## 对局中的暂停菜单里也有一份 —— 那儿不能给：补丁要重启才生效
## （挂载必须早于游戏代码的首次 load，见 boot.gd 硬约束 ①），
## 而重启会把正在打的这一局丢掉。
var allow_update := false

var _upd_link: Label       ## 「检查更新」/「立即重启」那行字
var _upd_note: Label       ## 底下那行状态小字
var _upd_busy := false     ## 正在查 / 正在下：连点不发第二次
var _upd_ready := false    ## 已经装好，就差重启
var _upd_countdown := 0    ## >0 = 正在数秒准备自动重启；0 = 没在数（也用来取消）
var _http: HTTPRequest

var _sel := 0
var _panel: Control
var _name_labels: Array[Label] = []
var _value_labels: Array[Label] = []
var _bars: Array[ColorRect] = []
var _arrows: Array = []          ## 每行 [左箭头, 右箭头]
var _hot_arrow: Label = null     ## 正被鼠标悬停的箭头；null = 没有
var _glow: Control               ## 选中行标题的辉光（主菜单悬停那套四层白描边）


## 行定义走函数不走常量：值的现状要从 CWSettings 读
func _rows() -> Array:
	return [
		{ "name": "AI 节奏", "texts": CWSettings.AI_DELAY_NAMES,
			"get": func() -> int: return CWSettings.AI_DELAYS.find(CWSettings.ai_delay_ms),
			"set": func(i: int) -> void:
				CWSettings.ai_delay_ms = CWSettings.AI_DELAYS[i] },
		{ "name": "掷骰动画", "texts": ["演出", "跳过"],
			"get": func() -> int: return 0 if CWSettings.dice_anim else 1,
			"set": func(i: int) -> void: CWSettings.dice_anim = i == 0 },
		{ "name": "传送演出", "texts": ["演出", "跳过"],
			"get": func() -> int: return 0 if CWSettings.teleport_anim else 1,
			"set": func(i: int) -> void: CWSettings.teleport_anim = i == 0 },
	]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func open() -> void:
	_sel = 0
	visible = true
	_repaint()


## 点面板外的空白处左键直接关（同配置面板/规则速查/知识之书）。
## 本层 FULL_RECT 且 STOP，scrim 那层 IGNORE——空白处点击会落到本层 _gui_input；
## 面板内的点击（拨值箭头）被各 STOP 控件先收，不会走这条路，照常拨值。
func _gui_input(event: InputEvent) -> void:
	if visible and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and not _panel.get_global_rect().has_point(event.position):
		accept_event()
		_cancel_restart()      ## 关页面 = 反悔：包留着，别把人的游戏关掉
		visible = false


## 由 CWMainMenu 路由（同配置面板/规则速查）
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel_restart()      ## 同上：Esc 也是反悔的口子
		visible = false
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
		_sel = posmod(_sel + (1 if event.is_action_pressed("ui_down") else -1),
			focus_count())
		_repaint()
	elif on_update_row():
		## 更新那行没有值可拨，只认「按下去」这一下
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_right"):
			_tap_update()
	elif event.is_action_pressed("ui_left"):
		_cycle(_sel, -1)
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("ui_accept"):
		_cycle(_sel, 1)


## 键盘能停几行：拨值行 +（只有主菜单那份才有的）「检查更新」一行
func focus_count() -> int:
	return _rows().size() + (1 if allow_update else 0)


## 焦点是不是停在「检查更新」上 —— 它排在所有拨值行后面
func on_update_row() -> bool:
	return allow_update and _sel == _rows().size()


## 拨一格：立即写 CWSettings 并落盘（设置没有「取消」，改了就是改了）
func _cycle(row: int, dir: int) -> void:
	var rows := _rows()
	if row < 0 or row >= rows.size():
		return   ## 更新行也走这条（它的下标就在 rows 之外）
	var n: int = rows[row]["texts"].size()
	var cur: int = maxi(rows[row]["get"].call(), 0)
	rows[row]["set"].call((cur + dir + n) % n)
	CWSettings.save_prefs()
	_repaint()


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var rows := _rows()
	var h: float = PAD + TITLE_H + rows.size() * ROW_H 		+ (UPDATE_H if allow_update else 0.0) + PAD
	var screen := CWView.screen_size()
	_panel = Control.new()
	_panel.position = Vector2((screen.x - W) / 2.0, (screen.y - h) / 2.0)
	_panel.size = Vector2(W, h)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bg)

	var title := CWStyle.label("设置", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD)
	_panel.add_child(title)

	## 选中行标题的辉光：全页只备一份、跟着焦点行走（先建，压在文字底下；
	## 层数与 alpha 即 CWPauseMenu.GLOW，和主菜单/配置面板是同一套光）
	_glow = Control.new()
	_glow.size = Vector2(200, 28)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_glow)
	for layer in CWPauseMenu.GLOW:
		var g := CWStyle.label("", CWStyle.SIZE_BODY, Color(1, 1, 1, 0))
		g.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		g.add_theme_constant_override("outline_size", layer[0])
		g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_glow.add_child(g)

	for i in rows.size():
		var y: float = PAD + TITLE_H + i * ROW_H
		var hit := Control.new()
		hit.position = Vector2(0, y)
		hit.size = Vector2(W, ROW_H)
		hit.mouse_filter = Control.MOUSE_FILTER_PASS
		hit.mouse_entered.connect(func() -> void:
			_sel = i
			_repaint())
		_panel.add_child(hit)

		var bar := ColorRect.new()
		bar.position = Vector2(PAD, y + 7)
		bar.size = Vector2(4, 22)
		bar.color = Color(CWStyle.IMMUNE, 0.0)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_panel.add_child(bar)
		_bars.append(bar)

		var name_label := CWStyle.label(rows[i]["name"], CWStyle.SIZE_BODY, CWStyle.TEXT_DIM)
		name_label.position = Vector2(PAD + 16, y + 5)
		_panel.add_child(name_label)
		_name_labels.append(name_label)

		## 拨值箭头 ASCII 的 < >（点阵字库没有 ‹ ›），两枚都在**固定位置**；
		## 值文本挂在两箭头正中。悬停箭头亮白光（_hot_arrow 记着谁，_repaint 统一画）
		var left := CWStyle.clickable_label(_panel, "<", Vector2(ARROW_L_X, y + 5), func() -> void: _tap(i, -1))
		var value := CWStyle.clickable_label(_panel, "", Vector2(ARROW_L_X + 14, y + 5), func() -> void: _tap(i, 1))
		value.size = Vector2(ARROW_R_X - ARROW_L_X - 14, 26)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var right := CWStyle.clickable_label(_panel, ">", Vector2(ARROW_R_X, y + 5), func() -> void: _tap(i, 1))
		for arrow: Label in [left, right]:
			arrow.mouse_entered.connect(func() -> void:
				_hot_arrow = arrow
				_repaint())
			arrow.mouse_exited.connect(func() -> void:
				if _hot_arrow == arrow:
					_hot_arrow = null
				_repaint())
		_value_labels.append(value)
		_arrows.append([left, right])

	if allow_update:
		_build_update(PAD + TITLE_H + rows.size() * ROW_H)

	var hint := CWStyle.label("←→ 拨值 · 改动立即生效 · ESC 返回",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.size = Vector2(W, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(0, h + 8)
	_panel.add_child(hint)


func _tap(row: int, dir: int) -> void:
	_sel = row
	_cycle(row, dir)


func _repaint() -> void:
	var rows := _rows()
	for i in rows.size():
		var on := i == _sel
		_bars[i].color = Color(CWStyle.IMMUNE, 1.0 if on else 0.0)
		_name_labels[i].add_theme_color_override("font_color",
			Color.WHITE if on else CWStyle.TEXT_DIM)
		var cur: int = maxi(rows[i]["get"].call(), 0)
		_value_labels[i].text = rows[i]["texts"][cur]
		_value_labels[i].add_theme_color_override("font_color",
			CWStyle.TEXT_HI if on else CWStyle.TEXT)
		## 拨值箭头只在焦点行亮出来；被悬停的那枚转白发光（同配置面板）
		for arrow: Label in _arrows[i]:
			arrow.visible = on
			var hovering := arrow == _hot_arrow
			arrow.add_theme_color_override("font_color",
				Color.WHITE if hovering else CWStyle.IMMUNE)
			arrow.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
			arrow.add_theme_constant_override("outline_size", 8 if hovering else 0)
	## 「检查更新」那一行（只有主菜单那份有）：没有值可拨，只有一行字 + 一行状态
	if allow_update and _upd_link != null:
		var on_upd := on_update_row()
		_bars[rows.size()].color = Color(CWStyle.IMMUNE, 1.0 if on_upd else 0.0)
		_upd_link.text = "立即重启" if _upd_ready else "检查更新"
		_upd_link.add_theme_color_override("font_color",
			Color.WHITE if on_upd else CWStyle.TEXT_DIM)
	## 选中行标题的辉光跟焦点走（设置页总有一行被选中，不用收起）。
	## 停在更新行上时它照的是那行字 —— 焦点在哪儿光就在哪儿，别让它落回上一行
	var glow_name: String = _upd_link.text if on_update_row() and _upd_link != null 		else String(rows[mini(_sel, rows.size() - 1)]["name"])
	_glow.position = Vector2(PAD + 16, PAD + TITLE_H + _sel * ROW_H + 5)
	for layer in _glow.get_children():
		(layer as Label).text = glow_name


# ============ 检查更新（Kevin 2026-09-10：「不用退出游戏也能更新」）============
#
# ## 为什么按下去之后还要重启
#
# 补丁是 `load_resource_pack()` 挂上去的，而**挂载必须早于游戏代码的首次 load**
# （GDScript 一旦 load 过就进缓存，之后再挂也换不掉 —— boot.gd 硬约束 ①）。
# 进到主菜单时半个游戏都已经 load 完了，所以这儿**只负责把包下到盘上并记账**，
# 真正生效仍归下一次启动的 boot.gd。
#
# 于是这一行有两副面孔：查完之前是「检查更新」，装好之后变成「立即重启」。
# `OS.set_restart_on_exit(true)` + `quit()` —— 退出后引擎自己把自己拉起来，
# 玩家不必去桌面找图标。
#
# ## 为什么不去调 boot.gd 的下载函数
#
# 那几个是实例方法，绑着启动那一屏的 `_note` / `_skip` / `_t0`，搬不过来。
# 但**判断**一个都没重写：白名单 `Boot.pinned`、装不装 `Boot.decide`、
# 验签 `PatchState.verify_manifest`、指纹 `PatchState.sha256_of` 全是那边的静态函数。
# 这里重写的只有「发一个 HTTP 请求并等它回来」这段管道。

const UPD_TIMEOUT := 12.0        ## 每口请求等多久；比启动那屏宽松，这儿玩家是主动点的
## 下载完之后等几秒自动重启（Kevin 2026-09-10：「可以更新完自动重启」）。
## **不是立刻退** —— 应用自己毫无预告地消失是很唬人的一件事；
## 数三秒既让玩家看清「发生了什么」，也留出一个反悔的口子（Esc 关掉设置页就取消）。
## 不想等的按那行字，立刻重启。
const RESTART_DELAY := 3

## 状态行那几句话。**集中写在一处**，因为它们都要挤进一行 216px
## （面板 264 − 左右内边距 − 那 16 的缩进），超了就被省略号从**尾巴**吃起 ——
## 而尾巴恰恰是「该怎么办」那半句（第一版的「…请去 GitHub Releases 下新客户端」
## 就是这么被吃成「…请去 GitHub …」的）。护栏 `t_settings` 逐条量宽度。
const UPD_NOTES := {
	"checking": "正在检查更新…",
	"offline": "连不上更新服务器，稍后再试",
	"bad_sig": "更新信息验不过，已忽略",
	"latest": "已经是最新版本",
	## 被拉黑的那一版：说「已经是最新」是骗人的 —— 不是没有新的，是它装崩过被拉黑了（Kevin 2026-09-11）
	"blocked": "补丁装崩 %d 次已拉黑，等下一版",
	"too_old": "基线太老，去 Releases 下新客户端",
	"downloading": "正在下载更新…",
	"incomplete": "更新没下完，稍后再试",
	"bad_sha": "更新文件校验失败，本次跳过",
	"done": "已下载 %d —— 重启后生效",
	"armed": "已下载 %d —— %d 秒后重启",
}


func _build_update(y: float) -> void:
	var hit := Control.new()
	hit.position = Vector2(0, y)
	hit.size = Vector2(W, UPDATE_H)
	hit.mouse_filter = Control.MOUSE_FILTER_PASS
	hit.mouse_entered.connect(func() -> void:
		_sel = _rows().size()
		_repaint())
	_panel.add_child(hit)

	var bar := ColorRect.new()
	bar.position = Vector2(PAD, y + 7)
	bar.size = Vector2(4, 22)
	bar.color = Color(CWStyle.IMMUNE, 0.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bar)
	_bars.append(bar)          ## 跟着拨值行一起进 _bars，_repaint 那边就不必分两种

	_upd_link = CWStyle.clickable_label(_panel, "", Vector2(PAD + 16, y + 5),
		func() -> void: _tap_update())
	## 状态小字压在下面一行：网络那几种结果都得说清楚，光靠标题一行摆不下
	_upd_note = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	_upd_note.position = Vector2(PAD + 16, y + 28)
	_upd_note.size = Vector2(W - PAD * 2 - 16, 14)
	_upd_note.clip_text = true
	_upd_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_upd_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_upd_note)


func _tap_update() -> void:
	_sel = _rows().size()
	if _upd_busy:
		return
	if _upd_ready:
		_restart()      ## 不想等那几秒的，按一下立刻走
		return
	_check_update()


## 查一遍更新。返回给玩家看的那句话（也写进 `_upd_note`），**测试直接核对它**。
func _check_update() -> void:
	_upd_busy = true
	_say(UPD_NOTES["checking"])
	var body := await _fetch(Boot.MANIFEST + "?t=%d" % Time.get_unix_time_from_system(), "")
	var sig := await _fetch(Boot.MANIFEST_SIG + "?t=%d" % Time.get_unix_time_from_system(), "")
	if body.is_empty() or sig.is_empty():
		_done(UPD_NOTES["offline"])
		return
	if not PatchState.verify_manifest(body, sig.get_string_from_utf8()):
		_done(UPD_NOTES["bad_sig"])      ## 见 boot.gd 纪律 ②：验不过就当没看见
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var plan: Dictionary = Boot.decide(parsed if parsed is Dictionary else {},
		PatchState.installed_build(), PatchState.blocked_build(), PatchState.base_build())
	match String(plan["act"]):
		"too_old":
			_done(UPD_NOTES["too_old"])
		"install":
			await _download(plan)
		_:
			_done(skip_note(int((parsed as Dictionary).get("build", 0)) if parsed is Dictionary else 0,
				PatchState.blocked_build()))


## decide 说「跳过」时给玩家看哪句：服务器在推的正是被拉黑的那一版 → 说清楚是拉黑了，别说「已经是最新」。
## **纯函数**，测试直接核对。
static func skip_note(offered: int, blocked: int) -> String:
	if offered > 0 and offered == blocked:
		return UPD_NOTES["blocked"] % PatchState.STRIKES
	return UPD_NOTES["latest"]


func _download(plan: Dictionary) -> void:
	_say(UPD_NOTES["downloading"])
	if (await _fetch(String(plan["url"]), PatchState.INCOMING)).is_empty():
		_done(UPD_NOTES["incomplete"])
		return
	## **校验在改名之前**：没过就不该有机会变成 current.pck（同 boot.gd）
	if PatchState.sha256_of(PatchState.INCOMING) != String(plan["sha"]):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PatchState.INCOMING))
		_done(UPD_NOTES["bad_sha"])
		return
	if FileAccess.file_exists(PatchState.PCK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PatchState.PCK))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(PatchState.INCOMING),
		ProjectSettings.globalize_path(PatchState.PCK))
	PatchState.record(int(plan["build"]), String(plan["sha"]))
	_upd_ready = true
	_upd_busy = false
	_arm_restart(int(plan["build"]))


## 发一口请求并等回来。`to` 非空 = 下到那个文件（此时返回值只是个成功标记）。
## 地址一律先过 `Boot.pinned`：白名单只有一处实现，这里只是再走一遍它。
func _fetch(url: String, to: String) -> PackedByteArray:
	if not Boot.pinned(url):
		return PackedByteArray()
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
	_http.download_file = to
	if _http.request(url) != OK:
		return PackedByteArray()
	var got: Array = []
	_http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, b: PackedByteArray) -> void:
			got.append([result, code, b]),
		CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(UPD_TIMEOUT * 1000.0)
	while got.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if got.is_empty():
		_http.cancel_request()
		return PackedByteArray()
	var res: Array = got[0]
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return PackedByteArray()
	return res[2] if to == "" else PackedByteArray([1])


func _say(note: String) -> void:
	if _upd_note != null:
		_upd_note.text = note
	_repaint()


func _done(note: String) -> void:
	_upd_busy = false
	_say(note)


## 下载完之后数几秒，然后自己重启（Kevin 要的「更新完自动重启」）。
##
## **留了一个反悔的口子**：Esc / 点面板外关掉设置页就取消（`_cancel_restart`）。
## 玩家是主动点「检查更新」才走到这一步的，但一个应用毫无预告地把自己关掉
## 仍然很唬人 —— 何况他可能只是想看看有没有更新，并不打算现在就重开。
func _arm_restart(build: int) -> void:
	_upd_countdown = RESTART_DELAY
	while _upd_countdown > 0:
		_say(UPD_NOTES["armed"] % [build, _upd_countdown])
		await get_tree().create_timer(1.0).timeout
		## 关页面 = 取消（把计数清零）；节点已经不在树上就更不该再动它
		if not is_inside_tree() or _upd_countdown <= 0:
			return
		_upd_countdown -= 1
	_restart()


## 取消自动重启，但**包已经装好了**——那行字仍是「立即重启」，随时可以按。
func _cancel_restart() -> void:
	if _upd_countdown <= 0:
		return
	_upd_countdown = 0
	_say(UPD_NOTES["done"] % PatchState.installed_build())


func _restart() -> void:
	## 退出后引擎把自己拉起来，下一次启动由 boot.gd 挂上刚下好的补丁。
	## 设置页是主菜单开的（allow_update 只在那儿为真），没有对局会被丢掉。
	OS.set_restart_on_exit(true)
	get_tree().quit()
