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
##
## 分档写法里**当前生效的那一档高亮**（Kevin 2026-09-06）：`describe()` 多收一个 `phase`（癌症卡的分期，
## `CWCardData.cancer_phase(round_no)`），`tier_marks()` 找出每行里该档的位置，`_rebuild()` 把那几个字
## 单独画成亮字 + 底下一块阵营色板。文字本身仍是原文，一个字不动。**自由选择类不标**（【代谢耦联】那三档是
## 玩家自己挑的，见 `FREE_CHOICE`）；「1/6 概率」这种没有空格的分数也不是分档写法，正则只认「a / b / c」。
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

## 卡面上的「a / b / c」不是按分期生效、而是让玩家自己挑一档的卡 —— 这种不高亮（Kevin 2026-09-06）
const FREE_CHOICE := ["代谢耦联"]
const HL_PAD := 2.0            ## 高亮色板比那几个字左右各宽出多少
const HL_ALPHA := 0.5          ## 色板的透明度（阵营色压在深色面板上）
static var _tier_re: RegEx     ## 「a / b / c」分档写法（至少三档、以「 / 」隔开），懒建

var _card := ""      ## 正在悬停的卡名；空串 = 没有
var _info := {}      ## 自由文案（分化提问里悬停种类按钮 → 细胞种类详情）；非空时压过 _card
var _anchor_x := 0.0 ## 自由文案的锚点：贴着被悬停按钮的左缘摆
var _anchor_y := -1.0 ## 锚点的 y：≥0 = 框顶对齐到被悬停那一行（右栏技能行 / 历史小卡）；-1 = 压在行动栏提示条上方（分化按钮）
## 点小卡「固定」住的那种（show_info）：悬停那种鼠标一走就收，这种没人来收它 ——
## 2026-09-07 Kevin 报「点过一次小卡，详情栏就卡在那里」。收起的三条路见 show_info / on_hover / _unhandled_input。
var _pinned := false
var _wait := 0.0
var _key := ""       ## 上次搭内容用的键；没变就不重搭（每帧 sync，重搭是浪费）


func _ready() -> void:
	visible = false
	## **要挡住鼠标**（2026-09-07 Kevin 截图：停在详情框上，底下那一格的地图信息还是浮出来了）。
	## 两个理由：① 棋盘按「指针是不是被控件占着」判要不要报格（CWBoard._process，09-06 定的
	## 「最上面的图层说了算」），IGNORE 的控件不算，格子详情就会从框底下钻出来；
	## ② 点开的那种框浮在棋盘上，IGNORE 时点它等于点穿到棋盘上，会真的把细胞走过去。
	mouse_filter = Control.MOUSE_FILTER_STOP


## 接 hand.card_hovered。换卡先收起再重新计时（划过一串卡不会闪一路框）。
func on_hover(card_name: String) -> void:
	if card_name == _card:
		return
	## 去停一张手牌 = 不再看点开的那张：固定的先让位，否则 sync 里自由文案压着卡面出不来
	if _pinned and card_name != "":
		_pinned = false
		_info = {}
	_card = card_name
	_wait = 0.0
	visible = false


func hide_now() -> void:
	_card = ""
	_info = {}
	_pinned = false
	visible = false


## 点开之后点别处就收（Kevin 2026-09-07）。**不吃掉这一下**：那一下该干嘛还干嘛。
## 走 `_unhandled_input` 收得到的是「点在棋盘 / 空处」；点在别的控件上（右栏行、手牌、行动栏）
## 由那几条路各自的收起口负责（悬停换目标、这一问结束都会传空字典进来）。
func _unhandled_input(event: InputEvent) -> void:
	if not _pinned:
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed:
		hide_now()


## 分化提问：鼠标停在种类按钮上 → 浮该细胞种类的 PRD 原文（rows 由 describe_type 给）；
## 传空字典 = 离开按钮，立刻收起。手感与手牌一致：同样等 DELAY 再浮出、换目标重新计时
## anchor_y ≥ 0 = 框顶对齐到这个 y（右栏技能行传自己那一行的 y）；不传 = 压在行动栏提示条上方（分化按钮那条路）。
## 2026-09-07 Kevin 报「详情有时莫名其妙显示在窗口下方」：就是右栏那条路此前没带 y、被当成行动栏按钮摆到了底部。
func on_hover_info(rows: Dictionary, anchor_x: float, anchor_y := -1.0) -> void:
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
	_anchor_y = anchor_y
	_wait = 0.0
	visible = false


## 点击右侧历史小卡：直接展示原始卡面，不等悬停延时。
func show_info(rows: Dictionary, anchor_x: float, anchor_y := -1.0) -> void:
	if rows.is_empty():
		hide_now()
		return
	## 再点同一张 = 收起（Kevin 2026-09-07）
	if _pinned and visible and rows == _info:
		hide_now()
		return
	_pinned = true
	_card = ""
	_info = rows
	_anchor_x = anchor_x
	_anchor_y = anchor_y
	_wait = DELAY
	_key = ""
	_rebuild(rows)
	position = place_at(size, _anchor_x, CWView.screen_size(), _anchor_y)
	visible = true


