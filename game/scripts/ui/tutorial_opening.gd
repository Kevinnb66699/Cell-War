## tutorial_opening.gd —— 新手引导的开场动画（PRD「开场动画」:59-87 / docs/新手引导_实现方案.md §S7）
##
## **独立场景，压根不建内核**（方案 §1.10 第 ③ 类演出）：这一段里没有 CWKernel、没有对局、没有席位，
## 屏幕上那两只细胞和那张棋盘全是**画出来的**。这么做不是图省事 —— 开场里「组织跌落」「同心圆净化」
## 在规则里根本不存在，硬要走引擎就得往内核里塞一堆只有这十秒钟用得上的东西。
##
## 分镜正本是 `res://data/tutorial/cutscenes/opening.json`：13 条对 PRD:63~87 的 13 行，
## 每条 `t / prd / kind / args / text`。**时间与参数只有那一份**，本文件不另写一套常数
## （写成两份就必然有一天对不上，而对不上的表现是「演出比 PRD 差半拍」，没人看得出来）。
##
## 三段新演出：
##   ① 文字变细胞（PRD:65）：首页那行 IMMUNE VS CANCER 拆成三个词，IMMUNE / CANCER 各自飞向
##      自己那一格、缩小淡出，同刻细胞贴图淡入，交接那几帧在落点炸一小把像素碎粒。
##   ② 同心圆净化 + 反向【侵蚀】（PRD:77/79）：以癌细胞为心的椭圆环（棋盘是压扁的，所以画椭圆不画正圆）
##      一格一格往外推，扫到的癌性格**倒着**播美术那两帧侵蚀过场（p66 → p33 → 健康）——
##      正着放是「癌漫过来」，倒过来就是「癌退回去」。
##   ③ 组织跌落（PRD:81）：环扫过之后 0~1 秒的随机时刻整格往下掉并淡出。
##      **随机走本场景自己的 `RandomNumberGenerator`**（附 C 第 5 条）：碰内核 rng 会让教程那几关的
##      预设骰子带子整条错位。开场这里连内核都没有，更是一滴都不许沾 —— `t_tutorial_opening` 有一条源码闸盯着。
##
## **自己的相机**：不碰 `Main` 那台 `Camera2D`（工程里只有一台，抢过来主菜单和对局的机位就跟着动）。
## 取景做在 `Stage` 这个 `Node2D` 的 `scale` / `position` 上 —— 那正是相机变换的逆，
## 看点 / 锚点 / zoom 三个参数与 `CWView` 同一套，所以「和首页一致」是结构上成立的，不是拿眼睛对出来的。
##
## **整段是时间的纯函数**：`_apply(t)` 按**量化到 1/12 秒**（`PIX_FPS`，同 `CWSkillFx` / `CWChemoFx`）的 t
## 把所有位置 / 透明度算一遍，不挂任何 `Tween`。好处有二：跳过 = `seek(duration())` 一步到位；
## 无头测试 = 自己喂时间，不用真等十秒。唯一的例外是攻击演出 —— 复用对局那支 `CWAttackFx`，它按 delta 自走。
##
## **没有 `class_name`**（附 C 第 1 条）：新全局类进不了热更补丁。用法是 preload 场景再 `instantiate()`。
extends Node2D

## 演完了（或被跳过）。`main.gd` 等这一下，再把第一关装起来、最后才把盖着的这一层淡掉
signal finished

const PIX_FPS := 12.0                ## 逐帧步进：同 CWSkillFx.PIX_FPS / CWChemoFx.PIX_FPS
const TIMELINE := "res://data/tutorial/cutscenes/opening.json"

const ATTACK_FX := preload("res://scripts/ui/attack_fx.gd")
const BOARD_SCENE := preload("res://scenes/Board.tscn")
const PIXEL_FONT := preload("res://assets/fonts/fusion_pixel_10px.ttf")
const LOGO_FONT := preload("res://assets/fonts/silkscreen_bold.ttf")

## 细胞贴图：**横排 6 帧静息呼吸表**，和棋盘上的细胞同一批（`CWMatch.IMMUNE_ART` / `CANCER_ART`）。
## 这里按分镜里的词条名建表、不按 `CWData` 的枚举 —— 开场是纯演出，不该为了取一张图去认识内核的类型系统。
const CELL_ART := {
	"ImmuneBasic": preload("res://assets/art/cells/anim/immune_breath.png"),
	"Melanoma": preload("res://assets/art/cells/anim/melanoma_breath.png"),
	"SignetRing": preload("res://assets/art/cells/anim/signet_breath.png"),
	"Osteosarcoma": preload("res://assets/art/cells/anim/osteo_breath.png"),
	"SmallCellLung": preload("res://assets/art/cells/anim/sclc_breath.png"),
}
const BREATH_FRAMES := 6             ## 同 CWMatch.BREATH_FRAMES
const BREATH_FPS := 6.0              ## 同 CWMatch.BREATH_FPS
const CELL_FOOT_DY := 6.0            ## 同 CWMatch.CELL_FOOT_DY：脚底落在格顶面中心再往下 6px

