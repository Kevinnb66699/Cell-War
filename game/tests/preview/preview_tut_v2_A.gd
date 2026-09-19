extends SceneTree
## 新手教程 v2 · **方向 A「贴身气泡」** 的界面方向稿 —— 给人看的工具，不是测试。
##
## Kevin 2026-09-19：「把之前教程的 UI 等设计全部删掉，基于脚本从 0 构建一个全新的新手教程」。
## 这一份只回答「长什么样」，不接流程 / 关卡数据 / 内核，不碰 `scripts/**`。
## 剧本是 `Cell_War_新手引导PRD_hxr.md`（09-18 版），逐帧说明见 `docs/新手引导v2_方向A.md`。
##
## 方向 A 的一句话：**台词贴着细胞说，控件提示贴着控件长，屏幕中央永远留给棋盘。**
##   · 台词 = 尾巴指向细胞的像素气泡，跟着细胞位置走；「……」是三颗渐显的点
##   · 控件提示 = 控件旁的小气泡（尾巴指着那枚按钮），不是横幅
##   · 章节提示 = 全屏半透明底 + 大字（棋盘透得出来）
##   · 重置 / 目录 = 左上角两枚小图标按钮（图标 + 悬停出字）
##   · 图鉴解锁 = 右上角滑入的小卡，连着来几条就往下摞
##   · 操作禁用 = 底栏控件降灰 + 光标变「…」
##
## **为什么非得出真渲染图**：排版预览用平底色就会骗人（记忆里一晚上栽过三次）。
## 这里一律是**真 Board.tscn + 真机位换算 + 真 CWStyle 字体 + 真 CWMatchPanel / CWActionBar**，
## 棋盘上的细胞是 `assets/art/cells/anim/*_breath.png` 的真贴图。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_tut_v2_A.gd -- <输出目录>

# ── 细胞贴图（同 tutorial_opening.gd 的那一族）──
const CELL_ART := {
	"immune": preload("res://assets/art/cells/anim/immune_breath.png"),
	"tcell": preload("res://assets/art/cells/anim/tcell_breath.png"),
	"bcell": preload("res://assets/art/cells/anim/bcell_breath.png"),
	"macro": preload("res://assets/art/cells/anim/macrophage_breath.png"),
	"sclc": preload("res://assets/art/cells/anim/sclc_breath.png"),
	"signet": preload("res://assets/art/cells/anim/signet_breath.png"),
}
## 右栏行里那枚 32px 的小头像（CWMatchPanel 用的是这一族静态图，不是呼吸带）
const ICON_ART := {
	"immune": preload("res://assets/art/cells/immune.png"),
	"tcell": preload("res://assets/art/cells/tcell.png"),
	"bcell": preload("res://assets/art/cells/bcell.png"),
	"macro": preload("res://assets/art/cells/macrophage.png"),
	"sclc": preload("res://assets/art/cells/sclc.png"),
	"signet": preload("res://assets/art/cells/signet.png"),
}
const BREATH_FRAMES := 6
const CELL_FOOT_DY := 6.0        ## 同 CWMatch：脚底落在格顶面中心再往下 6px

# ── 方向 A 的自有常数（配色全部落在 CWStyle 的既有色上，不新开一套）──
const BUBBLE_BG := Color("0a1018f2")   ## 气泡底：比 BTN_BG 再实一档，压在棋盘上要读得出字
const BUBBLE_PAD_H := 10.0
const BUBBLE_PAD_V := 7.0
const BUBBLE_MAX_W := 280.0            ## 台词气泡的最大排版宽度（14 个字一行，剧本里最长的一句刚好装下）
const TIP_MAX_W := 250.0               ## 控件小气泡：剧本里最长的一条「点击结算【微环境压迫】」正好一行
const TAIL := 13                       ## 尾巴：13×7 的像素三角（2px 描边）
const GAP_TAIL := 2.0                  ## 尾尖与目标之间留的缝
const ICON_PX := 12                    ## 左上角图标的点阵边长，显示时 ×2
const CODEX_W := 196.0
const CODEX_H := 46.0

const LATE := 0.30                     ## 搭完场景等这么久再读控件矩形（HBox 下一帧才排完版）
const GAP := 0.62                      ## 每帧总时长


