## guide.gd —— 新手引导面板 + 引导流程（教程局专用）
##
## 这是**旁观式教练** + **轻量导演**：引擎照常跑、CWGuideBridge 照常把人类询问
## 交给正常界面；引导只做三件事：
##   ① 挂一块一步步的说明（可继续 / 跳过引导 / 打开知识之书）——**沉浸式浮层**：
##      不装窗口框，文字直接浮在棋盘上方居中，行动提示带一圈慢闪烁的白色柔光；
##   ② 轮到你做决定时，给出「现在做什么」的实时提示（由 CWGuideBridge 喂进来）；
##   ③ 按步骤把棋盘 / 特殊组织 / 行动栏等区域提亮，帮新手把视线放到正确地方
##      （本类只报当前步骤的 flag，描边由 CWGuideSpotlight 画）；
##   ④ 「继续」在落子 / 结束回合 / 抽卡这几步能替玩家做（Kevin 2026-09-05 拍板：
##      不自动演示，玩家要么亲手做、要么点「继续」让我做，然后剧本翻到下一步）。
##
## 设计上刻意不做硬锁步：教程里玩家做错了也不惩罚，提示永远只是建议。
## 这样引擎 / 询问桥一行规则都不用改，教程坏不了对局。
##
## 本类也管引导进度（已完成哪几关 / 当前进行到第几关第几步），
## 通过 CWGuideProgress 落盘 —— 主菜单入口据此显示完成状态。
class_name CWGuide
extends Control

## 沉浸式浮层（Kevin 2026-09-10 拍板：取消左上角窗口面板，原 470×260 描边框整个去掉）：
## 说明文字直接浮在棋盘上方居中（棋盘带 x = [LEFT_STRIP+GUTTER*2, 960-PANEL_WIDTH-GUTTER]，
## 与机位锚点 388 同心），行动提示一行带**慢闪烁的白色柔光**，像一句浮进来的画外音。
## ZONE 只是布局边界，没有可见框；白雾 / 柔光是引导语音层的专属手段（DESIGN.md 已登记），
## 其余界面仍守「无阴影、无装饰动效」。
const ZONE := Rect2(88, 16, 600, 200)
const PAD := 16
## **操作放屏幕下方**（Kevin 2026-09-19，看 S3 第一关真机截图拍的）：
## 说明（眉行 / 标题 / 正文）留在上部 `ZONE`，**行动提示 + 三个按钮整组挪到左下**这一带 `ACT_ZONE`。
## 原因见 S3 截图：第一关正文五行，行框 16px 一路铺到 y=138，而行动提示原本钉死在 y=92 —— 直接压在正文上。
## 只把行距拉开治不了本：正文行数是剧本的自由量，说明与操作本来就该分开两处。
##
## `ACT_ZONE` 的四条边是**算出来的**，不是随手摆的：
##   下缘 464 —— 行动栏的目标选择态是 `CWActionBar.PROMPT_RECT`，横跨 x 12..685 / y 466..518，
##                压上去就和引擎自己的「选择要迁移到的组织」叠字。留 2px。
##   右缘 520 —— Kevin 指的空位（右下 x 525..685 是技能栏形态的行动栏）。
##   上缘 356 —— 出牌列 `CWFeed.RECT` 到 y=348 为止。
##   ⚠ 手牌抽屉抬起时上沿是 y=428（`CWHand`，只在悬停时抬），会和尾巴 / 按钮行叠 ——
##     第一章 `ui_layers.hand = false`，等开手牌的关（S8）再定这一处的让位。
const ACT_ZONE := Rect2(8, 356, 512, 108)
## 上部（说明）的纵向节奏：眉行 10px 行框 14、标题 20px 行框 28+2、正文 10px 每行 16。
## 正文行数不限 —— 它已经不会撞上任何东西了。
const ROW_META := 4.0
const ROW_TITLE := 22.0
const ROW_BODY := 58.0
const BODY_LINE := 16.0
## 下部（操作）的纵向节奏，**局部坐标**（相对 `ACT_ZONE`）：行动提示 20px 两行 60、
## 代做尾巴 10px 行框 14、按钮行 20px 行框 28
const ROW_HINT := 0.0
const ROW_TAIL := 64.0
const ROW_BTN := 80.0
## 白色柔光慢闪烁：3.2s 一个亮暗周期（比提亮层的 1.2s 脉冲慢一截，读起来是「呼吸」不是「报警」），
## 亮暗振幅给在纹理 alpha 之外靠 modulate 调
const HALO_PERIOD := 3.2
const HALO_ALPHA_LO := 0.35
const HALO_ALPHA_HI := 1.0