## 首页那两行字的排版（照 `scenes/MainMenu.tscn` 的 Sub / Logo 逐值抄；「和首页一致」就是这几个数）
const SUB_AT := Vector2(120, 119)
const SUB_SIZE := 20
const SUB_SPACING := 2               ## FontVariation.spacing_glyph
const SUB_INK := Color("30d1fa")
const LOGO_AT := Vector2(120, 172)
const LOGO_SIZE := 64
const LOGO_INK := Color("e9f6fa")
const LOGO_SHADOW := Color("1a1a2e")
const LOGO_GLOW := Color(0.188235, 0.819608, 0.980392, 0.28)
const SKY := Color("0a0d14")         ## 幕布：比首页的压暗层再深一档，底下的菜单 / 对局一点都不许透出来

## 跳过提示。**PRD 没写跳过规则** —— 这一条是补的，等 hxr 拍（开发日志 2026-09-18 那条里记着）
const SKIP_HINT := "按任意键跳过"
const SKIP_HINT_AT := 1.0            ## 演到这一刻才把提示浮出来，免得和第一拍抢眼
const SKIP_GRACE := 0.25             ## 同 `main.gd` 的 SKIP_GRACE_MS：起步这一下不算跳过
                                     ##（点「新手引导」的那一下会一路漏到这里来）

## z 序：棋盘格子拿像素 y 当 z（board.gd `new_tissue`），范围 ±120 ⇒ 幕布要压到它下面、文字要抬到它上面
const Z_SKY := -200
const Z_FX := 200
const Z_SCREEN := 300

## 跌落的随机种子。0 = 每次现随（真机）；测试钉一个数就能复现同一批跌落时刻
var rng_seed := 0
## 自动播放。测试置 false，自己用 `advance(delta)` 喂时间（**要在 add_child 之前置**）
var auto_play := true

var _cut: Dictionary = {}            ## 分镜正本
var _cues: Dictionary = {}           ## kind -> 那一条（kind 在表里唯一）
var _t := 0.0
var _running := false
var _done := false
var _struck := false                 ## 攻击演出只触发一次
var _rng := RandomNumberGenerator.new()

var _layer: CanvasLayer
var _root: Control                   ## 整段的淡出把手（CanvasLayer 不吃父节点的 modulate，所以要有这一层）
var _stage: Node2D                   ## 本场景自己的「相机」：scale / position 就是取景变换
var _board                           ## Board.tscn 的实例。**不加类型注解**：board.gd 没有 class_name，
                                     ## 标成 Node2D 就够不着 tile_center / TISSUE_TEX 这些成员
var _cells: Node2D
var _falls: Node2D
var _fx: Painter
var _attack                          ## CWAttackFx 的实例，同上（attack_fx.gd 也没有 class_name）
var _screen: Control
var _title: Array[Label] = []        ## [影, 辉, 正] 三层，同首页那一摞
var _words: Dictionary = {}          ## "IMMUNE" / "VS" / "CANCER" -> Label
var _word_home: Dictionary = {}      ## 词 -> 静止位置（屏幕坐标）
var _skip_hint: Label

var _immune: Sprite2D
var _cancer: Sprite2D
var _immune_at := Vector2i.ZERO      ## 免疫这一刻站在哪一格（行进途中 = 刚落脚的那一格）
var _cancer_at := Vector2i.ZERO
var _tissue := {}                    ## 格 -> CWData.Tissue：本场景自己记一份，不去翻棋盘节点的内部表
var _purify_at := {}                 ## 格 -> 开始反向侵蚀的时刻
var _fall_delay := {}                ## 格 -> 环扫过之后等多久才掉（0~1 秒，本层 rng 抽的）
var _hidden := {}                    ## 格 -> 跌落代画节点；棋盘上那一格同刻藏起来
var _hidden_n := -1                  ## 上一次同步给棋盘的藏格数，变了才重设活跃集
var _span := Vector2.ZERO            ## **癌区**的像素横跨 [最左, 最右]，建台时算一次（逐格揭示按它归一化）


## ── 「开场看过没有」：与引导进度同一份 user:// 配置 ──────────────────────
##
## 存在 `CWGuideProgress.PATH` 的同一个 section 里加一个键，而**不是**改 `cw_guide_progress.gd` ——
## 那个文件这几天另有人在改（S6 图鉴解锁），两边同时动同一份代码只会撞车。
## `ConfigFile` 是整份读改写，两边各自 `load` 再 `set_value`，互不覆盖对方的键。
const SEEN_KEY := "opening_seen"


static func seen() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CWGuideProgress.PATH) != OK:
		return false
	return bool(cfg.get_value(CWGuideProgress.SECTION, SEEN_KEY, false))


static func mark_seen() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CWGuideProgress.PATH)   ## 旧文件在就把 done 那些键带回来，别整份盖掉
	cfg.set_value(CWGuideProgress.SECTION, SEEN_KEY, true)
	cfg.save(CWGuideProgress.PATH)