var _dir := "user://"
## Board.tscn 的实例。**不加类型注解**：board.gd 没有 class_name，
## 标成 Node2D 就够不着 tile_center / MARK_MOVE / Z_CELL 这些成员（同 tutorial_opening.gd）
var _board
var _cells: Node2D
var _cam: Camera2D
var _ui: CanvasLayer
var _bar: CWActionBar
var _panel: CWMatchPanel
var _late := Callable()                ## 本帧的「等排完版再画」那一段
var _frames := 0
var _t := 0.0
var _queue: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]
	if not _dir.ends_with("/"):
		_dir += "/"
	DirAccess.make_dir_recursive_absolute(_dir)
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = CWView.screen_size()
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cells = Node2D.new()
	_board.add_child(_cells)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_ui = CanvasLayer.new()
	root.add_child(_ui)

	var frames: Array = [
		["01_章节提示", _f_chapter],
		["02_第一关关首", _f_l1_open],
		["03_第一关操作中", _f_l1_play],
		["04_第三关_右栏与图鉴", _f_l3],
		["05_目录面板", _f_toc],
		["06_第七关_结束回合", _f_l7],
		["07_自动重置提示", _f_autoreset],
		["08_间章_沉默与NPC", _f_interlude],
	]
	var at := 0.05
	for f in frames:
		var shot_name: String = f[0]
		var build: Callable = f[1]
		_at(at, func() -> void:
			_reset()
			build.call())
		_at(at + LATE, func() -> void:
			if _late.is_valid():
				_late.call())
		_at(at + GAP, func() -> void: _shot(shot_name))
		at += GAP + 0.05
	_at(at + 0.2, func() -> void: quit())


func _at(t: float, fn: Callable) -> void:
	_queue.append({ "at": t, "fn": fn })
	_queue.sort_custom(func(a, b) -> bool: return a["at"] < b["at"])


func _process(delta: float) -> bool:
	## 头两帧棋盘的 map 还没铺完（Board._ready 里才建 127 格），
	## 这时候 set_tissue / tile_center 全部落空（preview_solidify 踩过）
	_frames += 1
	if _frames < 3:
		return false
	_t += delta
	while not _queue.is_empty() and _t >= _queue[0]["at"]:
		var step: Dictionary = _queue.pop_front()
		step["fn"].call()
	return false


func _shot(shot_name: String) -> void:
	var path: String = _dir + shot_name + ".png"
	var err := root.get_texture().get_image().save_png(path)
	print("已保存 %s (err=%d)" % [path, err])


func _reset() -> void:
	_late = Callable()
	for c in _ui.get_children():
		_ui.remove_child(c)
		c.queue_free()
	for c in _cells.get_children():
		_cells.remove_child(c)
		c.queue_free()
	_bar = null
	_panel = null
	_board.set_marks({})


# ════════════════════════════════════════════════════════════════
#  棋盘：遮罩出小棋盘、铺组织、摆细胞、对机位
# ════════════════════════════════════════════════════════════════

## 只露这一批格：教程小棋盘走**遮罩**、不重铺格网（Kevin 2026-09-11 拍板）
func _show(tiles: Array) -> void:
	_board.set_active_tiles(tiles, 0.0)


## 铺组织。special 一律传 NONE：教程前几关是「一片干净的身体」，
## 正式盘的代谢核心 / 骨髓 / 血管要到第四章「跟回合有关的」才进场
func _paint(healthy: Array, cancer: Array = [], solid: Array = []) -> void:
	for c: Vector2i in healthy:
		_board.set_tissue(c, CWData.Tissue.HEALTHY, CWData.Special.NONE)
	for c: Vector2i in cancer:
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	for c: Vector2i in solid:
		_board.set_tissue(c, CWData.Tissue.SOLID, CWData.Special.NONE, true, 1.0)


func _cell(kind: String, c: Vector2i, breath := 2) -> Sprite2D:
	var tex: Texture2D = CELL_ART[kind]
	var s := Sprite2D.new()
	s.texture = tex
	s.hframes = BREATH_FRAMES
	s.frame = breath % BREATH_FRAMES
	s.offset = Vector2(0, -tex.get_height() / 2.0)   ## 锚点从贴图中心挪到脚底中心
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.position = _board.tile_center(c) + Vector2(0, CELL_FOOT_DY)
	s.z_index = _board.tile_z(c, _board.Z_CELL)
	_cells.add_child(s)
	return s


## 这只细胞的**头顶**落在屏幕的哪儿 —— 气泡的尾尖要指到这里
func _head(s: Sprite2D) -> Vector2:
	var h: float = s.texture.get_height()
	return CWView.board_to_screen(_cam, s.position - Vector2(0, h + 3.0))


## 把这批格摆进屏幕上的一块可用区，棋盘小就自动推近。
## `CWView.GAME_ZOOM` 是 127 格正式盘的倍率，两格的第一关用它只有指甲盖大；
## 顶到菜单机位的 3.2 就不再放大，再近能看出贴图边缘的插值
func _focus(tiles: Array, anchor: Vector2, avail: Vector2, max_zoom := 3.2) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c: Vector2i in tiles:
		var p: Vector2 = _board.tile_center(c)
		## 上边多留 34：格子上站着的细胞比顶面高一整个身位
		lo = Vector2(minf(lo.x, p.x - 18.0), minf(lo.y, p.y - 34.0))
		hi = Vector2(maxf(hi.x, p.x + 18.0), maxf(hi.y, p.y + 24.0))
	var span: Vector2 = hi - lo
	var z: float = minf(minf(avail.x / maxf(span.x, 1.0), avail.y / maxf(span.y, 1.0)), max_zoom)
	_cam.zoom = Vector2(z, z)
	_cam.position = CWView.camera_pos_for((lo + hi) * 0.5, anchor, z, CWView.screen_size())