## 关卡分隔：当前步骤每跨进新一章，就把「引导完成到这一关」写进进度。
## 玩家跳过时，只有已经**按过完成**的章节会被标记（避免没看就全绿）。
var active := false
var auto_next := false
## 「继续」的代做钩子（CWMatch 接线到 CWGuideBridge）：demo_ready 回答「此刻按继续会不会替玩家做这一步」，
## demo 真去做（返回做没做）。无效的 Callable = 没接（无头测试 / 面板单独建）—— 继续就只翻页
var demo := Callable()
var demo_ready := Callable()
## 章节切换钩子（CWMatch 接导演后设）：跨入新章节时回调一次，参数 = 新章节号。
## 教程每一关是导演装配的独立局面，章节切换意味着**换一局**——面板只管翻页，
## 换局由对局侧执行；未设置（无头 / 老测试）时行为与原先完全一致。
var on_chapter_done := Callable()
## 「此刻该提示什么」：翻页时重新问桥一遍，提示跟着正在教的那一步走（教结束回合就说结束回合，不再停在迁移那句）
var hint_now := Callable()
## 代做尾巴：代做可用时贴在按钮行上方的小字注解。%s = 按钮此刻的字（继续 / 下一章 / 完成引导），
## 关卡最后一步按钮写的是「下一章」，尾巴不能还说「继续」（Kevin 2026-09-05 截图报的）
const OFFER_TAIL := "（点「%s」我替你做这一步）"
## 步骤的完成判据。**preload 而不是 class_name**：补丁里新增的 class_name 认不出来，
## 而引导是天天在改的东西 —— 判据表要能跟着热更走（详见那个文件的头注）
const WATCH := preload("res://scripts/ui/guide_watch.gd")

var _match = null
var _chapter := 0
var _step := 0
var _hint_text := ""
var _highlight := ""
var _mistakes := 0
var _tutorial_done := false   ## 引导全部看完了（由第 5 关最后一步置位）

var _title: Label
var _hint: Label
var _hint_tail: Label   ## 「点『继续』我替你做」：贴按钮行上方的小字注解，不再和提示挤一行
var _body: Array[Label] = []
var _btn: Label
var _skip: Label
var _codex_btn: Label
var _content: Control
var _act: Control        ## 下部「操作」那一组（行动提示 / 代做尾巴 / 三个按钮），钉在 ACT_ZONE
var _halo: TextureRect   ## 行动提示底下的白色柔光（慢闪烁的发光体，无可见框）
var _btn_glow: TextureRect  ## 按钮行底下那一小片柔光
var _fog: TextureRect    ## 整个浮层底下的白雾渐变：把字从花花的棋盘上托出来
var _pulse_t := 0.0
var _chapter_label: Label
## 剧本翻到新的一步（`_render` 走完）时回调一次。`CWMatch` 接它去装决策闸 / UI 层 / 浮现 ——
## 闸的正牌时机是 `step_end`（方案 §1.10），但剧本自己翻页时也得当场换闸，
## 否则挂在旧闸上的那一问永远醒不来
var on_step_changed := Callable()


func setup(match) -> void:
	_match = match
	_build()
	active = true
	_chapter = 0
	_step = 0
	auto_next = false
	_hint_text = ""
	_tutorial_done = false
	_read_progress()
	_render()


## 中途玩家切换章节/继续时从保存读进度（只影响默认起始章节，不强制跳关）。
func _read_progress() -> void:
	var prog := CWGuideProgress.read()
	## 只恢复「已完成章节」的下一个；没完成过就从第 0 关开始
	if prog["done"] > 0:
		_chapter = clamp(prog["done"], 0, CWGuideData.CHAPTER_COUNT - 1)


