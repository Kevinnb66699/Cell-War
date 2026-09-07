## feed.gd —— 棋盘左侧的**出牌列**（Kevin 2026-09-07：「左侧放一整列的卡牌就行，
## 不用很详细，注明是谁打出的就行」「不要用小卡，就把手牌区抽到的卡缩小放上去就行」）
##
## 前身是一列文字条目，压住了棋盘左上角 21 格（他一眼看出来了）。现在两件事一起改：
## ① 对局机位往右让出 `CWView.LEFT_STRIP`，这一列不再压任何格子；
## ② 条目就是**手牌区那张卡**——卡宽照旧 72，只留顶上那一截（手牌静止时露出的也正是这一截）。
##
## **为什么不是整张卡按比例缩**：先试过缩一半（36×56），10px 点阵字跟着变成 5px，
## 卡名糊成一团马赛克，卡片就只剩一个色块，看不出打的是哪张 —— 那这一列就白做了。
## 卡名是这一列的全部信息量，字号一步也不能动；要变小只能少画一点，所以裁掉卡的下半截
## （下半截本来就是类别与「双击打出」那两行操作提示，这里既不出牌也不需要）。
##
## 收什么：**别人打出的卡** + **抽到即结算的事件卡**。自己打的不收（自己知道）；
## 别人抽卡不收 —— 牌名只有本人能看，一张背面朝上的卡说明不了任何事，那条留在对局日志里。
##
## 想看这张卡到底干什么：点它，走 `card_pressed` 出详情框（同右栏历史小卡那条路）。
class_name CWFeed
extends Control

const CARD_W := 72.0                    ## 与手牌同宽 —— 卡名折行、内边距全照搬 CWHand，不必另调一套
const CARD_H := 42.0                    ## 只留顶上这一截：卡名两行 + 底下一行「谁打的」
const WHO_Y := 27.0
const WHO_H := 13.0
const GAP := 4.0
const MAX_ROWS := 6                     ## 再多就长到手牌抽屉里去了；旧的自动挤掉，全量仍在对局日志里
const RECT := Rect2(8, 76, CARD_W, MAX_ROWS * (CARD_H + GAP) - GAP)
const FADE := 0.22
## 事件卡底行的后缀：写成「<抽到者>·抽」（Kevin 2026-09-07 先要「别叫世界事件」、
## 再要「也要显示是谁抽出来的」）。**「·抽」这半个字不能省** —— 只写名字的话，
## 它和「谁打出的」那种卡长得一模一样，而抽到即结算的事件卡不是任何人主动打的。
## 也**别写「世界事件」**：那是另一回事——世界事件是第 3/6/10/14 回合由系统抽的那 17 个全局事件。
const EVENT_SUFFIX := "·抽"

## 世界事件那一行写什么。**和事件卡分开**：世界事件是系统在第 3/6/10/14 回合抽的全局事件，
## 不属于任何一方，所以底行写「世界事件」、顶边用中性色（事件卡按抽到者的阵营染色）。
const WORLD_WHO := "世界事件"

## 点了某张卡：把它的卡面内容和屏幕位置交出去（对上 CWCardInfo.show_info 的签名）
signal card_pressed(rows: Dictionary, x: float, y: float)

var _rows: Array = []                   ## [{ box: Control, card: String, who: String }]


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	## 只有卡本身收鼠标：空白处要漏给棋盘
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 记一张。rows 是 CWCardInfo.describe() 的产物（点开时直接喂详情框，不必再算一遍）。
## is_event 只改底下那行字（事件卡不是谁**打出**的）；**颜色照旧按阵营来** ——
## Kevin 2026-09-07：「事件卡是谁抽到的就标记成哪一方的颜色」。事件卡也是某个细胞抽到的，
## 一眼看出是哪边抽到的，比统一染成中性白有用。
## who 传抽到 / 打出它的那位的名字（联机局里是昵称）。is_event 只在名字后面缀「·抽」。
func add_card(card_name: String, who: String, faction: int, rows: Dictionary,
		is_event := false) -> void:
	var line := who + EVENT_SUFFIX if is_event else who
	var accent: Color = CWStyle.IMMUNE if faction == CWData.Faction.IMMUNE else CWStyle.CANCER
	_push(_make_face(card_name, line, accent), card_name, line, rows)