# ════════════════════════════════════════════════════════════════
#  方向 A 的自有件：像素气泡
# ════════════════════════════════════════════════════════════════

## 像素三角尾巴。dir = "down"（气泡在上，指下）/ "right"（气泡在左，指右）。
## **烤成小图再 NEAREST 放大**才是像素三角；用 Polygon2D 画会得到一条抗锯齿斜边，
## 和全游戏的点阵气质当场脱节
func _tail_tex(dir: String, accent: Color) -> ImageTexture:
	var n := TAIL
	var m: int = (n + 1) / 2                 ## 7：尾巴的高度
	var w: int = n if dir == "down" else m
	var h: int = m if dir == "down" else n
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var border := Color(accent, 0.55)
	for i in n:                              ## i 沿底边
		for j in m:                          ## j 沿指向（0 = 贴着气泡那一排）
			if i < j or i > n - 1 - j:
				continue
			var edge: bool = i < j + 2 or i > n - 3 - j
			var col: Color = border if edge else BUBBLE_BG
			if dir == "down":
				img.set_pixel(i, j, col)
			else:
				img.set_pixel(j, i, col)
	return ImageTexture.create_from_image(img)


func _bubble_style(accent: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = BUBBLE_BG
	b.border_color = Color(accent, 0.55)     ## 描边**取说话人的阵营色**：谁在说话一眼看得出
	b.set_border_width_all(2)
	return b


## 一枚气泡（还没摆位置），返回的 Control 的 size 就是气泡本体。
## `dots` 不空时正文换成 N 颗渐显的点 ——「……」是沉默几拍，不是三个句号
func _bubble(text: String, accent: Color, max_w: float, fsize: int,
		dots: Array = []) -> Control:
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var body_w := 0.0
	var body_h := 0.0
	if dots.is_empty():
		var one: float = CWStyle.FONT.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		body_w = minf(one, max_w)
		body_h = CWStyle.FONT.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, body_w, fsize).y
	else:
		body_w = dots.size() * 16.0 - 6.0
		body_h = 16.0
	box.size = Vector2(body_w + BUBBLE_PAD_H * 2.0, body_h + BUBBLE_PAD_V * 2.0)
	var skin := Panel.new()
	skin.add_theme_stylebox_override("panel", _bubble_style(accent))
	skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(skin)
	if dots.is_empty():
		var lb := CWStyle.label(text, fsize, CWStyle.TEXT_HI)
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.position = Vector2(BUBBLE_PAD_H, BUBBLE_PAD_V)
		lb.size = Vector2(body_w, body_h)
		box.add_child(lb)
	else:
		for i in dots.size():
			var d := ColorRect.new()
			d.color = Color(CWStyle.TEXT_HI, float(dots[i]))
			d.size = Vector2(10, 10)
			d.position = Vector2(BUBBLE_PAD_H + i * 16.0, BUBBLE_PAD_V + 3.0)
			d.mouse_filter = Control.MOUSE_FILTER_IGNORE
			box.add_child(d)
	return box


## 把气泡摆到 `target`（屏幕坐标）旁边，尾尖指着它。
## 横向夹回画布内 —— 棋盘边缘的细胞说话时，气泡不能半个身子出屏
func _place(box: Control, target: Vector2, accent: Color, dir: String) -> Control:
	var tail := TextureRect.new()
	tail.texture = _tail_tex(dir, accent)
	tail.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tip: float = float((TAIL + 1) / 2)
	var w: float = box.size.x
	var h: float = box.size.y
	if dir == "down":
		box.position = Vector2(
			clampf(target.x - w * 0.5, 10.0, CWView.screen_size().x - w - 10.0),
			target.y - GAP_TAIL - tip - h)
		## 往回压 2px **盖住气泡自己的那道底边**：不盖的话尾巴会被一条描边横着切断，
		## 读起来像气泡下面另挂了一个小三角，而不是「从气泡里长出来的嘴」
		tail.position = Vector2(
			clampf(target.x - box.position.x - TAIL * 0.5, 6.0, maxf(w - TAIL - 6.0, 6.0)),
			h - 2.0)
	else:
		box.position = Vector2(target.x - GAP_TAIL - tip - w, target.y - h * 0.5)
		tail.position = Vector2(w - 2.0,
			clampf(target.y - box.position.y - TAIL * 0.5, 6.0, maxf(h - TAIL - 6.0, 6.0)))
	box.add_child(tail)
	_ui.add_child(box)
	return box


## 细胞说话：气泡贴在它头顶
func _say(s: Sprite2D, text: String, accent: Color) -> Control:
	return _place(_bubble(text, accent, BUBBLE_MAX_W, CWStyle.SIZE_BODY),
		_head(s), accent, "down")