## 每帧由 CWMatch 调。faction 决定【代谢耦联】那张给哪套措辞；
## blocked = 开场/返场演出中，那会儿不该浮任何东西；
## phase = 癌症卡的分期（CWCardData.cancer_phase），决定分档写法里高亮哪一档，-1 = 不高亮。
func sync(delta: float, faction: int, blocked: bool, phase := -1) -> void:
	var free_text := not _info.is_empty()
	if blocked or (not free_text and (_card == "" or not CWCardData.CARDS.has(_card))):
		visible = false
		return
	_wait += delta
	if _wait < DELAY:
		return
	var rows: Dictionary = _info if free_text else describe(_card, faction, phase)
	## 分期进键：跨期那一刻框还开着的话要重搭，高亮才会挪到新的一档
	var key: String = "info|%s" % rows["name"] if free_text else "%s|%d|%d" % [_card, faction, phase]
	if key != _key:
		_key = key
		_rebuild(rows)
	position = place_at(size, _anchor_x, CWView.screen_size(), _anchor_y) if free_text \
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


## 自由文案的摆位：左缘贴着被悬停的按钮（右边放不下就往左让），框底压在行动栏提示条上方一点。
##
## **右缘不进右侧竖条**（同 CWTileInfo.place 的规矩）：竖条上是回合数、玩家行、免疫等级，
## 盖住它等于让玩家一边读技能一边看不见自己还剩多少能量（2026-09-04 预览图上当场看见）。
## 右边那几枚按钮（细胞毒素、裂解）贴着棋盘右缘，不让的话框正好压上去。
## anchor_y ≥ 0：框顶对齐到它（被悬停那一行的 y），放不下就往上顶；-1：压在行动栏提示条上方（分化按钮）。
static func place_at(box: Vector2, anchor_x: float, screen: Vector2, anchor_y := -1.0) -> Vector2:
	var panel_left := screen.x - CWMatchPanel.RECT.size.x   ## 右侧竖条的左缘
	var x := clampf(anchor_x, 8.0, maxf(8.0, panel_left - 8.0 - box.x))
	var y := anchor_y if anchor_y >= 0.0 else CWActionBar.PROMPT_RECT.position.y - GAP_ABOVE_CARD - box.y
	return Vector2(x, clampf(y, 8.0, screen.y - box.y - 8.0))


## 这张卡该显示什么：{ name, kind, lines, marks, accent }。纯函数，供测试直接核对文案。
## phase = 癌症卡的分期下标（0/1/2），分档写法里高亮这一档；-1 或自由选择类的卡 → marks 全空。
## accent = 高亮色板的颜色，按卡属于哪一方（免疫池权重全 0 = 癌症卡）。
static func describe(card_name: String, faction: int, phase := -1) -> Dictionary:
	var c: Dictionary = CWCardData.CARDS.get(card_name, {})
	if c.is_empty():
		return { "name": card_name, "kind": "", "lines": PackedStringArray() }
	## **先规范化再折行**：分档高亮 `tier_marks` 要把整段上的位置投影到各行，
	## 两边必须是同一个字符串，否则高亮会整体错位
	var text: String = space_digits(CWCardData.effect_of(card_name, faction))
	var lines := wrap_text(text, W - PAD_H * 2.0)
	var tier: int = -1 if card_name in FREE_CHOICE else phase
	return {
		"name": card_name,
		"kind": "【%s】" % CWCardData.KIND_NAMES[c["kind"]],
		"lines": lines,
		"marks": tier_marks(text, lines, tier),
		"accent": CWStyle.CANCER if int(c["immune"].max()) == 0 else CWStyle.IMMUNE,
	}


## 把一段正文折成若干行。先按 PRD 自己的换行断开（列表项「· xxx」靠它各占一行），
## 再对每段做贪心折行。纯函数 —— 高度要在建控件之前就算出来。
##
## 名字不能叫 `wrap`：那是 @GlobalScope 的内置函数（数值取模回绕），重名会直接编译不过。
static func wrap_text(text: String, max_w: float) -> PackedStringArray:
	var out := PackedStringArray()
	## 顺手规范化（幂等）：这样 describe_type / describe_act / 世界事件那一列等
	## 所有走这条路的正文都能拿到同样的排版，不必各自记得调一次
	for para in space_digits(text).split("\n"):
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