func _build() -> void:
	position = ZONE.position
	size = ZONE.size
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 空白处点击要漏给棋盘

	_fog = _soft_rect(_soft_tex(GradientTexture2D.FILL_LINEAR,
		Color(Color.WHITE, 0.12)), Vector2(-40, -8), ZONE.size + Vector2(80, 32))
	add_child(_fog)

	_chapter_label = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_chapter_label.position = Vector2(PAD, ROW_META)
	_chapter_label.size = Vector2(ZONE.size.x - PAD * 2, 14)
	_chapter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_chapter_label)

	_title = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_title.position = Vector2(PAD, ROW_TITLE)
	_title.size = Vector2(ZONE.size.x - PAD * 2, 30)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_title)

	_content = Control.new()
	_content.position = Vector2(PAD, ROW_BODY)
	_content.size = Vector2(ZONE.size.x - PAD * 2, 32)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content)

	## ---- 下部「操作」那一组（Kevin 2026-09-19：操作放屏幕下方）----
	## 一个容器装着，位置一次算清：`ACT_ZONE` 是屏幕坐标，容器挂在浮层下面，所以要减掉浮层自己的原点。
	## `Control` 默认不裁剪子节点，所以容器坐标为负 / 超出父矩形都照常画、也照常收点击（`_fog` 早就是这么干的）
	_act = Control.new()
	_act.position = ACT_ZONE.position - ZONE.position
	_act.size = ACT_ZONE.size
	_act.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_act)

	## 按钮行 / 代做尾巴的小片柔光：这一行离棋盘最近、底下常是亮格，白雾带到底部已经衰减，
	## 再垫一小片把字托出来（同是软渐变，不出现可见边界）
	_btn_glow = _soft_rect(_soft_tex(GradientTexture2D.FILL_RADIAL,
		Color(Color.WHITE, 0.16)), Vector2(56, ROW_TAIL - 9), Vector2(400, 60))
	_act.add_child(_btn_glow)

	_halo = _soft_rect(_soft_tex(GradientTexture2D.FILL_RADIAL,
		Color(Color.WHITE, 0.4)), Vector2(-24, ROW_HINT + 30 - 45), Vector2(560, 90))
	_act.add_child(_halo)

	_hint = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_hint.position = Vector2(PAD, ROW_HINT)
	_hint.size = Vector2(ACT_ZONE.size.x - PAD * 2, 60)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.clip_text = true
	_act.add_child(_hint)

	_hint_tail = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT)
	_hint_tail.position = Vector2(PAD, ROW_TAIL)
	_hint_tail.size = Vector2(ACT_ZONE.size.x - PAD * 2, 14)
	_hint_tail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_act.add_child(_hint_tail)

	_btn = _primary("继续")
	_act.add_child(_btn)
	_skip = _clicky("跳过引导", func() -> void: dismiss())
	_act.add_child(_skip)
	_codex_btn = _clicky("知识之书", func() -> void: _open_codex())
	_act.add_child(_codex_btn)   ## 三个按钮都只在这里挂一次（接入时发现这一个漏挂了）
	## 按钮行的横向位置在 _render 里按实测宽度居中（按钮字数会变：继续/下一章/完成引导）


## 一块软渐变矩形：白雾（横条）和柔光（椭圆）共用。全局默认最近邻过滤（像素风），
## 渐变必须就地切成线性采样，不然会采出一圈圈硬带
func _soft_rect(tex: GradientTexture2D, at: Vector2, rect_size: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.position = at
	tr.size = rect_size
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


## 两端透明、中间最亮的软渐变。fill 决定形状：LINEAR = 横向雾带，RADIAL = 椭圆柔光
static func _soft_tex(fill: int, c: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(c, 0.0), c, Color(c, 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = fill
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0) if fill == GradientTexture2D.FILL_RADIAL else Vector2(0.5, 1.0)
	t.width = 64
	t.height = 64
	return t


func _process(delta: float) -> void:
	if _halo == null or not visible:
		return
	## 慢闪烁只动柔光的 modulate：白雾恒定，行动提示那一圈光慢慢呼吸
	_pulse_t += delta
	var k := 0.5 + 0.5 * sin(_pulse_t * TAU / HALO_PERIOD)
	_halo.modulate.a = lerpf(HALO_ALPHA_LO, HALO_ALPHA_HI, k)


## 主按钮（继续 / 下一章 / 完成引导）：浮层里唯一的主动作，用免疫青和两个暗色次级
## 文字按钮拉开层级（青 = 全游戏「可交互」的语义色），悬停提白
func _primary(text: String) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.mouse_entered.connect(func() -> void:
		label.add_theme_color_override("font_color", Color.WHITE))
	label.mouse_exited.connect(func() -> void:
		label.add_theme_color_override("font_color", CWStyle.IMMUNE))
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			_advance())
	return label


## 可点击的文字按钮：命中框贴着字、手型光标、左键回调。次级动作（跳过 / 知识之书）用常规档
## 的字（浮层直接压在棋盘上，再暗一档就读不清了），和主按钮的免疫青仍拉开层级；悬停提白
func _clicky(text: String, on_click: Callable,
		color: Color = CWStyle.TEXT, hovered: Color = Color.WHITE) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, color)
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.mouse_entered.connect(func() -> void:
		label.add_theme_color_override("font_color", hovered))
	label.mouse_exited.connect(func() -> void:
		label.add_theme_color_override("font_color", color))
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	return label


