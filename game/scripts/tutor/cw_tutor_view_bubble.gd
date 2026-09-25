## cw_tutor_view_bubble.gd —— 皮 A：**贴身气泡**（docs/新手引导v2_实现方案.md §5.2 / §5.5，S3，2026-09-19）
##
## 一句话（方向稿 `docs/archive/新手引导v2_方向A.md`）：**台词贴着细胞说，控件提示贴着控件长，
## 屏幕中央永远留给棋盘。** 画法与常量逐条照出图脚本 `tests/preview/preview_tut_v2_A.gd` 搬。
##
## Kevin 2026-09-19 的五条（方案 §5.5）：
##   ① 整体走 A；台词 = 贴着说话者那一格上方的像素气泡，尾巴指向细胞、**跟随位置**；
##      `who == "ui:<id>"` 挂在那个控件矩形上方；「……」= 三颗渐显的点 + 留白几拍。
##   ② **提示行一出现就把台词收掉**（沿用占位皮那条）。
##   ③ 【迁移】等按钮**保持单线原样、只慢闪**（提亮层 `cw_tutor_spot.gd` 已经这么做了）——
##      **皮不再往按钮上套气泡**：控件旁的小气泡只给 `tip` 非空的那种
##      （剧本里只有第六关「点击结算【微环境压迫】」那一条）。
##   ④ 图鉴解锁 = 右上角滑入的小卡，连着几条就**往下摞**。
##   ⑤ 章节提示用 B、禁操作期光标「…」—— 这两件住在常驻壳里，**本文件一个字都不碰**。
##
## 接口纪律（方案 §5.3）：**皮不认识棋盘、也不认识镜像**。
## 「这句话是谁说的、他站在哪」走装配方注入的 `speaker_of`（同 `reveal_tiles` 那条 Callable），
## 「那个控件在屏幕哪儿」问共用的提亮层（`spot.rect_of` / `spot.head_of`）。
##
## 带 class_name，代价是走不了热更（方案 §1.5 的三个例外之一）：
## 真机截图要 `screenshot.gd` 的 `call:CWTutorViewBubble:advance` 驱动 —— 合成的鼠标点击到不了 `Control`。
class_name CWTutorViewBubble
extends CWTutorView

## 剧本里的坐标串 `"q,r"` → Vector2i（`say.at` 允许写字符串，同导演的 `_targets`）
const SCRIPT_DATA := preload("res://scripts/kernel/cw_tutor_script.gd")

# ── 气泡本体（方向 A §1 的那张表，一个数都没改）──
const BUBBLE_BG := Color("0a1018f2")   ## 比 `CWStyle.BTN_BG` 再实一档 —— 压在棋盘上要读得出字
const PAD_H := 10.0
const PAD_V := 7.0
const SAY_MAX_W := 280.0               ## 一行 14 个字，超了自动折行
const TIP_MAX_W := 250.0               ## 一行 12 个字，「点击结算【微环境压迫】」正好一行
const BORDER_A := 0.55                 ## 描边取**说话人的阵营色** × 这个 alpha：谁在说话一眼看得出
const TAIL := 13                       ## 尾巴：13×7 的像素三角（2px 描边）
const GAP_TAIL := 2.0                  ## 尾尖与目标之间留的缝
const EDGE := 10.0                     ## 气泡离画布边至少留这么多（边缘的细胞说话不半个身子出屏）
## 细胞头顶离**格顶面中心**多高（棋盘像素）：呼吸带一帧高 32（`immune_breath.png`），
## 减去脚底那 6（`CWMatch.CELL_FOOT_DY`）、再留 3 的缝 = 29 —— 与方向稿 A 的 `_head()` 同一个数。
## **量的是贴图框不是墨迹**：框里本来就有透明留白，所以气泡离细胞会比看上去远一点点；
## 各族贴图高 18~34 不等，皮又不认识棋盘上那只 Sprite，取一个数比按族查表划算
const HEAD_UP := 29.0
## 「继续 ▸」占气泡底部的一行（`auto:false` 时才有）。真机截图走 `call:CWTutorViewBubble:advance`
const NEXT_TEXT := "继续 ▸"