## 手牌那张卡的顶上一截：底板、顶边高光、卡名折行全照搬 CWHand（折行直接用它的 `name_lines`），
## 顶边染成阵营色 —— 一眼看出是谁打的，不必读字
func _make_face(card_name: String, who: String, accent: Color) -> Control:
	var face := Control.new()
	face.size = Vector2(CARD_W, CARD_H)
	face.clip_contents = true            ## 同手牌：卡名可能比卡还宽
	face.mouse_filter = Control.MOUSE_FILTER_STOP
	face.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var bg := Panel.new()
	var box := CWStyle.box(0.75, CWStyle.PANEL)
	box.border_width_top = 4             ## 手牌卡面那道顶边
	box.border_color = accent
	bg.add_theme_stylebox_override("panel", box)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(bg)
	var lines := CWHand.name_lines(card_name)
	var y: float = CWHand.NAME_Y2[0] if lines.size() > 1 else CWHand.NAME_Y
	for line in lines:
		var l := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
		l.position = Vector2(CWHand.NAME_PAD, y)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		face.add_child(l)
		y = CWHand.NAME_Y2[1]
	var who_label := CWStyle.label(who, CWStyle.SIZE_LABEL, accent)
	## **先开裁切再定尺寸**（架构约定）：不裁的 Label 最小宽 = 全文宽，长昵称会把这一列撑开
	who_label.clip_text = true
	who_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	who_label.position = Vector2(CWHand.NAME_PAD, WHO_Y)
	who_label.size = Vector2(CARD_W - CWHand.NAME_PAD * 2, WHO_H)
	who_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(who_label)
	return face


func clear_all() -> void:
	for r in _rows:
		(r["box"] as Node).queue_free()
	_rows.clear()


## 最新的一张在**最上面**（Kevin 2026-09-07 定的滚动顺序）：这一列贴着迷你日志往下长，
## 眼睛从上往下扫，新的先看见
func _layout() -> void:
	var y := 0.0
	for i in range(_rows.size() - 1, -1, -1):
		(_rows[i]["box"] as Control).position = Vector2(0, y)
		y += CARD_H + GAP


## 记一个**世界事件**。牌面写事件名，底下写「世界事件」，顶边中性色 —— 它不属于任何一方。
## 详情框的内容照 CWCardInfo.describe 的 { name, kind, lines } 形状拼，点开走同一只框。
func add_world_event(ev_name: String, left: int) -> void:
	var body: String = CWWorldFx.BLURB.get(ev_name, "")
	if left > 1:
		body += "（持续 %d 回合）" % left
	var rows := {
		"name": "【%s】" % ev_name,
		"kind": "【世界事件】",
		"lines": CWCardInfo.wrap_text(body, CWCardInfo.W - CWCardInfo.PAD_H * 2.0),
	}
	_push(_make_face(ev_name, WORLD_WHO, CWStyle.TEXT_HI), ev_name, WORLD_WHO, rows)


## 两个入口（打出/抽到的卡、世界事件）**共用的收尾**：挂上去、挤掉旧的、排版、淡入、
## 连上「点开看详情」。
##
## 为什么非要收成一个：2026-09-07 世界事件那条路是照着 add_card 手抄的，
## 抄漏了 `gui_input` 那一段 —— 于是世界事件那张卡点不开，而两边看起来都「写好了」。
## 收尾只留一份，就不会再有下一次分叉。
func _push(box: Control, card_name: String, who: String, rows: Dictionary) -> void:
	add_child(box)
	_rows.append({ "box": box, "card": card_name, "who": who, "rows": rows })
	while _rows.size() > MAX_ROWS:
		var gone: Dictionary = _rows.pop_front()
		(gone["box"] as Node).queue_free()
	_layout()
	box.modulate.a = 0.0
	create_tween().tween_property(box, "modulate:a", 1.0, FADE)
	box.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		box.accept_event()
		var at := box.get_global_rect().position
		card_pressed.emit(rows, at.x, at.y))