## 只清「开场已看」这一个键，不碰关卡进度（真机截图流程要反复重看开场）
static func clear_seen() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CWGuideProgress.PATH) != OK:
		return
	cfg.set_value(CWGuideProgress.SECTION, SEEN_KEY, false)
	cfg.save(CWGuideProgress.PATH)


# ── 生命周期 ──────────────────────────────────────────────────────────

func _ready() -> void:
	_cut = load_timeline()
	for cue in _cut.get("cues", []):
		_cues[str((cue as Dictionary)["kind"])] = cue
	_build()
	if auto_play:
		begin()


## 分镜正本。**读不出来就返回 `{}`** —— 调用方据此整段跳过，而不是留一块黑幕把玩家关在外面
##（开场是装饰，装饰坏了不该拦住教程）
static func load_timeline() -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TIMELINE))
	if not (raw is Dictionary) or not (raw as Dictionary).has("cues"):
		push_warning("开场动画：分镜读不出来（%s）" % TIMELINE)
		return {}
	return raw as Dictionary


func duration() -> float:
	return float(_cut.get("duration", 0.0))


func cues() -> Array:
	return _cut.get("cues", [])


func begin() -> void:
	if _cut.is_empty():
		_finish()
		return
	if rng_seed != 0:
		_rng.seed = rng_seed
	else:
		_rng.randomize()
	_roll_falls()
	_reset_fx()
	_t = 0.0
	_running = true
	_done = false
	_apply(0.0)


func _process(delta: float) -> void:
	if _running and auto_play:
		advance(delta)


## 喂时间。真机由 `_process` 调；无头测试自己调，不用真等十秒
func advance(delta: float) -> void:
	if not _running:
		return
	_t += delta
	_apply(_t)
	_attack.sync(delta)
	if _t >= duration():
		_finish()


## 一步跳到某个时刻（跳过 = `seek(duration())`）。攻击演出按 delta 自走，所以先擦掉再看要不要重放；
## 往回跳还要把已登记的净化 / 跌落一并撤掉，否则旧状态会跟着回到过去
func seek(to: float) -> void:
	var back := to < _t
	_t = maxf(to, 0.0)
	if back:
		_reset_fx()
	_attack.clear()
	_struck = _t >= _at("strike")
	_apply(_t)


## 按键跳过。起步那 `SKIP_GRACE` 秒不认 —— 点开「新手引导」的那一下会一路漏到这里来。
## **本节点排在 `Main` 的最后一个子节点**，`_unhandled_input` 由后往前propagate ⇒ 它先收到并吃掉，
## 底下的主菜单不会跟着把某一项敲出去
func _unhandled_input(event: InputEvent) -> void:
	if not _running or _t < SKIP_GRACE:
		return
	var key_down: bool = event is InputEventKey and event.is_pressed() and not event.is_echo()
	var click: bool = event is InputEventMouseButton and event.is_pressed()
	if not (key_down or click):
		return
	get_viewport().set_input_as_handled()
	skip()


## 点任意处跳过。**走 `gui_input` 而不是 `_unhandled_input`**：`_root` 是一整块
## `MOUSE_FILTER_STOP` 的 `Control`，演出期间它必须把鼠标事件全吃下来 ——
## 底下的主菜单还在（只是被幕布盖着），它那几项是 `Control.gui_input` 接的鼠标，
## 比 `_unhandled_input` 先收到；不挡的话玩家在开场里随手一点就把「开始对局」点开了
func _on_root_input(event: InputEvent) -> void:
	if not _running or _t < SKIP_GRACE:
		return
	if not (event is InputEventMouseButton and event.is_pressed()):
		return
	_root.accept_event()
	skip()


func skip() -> void:
	if not _running:
		return
	seek(duration())   ## 定格在末帧：`main.gd` 要等第一关装好才淡掉这一层，停在半路上难看
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	_running = false
	finished.emit()


## 整段淡掉（`main.gd` 在第一关的章节提示立起来之后调）。淡的是 `_root` 这个 `Control` ——
## `CanvasLayer` 不吃父节点的 modulate，没有它就只能一个个子节点去淡
func fade_out(seconds: float) -> void:
	if _root == null:
		return
	if seconds <= 0.0:
		_root.modulate.a = 0.0
		return
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, seconds)
	await tw.finished


# ── 搭台 ──────────────────────────────────────────────────────────────