func _advance() -> void:
	## 正在教的这一步能代做（落子 / 结束回合 / 抽卡）且引擎正等着玩家 → 先替玩家做了，再按剧本翻页
	if demo.is_valid():
		demo.call()
	_turn_page()


## 只翻页、不做动作。状态推进（check_progress）专用：动作玩家已亲手完成，
## 再走 demo 等于替玩家多做一次他已经做过的事。
func _turn_page() -> void:
	var chapter_before := _chapter
	_step += 1
	while _chapter < CWGuideData.CHAPTER_COUNT and _step >= CWGuideData.steps(_chapter).size():
		## 这一章看完了：记到进度。
		if not CWGuideProgress.has_done(_chapter):
			CWGuideProgress.set_done(_chapter)
		_chapter += 1
		_step = 0
	if _chapter >= CWGuideData.CHAPTER_COUNT:
		if not _tutorial_done:
			_tutorial_done = true
			CWGuideProgress.set_all_done()
			## 全部看完：只收面板，不打断对局，玩家继续自由游玩这局
			active = false
			visible = false
		return
	auto_next = false
	if _chapter != chapter_before and on_chapter_done.is_valid():
		on_chapter_done.call(_chapter)   ## 跨章 = 换一局（导演装配新局面）
	_render()


## 剧本正文里的 `**着重**` 怎么落到屏幕上。
##
## **今天的正文是 `Label`，不是 `RichTextLabel`** —— `CWStyle.label()` 造的就是 `Label`，
## 而 `Label` 不认 BBCode，于是 S3 真机截图里「发现\*\*癌组织\*\*」的星号被**照字面画了出来**。
## 处置照「数据不改、渲染时剥」：剧本正本（`game/data/tutorial/*.json`）保留 Markdown 的着重标记
## —— 它是给写剧本的人看的，也是将来换 `RichTextLabel` 时唯一的信息源 —— 渲染这一层把它剥掉。
## 换成 `RichTextLabel` 那天，这一个函数改成 `**x**` → `[b]x[/b]` 就够，别处一个字不用动。
static func plain(text: String) -> String:
	return text.replace("**", "")


## 重置本关（常驻「重置」按钮，PRD:41）：**步游标归零**，章号不动。
## 局面那一半由 `CWMatch` 走 `CWTutorialStage.reload_world(关首那份 world)`
func reset_to_step0() -> void:
	_step = 0
	auto_next = false
	_hint_text = ""
	visible = true
	active = true
	_render()


## 换局 / 重装之后重新取一次判据基线（S3 回传第 8 条）。
##
## 跨关换局那一瞬间两关的免疫起点不是同一格，`watch: "moved"` 拿**上一关**的基线去比当场成立 ——
## 于是新关的第一步一出生就被判「做到了」，翻过去，还把上一关写进 `guide_progress.cfg`。
## 装闸的时候（`CWMatch._on_step` 的 `step_end`）顺手重取一次，基线就永远属于当前这一局
func rebase_watch() -> void:
	_watch_base = WATCH.snapshot(_mirror(), _human_pid())


## 跳到指定章节（引导目录用）。跳到哪一章顺便把它前面的章节都视为读过了 ——
## 玩家主动跳过前面的内容时，进度就跟着跳。
func goto_chapter(idx: int) -> void:
	idx = clampi(idx, 0, CWGuideData.CHAPTER_COUNT - 1)
	var chapter_before := _chapter
	for i in range(idx):
		if not CWGuideProgress.has_done(i):
			CWGuideProgress.set_done(i)
	_chapter = idx
	_step = 0
	auto_next = false
	if _chapter != chapter_before and on_chapter_done.is_valid():
		on_chapter_done.call(_chapter)   ## 目录跳章同样换局面
	_render()


## 关闭引导（不改变进度，只隐藏面板）
func dismiss() -> void:
	active = false
	visible = false


