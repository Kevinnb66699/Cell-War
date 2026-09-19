## cw_tutor_view_plain.gd —— 皮 P：**占位皮**（零美术）
## （docs/新手引导v2_实现方案.md §5.2，S1，2026-09-19）
##
## ⚠ **本文件只保证流程跑得通，不代表任何美术口径。**
## Kevin 2026-09-19 把两版方向稿都否了（「两个都不好，重做」）⇒ 皮那一片（S3）阻塞在第二轮方向稿上，
## 而 S1/S2 的真机验收不能等。做法是零美术：棋盘下方一块文字区 + 右下角一颗「继续」，
## `point` 三档 `mode` 都不画，`chapter` / `codex_unlocked` 纯文字。
## **方向稿定稿之后由 S3 的皮取代**；S12 收口时决定留（当兜底）还是删。
##
## 带 class_name 的理由同基类：真机截图要 `screenshot.gd` 的 `call:CWTutorViewPlain:advance` 驱动。
class_name CWTutorViewPlain
extends CWTutorView

## 文字区那一带。上缘 356 = 出牌列 `CWFeed.RECT` 的下缘（`feed.gd:30`，它是 x 8..80 的窄列）；
## 下缘 464 给行动栏的目标选择态（`CWActionBar.PROMPT_RECT` 从 y=466 起）留 2px ——
## 这四条边是老浮层 `ACT_ZONE` 算出来的，那份账仍然成立，原样搬过来
const ZONE := Rect2(8, 356, 700, 108)
const PAD := 8
## 一行的实际高度。**不是随手填的**：SIZE_BODY 的 `Label` 真机实测行距就是 32px
## （09-19 截图上三句台词占 364 / 396 / 428）。填小了「继续」会压在第三句上
const ROW_H := 32
## 这一块最多放几行（3 行台词，或 1 行提示 + 解锁通知）
const MAX_ROWS := 3


## 台词 / 行动提示 / 图鉴解锁通知**共用这一块**：
## 它们在流程上本来就是互斥的（说话的时候不该同时催人动手），共用一块地方就不会互相压字
var _rows: VBoxContainer
var _next: Label          ## 「继续」（纯文字，点它发 advance_pressed）
var _busy := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = ZONE.position
	size = ZONE.size
	_rows = VBoxContainer.new()
	_rows.position = Vector2(PAD, PAD)
	_rows.size = Vector2(ZONE.size.x - PAD * 2, ROW_H * MAX_ROWS)
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rows)
	## 「继续」钉在**右下角**：文字区左对齐，最长那句也只铺到一半宽，右下角永远空着
	_next = CWStyle.label("继续 ▸", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	_next.position = Vector2(ZONE.size.x - 120, ZONE.size.y - ROW_H)
	_next.size = Vector2(112, ROW_H)
	_next.mouse_filter = Control.MOUSE_FILTER_STOP   ## 这一颗要收点击
	_next.visible = false
	_next.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			advance())
	add_child(_next)


## 「继续」按下。**真机截图走 `call:CWTutorViewPlain:advance`** —— 合成鼠标点不到 Control
func advance() -> void:
	if not _busy:
		return
	_busy = false
	_next.visible = false
	advance_pressed.emit()


func _clear_rows() -> void:
	if _rows == null or not is_instance_valid(_rows):
		return
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()   ## 先摘再 free：queue_free 是延迟的，只 free 的话这一帧 VBox 还按老行数排版


func _row(text: String, color: Color) -> void:
	if _rows == null or not is_instance_valid(_rows):
		return
	var l := CWStyle.label(text, CWStyle.SIZE_BODY, color)
	l.custom_minimum_size = Vector2(0, ROW_H)
	_rows.add_child(l)


func say(who: String, lines: PackedStringArray, opts: Dictionary) -> void:
	_clear_rows()
	var head := "" if who == "player" else "[%s] " % who
	for i in lines.size():
		_row(("%s%s" % [head, lines[i]]) if i == 0 else str(lines[i]), CWStyle.TEXT_HI)
	if bool(opts.get("auto", false)):
		return                      ## 自动往下走：不出「继续」，导演一帧翻过
	_busy = true
	_next.visible = true
	await advance_pressed


func busy() -> bool:
	return _busy


func chapter(no: int, title: String) -> void:
	if chrome != null and is_instance_valid(chrome):
		await chrome.show_chapter(no, title)
		return
	## 没挂常驻壳（无头 / 预览）时退成一行字，照样是协程
	await say("narrator", PackedStringArray(["第 %d 章 %s" % [no, title]]), { "auto": true })


## 解锁通知**接在台词后面再补一行**（不清台词）：剧本里 `unlock` 紧跟着讲这件事的那一句，
## 两者一起读才通顺 —— 「这是健康组织 / 图鉴解锁：健康组织」
func codex_unlocked(ids: PackedStringArray) -> void:
	if ids.is_empty():
		return
	_row("图鉴解锁：%s" % ", ".join(ids), CWStyle.IMMUNE)


## 行动提示行：**换人动手了，上一段台词让位**。空串 = 什么都不提示（清干净）
func hint(text: String) -> void:
	_clear_rows()
	if text != "":
		_row(text, CWStyle.TEXT_DIM)


func teardown() -> void:
	_busy = false
	_clear_rows()
	if _next != null and is_instance_valid(_next):
		_next.visible = false
	super.teardown()