func _build() -> void:
	_layer = get_node_or_null(^"Layer") as CanvasLayer
	_root = get_node_or_null(^"Layer/Root") as Control
	if _root == null:
		push_error("开场动画：场景里缺 Layer/Root（整段的淡出把手）")
		return
	## 整块吃鼠标：底下的主菜单还活着（只是被幕布盖着），它那几项是 `Control.gui_input` 接的，
	## 比 `_unhandled_input` 先收到 —— 不挡的话玩家在开场里随手一点就把「开始对局」点开了
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.gui_input.connect(_on_root_input)
	var sky := ColorRect.new()
	sky.name = "Sky"
	sky.color = SKY
	sky.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.z_index = Z_SKY   ## 棋盘格子的 z 是像素 y（可负），幕布要压到它们**全部**下面
	_root.add_child(sky)

	_stage = Node2D.new()
	_stage.name = "Stage"
	_root.add_child(_stage)
	_board = BOARD_SCENE.instantiate()
	_stage.add_child(_board)
	_board.modulate.a = 0.0   ## 第一拍只有文字，棋盘等 `board_in` 才浮现
	_cells = Node2D.new()
	_cells.name = "Cells"
	_stage.add_child(_cells)
	_falls = Node2D.new()
	_falls.name = "Falls"
	_stage.add_child(_falls)
	_attack = ATTACK_FX.new()
	_attack.name = "Attack"
	_attack.z_index = Z_FX
	_stage.add_child(_attack)
	_fx = Painter.new()
	_fx.name = "Fx"
	_fx.z_index = Z_FX
	_fx.paint = _paint_fx
	_stage.add_child(_fx)

	_screen = Control.new()
	_screen.name = "Screen"
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen.z_index = Z_SCREEN
	_root.add_child(_screen)
	_build_world()
	_build_text()
	_look(_menu_focus(), CWView.MENU_ANCHOR, CWView.MENU_ZOOM)


## 首页那两行字。副标题拆成三个词各一个 `Label`（IMMUNE / VS / CANCER 要各走各的），
## 但摆在一起**逐像素等于**首页那一个 Label：位置按前缀宽度现算，字体 / 字号 / 字距 / 颜色照抄。
func _build_text() -> void:
	var sub_font := FontVariation.new()
	sub_font.base_font = PIXEL_FONT
	sub_font.spacing_glyph = SUB_SPACING
	var logo: Dictionary = _args("logo")
	var words: Array = logo.get("sub", ["IMMUNE", "VS", "CANCER"])
	var prefix := ""
	for w in words:
		var lb := Label.new()
		lb.text = str(w)
		lb.add_theme_font_override("font", sub_font)
		lb.add_theme_font_size_override("font_size", SUB_SIZE)
		lb.add_theme_color_override("font_color", SUB_INK)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lb.position = SUB_AT + Vector2(sub_font.get_string_size(
			prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, SUB_SIZE).x, 0)
		lb.pivot_offset = sub_font.get_string_size(
			str(w), HORIZONTAL_ALIGNMENT_LEFT, -1, SUB_SIZE) / 2.0
		_screen.add_child(lb)
		_words[str(w)] = lb
		_word_home[str(w)] = lb.position
		prefix += str(w) + " "
	## 大标题三层（影 / 辉 / 正），同首页 Logo 那一摞 ——
	## 那边是五层，中间两圈更淡的辉光这里省掉：开场里它只出现两秒，叠到第三层看不出差别
	for spec in [{"ink": LOGO_SHADOW, "dy": 8.0, "outline": 0},
			{"ink": Color(1, 1, 1, 0), "dy": 0.0, "outline": 8},
			{"ink": LOGO_INK, "dy": 0.0, "outline": 0}]:
		var layer: Dictionary = spec
		var ink: Color = layer["ink"]
		var lb := Label.new()
		lb.text = str(logo.get("title", "CELL WAR"))
		lb.add_theme_font_override("font", LOGO_FONT)
		lb.add_theme_font_size_override("font_size", LOGO_SIZE)
		lb.add_theme_color_override("font_color", ink)
		if int(layer["outline"]) > 0:
			lb.add_theme_color_override("font_outline_color", LOGO_GLOW)
			lb.add_theme_constant_override("outline_size", int(layer["outline"]))
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lb.position = LOGO_AT + Vector2(0, float(layer["dy"]))
		_screen.add_child(lb)
		_title.append(lb)
	_skip_hint = Label.new()
	_skip_hint.text = SKIP_HINT
	_skip_hint.add_theme_font_override("font", PIXEL_FONT)
	_skip_hint.add_theme_font_size_override("font_size", 10)
	_skip_hint.add_theme_color_override("font_color", Color(0.80, 0.88, 0.91, 0.55))
	_skip_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skip_hint.position = CWView.screen_size() - Vector2(104.0, 30.0)   ## 离屏幕右下角留一指宽
	_screen.add_child(_skip_hint)