func open_codex_at_current() -> void:
	_open_codex()


func _open_codex() -> void:
	if _match == null or not is_instance_valid(_match):
		return
	## 通过一个信号/约定，让外部（CWMatch）打开知识之书到达对应章节。
	## 这里用最轻的约定：match 暴露一个 codex_focus()；没有就只提示。
	if _match.has_method("focus_codex_on_topic"):
		_match.focus_codex_on_topic(CWGuideData.CODEX_PAGE[_chapter])


## 由 CWGuideBridge 在轮到玩家时喂进来的一句「现在做什么」。
func set_hint(text: String) -> void:
	_hint_text = text
	_refresh_hint()


## 行动提示 = 桥喂来的一句「现在做什么」；代做尾巴单独贴在按钮行上方 —— 它解释的是按钮不是动作，
## 混在一起会稀释提示（Kevin 2026-09-10 重排）。步骤变了（_render）或提示变了（set_hint）都要重算：
## 同一句提示，翻到「第一步：落子」之前没有尾巴、翻到之后才有
func _refresh_hint() -> void:
	if _hint == null:
		return
	if hint_now.is_valid():
		var now: String = hint_now.call()
		if now != "":
			_hint_text = now
	var tail := ""
	if _hint_text != "" and _btn != null and demo_ready.is_valid() and demo_ready.call():
		tail = OFFER_TAIL % _btn.text
	_hint.text = _hint_text
	_hint.visible = _hint_text != ""   ## 还没喂到提示时收着，柔光也跟着灭，别悬一团没来由的光
	_halo.visible = _hint_text != ""
	_hint_tail.text = tail
	_hint_tail.visible = tail != ""


## 当前步骤想提亮哪个区域（棋盘/特殊组织/能量/…）。CWMatch 每帧读走喂给 CWGuideSpotlight。
func highlight_flag() -> String:
	var all := CWGuideData.steps(_chapter)
	if _step < 0 or _step >= all.size():
		return ""
	return str(all[_step].get("flag", ""))


## 当前章节与步骤号
func chapter() -> int:
	return _chapter


func step_no() -> int:
	return _step


## 当前教程辅助阶段；正式对局不创建 CWGuide，因此不会获得这些限制或提示。
func ui_stage() -> int:
	return CWGuideData.ui_stage(_chapter)


## 纠错只记录在教程面板；不会改引擎状态，也不会阻止玩家重新尝试。
func record_mistake() -> void:
	_mistakes += 1


func mistake_count() -> int:
	return _mistakes


## 第 16 关只读辅助；不执行动作、不改正式局面。
func graduation_assist() -> Dictionary:
	if _match == null or not is_instance_valid(_match) or _match.mirror == null:
		return {}
	if _chapter != CWGuideData.CHAPTER_COUNT - 1:
		return {}
	return CWGuideData.graduation_assist(_match.mirror)


## ---- 状态推进：带 watch 的步骤由真实局面判定完成 ----
## 判据本身在 `guide_watch.gd`（哨兵、快照、逐键判定都在那儿）
## 步骤成为当前的那一刻的局面快照（`_render` 里取）；判据全部拿它和此刻的比
var _watch_base := {}


## 每帧由 CWMatch._process 喂：当前步骤带 watch 且真实局面已满足 → 自动翻页（不代做）。
## 讲解型步骤（无 watch）不经过这里，仍只认「继续」。
##
## **换了行动回合就重新取基线**：计数类判据（attacked / drew）引擎每个行动回合清零，
## 拿跨回合的旧基线去比，要么永远不成立、要么当场误判成立。
## 步骤刚成为当前时多半还没轮到玩家（actor = -1），所以这一支也是「等轮到你」的入口。
func check_progress() -> void:
	if not active:
		return
	var key: String = CWGuideData.watch_of(_chapter, _step)
	if key == "":
		return
	var now: Dictionary = WATCH.snapshot(_mirror(), _human_pid())
	if not WATCH.same_turn(_watch_base, now):
		_watch_base = now
		return
	if WATCH.done(key, _watch_base, now):
		_turn_page()


## 某条判据此刻成立吗（拿当前步骤的基线跟现在比）。`reset_when` 用它 —— 同一张判据表、同一个基线，
## 和 `check_progress` 的区别只是命中之后干什么（那边翻页、这边重置本关）
func watch_hit(key: String) -> bool:
	if key == "":
		return false
	var now: Dictionary = WATCH.snapshot(_mirror(), _human_pid())
	if not WATCH.same_turn(_watch_base, now):
		return false
	return WATCH.done(key, _watch_base, now)


