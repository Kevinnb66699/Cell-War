## energy_fx.gd —— 能量增损的通用飘字（issue #48，HXR-I：
## 「对于所有使细胞能量产生改变的事件，细胞贴图和右侧细胞状态栏都应有相应动画来提示」）
##
## **不接引擎、不加报文**：能量变化由 `CWMatch._sync_cells` 的**镜像差分**认出来
## （上一帧这只细胞几点能量、这一帧几点），所以**凡是**改能量的事件都覆盖到了 ——
## 有氧 / 无氧收入、攻击伤害与反弹、迁移费用、卡牌增损、过载、复活初始能量……
## 一条条去接演出报文是接不全的，而差分天生全覆盖。同 `CWTeleportFx` 那条先例
## （`teleport_fx.gd:8-9`：传送也是靠差分认出来的，引擎零改动）。
##
## 形态：细胞头顶飘一个 ±数字，往上走 RISE_PX、末段淡出。右栏那一行同时色闪一下
## （`CWMatchPanel.bump_energy`）—— 两处同一拍，眼睛跟得上「棋盘上这只 = 右栏那一行」。
##
## 字**不走 CWStyle.FONT**：棋盘层带着相机缩放（zoom 1.27），10px 点阵字过去就被重采样磨出灰边
## （架构约定 #13）。这里用一张手写的 3×5 像素字模，和盾的 SHIELD_HALF 一个路子 ——
## 纯整数像素、纯函数、无头测试直接核字模。
##
## 沿用像素纪律（`chemo_fx.gd` 头注）：① 整数像素 ② 时间按 PIX_FPS 量化 ③ 透明度只取几档。
##
## **别刷屏**（issue #48 的另一半）：同一只细胞在 MERGE 秒内的多次变化**合并成一条**
## （攻击的扣血 + 反弹常常同一拍落地）；再多就按 SLOT_DX 左右错峰，最多同时留 MAX_PER_CELL 条。
##
## **没有 class_name**（同 `attack_fx.gd`）：新 class_name 热更装不上 —— 全局类表在导出那一刻
## 烘死，补丁里的新类名认不出来。用法：`const ENERGY_FX := preload(...)` 再 `.new()`。
extends Node2D

const PIX_FPS := 12.0
const LIFE := 1.05           ## 一条飘字活多久
const RISE_PX := 13.0        ## 一生往上走多少（缓出：起手快、末尾几乎停住）
const MERGE := 0.22          ## 这么久之内同一只细胞的再一次变化并进上一条
const MAX_PER_CELL := 3
const SLOT_DX: Array[float] = [0.0, -11.0, 11.0]   ## 并不进去的就左右错开，别叠在一起
## 「还没见过这只细胞的能量」——差分要有上一帧才成立，第一帧只记不演（同 _was_alive 的道理）
const UNSEEN := -0x3FFFFFFF

## 进账 / 出账两支笔在 `CWStyle`（右栏那一行的色闪用的是同两支 —— 配色只许有一处）
const SHADOW := Color("0d1520")  ## 字底那一层影：棋盘上什么底色都有，没影就会糊进去

## 3×5 的像素字模：每格一行，从高位到低位是左到右三列。
## 只有 0~9 和 `+ - .` —— 能量的写法就是 `CWData.fmt` 的「几点几」，再没别的字符。
const GLYPH := {
	"0": [0b111, 0b101, 0b101, 0b101, 0b111],
	"1": [0b010, 0b110, 0b010, 0b010, 0b111],
	"2": [0b111, 0b001, 0b111, 0b100, 0b111],
	"3": [0b111, 0b001, 0b111, 0b001, 0b111],
	"4": [0b101, 0b101, 0b111, 0b001, 0b001],
	"5": [0b111, 0b100, 0b111, 0b001, 0b111],
	"6": [0b111, 0b100, 0b111, 0b101, 0b111],
	"7": [0b111, 0b001, 0b010, 0b010, 0b010],
	"8": [0b111, 0b101, 0b111, 0b101, 0b111],
	"9": [0b111, 0b101, 0b111, 0b001, 0b111],
	"+": [0b000, 0b010, 0b111, 0b010, 0b000],
	"-": [0b000, 0b000, 0b111, 0b000, 0b000],
	".": [0b000, 0b000, 0b000, 0b000, 0b010],
}
const GLYPH_W := 3
const GLYPH_H := 5
const ADVANCE := 4           ## 字宽 3 + 1 列字距
const DOT_ADVANCE := 2       ## 小数点自己窄一半，不然「1.5」中间空一个洞
## 每个字模像素放大几倍。3×5 原大在 960×540 的棋盘上小得认不出，2 倍（6×10）与右栏
## 那个 SIZE_BODY 的能量数字差不多高。**只取整数倍** —— 像素风最忌讳非整数缩放
const SCALE := 2

var _floats: Array = []      ## [{ cid, at, amount, slot, t }]