## 盘面：右半边翻成癌组织、两只细胞各站一格。**全是画的** —— 这里没有世界、没有席位。
## 「右半边」按**像素横坐标**切而不是按轴坐标：轴坐标的 q 是斜着走的，切出来不是一条竖界
func _build_world() -> void:
	var b: Dictionary = _cut.get("board", {})
	_immune_at = _axial(str(b.get("immune_at", "-1,-1")))
	_cancer_at = _axial(str(b.get("cancer_at", "2,-1")))
	var lo := INF
	var hi := -INF
	var edge: float = _board.tile_center(_axial(str(b.get("cancer_from", "1,-1")))).x - 1.0
	for c: Vector2i in CWData.all_coords():
		var x: float = _board.tile_center(c).x
		if x < edge:
			_tissue[c] = CWData.Tissue.HEALTHY
			continue
		_tissue[c] = CWData.Tissue.CANCER
		## 逐格揭示的归一化只按**癌区自己**的横跨算，不按整张棋盘 ——
		## 按整张算的话前半段时间全花在左边那片健康组织上，红色要到最后一刻才开始铺
		lo = minf(lo, x)
		hi = maxf(hi, x)
	_span = Vector2(lo, hi)
	_immune = _make_cell(str(b.get("immune_type", "ImmuneBasic")))
	_cancer = _make_cell(str(b.get("cancer_type", "Osteosarcoma")))


func _make_cell(kind: String) -> Sprite2D:
	var s := Sprite2D.new()
	var tex: Texture2D = CELL_ART.get(kind, CELL_ART["ImmuneBasic"])
	s.texture = tex
	s.hframes = BREATH_FRAMES
	s.offset = Vector2(0, -tex.get_height() / 2.0)   ## 锚点从贴图中心挪到脚底中心（同主菜单的装饰细胞）
	s.modulate.a = 0.0
	_cells.add_child(s)
	return s


## 跌落时刻的随机（PRD:81 的「0~1 秒」）。**本层自己的 rng**，附 C 第 5 条：
## 碰内核 rng 就会让教程那几关的预设骰子带子整条错位。开场这里连内核都没有，一滴也不许沾
func _roll_falls() -> void:
	var a: Dictionary = _args("fall")
	var lo: float = float(a.get("min", 0.0))
	var hi: float = float(a.get("max", 1.0))
	_fall_delay.clear()
	for c: Vector2i in CWData.all_coords():
		_fall_delay[c] = _rng.randf_range(lo, hi)


## 净化 / 跌落这两笔「已经发生过」的账清掉（重播、往回跳都要）
func _reset_fx() -> void:
	_purify_at.clear()
	_struck = false
	for c in _hidden:
		(_hidden[c] as Node).queue_free()
	_hidden.clear()
	_hidden_n = -1
	if _board != null:
		_board.set_active_tiles(CWData.all_coords(), 0.0)


# ── 时间轴 ────────────────────────────────────────────────────────────

func _cue(kind: String) -> Dictionary:
	return _cues.get(kind, {})


func _at(kind: String) -> float:
	return float(_cue(kind).get("t", 0.0))


func _args(kind: String) -> Dictionary:
	return _cue(kind).get("args", {})


## 这一刻该画成什么样。**t 先量化到 1/12 秒**（像素纪律②）：整段演出走格，不做逐帧平滑。
## 次序有讲究：先让细胞与同心圆把这一帧的「净化」登记上，再让棋盘按账本铺贴图 —— 反过来会慢一帧
func _apply(t: float) -> void:
	var q := floorf(maxf(t, 0.0) * PIX_FPS) / PIX_FPS
	_apply_text(q)
	_apply_cells(q)
	_apply_falls(q)
	_apply_board(q)
	_apply_camera(q)
	_fx.queue_redraw()


## ① 大标题与三个词（PRD:63）＋ 文字变细胞的前半段（PRD:65）
func _apply_text(q: float) -> void:
	var a: Dictionary = _args("words_to_cells")
	var dur: float = maxf(float(a.get("dur", 1.5)), 0.001)
	var swap: float = clampf(float(a.get("swap_at", 0.7)), 0.01, 1.0)
	var fade_in := CWPix.phase(q, _at("logo"),
		maxf(float(_args("logo").get("fade", 0.75)), 0.001))
	var leave := CWPix.phase(q, _at("words_to_cells"), dur * swap)
	for lb in _title:
		(lb as Label).modulate.a = _steps(fade_in * (1.0 - leave))
	for w in _words:
		var lb: Label = _words[w]
		lb.modulate.a = _steps(fade_in * (1.0 - leave))
		var dest: Variant = _word_dest(str(w))
		if dest == null:
			continue
		var e := leave * leave * (3.0 - 2.0 * leave)      ## 缓入缓出：起步慢、到位稳
		lb.position = (_word_home[w] as Vector2).lerp(dest as Vector2, e).round()
		lb.scale = Vector2.ONE.lerp(Vector2(0.35, 0.35), e)
	if _skip_hint != null:
		_skip_hint.modulate.a = _steps(CWPix.phase(q, SKIP_HINT_AT, 0.5) * 0.9)


## 这个词要飞到哪儿（屏幕坐标，落在自己那只细胞的胞体中心上）；不是 IMMUNE / CANCER 就返回 null
func _word_dest(w: String) -> Variant:
	match w:
		"IMMUNE": return _to_screen(_body_center(_immune_at, _immune))
		"CANCER": return _to_screen(_body_center(_cancer_at, _cancer))
	return null