## 那一行的高 = **字体的行高**（20 号点阵字 28：ascent 22 + descent 6），不写死。
## 09-19 写的 18：Label 的最小尺寸会把自己悄悄撑到 28，行底就压出气泡的内边距、盖在底边描边与尾巴上
## （Kevin 2026-09-20 真机「继续显示到屏幕外了」）。气泡因此比原来高 10px，位置逻辑一字不变
static func next_h() -> float:
	return CWStyle.FONT.get_height(CWStyle.SIZE_BODY)

## 「……」= 沉默几拍，不是三个句号（方向 A §1）：三颗 10×10 的方点，
## alpha 依次 1.0 / 0.55 / 0.22，**逐颗渐显**（一拍一颗），停 0.6 秒
const DOT_ALPHA := [1.0, 0.55, 0.22]
const DOT_SIZE := 10.0
const DOT_GAP := 16.0
const DOT_BEAT := 0.35
const DOT_HOLD := 0.6

## 行动提示行（`hint`）。**不是气泡**：气泡是「有人在说话」，提示行是「现在轮到你动手」，
## 两件事共用一种画法玩家会分不清谁在等谁。横向居中在棋盘可用区（`CWView.board_span()` 的中点 388），
## 下缘 458 给行动栏的目标选择态（`CWActionBar.PROMPT_RECT` 从 y=466 起）留 8px
const HINT_RECT := Rect2(88.0, 424.0, 600.0, 34.0)

## 图鉴解锁小卡（方向 A §5）：196×46，右侧滑入 0.25 秒、停 2.2 秒、滑出 0.22 秒，竖向间距 6
const CODEX := Vector2(196.0, 46.0)
const CODEX_GAP := 6.0
const CODEX_TOP := 14.0
const CODEX_RIGHT := 950.0             ## 卡的右缘：没有右栏时贴到这儿
const CODEX_RIGHT_SIDEBAR := 686.0     ## 右栏弹出后让开那 264px
const CODEX_IN := 0.25
const CODEX_HOLD := 2.2
const CODEX_OUT := 0.22

var _say: Control = null          ## 当前那只台词气泡。连说几句 = **原地换一只**，不摞第二个泡
var _say_who := ""
var _say_at: Variant = null
var _next: Label = null           ## 「继续 ▸」，挂在气泡底部右下角
var _dots: Array = []             ## 「……」那三颗方点（测试数它）
var _busy := false
## 第几段台词。**「……」那段是协程**（一拍一颗点），而下一句 / 提示行 / 拆局随时会把
## 这一段掀掉 —— 老协程醒来时 `_dots` 已经是别人的了。每段一个号，号对不上就自己退场
var _say_gen := 0
var _hint: Label = null
var _tip: Control = null          ## 控件旁的小气泡（只给 `tip` 非空的那种）
var _tip_text := ""
var _cards: Array = []            ## 右上角的图鉴小卡，越新越靠下


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_hint = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_hint.add_theme_stylebox_override("normal",
		CWStyle.plate(Color(CWStyle.PANEL, 0.96), int(PAD_V), int(PAD_H)))
	_hint.visible = false
	add_child(_hint)


## 「继续」按下。**真机截图走 `call:CWTutorViewBubble:advance`** —— 合成鼠标点不到 Control。
## 只发信号、**不动 `_busy`**：一段台词可能有好几句，翻没翻完由 `say` 自己数
func advance() -> void:
	if not _busy:
		return
	if _next != null and is_instance_valid(_next):
		_next.visible = false
	advance_pressed.emit()


func busy() -> bool:
	return _busy


## 「继续」亮着（这一句画完、还没翻）才算 —— 翻过去的那一瞬 `advance()` 已把它藏起，连点不会跳句
func _next_armed() -> bool:
	return _busy and _next != null and is_instance_valid(_next) and _next.visible


