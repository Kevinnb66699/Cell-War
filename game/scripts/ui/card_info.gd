## card_info.gd —— 手牌悬停详情：鼠标停在某张手牌 0.25s 后浮出的效果说明
##
## 团队 2026-09-01 定的卡面交互第三条（前两条是双击打出 / 右键双击弃置，见 hand.gd）。
## 照着 `CWTileInfo` 那套打：延时浮出、换目标重新计时、`describe`/`wrap`/`place`
## 都是纯函数，无头测试直接核对文案与不越界，不用真渲染。
##
## **和格子详情的两处不同**：
## ① **位置固定**，不跟着悬停的卡走。格子散在整张棋盘上，贴着格子摆才找得到；
##    手牌全挤在左下角那 300px 里，跟着走只会让框在原地抖，字反而没法读。
##    框贴着抬起后的卡顶（428）往上长。
## ② **要折行**。格子详情每行都是「组织 · 坐标」这种短句，而卡牌效果是 PRD 的整段正文，
##    最长的有一百多字。折行用 `wrap()` 自己算，不用 Label 的 autowrap ——
##    autowrap 要控件进了场景树、排过版才知道占几行，纯函数测不了高度。
##
## 文案一律来自 `CWCardData.effect_of()`，即 **PRD 原文**。这里一个字都不改写：
## 改写等于把规则抄第二份（架构约定 #10）。所以「0.8 / 1.5 / 2」这种分档写法会原样出现——
## 那正是 PRD 的写法，玩家看规则书读到的也是它。
class_name CWCardInfo
extends Control

const DELAY := 0.25         ## 悬停多久后浮出（与 CWTileInfo 对齐，两处手感要一样）
const W := 320.0            ## 定宽。效果正文要折行，宽度浮动的话每张卡折行位置都不同，很吵
const PAD_V := 10.0
const PAD_H := 12.0
const GAP_ABOVE_CARD := 12.0   ## 框底与抬起后卡顶之间留的缝
const LINE_NAME := 26.0        ## 卡名行高（20px 字）
const LINE_BODY := 15.0        ## 正文行高（10px 字）
const RULE_H := 7.0            ## 卡名与正文之间那条分隔线占的高

## 中文里不该出现在行首的字符。贪心折行会把它们甩到下一行开头，
## 看着像断句错了 —— 遇到就把断点往前挪一个字。
const NO_LINE_START := "。，、；：？！）」』》%…—～·"

var _card := ""      ## 正在悬停的卡名；空串 = 没有
var _info := {}      ## 自由文案（分化提问里悬停种类按钮 → 细胞种类详情）；非空时压过 _card
var _anchor_x := 0.0 ## 自由文案的锚点：贴着被悬停按钮的左缘摆
var _wait := 0.0
var _key := ""       ## 上次搭内容用的键；没变就不重搭（每帧 sync，重搭是浪费）


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 详情框不挡任何点击


## 接 hand.card_hovered。换卡先收起再重新计时（划过一串卡不会闪一路框）。
func on_hover(card_name: String) -> void:
	if card_name == _card:
		return
	_card = card_name
	_wait = 0.0
	visible = false


func hide_now() -> void:
	_card = ""
	_info = {}
	visible = false


## 分化提问：鼠标停在种类按钮上 → 浮该细胞种类的 PRD 原文（rows 由 describe_type 给）；
## 传空字典 = 离开按钮，立刻收起。手感与手牌一致：同样等 DELAY 再浮出、换目标重新计时
func on_hover_info(rows: Dictionary, anchor_x: float) -> void:
	if rows.is_empty():
		if not _info.is_empty():
			_info = {}
			_wait = 0.0
			visible = false
		return
	if rows == _info:
		return
	_info = rows
	_anchor_x = anchor_x
	_wait = 0.0
	visible = false


## 每帧由 CWMatch 调。faction 决定【代谢耦联】那张给哪套措辞；
## blocked = 开场/返场演出中，那会儿不该浮任何东西。
func sync(delta: float, faction: int, blocked: bool) -> void:
	var free_text := not _info.is_empty()
	if blocked or (not free_text and (_card == "" or not CWCardData.CARDS.has(_card))):
		visible = false
		return
	_wait += delta
	if _wait < DELAY:
		return
	var rows: Dictionary = _info if free_text else describe(_card, faction)
	var key: String = "info|%s" % rows["name"] if free_text else "%s|%d" % [_card, faction]
	if key != _key:
		_key = key
		_rebuild(rows)
	position = place_at(size, _anchor_x, CWView.screen_size()) if free_text \
		else place(size, CWView.screen_size())
	visible = true


## 某种分化细胞该显示什么：{ name, kind, lines }。文案是 CWData.IMMUNE_TYPE_TEXT 里的 PRD 原文；
## 没有文案的种类（未分化）给空行数组，不崩。
## kind 传「【细胞种类】」= 右栏固定详情在看这个细胞是什么；默认「【分化】」= 分化提问里在选它
static func describe_type(t: int, kind := "【分化】") -> Dictionary:
	return {
		"name": CWData.IMMUNE_TYPE_NAMES.get(t, ""),
		"kind": kind,
		"lines": wrap_text(CWData.IMMUNE_TYPE_TEXT.get(t, ""), W - PAD_H * 2.0),
	}