## ② 棋盘浮现（PRD:67）＋ 右侧癌组织（PRD:69）＋ 反向侵蚀落到贴图上（PRD:79）
func _apply_board(q: float) -> void:
	_board.modulate.a = _steps(CWPix.phase(q, _at("board_in"),
		maxf(float(_args("board_in").get("dur", 1.5)), 0.001)))
	var t_field := _at("cancer_field")
	var field_dur: float = maxf(float(_args("cancer_field").get("dur", 0.75)), 0.001)
	var ero: Dictionary = _args("erosion_rev")
	var frame: float = maxf(float(ero.get("frame", 0.16)), 0.001)
	var frames: int = maxi(int(ero.get("frames", 2)), 1)
	for c: Vector2i in CWData.all_coords():
		var tex: Texture2D = _rev_erosion_frame(c, q, frame, frames)
		if tex != null:
			_board.set_tile_tex(c, tex)
			continue
		var tissue: int = CWData.Tissue.HEALTHY if _is_healthy(c, q, frame, frames) \
			else CWData.Tissue.CANCER
		## 右侧那片癌组织由左往右一格格翻出来（同 `CWMatch._play_bloom`：排个序再逐格揭，别一次全出）
		if tissue == CWData.Tissue.CANCER:
			var k: float = (_board.tile_center(c).x - _span.x) / maxf(_span.y - _span.x, 1.0)
			if q < t_field + k * field_dur:
				tissue = CWData.Tissue.HEALTHY
		_board.set_tissue(c, tissue, CWData.special_of(c))


## 这一格此刻在不在反向侵蚀的两帧里。正向（健康→癌）是 p33 → p66，
## **倒着播**就是 p66 → p33 → 健康 = 癌退回去；方向取「癌残在哪一侧」= 背着同心圆心那一侧
func _rev_erosion_frame(c: Vector2i, q: float, frame: float, frames: int) -> Texture2D:
	if not _purify_at.has(c):
		return null
	var i := int((q - float(_purify_at[c])) / frame)
	if i < 0 or i >= frames:
		return null
	var dir: int = CWData.dir_toward(_cancer_at, c)   ## 从环心往外看，这一格的外侧
	if dir < 0 or dir >= CWErosionFx.ART.size():
		return null
	return CWErosionFx.ART[dir][frames - 1 - i]


## 这一格此刻算健康吗：本来就健康，或者净化那两帧已经走完
func _is_healthy(c: Vector2i, q: float, frame: float, frames: int) -> bool:
	if _tissue.get(c, CWData.Tissue.HEALTHY) == CWData.Tissue.HEALTHY:
		return true
	return _purify_at.has(c) and q >= float(_purify_at[c]) + frame * float(frames)


## ③ 两只细胞：站位（PRD:71）→ 行进与途中净化（PRD:73）→ 攻击（PRD:75）
func _apply_cells(q: float) -> void:
	var wa: Dictionary = _args("words_to_cells")
	var swap_t := _at("words_to_cells") + float(wa.get("dur", 1.5)) \
		* clampf(float(wa.get("swap_at", 0.7)), 0.01, 1.0)
	## 站定那一拍（PRD:71）就是「细胞完全成形」的时刻：淡入从交接点起、到 `stand` 止
	var a_cell := _steps(CWPix.phase(q, swap_t, maxf(_at("stand") - swap_t, 0.001)))
	_immune.modulate.a = a_cell
	_cancer.modulate.a = a_cell
	var breath := int(q * BREATH_FPS) % BREATH_FRAMES
	_immune.frame = breath
	_cancer.frame = (breath + 3) % BREATH_FRAMES      ## 错开半拍，别让两只同频起伏
	_cancer.position = _foot(_cancer_at)
	_cancer.z_index = _cell_z(_cancer_at)

	## 行进（PRD:73）：一格一跳；落到癌性格就当场触发【净化】（= 那一格开始反向侵蚀）
	var t_march := _at("march")
	var hop: float = maxf(float(_args("march").get("hop", 0.6)), 0.001)
	var path: Array = _args("march").get("path", [])
	var from := _axial(str(_cut.get("board", {}).get("immune_at", "-1,-1")))
	_immune_at = from
	var foot := _foot(from)
	for i in path.size():
		var to := _axial(str(path[i]))
		var p := CWPix.phase(q, t_march + float(i) * hop, hop)
		if p <= 0.0:
			break
		foot = _foot(from).lerp(_foot(to), p) - Vector2(0, sin(p * PI) * 5.0)   ## 小跳一下
		if p >= 1.0:
			_immune_at = to
			if _tissue[to] == CWData.Tissue.CANCER and not _purify_at.has(to):
				_purify_at[to] = t_march + float(i + 1) * hop
		from = to
	_immune.position = foot.round()
	_immune.z_index = _cell_z(_immune_at)

	## 攻击（PRD:75）：复用对局那支攻击演出 —— `target_alive:false` ⇒ 癌细胞被打飞并淡出，
	## `entered:false` ⇒ 免疫收势弹回原格子。这两拍正是 PRD 那一行的后半句，不必另写一支
	if not _struck and q >= _at("strike"):
		_struck = true
		_attack.play({
			"cid": 0, "target_id": 1, "hit": bool(_args("strike").get("hit", true)),
			"entered": false, "target_alive": false, "attacker_alive": true,
		}, _foot(_immune_at), _foot(_cancer_at), _immune.texture, _cancer.texture)
	## 演出期间两只真身让位（同 `CWMatch._sync_cells` 撞上 `CWAttackFx.owns` 的做法）；
	## 打飞之后癌细胞就不回来了
	var owned: bool = _struck and bool(_attack.owns(0))
	_immune.visible = not owned
	_cancer.visible = not owned and not _struck