## 点气泡本体 = 翻页（只认左键按下；`gui_input` 只在带「继续」的气泡上接）
func _on_say_click(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
			and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and _next_armed():
		advance()


## 回车 / 空格（ui_accept）也能翻页：键盘玩家不用去够那只跟着细胞跑的气泡
func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_accept") and _next_armed():
		advance()
		get_viewport().set_input_as_handled()


## 悬停时「继续 ▸」由暗字提到亮字：告诉玩家这只气泡是可以点的
func _set_next_hot(hot: bool) -> void:
	if _next != null and is_instance_valid(_next):
		_next.add_theme_color_override("font_color", CWStyle.TEXT_HI if hot else CWStyle.TEXT_DIM)


# ════════════════════════════════════════════════════════════════
#  ① 台词（贴着说话者那一格上方）
# ════════════════════════════════════════════════════════════════

## 这一段是「……」吗 —— 剧本写的是省略号，不是一句台词。**纯函数**，测试直接核
static func is_silence(lines: PackedStringArray) -> bool:
	if lines.is_empty():
		return true
	for s in lines:
		if str(s).replace("…", "").replace(".", "").replace("。", "").strip_edges() != "":
			return false
	return true


## 「……」留几拍：剧本写了 `beats` 就听它的，没写就是三颗点三拍。**纯函数**
static func beats_of(opts: Dictionary) -> int:
	var n := int(opts.get("beats", 0))
	return n if n > 0 else DOT_ALPHA.size()


func say(who: String, lines: PackedStringArray, opts: Dictionary) -> void:
	_say_who = who
	_say_at = opts.get("at", null)
	_busy = true
	var accent := _accent_of(who)
	if is_silence(lines):
		_build_say("", accent, false, beats_of(opts))
		await _play_dots(_say_gen)
		_busy = false
		return
	if bool(opts.get("auto", false)):
		## 自动往下走：不出「继续」，导演一帧翻过 —— 玩家根本没有翻页的机会，
		## 所以整段一次画完。**气泡留在屏幕上**，由下一段原地换掉、或由提示行收掉
		_build_say("\n".join(lines), accent, false, 0)
		_busy = false
		return
	## ★ **一句一泡**（方向 A §1「多句：原地替换正文，不摞第二个泡」）。
	## 三句摞进一只泡，在第一关那个 4 倍的机位下会把主角细胞整个盖住 —— 09-19 真机第一版
	## 就是这样（A 的方向稿第 ② 帧里只画了一句，所以看不出来）
	for i in lines.size():
		_build_say(str(lines[i]), accent, true, 0)
		if _next != null and is_instance_valid(_next):
			_next.visible = true
		await advance_pressed
	_busy = false


## 三颗点逐颗渐显，再停 `DOT_HOLD`。`_dots` 一开始就建齐（测试数得着），只是 alpha 从 0 起。
## **拿的是这一段自己那份点**（`_dots` 随时会被下一段换掉），每一拍还要再验一次代号
func _play_dots(gen: int) -> void:
	var dots: Array = _dots.duplicate()
	for i in dots.size():
		## **先验号再转型**：对着已经 free 的对象做 `as` 本身就会报错，
		## `is_instance_valid` 得排在转型前面
		if gen != _say_gen or not is_inside_tree() or not is_instance_valid(dots[i]):
			return
		(dots[i] as ColorRect).color = Color(CWStyle.TEXT_HI,
			float(DOT_ALPHA[i % DOT_ALPHA.size()]))
		await _wait(DOT_BEAT)
	if gen == _say_gen:
		await _wait(DOT_HOLD)


func _wait(secs: float) -> void:
	if secs <= 0.0 or not is_inside_tree():
		return
	await get_tree().create_timer(secs).timeout


## 说话人的阵营色（方向 A §1：间章与第七关有 NPC 说话，玩家得一眼看出这句不是自己说的）。
## 旁白没有阵营 ⇒ 落到中性的描边基色
func _accent_of(who: String) -> Color:
	if who.begins_with("ui:"):
		return CWStyle.IMMUNE
	var s := _speaker(who)
	if s.is_empty():
		return CWStyle.LINE
	return CWStyle.IMMUNE if bool(s.get("immune", true)) else CWStyle.CANCER


## 装配方注入的那条 Callable 问一次（`who` → { at, immune }）。问不出来给 {}
func _speaker(who: String) -> Dictionary:
	if not speaker_of.is_valid():
		return {}
	var v: Variant = speaker_of.call(who)
	return v as Dictionary if v is Dictionary else {}


## 台词气泡的尾尖指到屏幕的哪一点。返回 null = 指不着（旁白 / 句柄没注入）⇒ 落到提示行上方
func _say_anchor() -> Variant:
	if _say_who.begins_with("ui:"):
		var r := _ui_rect(_say_who.substr(3))
		return null if r.size == Vector2.ZERO else Vector2(r.get_center().x, r.position.y)
	var at: Variant = _tile_of(_say_who, _say_at)
	if at == null or spot == null or not is_instance_valid(spot):
		return null
	return spot.head_of(at as Vector2i, HEAD_UP)


## 说话者站在哪一格：剧本显式写了 `at` 就听它的，否则问装配方
func _tile_of(who: String, at: Variant) -> Variant:
	if at != null:
		return SCRIPT_DATA.parse_at(str(at)) if at is String else (at as Vector2i)
	var s := _speaker(who)
	return s["at"] if s.has("at") else null


func _ui_rect(id: String) -> Rect2:
	if spot == null or not is_instance_valid(spot):
		return Rect2()
	return spot.rect_of(id)


func _clear_say() -> void:
	_say_gen += 1          ## 换号 = 还在播的「……」醒来就自己退场（它的点已经被 free 了）
	_dots.clear()
	_next = null
	if _say != null and is_instance_valid(_say):
		_say.queue_free()
	_say = null


## 一只台词气泡。`dots > 0` 时正文换成 N 颗方点（先全暗，`_play_dots` 一颗颗点亮）
func _build_say(text: String, accent: Color, with_next: bool, dots: int) -> void:
	_clear_say()
	_say = _bubble(text, accent, SAY_MAX_W, with_next, dots)
	add_child(_say)
	_place_say()


func _place_say() -> void:
	if _say == null or not is_instance_valid(_say):
		return
	_fit(_say)
	var a: Variant = _say_anchor()
	if a == null:
		## 指不着的（旁白）：摆到提示行正上方居中 —— 棋盘正中留给棋盘
		_place(_say, Vector2(HINT_RECT.get_center().x, HINT_RECT.position.y - 6.0), false)
		return
	_place(_say, a as Vector2, true)


# ════════════════════════════════════════════════════════════════
#  ② 行动提示行（`hint`）
# ════════════════════════════════════════════════════════════════

## **★ Kevin 2026-09-19：提示行一出现就把台词收掉**（沿用占位皮那条）。
## 它们在流程上本来就互斥 —— 说话的时候不该同时催人动手
func hint(text: String) -> void:
	_clear_say()
	if _hint == null or not is_instance_valid(_hint):
		return
	_hint.text = text
	_hint.visible = text != ""
	if not _hint.visible:
		return
	var box := _hint.get_minimum_size()
	_hint.size = box
	_hint.position = Vector2(HINT_RECT.get_center().x - box.x / 2.0,
		HINT_RECT.end.y - box.y).round()


# ════════════════════════════════════════════════════════════════
#  ③ 控件旁的小气泡（`point` 的 `tip`）
# ════════════════════════════════════════════════════════════════

## 提亮照旧交给提亮层（Kevin 09-19：按钮**保持单线原样、只慢闪**，皮一笔都不画），
## 但**那块最小的 `tip` 牌让位**：气泡的形状与尖角是皮的语言（方案 §5.1 末），这里自己画一只
func point(targets: Array, mode := "soft", tip := "") -> void:
	super.point(targets, mode, "")
	_tip_text = tip
	_build_tip()


func clear_point() -> void:
	super.clear_point()
	_tip_text = ""
	_build_tip()


func _build_tip() -> void:
	if _tip != null and is_instance_valid(_tip):
		_tip.queue_free()
	_tip = null
	if _tip_text == "":
		return
	_tip = _bubble(_tip_text, CWStyle.IMMUNE, TIP_MAX_W, false, 0)
	add_child(_tip)
	_place_tip()


func _place_tip() -> void:
	if _tip == null or not is_instance_valid(_tip):
		return
	_fit(_tip)
	if spot == null or not is_instance_valid(spot):
		_place(_tip, Vector2(HINT_RECT.get_center().x, HINT_RECT.position.y - 6.0), false)
		return
	var r: Rect2 = spot.focus_rect()
	_place(_tip, Vector2(r.get_center().x, r.position.y - GAP_TAIL), true)


# ════════════════════════════════════════════════════════════════
#  ④ 图鉴解锁：右上角滑入的小卡，连着几条就往下摞
# ════════════════════════════════════════════════════════════════

## 解锁点 id → 卡面上那个名字。走图鉴现成的对照表（`data/tutorial/codex_map.json` →
## `CWCodex.unlock_map()`）取第一条条目的标题；**表里没有就原样写 id**，不自己编名字。
## S6 收口图鉴映射时把这一支指过去即可，卡面的画法不用动
static func card_title(point_id: String) -> String:
	var ids: Array = CWCodex.unlock_map().get(point_id, [])
	if ids.is_empty():
		return point_id
	var want := str(ids[0])
	for ch in CWCodex.chapters():
		for e in (ch as Dictionary)["entries"]:
			if str((e as Dictionary).get("id", "")) == want:
				return str((e as Dictionary).get("t", point_id))
	return point_id


## 第 i 张卡的纵坐标。**纯函数**：测试核排队的间距
static func card_y(i: int) -> float:
	return CODEX_TOP + float(i) * (CODEX.y + CODEX_GAP)


## 卡的右缘：右栏弹出后让开那 264px（方向 A §5）
static func card_right() -> float:
	return CODEX_RIGHT_SIDEBAR if CWTutorLayers.on("sidebar") else CODEX_RIGHT


## 几个解锁点落到同一条目（第六关第 6 步 压迫 / 增生 / 侵蚀 三点共用「E 阶段」）就只滑一张卡 ——
## 三张一模一样的「【E 阶段】」摞在右上角（2026-09-24 真机截图）
func codex_unlocked(ids: PackedStringArray) -> void:
	var seen: Array = []
	for id in ids:
		var title := card_title(str(id))
		if title in seen:
			continue
		seen.append(title)
		_push_card(title)


func _push_card(title: String) -> void:
	if not is_inside_tree():
		return                     ## 没进树就没有 Tween，小卡也没人看（无头 / 拆局那几帧）
	var right := card_right()
	var card := Control.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = CODEX
	card.position = Vector2(right, card_y(_cards.size()))   ## 从屏幕右缘外滑进来
	var skin := Panel.new()
	var b := StyleBoxFlat.new()
	b.bg_color = Color("0a1018e6")
	b.border_color = Color(CWStyle.LINE, 0.4)
	b.set_border_width_all(2)
	skin.add_theme_stylebox_override("panel", b)
	skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(skin)
	var stripe := ColorRect.new()
	stripe.color = Color(CWStyle.IMMUNE, 0.85)
	stripe.position = Vector2(2.0, 2.0)
	stripe.size = Vector2(3.0, CODEX.y - 4.0)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(stripe)
	var cap := CWStyle.label("图鉴解锁", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	cap.position = Vector2(14.0, 6.0)
	card.add_child(cap)
	var nm := CWStyle.label("【%s】" % title, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	nm.position = Vector2(12.0, 16.0)
	card.add_child(nm)
	add_child(card)
	_cards.append(card)
	var tw := create_tween()
	var slide_in := tw.tween_property(card, "position:x", right - CODEX.x, CODEX_IN)
	slide_in.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_interval(CODEX_HOLD)
	tw.tween_property(card, "position:x", right, CODEX_OUT)
	tw.tween_callback(func() -> void: _drop_card(card))


## 一张卡到点了：摘掉它，剩下的往上补位（不补位的话第二张会孤零零挂在第二格上）
func _drop_card(card: Control) -> void:
	_cards.erase(card)
	if is_instance_valid(card):
		card.queue_free()
	for i in _cards.size():
		var c: Control = _cards[i]
		if is_instance_valid(c):
			c.position.y = card_y(i)


func _clear_cards() -> void:
	for c in _cards:
		if is_instance_valid(c):
			(c as Control).queue_free()
	_cards.clear()


# ════════════════════════════════════════════════════════════════
#  气泡的画法（方向 A 的 `_bubble` / `_tail_tex` / `_place`）
# ════════════════════════════════════════════════════════════════

## 像素三角尾巴（尖朝下的那一版；朝上靠 `flip_v`，不烤第二张）。
## **烤成小图再 NEAREST 放大**才是像素三角：用 `Polygon2D` 画会得到一条抗锯齿斜边，
## 和全游戏的点阵气质当场脱节
static func tail_tex(accent: Color) -> ImageTexture:
	var n := TAIL
	var m: int = (n + 1) / 2
	var img := Image.create(n, m, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var border := Color(accent, BORDER_A)
	for i in n:                              ## i 沿底边
		for j in m:                          ## j 沿指向（0 = 贴着气泡那一排）
			if i < j or i > n - 1 - j:
				continue
			var edge: bool = i < j + 2 or i > n - 3 - j
			img.set_pixel(i, j, border if edge else BUBBLE_BG)
	return ImageTexture.create_from_image(img)


## 一枚气泡（还没摆位置），返回的 Control 的 size 就是气泡本体
func _bubble(text: String, accent: Color, max_w: float, with_next: bool, dots: int) -> Control:
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if with_next:
		## ★ 带「继续」的气泡**整只接鼠标**（Kevin 2026-09-19 真机「这里点不了继续」：
		## 这张皮此前只给截图工具留了 `call:advance`，气泡 IGNORE、「继续」是纯 Label，玩家谁也点不着；
		## 占位皮 P 早就接了 `_next.gui_input`）。点整只气泡而不只点那两个字：手指 / 鼠标都好点。
		## 说话期间闸是关死的（PRD:51），气泡压住的那几格本来也点不了什么
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		box.gui_input.connect(_on_say_click)
		box.mouse_entered.connect(_set_next_hot.bind(true))
		box.mouse_exited.connect(_set_next_hot.bind(false))
	## 尾巴**只烤一次**：气泡每帧都要跟着细胞重摆，每帧重烤一张小图是纯浪费
	var tail := TextureRect.new()
	tail.name = "Tail"
	tail.texture = tail_tex(accent)
	tail.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tail.size = Vector2(float(TAIL), float((TAIL + 1) / 2))   ## 不给尺寸的 TextureRect 是 0×0，一笔都不画
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tail.visible = false
	var body_w := 0.0
	var body_h := 0.0
	if dots > 0:
		body_w = float(dots) * DOT_GAP - (DOT_GAP - DOT_SIZE)
		body_h = DOT_SIZE + 6.0
	else:
		var one: float = CWStyle.FONT.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_BODY).x
		body_w = minf(one, max_w)
		body_h = CWStyle.FONT.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, body_w, CWStyle.SIZE_BODY).y
	if with_next:
		body_w = maxf(body_w, CWStyle.FONT.get_string_size(
			NEXT_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_BODY).x)
		body_h += next_h()
	box.size = Vector2(body_w + PAD_H * 2.0, body_h + PAD_V * 2.0)
	var skin := Panel.new()
	var b := StyleBoxFlat.new()
	b.bg_color = BUBBLE_BG
	b.border_color = Color(accent, BORDER_A)   ## 描边取说话人的阵营色
	b.set_border_width_all(2)
	skin.add_theme_stylebox_override("panel", b)
	skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(skin)
	if dots > 0:
		for i in dots:
			var d := ColorRect.new()
			d.color = Color(CWStyle.TEXT_HI, 0.0)
			d.size = Vector2(DOT_SIZE, DOT_SIZE)
			d.position = Vector2(PAD_H + float(i) * DOT_GAP, PAD_V + 3.0)
			d.mouse_filter = Control.MOUSE_FILTER_IGNORE
			box.add_child(d)
			_dots.append(d)
	else:
		var lb := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		lb.name = "Body"          ## `_fit` 每帧照它的真实行数把气泡撑到位
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.position = Vector2(PAD_H, PAD_V)
		lb.size = Vector2(body_w, body_h - (next_h() if with_next else 0.0))
		box.add_child(lb)
	if with_next:
		## 「继续 ▸」钉在气泡**右下角**：正文左对齐，右下角永远空着
		_next = CWStyle.label(NEXT_TEXT, CWStyle.SIZE_BODY, CWStyle.TEXT_DIM)
		_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_next.position = Vector2(PAD_H, box.size.y - PAD_V - next_h())
		_next.size = Vector2(body_w, next_h())
		_next.visible = false
		box.add_child(_next)
	box.add_child(tail)          ## 尾巴最后加 ⇒ 压在气泡底边之上（要盖掉那 2px）
	return box


## 气泡的高度**按 Label 真正排出来的行数**重算一次，不吃 `get_multiline_string_size` 的估值：
## 那一支的折行标志与 `AUTOWRAP_WORD_SMART` 不是同一套，估少了「继续 ▸」就压在末行上
## （09-19 真机第一版的第 ② 帧正是这样）。**每帧问一次**：排版要等字体光栅化完才定下来
func _fit(box: Control) -> void:
	var lb := box.get_node_or_null("Body") as Label
	if lb == null or lb.get_line_count() <= 0:
		return
	var want: float = float(lb.get_line_count()) * float(lb.get_line_height())
	if is_equal_approx(want, lb.size.y):
		return
	lb.size.y = want
	var tall: bool = _next != null and is_instance_valid(_next) and _next.get_parent() == box
	box.size.y = want + PAD_V * 2.0 + (next_h() if tall else 0.0)
	if tall:
		_next.position.y = box.size.y - PAD_V - next_h()


## 把气泡摆到 `target`（屏幕坐标）旁边，尾尖指着它。
## 横向夹回画布内；上面塞不下就翻到目标下方、尾巴掉个头 —— 棋盘推到 4 倍时
## 细胞头顶离屏幕上缘只剩一点点，不翻的话气泡半只出屏
func _place(box: Control, target: Vector2, with_tail: bool) -> void:
	var tip: float = float((TAIL + 1) / 2)
	var w: float = box.size.x
	var h: float = box.size.y
	var up: bool = target.y - GAP_TAIL - tip - h < EDGE
	var y: float = (target.y + GAP_TAIL + tip) if up else (target.y - GAP_TAIL - tip - h)
	box.position = Vector2(
		clampf(target.x - w * 0.5, EDGE, maxf(CWView.screen_size().x - w - EDGE, EDGE)),
		clampf(y, EDGE, maxf(CWView.screen_size().y - h - EDGE, EDGE))).round()
	var tail := box.get_node_or_null("Tail") as TextureRect
	if tail == null:
		return
	tail.visible = with_tail
	if not with_tail:
		return
	tail.flip_v = up
	## 往回压 2px **盖住气泡自己的那道底边**：不盖的话尾巴会被一条描边横着切断，
	## 读起来像气泡下面另挂了一个小三角，而不是「从气泡里长出来的嘴」
	tail.position = Vector2(
		clampf(target.x - box.position.x - TAIL * 0.5, 6.0, maxf(w - TAIL - 6.0, 6.0)),
		(2.0 - tip) if up else (h - 2.0)).round()


## **每帧重摆**：细胞会走、棋盘会缩放，而行动栏那排按钮是「问的时候才建」的 ——
## 发 `point` 的那一帧栏里还没有【迁移】这颗（同提亮层的那条教训）
func _process(_delta: float) -> void:
	if _say != null and is_instance_valid(_say):
		_place_say()
	if _tip != null and is_instance_valid(_tip):
		_place_tip()


func teardown() -> void:
	_busy = false
	_clear_say()
	_tip_text = ""
	_build_tip()
	_clear_cards()
	if _hint != null and is_instance_valid(_hint):
		_hint.text = ""
		_hint.visible = false
	super.teardown()