## 细胞沉默：三颗渐显的点
func _say_dots(s: Sprite2D, alphas: Array, accent: Color) -> Control:
	return _place(_bubble("", accent, BUBBLE_MAX_W, CWStyle.SIZE_BODY, alphas),
		_head(s), accent, "down")


## 控件说话：小一号的气泡贴着那枚控件
func _tip(target: Vector2, text: String, accent: Color, dir := "down") -> Control:
	return _place(_bubble(text, accent, TIP_MAX_W, CWStyle.SIZE_BODY), target, accent, dir)


# ════════════════════════════════════════════════════════════════
#  方向 A 的自有件：章节提示 / 角标按钮 / 图鉴卡 / 目录 / 提亮 / 等待光标
# ════════════════════════════════════════════════════════════════

## 章节提示：全屏半透明底 + 大字（通用规则 1）。棋盘**透得出来**，
## 所以它是「盖一层」而不是「切一页」—— 关与关之间静默切换的气质在这儿就定了
func _chapter(no: String, title: String, accent: Color) -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.024, 0.043, 0.071, 0.86)
	scrim.size = CWView.screen_size()
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(scrim)
	## 字压在一条**整幅不透明的横带**上，而不是直接压在压暗的棋盘上：
	## 棋盘正中就是主角细胞，它再亮一档就能从 0.86 的幕布里透出来，
	## 「第一章」三个字正好糊在它身上（第一版就这样）
	var band := ColorRect.new()
	band.color = Color(0.024, 0.043, 0.071, 0.97)
	band.position = Vector2(0, 198)
	band.size = Vector2(CWView.screen_size().x, 124)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(band)
	for y in [198.0, 320.0]:
		var rule := ColorRect.new()
		rule.color = Color(accent, 0.34)
		rule.position = Vector2(0.0, float(y))
		rule.size = Vector2(CWView.screen_size().x, 2)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(rule)
	_wide(CWStyle.label(no, CWStyle.SIZE_BIG, CWStyle.TEXT_DIM), 212.0)
	_wide(CWStyle.label(title, CWStyle.SIZE_HERO, accent), 252.0)


func _wide(l: Label, y: float) -> void:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size = Vector2(CWView.screen_size().x, 0)
	l.position = Vector2(0, y)
	_ui.add_child(l)


## 点阵图标：把网格烤成小图，×2 用 NEAREST 放 —— 和全游戏的点阵字同一副嗓子
func _icon(kind: String) -> ImageTexture:
	var n := ICON_PX
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	if kind == "reset":
		## 回转箭头：一圈环 + 右上开口 + 开口处一枚箭头
		var c := Vector2(5.5, 5.5)
		for y in n:
			for x in n:
				var v := Vector2(x, y) - c
				var d: float = v.length()
				if d < 3.1 or d > 5.2:
					continue
				if v.x > 1.0 and v.y < -1.0:
					continue           ## 右上的缺口
				img.set_pixel(x, y, Color.WHITE)
		for i in 4:                    ## 箭头：贴着缺口右缘往下指
			for j in range(0, 4 - i):
				img.set_pixel(clampi(7 + j, 0, n - 1), clampi(1 + i, 0, n - 1), Color.WHITE)
	else:
		## 目录：三行「点 + 线」
		for k in 3:
			var y: int = 2 + k * 4
			for dy in 2:
				for x in range(0, 2):
					img.set_pixel(x, y + dy, Color.WHITE)
				for x in range(4, 12):
					img.set_pixel(x, y + dy, Color.WHITE)
	return ImageTexture.create_from_image(img)