## ④ 同心圆净化（PRD:77）＋ 组织跌落（PRD:81）＋ 两格不跌（PRD:83）
func _apply_falls(q: float) -> void:
	var t_ring := _at("rings")
	if q < t_ring:
		return
	var step: float = maxf(float(_args("rings").get("step", 0.18)), 0.001)
	var keep := {}
	for at in _args("keep").get("tiles", []):
		keep[_axial(str(at))] = true
	var drop: float = maxf(float(_args("fall").get("drop", 0.55)), 0.001)
	var dy: float = float(_args("fall").get("dy", 96.0))
	for c: Vector2i in CWData.all_coords():
		var pass_at: float = t_ring + float(CWData.hex_dist(c, _cancer_at)) * step
		if q < pass_at:
			continue
		## 环扫到：癌性格当场开始反向侵蚀（PRD:77 / 79）
		if _tissue[c] == CWData.Tissue.CANCER and not _purify_at.has(c):
			_purify_at[c] = pass_at
		if keep.has(c):
			continue                     ## 免疫脚下那一格与它右边那一格不跌（PRD:83）
		var fall_at: float = pass_at + float(_fall_delay.get(c, 0.0))
		if q < fall_at:
			continue
		var p := CWPix.phase(q, fall_at, drop)
		var s: Sprite2D = _fall_node(c)
		s.position = _tile_pos(c) + Vector2(0, p * p * dy)   ## 加速下坠
		s.modulate.a = _steps(1.0 - p)
	_sync_hidden()


## 这一格的跌落代画节点（第一次用到才建）。建的同一刻把棋盘上那一格藏起来 ——
## 两者位置、贴图一致，换手看不出来
func _fall_node(c: Vector2i) -> Sprite2D:
	if _hidden.has(c):
		return _hidden[c]
	var s := Sprite2D.new()
	s.texture = _tile_tex(c)
	s.position = _tile_pos(c)
	s.z_index = int(_tile_pos(c).y)     ## 同 board.gd `new_tissue` 的画家算法
	_falls.add_child(s)
	_hidden[c] = s
	return s


## 藏格集合变了才去动棋盘的活跃集（`set_active_tiles` 要扫 127 格，别每帧无脑调）
func _sync_hidden() -> void:
	if _hidden.size() == _hidden_n:
		return
	_hidden_n = _hidden.size()
	var shown: Array = []
	for c: Vector2i in CWData.all_coords():
		if not _hidden.has(c):
			shown.append(c)
	_board.set_active_tiles(shown, 0.0)


## ⑤ 镜头（PRD:85）：跌落途中逐渐放大，把免疫细胞调到屏幕中央。
## zoom 走几何插值、取景插「看点 / 锚点」—— 与 `CWView.blend` 同一套理由（线性插 position 走得不匀）
func _apply_camera(q: float) -> void:
	var a: Dictionary = _args("zoom")
	var p := CWPix.phase(q, _at("zoom"), maxf(float(a.get("dur", 3.5)), 0.001))
	var to_zoom: float = float(a.get("zoom", 4.6))
	var anchor: Array = a.get("anchor", [480.0, 270.0])
	var e := p * p * (3.0 - 2.0 * p)
	_look(_menu_focus().lerp(_body_center(_immune_at, _immune), e),
		CWView.MENU_ANCHOR.lerp(Vector2(float(anchor[0]), float(anchor[1])), e),
		CWView.MENU_ZOOM * pow(to_zoom / CWView.MENU_ZOOM, e))


# ── 相机与几何 ────────────────────────────────────────────────────────

## 本场景自己的相机：把棋盘上的 `focus` 摆到屏幕的 `anchor`，再按 `zoom` 放大。
## 做在 `Stage` 的变换上而不是新起一台 `Camera2D` —— 工程里只有一台相机（`CWView` 的头注），
## 开场要是把它抢过来，主菜单和对局的机位就跟着一起动了
func _look(focus: Vector2, anchor: Vector2, zoom: float) -> void:
	_stage.scale = Vector2(zoom, zoom)
	_stage.position = (anchor - focus * zoom).round()