## 某个主动技能该显示什么：{ name, kind, lines }。文案是 CWData.skill_text() 里的 PRD 原文。
## faction 决定「迁移 / 移动」「基因表达」两套措辞（规则里就是两个词、两个价）
static func describe_act(act: String, faction: int) -> Dictionary:
	return {
		"name": CWData.act_name(act, faction),
		"kind": "【主动技能】",
		"lines": wrap_text(CWData.skill_text(act, faction), W - PAD_H * 2.0),
	}


## 某种癌细胞的自带技能：{ name, kind, lines }。与 describe_type（免疫种类）成对
static func describe_ctype(t: int) -> Dictionary:
	return {
		"name": CWData.CANCER_TYPE_NAMES.get(t, ""),
		"kind": "【细胞种类】",
		"lines": wrap_text(CWData.CANCER_TYPE_TEXT.get(t, ""), W - PAD_H * 2.0),
	}


## 自由文案的摆位：左缘贴着被悬停的按钮（右边放不下就往左让），框底压在行动栏提示条上方一点
static func place_at(box: Vector2, anchor_x: float, screen: Vector2) -> Vector2:
	var x := clampf(anchor_x, 8.0, screen.x - box.x - 8.0)
	var y := CWActionBar.PROMPT_RECT.position.y - GAP_ABOVE_CARD - box.y
	return Vector2(x, clampf(y, 8.0, screen.y - box.y - 8.0))


## 这张卡该显示什么：{ name, kind, lines }。纯函数，供测试直接核对文案。
static func describe(card_name: String, faction: int) -> Dictionary:
	var c: Dictionary = CWCardData.CARDS.get(card_name, {})
	if c.is_empty():
		return { "name": card_name, "kind": "", "lines": PackedStringArray() }
	return {
		"name": card_name,
		"kind": "【%s】" % CWCardData.KIND_NAMES[c["kind"]],
		"lines": wrap_text(CWCardData.effect_of(card_name, faction), W - PAD_H * 2.0),
	}


## 把一段正文折成若干行。先按 PRD 自己的换行断开（列表项「· xxx」靠它各占一行），
## 再对每段做贪心折行。纯函数 —— 高度要在建控件之前就算出来。
##
## 名字不能叫 `wrap`：那是 @GlobalScope 的内置函数（数值取模回绕），重名会直接编译不过。
static func wrap_text(text: String, max_w: float) -> PackedStringArray:
	var out := PackedStringArray()
	for para in text.split("\n"):
		if para == "":
			continue
		var line := ""
		for ch in para:
			var tryout := line + ch
			if line != "" and _text_w(tryout) > max_w:
				## 断点落在了不该做行首的字符前面：把前一个字一起带下去
				if NO_LINE_START.contains(ch) and line.length() > 1:
					out.append(line.substr(0, line.length() - 1))
					line = line[line.length() - 1] + ch
				else:
					out.append(line)
					line = ch
			else:
				line = tryout
		if line != "":
			out.append(line)
	return out


static func _text_w(s: String) -> float:
	return CWStyle.FONT.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1,
		CWStyle.SIZE_LABEL).x


## 摆位：左缘对齐手牌区，框底压在**抬起后的卡顶**上面一点，往上长。
##
## 为什么往上长而不是往下：卡顶 428 以下全是手牌自己的地盘，往下会盖住正在看的那张卡。
## 高度随效果文长短变，所以固定的是**底边**不是顶边——不然长卡短卡的框底会跳。
## `screen` 只用来兜上沿：正文特别长时宁可顶到画布上沿，也不要跑出去。
static func place(box: Vector2, screen: Vector2) -> Vector2:
	var card_top := CWHand.REST_TOP - CWHand.LIFT     ## 428：悬停抬起后卡的顶边
	var y := card_top - GAP_ABOVE_CARD - box.y
	return Vector2(CWHand.LEFT, clampf(y, 8.0, screen.y - box.y - 8.0))


func _rebuild(rows: Dictionary) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var lines: PackedStringArray = rows["lines"]
	var h := PAD_V + LINE_NAME + RULE_H + LINE_BODY * lines.size() + PAD_V
	size = Vector2(W, h)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var name_label := CWStyle.label(rows["name"], CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	name_label.position = Vector2(PAD_H, PAD_V)
	add_child(name_label)
	## 类别贴右，和卡名同一行 —— 卡面上它也在角落，别让它抢正文的位置
	var kind := CWStyle.label(rows["kind"], CWStyle.SIZE_LABEL, CWStyle.IMMUNE)
	kind.size = Vector2(W - PAD_H * 2.0, 14)
	kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	kind.position = Vector2(PAD_H, PAD_V + 8)
	add_child(kind)

	var rule := ColorRect.new()
	rule.color = Color(CWStyle.LINE, 0.25)
	rule.position = Vector2(PAD_H, PAD_V + LINE_NAME)
	rule.size = Vector2(W - PAD_H * 2.0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rule)

	var y := PAD_V + LINE_NAME + RULE_H
	for line in lines:
		var body := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT)
		body.position = Vector2(PAD_H, y)
		add_child(body)
		y += LINE_BODY