## 分档写法「a / b / c」里第 tier 档在各行的位置：与 lines 平行的数组，每项是该行的 [Vector2i(起, 长)…]，
## 空数组 = 这行没有。tier < 0 = 不标。
##
## 在**折行前的整段**上找档、再按行切：折行是逐字贪心的，一组「1 / 1.5 / 2」可能被断在中间，
## 只在单行上找会漏掉被拆开的那组；按段找完再把区间投影到各行，跨行的那一档两行各标各的一段
## （wrap_text 不丢字，同一段的各行拼起来正好等于原段）。
static func tier_marks(text: String, lines: PackedStringArray, tier: int) -> Array:
	var marks: Array = []
	for i in lines.size():
		marks.append([])
	if tier < 0:
		return marks
	var li := 0
	for para in text.split("\n"):
		if para == "":
			continue
		var spans := _tier_spans(para, tier)
		var offset := 0
		while li < lines.size() and offset < para.length():
			var line: String = lines[li]
			for sp in spans:
				var s: int = maxi(sp.x, offset)
				var e: int = mini(sp.x + sp.y, offset + line.length())
				if e > s:
					marks[li].append(Vector2i(s - offset, e - s))
			offset += line.length()
			li += 1
	return marks


## 一段文字里每组「a / b / c」的第 tier 档：[Vector2i(起, 长)…]。档数不够就取最后一档。
## 只认**三档及以上**、以「 / 」（两边带空格）隔开的数字（可带正负号与小数）——
## 「1/6 概率」这种分数、「a / b」两个数并列都不算。
static func _tier_spans(para: String, tier: int) -> Array:
	if _tier_re == null:
		_tier_re = RegEx.new()
		_tier_re.compile("[+\\-]?\\d+(?:\\.\\d+)?(?: / [+\\-]?\\d+(?:\\.\\d+)?)+")
	var out: Array = []
	for m in _tier_re.search_all(para):
		var parts: PackedStringArray = m.get_string().split(" / ")
		if parts.size() < 3:
			continue
		var idx: int = mini(tier, parts.size() - 1)
		var start: int = m.get_start()
		for k in idx:
			start += parts[k].length() + 3
		out.append(Vector2i(start, parts[idx].length()))
	return out


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

	var marks: Array = rows.get("marks", [])
	var accent: Color = rows.get("accent", CWStyle.IMMUNE)
	var y := PAD_V + LINE_NAME + RULE_H
	for i in lines.size():
		var spans: Array = marks[i] if i < marks.size() else []
		if spans.is_empty():
			var body := CWStyle.label(lines[i], CWStyle.SIZE_LABEL, CWStyle.TEXT)
			body.position = Vector2(PAD_H, y)
			add_child(body)
		else:
			_add_marked_line(lines[i], spans, y, accent)
		y += LINE_BODY


## 带高亮的一行：前文 / 那一档 / 后文各自一个标签接着排，x 用实测字宽推进
## （像素字体没有字距，拼起来与整行一个标签画出来的一样）；那一档底下先铺一块阵营色板
## （比字左右各宽 HL_PAD），字换亮色压在上面。文字一个字不改，只是分开画。
func _add_marked_line(line: String, spans: Array, y: float, accent: Color) -> void:
	var x := PAD_H
	var cursor := 0
	for sp in spans:
		if sp.x > cursor:
			x += _put_run(line.substr(cursor, sp.x - cursor), x, y, CWStyle.TEXT)
		var seg: String = line.substr(sp.x, sp.y)
		var chip := ColorRect.new()
		chip.color = Color(accent, HL_ALPHA)
		chip.position = Vector2(x - HL_PAD, y + 1.0)
		chip.size = Vector2(_text_w(seg) + HL_PAD * 2.0, LINE_BODY - 2.0)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(chip)
		x += _put_run(seg, x, y, CWStyle.TEXT_HI)
		cursor = sp.x + sp.y
	if cursor < line.length():
		_put_run(line.substr(cursor), x, y, CWStyle.TEXT)


func _put_run(s: String, x: float, y: float, color: Color) -> float:
	var l := CWStyle.label(s, CWStyle.SIZE_LABEL, color)
	l.position = Vector2(x, y)
	add_child(l)
	return _text_w(s)


## 汉字与数字之间补一个空格（Kevin 2026-09-07：「汉字和数字中间要加一个空格」）。
##
## **纯显示层的规范化**：卡面正文是 `tools/gen_card_data.py` 从 PRD **逐字抄**来的
## （架构约定 #10），去改 `cw_card_data.gd` 等于把规则抄第二份，PRD 一动就对不上。
## 所以排版上的事在渲染前做，数据文件保持与 PRD 逐字一致。
##
## **幂等**：已经有空格就不再加，所以 wrap_text 里再调一次也不会变成两个空格。
##
## 只认**汉字**（U+4E00~U+9FFF），不碰标点：「，2」「）3」这类本来就断开了，
## 再塞一个空格反而更难看。纯函数，无头测试直接核对。
static func space_digits(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch: String = text[i]
		if i > 0 and _wants_gap(text[i - 1], ch):
			out += " "
		out += ch
	return out


## 这两个字符之间该不该有空格：一边汉字、另一边数字（哪一边在前都算）
static func _wants_gap(a: String, b: String) -> bool:
	return (_is_han(a) and _is_ascii_digit(b)) or (_is_ascii_digit(a) and _is_han(b))


static func _is_han(ch: String) -> bool:
	var c: int = ch.unicode_at(0)
	return c >= 0x4E00 and c <= 0x9FFF


static func _is_ascii_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"