## 开场的起手机位：首页那个看点（= 中央格贴图中心 + `MENU_LOOK_AT`）再往右挪 `look_dx` 棋盘像素。
## zoom 仍是首页那个 3.2、只平移不缩放 —— 首页看的是棋盘左中，而开场的戏在右侧癌区，
## 不挪的话两只细胞贴着屏幕右缘演（实测癌细胞落在 x = 895 / 960）
func _menu_focus() -> Vector2:
	return CWView.board_origin(_board) + CWView.MENU_LOOK_AT \
		+ Vector2(float(_args("board_in").get("look_dx", 0.0)), 0.0)


func _to_screen(p: Vector2) -> Vector2:
	return _stage.position + p * _stage.scale.x


## 站在这一格上的细胞，胞体中心在哪（文字要飞到这里，镜头最后也对准这里）
func _body_center(c: Vector2i, s: Sprite2D) -> Vector2:
	var h: float = 34.0
	if s != null and s.texture != null:
		h = float(s.texture.get_height())
	return _foot(c) - Vector2(0, h / 2.0)


func _foot(c: Vector2i) -> Vector2:
	return _board.tile_center(c) + Vector2(0, CELL_FOOT_DY)


func _tile_pos(c: Vector2i) -> Vector2:
	return _board.tile_center(c) + Vector2(0, _board.TOP_FACE_DY)


func _tile_tex(c: Vector2i) -> Texture2D:
	var i: int = 0 if _purify_at.has(c) or _tissue[c] == CWData.Tissue.HEALTHY else 1
	return _board.TISSUE_TEX[CWData.special_of(c)][i]


func _cell_z(c: Vector2i) -> int:
	return int(_tile_pos(c).y) + 1   ## 压在自己脚下那一格上面（同主菜单的装饰细胞）


static func _axial(s: String) -> Vector2i:
	var parts := s.split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## 透明度只取几档（像素纪律③）：连续的 alpha 在像素画上会磨出灰边
static func _steps(a: float) -> float:
	return roundf(clampf(a, 0.0, 1.0) * 6.0) / 6.0


# ── 同心圆（PRD:77）与交接碎粒（PRD:65）──────────────────────────────

## 棋盘是压扁的六边形网格（横距 36 / 纵距 20），所以「圆」要画成同样压扁的椭圆，
## 否则环扫到的格和画面上的环对不上（压扁比同 `board.hex_at` 的 squash）
func _squash() -> float:
	return float(_board.distance_y) / (float(_board.distance_x) * sqrt(3.0) / 2.0)


func _paint_fx(ci: CanvasItem) -> void:
	var q := floorf(maxf(_t, 0.0) * PIX_FPS) / PIX_FPS
	_paint_swap(ci, q)
	_paint_rings(ci, q)


## 词变细胞那一下：落点炸一小把碎粒（PRD:65 的「变为」总要有个交接，光靠淡入淡出看不出「变」）
func _paint_swap(ci: CanvasItem, q: float) -> void:
	var a: Dictionary = _args("words_to_cells")
	var dur: float = maxf(float(a.get("dur", 1.5)), 0.001)
	var swap: float = clampf(float(a.get("swap_at", 0.7)), 0.01, 1.0)
	var p := CWPix.phase(q, _at("words_to_cells") + dur * swap, maxf(dur * (1.0 - swap), 0.001))
	if p <= 0.0 or p >= 1.0:
		return
	var n: int = int(a.get("burst", 18))
	var cool := SUB_INK
	cool.a = 1.0 - p
	CWPix.burst(ci, _body_center(_immune_at, _immune), p, cool, n, 22.0)
	var warm := Color("ffb03a")
	warm.a = 1.0 - p
	CWPix.burst(ci, _body_center(_cancer_at, _cancer), p, warm, n, 22.0)


## 同心圆本体：一圈一圈往外推的椭圆环。`width` 是「同时有几秒的圈还留在画面上」——
## 只画最新那一圈看不出「同心」，所以旧圈留一会儿、越旧越淡
func _paint_rings(ci: CanvasItem, q: float) -> void:
	var a: Dictionary = _args("rings")
	var t_ring := _at("rings")
	if q < t_ring:
		return
	var step: float = maxf(float(a.get("step", 0.18)), 0.001)
	var width: float = maxf(float(a.get("width", 0.6)), 0.001)
	var ink := Color(str(a.get("ink", "b7ecff")))
	var c := _tile_pos(_cancer_at)
	var lead := (q - t_ring) / step                     ## 此刻环推到第几格
	var squash := _squash()
	var k := 0
	while float(k) <= lead:
		var age := (lead - float(k)) * step
		if age <= width:
			ink.a = _steps(1.0 - age / width)
			CWPix.ring(ci, c, float(k) * float(_board.distance_x), ink, squash)
		k += 1


## 只为了有个 `_draw` 的小节点：环要画在棋盘的坐标系里（跟着 `Stage` 一起缩放），
## 而本脚本挂在场景根上、根本不在那个坐标系里。同 `board.gd` 的内部类 `TurnArrow`
class Painter extends Node2D:
	var paint := Callable()

	func _draw() -> void:
		if paint.is_valid():
			paint.call(self)