## 屏幕前这位真人的席位（没有 = -1）。教程局永远只有一席，取第一个就够
func _human_pid() -> int:
	if _match == null or not is_instance_valid(_match) or _match.human_players.is_empty():
		return -1
	return int(_match.human_players[0])


## 当前这一局的那一份观测（没有 = null）
func _mirror() -> CWMirror:
	if _match == null or not is_instance_valid(_match):
		return null
	return _match.mirror



func _render() -> void:
	var all := CWGuideData.steps(_chapter)
	if all.is_empty():
		dismiss()
		return
	var s: Dictionary = all[mini(_step, all.size() - 1)]
	_chapter_label.text = "%d/%d %s · 步骤 %d/%d" % [
		_chapter + 1, CWGuideData.CHAPTER_COUNT,
		CWGuideData.chapter_titles()[_chapter], _step + 1, all.size()]
	if _title != null:
		_title.text = plain(s["t"])
	for l in _body:
		l.queue_free()
	_body.clear()
	var y := 0.0
	var body_lines: Array = s["b"].duplicate()
	if _chapter == CWGuideData.CHAPTER_COUNT - 1 and _match != null \
			and is_instance_valid(_match) and _match.mirror != null:
		var assist := CWGuideData.graduation_assist(_match.mirror)
		## 新 PRD 没有毕业战 ⇒ 门面返回 `{}`（方案 §1.1）。**必须判空**：
		## 空表上取 `assist["suggestion"]` 是「键不存在」的运行时错误，而 `_chapter == CHAPTER_COUNT - 1`
		## 现在天天成立（最后一关就是普通一关）—— 最后一关每次翻页都会报一条、正文也贴不出来。
		if not assist.is_empty():
			body_lines.append("建议：" + str(assist["suggestion"]))
			body_lines.append("预测：" + str(assist["e_prediction"]))
			body_lines.append("规则：" + str(assist["rule_explanation"]))
	for line in body_lines:
		var label := CWStyle.label(plain(str(line)), CWStyle.SIZE_LABEL, CWStyle.TEXT)
		label.position = Vector2(0, y)
		label.size = Vector2(_content.size.x, BODY_LINE)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_content.add_child(label)
		_body.append(label)
		y += BODY_LINE
	## 正文块的高度跟着行数长（**它不再顶到任何东西**：操作那一组在屏幕下方，Kevin 09-19），
	## 白雾也跟着收放 —— 固定 200 高的雾在只有一行正文时会平白洗掉两排棋盘格
	_content.size.y = maxf(y, BODY_LINE)
	_fog.size = Vector2(ZONE.size.x + 80, ROW_BODY + _content.size.y + 32)
	var last_of_chapter: bool = _step >= all.size() - 1
	var last_of_all: bool = _chapter >= CWGuideData.CHAPTER_COUNT - 1 and last_of_chapter
	_btn.text = "下一章" if last_of_chapter and not last_of_all else ("完成引导" if last_of_all else "继续")
	## 按钮行按实测宽度整行居中（按钮字数会变：继续 / 下一章 / 完成引导，先定字再量宽）
	_btn.size = _btn.get_minimum_size()
	_skip.size = _skip.get_minimum_size()
	_codex_btn.size = _codex_btn.get_minimum_size()
	var gap := 16.0
	var total: float = _skip.size.x + gap + _codex_btn.size.x + gap + _btn.size.x
	var x := (ACT_ZONE.size.x - total) / 2.0
	for c: Label in [_skip, _codex_btn, _btn]:
		c.position = Vector2(x, ROW_BTN)
		x += c.size.x + gap
	## 引导目录/章节选择放在「完成引导」之后不再重复出现，避免浮层太挤
	_refresh_hint()
	## 判据的基线在「步骤成为当前」的瞬间取好（渲染即当前）
	_watch_base = WATCH.snapshot(_mirror(), _human_pid())
	## 剧本翻到新的一步：装闸 / UI 层 / 浮现（S4，见 on_step_changed 的注释）
	if on_step_changed.is_valid():
		on_step_changed.call()


## 引导结束时由 CWMatch 调用：隐藏面板并清掉引用
func teardown() -> void:
	active = false
	visible = false
	_match = null
