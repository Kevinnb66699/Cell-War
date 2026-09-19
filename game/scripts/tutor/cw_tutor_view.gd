## cw_tutor_view.gd —— 导演 → 皮 的**唯一接口**（docs/新手引导v2_实现方案.md §5.1，S1，2026-09-19）
##
## 导演只发**意图**，一个控件名都不认识：`point([{kind:"ui", id:"bar:迁移"}])` 里的「迁移」是
## **按钮标题**不是节点路径，两版皮各自用 `action_bar.button_rect("迁移")` 或别的办法去找。
## 换皮 = 换一个实例，导演与数据一行都不用改。
##
## **基类给默认实现**（六个）：`chapter` / `point` / `clear_point` / `block` / `reset_anim` / `reveal`
## 一律转调两个共用件（`cw_tutor_chrome.gd` 常驻壳、`cw_tutor_spot.gd` 提亮层，后者 S2 补）。
## 理由：PRD 通用规则 1/4/5/7/8/9 与「说话的样子」无关，两皮各抄一份必然漂移。
## 皮通常只覆写 `say` / `hint` / `codex_unlocked` 三个。
##
## **带 class_name，代价是走不了热更，别再往里塞新逻辑**（方案 §1.5 的三个例外之一）：
## 真机截图要 `screenshot.gd` 的 `call:类名:方法` 驱动 —— 合成的鼠标点击到不了 `Control`。
class_name CWTutorView
extends Control

signal advance_pressed              ## 玩家点「继续」（只有 say 且 auto:false 时导演才理）
signal reset_pressed                ## 常驻壳
signal menu_goto(level_id: String)
signal switch_type_pressed

## 提亮层（`cw_tutor_spot.gd`）与教程演出库（`cw_tutor_fx.gd`）。两支都**没有 class_name**
## （方案 §1.5 只给了三个例外），所以在这儿 preload 一次
const SPOT := preload("res://scripts/tutor/cw_tutor_spot.gd")
const FX := preload("res://scripts/tutor/cw_tutor_fx.gd")

## 常驻壳（章节提示 / 全屏 STOP / 重置 / 目录）。两皮共用一只，由装配方注入
var chrome: CWTutorChrome = null
## 提亮层。两皮共用一只，由装配方注入 —— 它要认识行动栏 / 右栏 / 棋盘的矩形，而**皮不认识**
var spot = null
## 教程演出库（`cw_tutor_fx.gd`）。**装配方注入接了棋盘的那一只**，皮不自己建 ——
## 「倒带」那支有一半画在棋盘上（`_draw_rewind` 要 `board.tile_center`），
## 没接棋盘的话每一帧报一条「Nonexistent function 'tile_center' in base 'Nil'」（09-19 真机实测）
var fx = null
## 地图浮现：把一组坐标加进棋盘的活跃集（`CWBoard.set_active_tiles`）。装配方注入，
## **皮不认识棋盘** —— 这是接口纪律「只发意图、不发控件」在 reveal 上的落法
var reveal_tiles: Callable = Callable()
## 说话人是谁（S3 的贴身气泡要它）：`who`（"player" / "seat:<n>"）→ `{ at: Vector2i, immune: bool }`，
## 问不出来给 `{}`。装配方注入，同 `reveal_tiles` 那条 —— **皮不认识镜像**，
## 而「气泡挂在哪一格、描边取哪个阵营色」这两件只有局面答得上来
var speaker_of: Callable = Callable()


## ① 说台词。`who`: "player" | "seat:<n>" | "narrator" | "ui:<控件 id>"
##    `opts`: { beats:int, auto:bool, at:Vector2i }
##    **协程**：播完才返回（期间导演已经把闸关死了）
func say(_who: String, _lines: PackedStringArray, _opts: Dictionary) -> void:
	pass


## 这一段还在念吗（导演每帧问一次，用它决定翻不翻页）
func busy() -> bool:
	return false


## ② 高亮。`targets` 每条形如 { "kind":"ui", "id":… } / { "kind":"hex", "at":Vector2i }
##    `mode`: "soft"（默认 = PRD 通用规则 8 的轻微慢闪）| "arrow" | "fullscreen"（PRD:445）
##    `tip`: 挂在目标上的一句话（PRD:447/479/491），空串 = 不挂
func point(targets: Array, mode := "soft", tip := "") -> void:
	if spot != null and is_instance_valid(spot):
		spot.point(targets, mode, tip)


func clear_point() -> void:
	if spot != null and is_instance_valid(spot):
		spot.clear()


## ③ 章节全屏半透明提示（PRD:35）。**协程**：播完才往下
func chapter(no: int, title: String) -> void:
	if chrome != null and is_instance_valid(chrome):
		await chrome.show_chapter(no, title)


## ④ 图鉴解锁通知（PRD:29 的 12 处）
func codex_unlocked(_ids: PackedStringArray) -> void:
	pass


## ⑤ 禁操作层（PRD:51 的第 2 层）：真·全屏 `Control`（`MOUSE_FILTER_STOP`），
## z 序盖在棋盘与行动栏之上、排在常驻「重置 / 目录」之下（那两颗提示期照常可点）
func block(on: bool) -> void:
	if chrome != null and is_instance_valid(chrome):
		chrome.set_block(on)


## ⑥ 自动重置动画提示（PRD:47）。**协程**：播完才重装关首那份 world。
## 候选走 `cw_tutor_fx.RESET_VARIANT`（Kevin 2026-09-19 三选一定「倒带」rewind）——
## 换候选只改演出库那一行常量，这里不再抄一份
func reset_anim() -> void:
	if fx == null or not is_instance_valid(fx):
		return
	await fx.play("reset_hint", { "variant": FX.RESET_VARIANT })


## ⑦ 地图浮现（PRD:45）。**协程**：按 `ring_delays` 错峰由棋盘那边做
func reveal(coords: Array) -> void:
	if reveal_tiles.is_valid():
		reveal_tiles.call(coords)


## ⑧ 行动提示行
func hint(_text: String) -> void:
	pass


## 劝重置（方案 §3.5）：不重置，只把提示行换成 `advise` 那一句 + 「重置本关」跟着慢闪
func urge_reset(on: bool) -> void:
	if chrome != null and is_instance_valid(chrome):
		chrome.urge_reset(on)


## ⑨ 常驻壳的一份状态：{chapter, level, menu:[{id,title,unlocked}], can_reset}
func shell(state: Dictionary) -> void:
	if chrome != null and is_instance_valid(chrome):
		chrome.sync(state)


func teardown() -> void:
	clear_point()
	if fx != null and is_instance_valid(fx):
		fx.clear()