## 常驻两枚小图标按钮（通用规则 4 / 5）：左上角，图标 + 悬停出字。
## 摆左上而不是底栏：底栏是**对局**的地盘（行动栏 / 手牌），教程的元操作别混进去
func _corner(hover := -1) -> void:
	var kinds := ["reset", "menu"]
	var names := ["重置", "目录"]
	for i in 2:
		var hot: bool = hover == i
		var p := Panel.new()
		var b := StyleBoxFlat.new()
		b.bg_color = Color("12212ee6") if hot else Color("0a1018cc")
		b.border_color = Color(CWStyle.LINE, 0.5 if hot else 0.3)
		b.set_border_width_all(2)
		p.add_theme_stylebox_override("panel", b)
		p.position = Vector2(12.0 + i * 40.0, 12.0)
		p.size = Vector2(32, 32)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(p)
		var t := TextureRect.new()
		t.texture = _icon(kinds[i])
		t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		t.position = p.position + Vector2(4, 4)
		t.size = Vector2(ICON_PX * 2, ICON_PX * 2)
		t.modulate = CWStyle.TEXT_HI if hot else CWStyle.TEXT
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(t)
		if hot:
			var cap := CWStyle.label(names[i], CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
			cap.position = p.position + Vector2(38, 11)
			_ui.add_child(cap)


## 图鉴解锁：右上角滑入的小卡，连着来几条就往下摞（剧本里一关会连解两三条）。
## right_x = 卡的右缘；右栏弹出的关要让开那 264px
func _codex(entries: Array, right_x: float) -> void:
	for i in entries.size():
		var card := Panel.new()
		var b := StyleBoxFlat.new()
		b.bg_color = Color("0a1018e6")
		b.border_color = Color(CWStyle.LINE, 0.4)
		b.set_border_width_all(2)
		card.add_theme_stylebox_override("panel", b)
		card.position = Vector2(right_x - CODEX_W, 14.0 + i * (CODEX_H + 6.0))
		card.size = Vector2(CODEX_W, CODEX_H)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(card)
		var stripe := ColorRect.new()
		stripe.color = Color(CWStyle.IMMUNE, 0.85)
		stripe.position = card.position + Vector2(2, 2)
		stripe.size = Vector2(3, CODEX_H - 4)
		stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(stripe)
		var cap := CWStyle.label("图鉴解锁", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		cap.position = card.position + Vector2(14, 6)
		_ui.add_child(cap)
		var nm := CWStyle.label("【%s】" % String(entries[i]), CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		nm.position = card.position + Vector2(12, 16)
		_ui.add_child(nm)


## 控件 / 格子的提亮环（通用规则 8：较慢频次、反差较低的轻微闪烁）。
## 拍的是**亮相那一拍**；口径是 1.6 秒一个来回，描边 alpha 在 0.5↔0.22 之间走
func _ring(r: Rect2, accent: Color, alpha := 0.5) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var p := Panel.new()
	var b := StyleBoxFlat.new()
	b.bg_color = Color(accent, 0.10)
	b.border_color = Color(accent, alpha)
	b.set_border_width_all(2)
	p.add_theme_stylebox_override("panel", b)
	p.position = r.position - Vector2(4, 4)
	p.size = r.size + Vector2(8, 8)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(p)


## 光标变「…」：提示还没说完，点什么都不响应（通用规则 9）。
## 底栏降灰说的是「这枚按钮此刻不可用」，光标说的是「整个画面此刻不接受操作」，两条都要
func _cursor_wait(at: Vector2) -> void:
	var img := Image.create(8, 11, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 11:
		if y <= 7:
			for x in range(0, y + 1):
				img.set_pixel(x, y, Color.WHITE)
		else:
			for x in range(4, 7):
				img.set_pixel(x, y, Color.WHITE)
	var tex := ImageTexture.create_from_image(img)
	for k in 2:                 ## 先一层暗影，浅底深底上都看得见
		var t := TextureRect.new()
		t.texture = tex
		t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		t.size = Vector2(16, 22)
		t.position = at + (Vector2(2, 2) if k == 0 else Vector2.ZERO)
		t.modulate = Color(0, 0, 0, 0.6) if k == 0 else CWStyle.TEXT_HI
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(t)
	var chip := Panel.new()
	chip.add_theme_stylebox_override("panel",
		CWStyle.plate(Color(CWStyle.TEXT_DIM, 0.35), 0, 0))
	chip.position = at + Vector2(15, 13)
	chip.size = Vector2(28, 16)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(chip)
	var dots := CWStyle.label("…", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	dots.position = chip.position + Vector2(4, -5)
	_ui.add_child(dots)


## 目录面板（通用规则 5）。章 - 关两层清单，当前一关挂 CWStyle 的焦点菱形
func _toc(cur: int) -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.024, 0.043, 0.071, 0.62)
	scrim.size = CWView.screen_size()
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(scrim)
	var pan := Panel.new()
	pan.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	pan.position = Vector2(268, 76)
	pan.size = Vector2(424, 388)
	pan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(pan)
	var title := CWStyle.label("目录", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = pan.position + Vector2(20, 12)
	_ui.add_child(title)
	var hint := CWStyle.label("再点一次左上角的目录图标收起", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	hint.position = pan.position + Vector2(20, 52)
	_ui.add_child(hint)
	var rows := [
		["ch", "第一章 Cell", ""],
		["lv", "一 · 免疫", "已完成"],
		["lv", "二 · 癌", "已完成"],
		["lv", "三 · ATP", ""],
		["ch", "第二章 Immune", ""],
		["lv", "四 · 抗原记忆", "未解锁"],
		["lv", "五 · 分化", "未解锁"],
		["lv", "间章 · 癌变", "未解锁"],
		["ch", "第三章 Cancer", ""],
		["lv", "七 · ……", "未解锁"],
	]
	var y: float = pan.position.y + 76.0
	var idx := 0
	for r in rows:
		var kind: String = r[0]
		var text: String = r[1]
		var note: String = r[2]
		if kind == "ch":
			var ch := CWStyle.label(text, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
			ch.position = Vector2(pan.position.x + 20, y + 4)
			_ui.add_child(ch)
			y += 26.0
		else:
			var here: bool = idx == cur
			var col: Color = CWStyle.TEXT_OFF
			if note == "已完成":
				col = CWStyle.TEXT
			if here:
				col = CWStyle.TEXT_HI
			var lv := CWStyle.label(text, CWStyle.SIZE_BODY, col)
			lv.position = Vector2(pan.position.x + 42, y)
			_ui.add_child(lv)
			if here:
				var mk := CWStyle.focus_marker()
				mk.position = Vector2(pan.position.x + 28, y + 14)
				_ui.add_child(mk)
			if note != "":
				var nt := CWStyle.label(note, CWStyle.SIZE_LABEL,
					CWStyle.TEXT_DIM if note == "已完成" else CWStyle.TEXT_OFF_DIM)
				nt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				nt.position = Vector2(pan.position.x + 20, y + 9)
				nt.size = Vector2(pan.size.x - 40, 0)
				_ui.add_child(nt)
			y += 30.0
			idx += 1


# ════════════════════════════════════════════════════════════════
#  真 HUD：行动栏与右侧竖条
# ════════════════════════════════════════════════════════════════

## 第一、二关只显示【迁移】（剧本：不显示路径规划 / 能量消耗）。
## disabled = 提示 / 对话进行中，整条降灰（通用规则 9）
func _action(entries: Array) -> void:
	_bar = CWActionBar.new()
	_ui.add_child(_bar)
	_bar.show_bar("", "", entries)


## 右侧竖条：第三关起弹出。`round_no=false` 时那一块 62px 真让给下面的行。
##
## **先 refresh 再 guide_layers**：`guide_layers` 只有在面板已经按人数建过之后才会重搭，
## 反过来调的话 `_round` 那时还是 null、visible 没关上，重搭之后「第 1 回合」
## 会叠在顶上去的癌性加权块上（第一版的第七关就是这样）
func _sidebar(seats: int, level: int, memory: int, round_no: bool, end_turn: bool) -> void:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[seats], 1)
	g.setup.build_board()
	g.round_no = 1
	g.immune_level = level
	g.memory = memory
	var m := CWMirror.new()
	var err := m.sync_from(g)
	if err != "":
		push_error("preview_tut_v2_A：镜像装载失败 —— %s" % err)
	_panel = CWMatchPanel.new()
	_ui.add_child(_panel)
	_panel.refresh(m, Callable())
	_panel.guide_layers(end_turn, round_no)
	_panel.refresh(m, Callable())
	_panel.show_end_turn(end_turn)
	_trim_weighted()


## 教程里没有「癌性加权 / 胜负进度」这回事（第四章才讲回合），那一块整个收掉。
## **本稿只是隐藏，位置没让出来** —— 实装时它该和 `round_no` 一样加一道 ui_layers 闸，
## 真把 66px 让给下面的行（见 docs/新手引导v2_方向A.md 的风险一条）
func _trim_weighted() -> void:
	for l in [_panel._weighted, _panel._weighted_max, _panel._weighted_caption]:
		(l as Control).visible = false
	_panel._bar_fill.visible = false
	## 进度槽是个没有存把手的 ColorRect，按「位置 + 高度」把它认出来
	var y: float = _panel._score_top() + 28.0
	for c in _panel.get_children():
		var cr := c as ColorRect
		if cr != null and is_equal_approx(cr.position.y, y) and is_equal_approx(cr.size.y, 8.0):
			cr.visible = false


## 把一行席位改写成教程里该有的样子。教程的席位表由关卡数据给
## （第七关是「1 癌 + N 免疫」，正式局的 FACTION_ORDER 排不出来），
## 这里借正式局的行数来量空间，名字 / 种类 / 能量 / 阵营色逐个改写
func _seat(pid: int, immune: bool, icon: Texture2D, who: String, kind: String,
		energy: String, acting := false) -> void:
	var row: Dictionary = _panel._rows[pid]
	var col: Color = CWStyle.IMMUNE if immune else CWStyle.CANCER
	row["fac"].color = col
	row["bg"].color = Color(col, 0.10 if acting else 0.0)
	row["name"].text = who
	row["name"].add_theme_color_override("font_color",
		CWStyle.TEXT_HI if acting else CWStyle.TEXT)
	row["type"].text = kind
	row["energy"].text = energy
	row["income"].text = ""
	row["skills"].text = ""
	row["icon"].visible = icon != null
	row["icon"].texture = icon
	for p in row["pips"]:                 ## 教程没有手牌
		(p as Control).visible = false


# ════════════════════════════════════════════════════════════════
#  八帧
# ════════════════════════════════════════════════════════════════

const L1 := [Vector2i(-1, 0), Vector2i(0, 0)]


func _l1_scene() -> Sprite2D:
	_show(L1)
	_paint(L1)
	_focus(L1, Vector2(480, 286), Vector2(620, 356), 4.0)
	return _cell("immune", L1[0])


## ① 第一章章节提示：底下就是第一关的棋盘，半透明盖着
func _f_chapter() -> void:
	_l1_scene()
	_corner()
	_chapter("第一章", "Cell", CWStyle.IMMUNE)


## ② 第一关关首：台词正在说，【迁移】降灰、光标是「…」
func _f_l1_open() -> void:
	var me := _l1_scene()
	_corner()
	_action([{ "title": "迁移", "disabled": true }])
	_say(me, "欢迎来到Cell_War！", CWStyle.IMMUNE)
	_cursor_wait(Vector2(548, 430))


## ③ 第一关操作中：台词说完，【迁移】与目的格都在提示态，可操作
func _f_l1_play() -> void:
	_l1_scene()
	_corner()
	_action([{ "title": "迁移" }])
	_board.set_marks({ L1[1]: _board.MARK_MOVE })
	_late = func() -> void:
		var r: Rect2 = _bar.button_rect("迁移")
		_ring(r, CWStyle.IMMUNE)
		_tip(Vector2(r.get_center().x, r.position.y - 4.0), "向前行动一格", CWStyle.IMMUNE)


## 第三关：地图自免疫细胞向前延伸，几格外一个凸的癌组织连通块
const L3_HEALTHY := [
	Vector2i(-5, 0), Vector2i(-4, 0), Vector2i(-3, 0), Vector2i(-2, 0), Vector2i(-1, 0),
	Vector2i(0, 0), Vector2i(-4, -1), Vector2i(-3, -1), Vector2i(-2, -1), Vector2i(-1, -1),
	Vector2i(0, -1), Vector2i(-4, 1), Vector2i(-3, 1), Vector2i(-2, 1), Vector2i(-1, 1),
	Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, -2), Vector2i(2, -2),
]
const L3_CANCER := [
	Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, -1), Vector2i(2, -1), Vector2i(1, 1),
]


func _l3_scene() -> Array:
	var all: Array = L3_HEALTHY + L3_CANCER
	_show(all)
	_paint(L3_HEALTHY, L3_CANCER)
	_focus(all, Vector2(348, 282), Vector2(596, 392))
	return [_cell("immune", Vector2i(-4, 0)), _cell("signet", Vector2i(2, 0), 4)]


## 第三关的两席：玩家的未分化免疫细胞 + 癌组织里那只癌细胞
func _l3_seats() -> void:
	## 教程到第三关都还没有「回合」这回事（第四章才讲），所以回合块也关掉 ——
	## 剧本给第三关的右栏只有「状态框 + 抗原记忆框」
	_sidebar(2, 1, 6, false, false)
	_seat(0, true, ICON_ART["immune"], "你", "免疫细胞", "3.1", true)
	_seat(1, false, ICON_ART["signet"], "癌细胞", "印戒细胞癌", "3.0")


## ④ 第三关：右栏弹出 + 癌组织连通块 + 台词 + 图鉴解锁同框
func _f_l3() -> void:
	var who: Array = _l3_scene()
	_l3_seats()
	_corner()
	_action([{ "title": "迁移" }])
	_say(who[0], "发现新的癌细胞，继续清理", CWStyle.IMMUNE)
	_codex(["净化", "攻击"], CWView.screen_size().x - CWView.PANEL_WIDTH - 10.0)


## ⑤ 目录面板：从第三关点开（目录图标处于悬停态，旁边出字）
func _f_toc() -> void:
	_l3_scene()
	_l3_seats()
	_toc(2)
	_corner(1)


## 第七关：玩家是癌细胞，脚下一圈自己铺的癌组织，远处一只 T 细胞在同一条直线上
func _f_l7() -> void:
	var tiles: Array = CWData.all_coords(5)
	var cancer: Array = []
	var healthy: Array = []
	for c: Vector2i in tiles:
		if CWData.hex_dist(c, Vector2i.ZERO) <= 1:
			cancer.append(c)
		else:
			healthy.append(c)
	_show(tiles)
	_paint(healthy, cancer)
	_focus(tiles, Vector2(340, 276), Vector2(636, 416), 1.9)
	var me := _cell("sclc", Vector2i(0, 0), 3)
	_cell("macro", Vector2i(1, 0))
	_cell("bcell", Vector2i(2, -2))
	_cell("immune", Vector2i(-2, 1))
	_cell("macro", Vector2i(0, -3), 4)
	_cell("tcell", Vector2i(5, 0), 1)
	## 全屏级的引导指向：整屏压暗一档 + 一圈画框，只有被指的控件和它的气泡是亮的
	var dim := ColorRect.new()
	dim.color = Color(0.016, 0.031, 0.051, 0.34)
	dim.size = CWView.screen_size()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(dim)
	var frame := Panel.new()
	var fb := StyleBoxFlat.new()
	fb.bg_color = Color(0, 0, 0, 0)
	fb.border_color = Color(CWStyle.CANCER, 0.26)
	fb.set_border_width_all(2)
	frame.add_theme_stylebox_override("panel", fb)
	frame.position = Vector2(6, 6)
	frame.size = CWView.screen_size() - Vector2(12, 12)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(frame)
	## 右栏：上方不显示第 X 回合，显示结束回合按钮，其他 UI 继续隐藏
	_sidebar(6, 2, 14, false, true)
	## 席位表：1 癌（玩家） + 5 免疫。正式局的 FACTION_ORDER 排不出这种配比，
	## 借它的行数来量空间，每一行的名字 / 种类 / 能量 / 阵营色逐个改写
	## 名字一栏只有 64px（≈ 3 个字），再长会被 CWMatchPanel 自己裁成省略号；
	## 能量写「Null」而不是「∞」—— 点阵字库里没有 ∞ 的字形，画出来是个空方框
	_seat(0, false, ICON_ART["sclc"], "你", "小细胞肺癌", "Null", true)
	_seat(1, true, ICON_ART["macro"], "巨噬", "巨噬细胞", "2.4")
	_seat(2, true, ICON_ART["bcell"], "B 细胞", "B 细胞", "1.8")
	_seat(3, true, ICON_ART["immune"], "免疫", "免疫细胞", "2.0")
	_seat(4, true, ICON_ART["macro"], "巨噬", "巨噬细胞", "1.2")
	_seat(5, true, ICON_ART["tcell"], "T 细胞", "T 细胞", "3.6")
	_corner()
	_late = func() -> void:
		var end_rect: Rect2 = _panel.rect_of("end")
		for i in 3:                ## 三枚像素人字箭朝按钮行进，越靠近越亮
			_chevron(Vector2(end_rect.position.x - 84.0 + i * 26.0,
				end_rect.get_center().y + 4.0), Color(CWStyle.CANCER, 0.28 + i * 0.22))
		_ring(end_rect, CWStyle.CANCER, 0.62)
		## 气泡摆在按钮**正上方**而不是左边：左边那条路上要走人字箭，
		## 而且气泡压出面板就会盖住棋盘右下角那几格
		_tip(Vector2(end_rect.get_center().x, end_rect.position.y - 4.0),
			"点击结算【微环境压迫】", CWStyle.CANCER)
		_say_dots(me, [1.0, 0.5, 0.2], CWStyle.CANCER)


## 一枚朝右的像素人字箭，全屏引导指向用
func _chevron(at: Vector2, col: Color) -> void:
	var img := Image.create(9, 17, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 17:
		var d: int = 8 - absi(y - 8)
		for x in range(maxi(d - 2, 0), d + 1):
			img.set_pixel(x, y, Color.WHITE)
	var t := TextureRect.new()
	t.texture = ImageTexture.create_from_image(img)
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	t.size = Vector2(18, 34)
	t.position = at - Vector2(9, 17)
	t.modulate = col
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(t)


## ⑦ 自动重置的动画提示（通用规则 7）：棋盘压暗、中央一圈回转环 + 一行因由
func _f_autoreset() -> void:
	_l3_scene()
	_l3_seats()
	_corner()
	var dim := ColorRect.new()
	dim.color = Color(0.016, 0.031, 0.051, 0.58)
	dim.size = CWView.screen_size()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(dim)
	var t := TextureRect.new()
	t.texture = _icon("reset")
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	t.size = Vector2(ICON_PX * 5, ICON_PX * 5)
	t.position = Vector2(348.0 - ICON_PX * 2.5, 178.0)
	t.modulate = Color(CWStyle.IMMUNE, 0.9)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(t)
	var plate := Panel.new()
	plate.add_theme_stylebox_override("panel",
		CWStyle.plate(Color(0.024, 0.043, 0.071, 0.92), 0, 0))
	plate.position = Vector2(348.0 - 190.0, 250.0)
	plate.size = Vector2(380, 84)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(plate)
	var a := CWStyle.label("自动重置", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	a.position = Vector2(348.0 - 160.0, 258.0)
	a.size = Vector2(320, 0)
	_ui.add_child(a)
	var b := CWStyle.label("能量不够走到癌细胞旁边了 —— 回到本关开头", CWStyle.SIZE_LABEL,
		CWStyle.TEXT_DIM)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.position = Vector2(348.0 - 180.0, 302.0)
	b.size = Vector2(360, 0)
	_ui.add_child(b)


## ⑧ 间章：所有 UI 消失只剩地图；玩家细胞「……」，旁边的 NPC 免疫也会弹话
func _f_interlude() -> void:
	var tiles: Array = CWData.all_coords(3)
	_show(tiles)
	_paint(tiles)
	_focus(tiles, Vector2(470, 292), Vector2(616, 376), 2.4)
	var me := _cell("immune", Vector2i(0, 0), 1)
	var npc := _cell("tcell", Vector2i(2, -1))
	_cell("bcell", Vector2i(-2, 1), 3)
	_say_dots(me, [1.0, 0.55, 0.22], CWStyle.IMMUNE)
	_say(npc, "发现新的敌人，继续清除——", CWStyle.IMMUNE)