func _init() -> void:
	visible = false


## 这一只细胞的能量变了 `amount`（引擎那套十分之一整数：10 = 1.0 点，同 `CWData.fmt`）。
## `at` 是这一帧它头顶的棋盘像素。0 不演（差分只在变了的时候调，这里是兜底）。
func push(cid: int, at: Vector2, amount: int) -> void:
	if amount == 0:
		return
	var mine: Array = []
	for f in _floats:
		if int(f["cid"]) == cid:
			mine.append(f)
	## ① 同一拍里的多次变化合并（攻击扣血 + 反弹常常一起落地）
	if not mine.is_empty():
		var last: Dictionary = mine[mine.size() - 1]
		if float(last["t"]) <= MERGE:
			last["amount"] = int(last["amount"]) + amount
			last["at"] = at
			if int(last["amount"]) == 0:
				_floats.erase(last)      ## 一进一出正好抵消：那就什么都没发生
			visible = not _floats.is_empty()
			queue_redraw()
			return
	## ② 合不进去的错峰；再多就把最老的那条顶掉
	if mine.size() >= MAX_PER_CELL:
		_floats.erase(mine[0])
		mine.remove_at(0)
	_floats.append({ "cid": cid, "at": at, "amount": amount,
		"slot": mine.size() % SLOT_DX.size(), "t": 0.0 })
	visible = true
	queue_redraw()


func active() -> int:
	return _floats.size()


## 拆局：把这一层擦干净（同各演出层的 clear —— 没人再调 sync，最后那一帧会永远停在屏幕上）
func clear() -> void:
	_floats.clear()
	visible = false
	queue_redraw()


func sync(delta: float) -> void:
	if _floats.is_empty():
		return
	var keep: Array = []
	for f in _floats:
		f["t"] = float(f["t"]) + delta
		if float(f["t"]) < LIFE:
			keep.append(f)
	_floats = keep
	visible = not _floats.is_empty()
	queue_redraw()


## 飘字的文案：`+1.5` / `-0.8`。**不能直接用 `CWData.fmt(负数)`** ——
## 它是 `"%d.%d" % [e / 10, abs(e) % 10]`，-5 会印成 `0.5`（整数除法把符号吃了）。
## **纯函数**，护栏直接核。
static func text_of(amount: int) -> String:
	return ("+" if amount > 0 else "-") + CWData.fmt(absi(amount))


## 这串字占多宽（**字模格**，画的时候再乘 SCALE）。**纯函数**
static func text_width(s: String) -> int:
	var w := 0
	for i in s.length():
		w += DOT_ADVANCE if s[i] == "." else ADVANCE
	return maxi(w - 1, 0)


## 活了 age 秒的那条飘字：往上走多少、透明度取哪一档（0 = 该收了）。**纯函数**
static func rise(age: float) -> float:
	var p := clampf(age / LIFE, 0.0, 1.0)
	return -RISE_PX * (1.0 - (1.0 - p) * (1.0 - p))   ## 缓出：起手快、末尾几乎停住


## 透明度只取三档（纪律 ③）
static func alpha_of(age: float) -> float:
	var p := clampf(age / LIFE, 0.0, 1.0)
	if p >= 1.0:
		return 0.0
	return 1.0 if p < 0.62 else (0.66 if p < 0.84 else 0.33)


func _draw() -> void:
	for f in _floats:
		var age: float = floorf(float(f["t"]) * PIX_FPS) / PIX_FPS
		var a := alpha_of(age)
		if a <= 0.0:
			continue
		var amount: int = int(f["amount"])
		var s := text_of(amount)
		var at: Vector2 = Vector2(f["at"]) + Vector2(
			SLOT_DX[int(f["slot"])] - float(text_width(s) * SCALE) * 0.5, rise(age))
		var ink: Color = CWStyle.ENERGY_GAIN if amount > 0 else CWStyle.ENERGY_LOSS
		ink.a = a
		var shade := SHADOW
		shade.a = a * 0.75
		draw_text(self, s, at + Vector2(SCALE, SCALE), shade)
		draw_text(self, s, at, ink)


## 一串 3×5 的像素字（每格放大 `scale` 倍），左上角对齐到 `at`。
## **静态**：预览脚本与护栏都直接调
static func draw_text(ci: CanvasItem, s: String, at: Vector2, color: Color, scale := SCALE) -> void:
	var pen := at
	for i in s.length():
		var ch := s[i]
		var rows: Array = GLYPH.get(ch, [])
		for r in rows.size():
			var bits: int = rows[r]
			for c in GLYPH_W:
				if bits & (1 << (GLYPH_W - 1 - c)) != 0:
					CWPix.px(ci, pen + Vector2(float(c * scale), float(r * scale)), color, scale)
		pen.x += float((DOT_ADVANCE if ch == "." else ADVANCE) * scale)
