## cw_tutor_chrome.gd —— 教程的**常驻壳**：全屏 STOP 层 + 常驻「重置本关」
## （docs/新手引导v2_实现方案.md §3.4 / §3.6，S1 最小版，2026-09-19）
##
## **这一片只做两件**（S2 补齐章节提示的全屏半透明大字、目录面板、「切换种类」）：
## ① **禁操作的第二层**（PRD:51）—— 提示 / 对话播放期，闸那一层把「这一问」挂起了，
##    但玩家还能点棋盘、点行动栏上一问留下的按钮。所以要一层**真·全屏 `Control`**
##    （`MOUSE_FILTER_STOP`），z 序盖在棋盘与行动栏之上、**排在常驻按钮之下**
##    —— 「重置 / 目录」提示期照常可点（PRD:41/43）。
##    **不能指望皮自己那层**：老 `CWGuide.ZONE` 只有 600×200，盖不住棋盘与右栏。
## ② **常驻「重置本关」**（PRD:41）：局面退回本关初始状态。劝重置时它跟着慢闪（PRD 通用规则 8）。
##
## 带 class_name 的理由同两版皮（方案 §1.5 的三个例外）：真机截图要 `call:CWTutorChrome:方法` 驱动。
class_name CWTutorChrome
extends Control

## 章节提示停多久（S2 才真画，这里只把时长与协程形状定下来）
const CHAPTER_SECS := 1.8
## 「重置本关」那颗的位置：左上角，**排在迷你日志入口下面一行**。
## 迷你日志收成 compact 之后仍占 `CWLogPanel.RECT.position`（16,16）起的 300x22
## （`log_hint.gd:61` / `:27` / `:33`）—— 09-19 真机第一版写的 (12,12) 正好压在它身上，
## 两行字叠成一团。x 跟它对齐、y 让过 22 + 8 的行距，再往下就撞出牌列 CWFeed 的顶（y=76）
const RESET_RECT := Rect2(16, 46, 120, 24)

signal reset_pressed
signal menu_pressed

var _block: ColorRect       ## 全屏 STOP 层
var _reset: Label
var _urging := false
var _pulse_t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_block = ColorRect.new()
	_block.color = Color(0, 0, 0, 0)          ## 只挡点击，不改画面（PRD 没要求压暗）
	_block.set_anchors_preset(Control.PRESET_FULL_RECT)
	_block.mouse_filter = Control.MOUSE_FILTER_STOP
	_block.visible = false
	add_child(_block)
	## 常驻按钮加在遮挡层**之后** ⇒ z 序在它之上 ⇒ 提示期照常可点
	_reset = CWStyle.label("重置本关", CWStyle.SIZE_BODY, CWStyle.TEXT_DIM)
	_reset.position = RESET_RECT.position
	_reset.size = RESET_RECT.size
	_reset.mouse_filter = Control.MOUSE_FILTER_STOP
	_reset.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			reset_pressed.emit())
	add_child(_reset)


func _process(delta: float) -> void:
	if not _urging:
		return
	## PRD 通用规则 8：较慢频次、反差较低的轻微闪烁。三个参数收敛在 CWStyle 一处
	_pulse_t += delta
	var k := 0.5 + 0.5 * sin(_pulse_t * TAU / CWStyle.HALO_PERIOD)
	_reset.modulate.a = lerpf(CWStyle.HALO_ALPHA_LO, CWStyle.HALO_ALPHA_HI, k)


## 禁操作层开合（PRD:51 的第 2 层）
func set_block(on: bool) -> void:
	if _block != null and is_instance_valid(_block):
		_block.visible = on


func blocking() -> bool:
	return _block != null and is_instance_valid(_block) and _block.visible


## 劝重置（方案 §3.5）：**不重置**，只让「重置本关」慢闪
func urge_reset(on: bool) -> void:
	_urging = on
	if not on and _reset != null and is_instance_valid(_reset):
		_pulse_t = 0.0
		_reset.modulate.a = 1.0


## 章节全屏提示（PRD:35）。**协程**：播完才往下。S2 才真画那一屏半透明大字 ——
## 这一片先把「它是协程、导演要等它」这件事钉住，免得 S2 接上时导演要跟着改
func show_chapter(_no: int, _title: String) -> void:
	if not is_inside_tree():
		return
	await get_tree().create_timer(CHAPTER_SECS).timeout


## 常驻壳的一份状态（S2 的目录面板读它）。这一片只认 `can_reset`
func sync(state: Dictionary) -> void:
	if _reset != null and is_instance_valid(_reset):
		_reset.visible = bool(state.get("can_reset", true))
