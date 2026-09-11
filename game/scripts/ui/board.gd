extends Node2D

## 预加载组织块
const TISSUE = preload("res://scenes/Tissue.tscn")
const HEALTH = preload("res://assets/art/tissue_normal.png")
const CANCER = preload("res://assets/art/tissue_cancer.png")
## 血管：健康版仍叫 vessel.png（原本没有癌变版，所以当初没带 _normal 后缀），
## 癌变版 2026-09-08 补上。改名统一成 vessel_normal.png 会动 uid，收益只是好看，没做。
const VESSELH = preload("res://assets/art/vessel.png")
const VESSELC = preload("res://assets/art/vessel_cancer.png")
## 积累进度外圈（Kevin 2026-09-08 拍的 A′ 案；2026-09-11 起换成 5yntaxEr 的手绘贴图，issue #24）：
## 每种组织 × 健康 / 病变各一对「底」（暗色底圈）「满」（亮色满圈），两张同一像素集、只差颜色；
## shader 按进度从底顶点顺时针把「满」露出来、其余露「底」，**按贴图纹素截取**。
## 颜色全在贴图里，代码不再给色 —— 病变那两对的配色（癌化骨髓 = 绿、癌化核心 = 紫）
## 也是 zip 里原样给的，要改直接换文件。下标 0 = 健康、1 = 病变（含固化，和 set_tissue 同一口径）。
const STORE_SHADER = preload("res://assets/shaders/store_progress.gdshader")
const STORE_TRACK := {
	CWData.Special.CORE: [preload("res://assets/art/ui/store/core_track_normal.png"),
		preload("res://assets/art/ui/store/core_track_cancer.png")],
	CWData.Special.MARROW: [preload("res://assets/art/ui/store/marrow_track_normal.png"),
		preload("res://assets/art/ui/store/marrow_track_cancer.png")],
}
const STORE_LIT := {
	CWData.Special.CORE: [preload("res://assets/art/ui/store/core_lit_normal.png"),
		preload("res://assets/art/ui/store/core_lit_cancer.png")],
	CWData.Special.MARROW: [preload("res://assets/art/ui/store/marrow_lit_normal.png"),
		preload("res://assets/art/ui/store/marrow_lit_cancer.png")],
}
const ENERGYH = preload("res://assets/art/energy_normal.png")
const MARROWH = preload("res://assets/art/marrow_normal.png")
const ENERGYC = preload("res://assets/art/energy_cancer.png")
const MARROWC = preload("res://assets/art/marrow_cancer.png")
## 骨髓的「空仓」两张：图标那个框照旧，里面的骨头**淡下去**（保留 35% 的图标色）。
## 由 marrow_normal / marrow_cancer 把骨头那 26 个像素朝底色混出来（2026-09-08）。
##
## **为什么是淡化而不是抹掉**：第一版直接删掉，Kevin 说「直接消失在视觉效果上比较怪」——
## 框会变成一个空洞，像贴图缺了一块。淡化则读成「这里本来有东西、现在没了」。
## 35% 是三档里试出来的：22% 太淡、几乎还是空洞；50% 和「有卡」的亮度差不够一眼分清。
## 美术要重画的话直接换这两个文件，代码不用动。
const MARROWH_E = preload("res://assets/art/marrow_empty_normal.png")
const MARROWC_E = preload("res://assets/art/marrow_empty_cancer.png")
## 骨髓的第三档「进度到头、卡还没结算」（Kevin 2026-09-11：癌化后周期 3 → 2，攒到 2/3 的格子
## 瞬间 2/2，环满了仓里却没卡）：空仓那对再把整个图标（框 + 骨头）淡到 35%。
## **进度环不动**（Kevin 同日定：「进度条不要变淡，就把中间的卡牌 icon 变淡」——
## 第一版连环一起淡过，当天撤掉）。`tools/gen_marrow_pending.py` 推的；美术要重画直接换文件。
const MARROWH_P = preload("res://assets/art/marrow_pending_normal.png")
const MARROWC_P = preload("res://assets/art/marrow_pending_cancer.png")

## 固化进度的石化贴图族（`tools/gen_solid_tissue.py` 烘的，结晶核扩散）。
## 键 = 底图名，值 = 变体数，**必须与生成器的 BASES 对上**（那边加变体，这边跟着加）。
const SOLIDIFY_BASES := {
	"tissue_cancer": 4,          ## 癌组织成片固化，一个变体一眼看出是克隆的
	"energy_cancer": 1,          ## 核心与骨髓散布各处、互不相邻，一个够用
	"marrow_cancer": 1,
	"marrow_empty_cancer": 1,
	"marrow_pending_cancer": 1,
}
## 文件名里的档位（计数 ×10）。四档对应贴图族的四张，见生成器文件头。
const SOLIDIFY_STEPS := [5, 10, 15, 20]
## 特殊组织 → 石化贴图族的底图名。**血管不在表里**：它不可固化
## （`CWTissue.solidifiable`），查不到就不画石头，正是想要的行为。
const SOLID_BASE_OF := {
	CWData.Special.NONE: "tissue_cancer",
	CWData.Special.CORE: "energy_cancer",
	CWData.Special.MARROW: "marrow_cancer",
}
var _solidify := {}   ## 底图名 -> [档位][变体] 的贴图表，_ready() 里装

var radius = CWData.BOARD_RADIUS + 1  ## 六边形每边的格数（= 最大环号 + 1）
var distance_x = 36 ## 块的横距离
var distance_y = 20 ## 块的纵距离
var first_x = -100 ## 第一个块x坐标
var first_y = -120 ## 第一个块y坐标
var map = {} ## 组织块位置

## 棋盘尺寸和特殊组织位置**一律读 CWData**，本文件不留第二份拷贝。
## 规则引擎用轴坐标 (q,r)，本文件画图用「行,列」下标，换算见 axial_to_rc()。
## 这里以前自己抄了一份行列下标，地图改版时两边对不上——2026-08-27 就是这么错的
## （抄的还是 5 个骨髓、代谢核心在半径 4 的旧版）。现在坐标只有 CWData 一处，改不错。
var vessel_position = []   ## 以下三个由 _ready() 从 CWData 的轴坐标换算填入
var energy_position = []
var marrow_position = []

## 轴坐标 (q,r) → 本文件的「行,列」下标。
## 中间那一行是 r=0，行内 q 自左向右递增；r 每 +1 往下走一行，整行同时右移半格。
func axial_to_rc(a: Vector2i) -> Vector2:
	var ring: int = CWData.BOARD_RADIUS
	var q_min: int = -ring if a.y >= 0 else -ring - a.y      ## 这一行最左边那格的 q
	return Vector2(a.y + ring + 1, a.x - q_min + 1)

## 贴图 34px 高，其中顶面只占上面 26px（下面 8px 是两侧的立面）。
## Sprite2D 是 centered=true，position 落在贴图中心，比顶面中心低 (34-26)/2 = 4px。
const TOP_FACE_DY := 4.0

## 轴坐标 → 该格「顶面中心」在本节点里的像素位置。
## 要把东西摆到某一格上（骰子、高亮、标记）一律走这里，别自己再算一遍（约定 #10）。
func tile_center(a: Vector2i) -> Vector2:
	var key := axial_to_rc(a)
	if not map.has(key):
		return Vector2.ZERO
	return map[key]["position"] - Vector2(0, TOP_FACE_DY)


## 没点中任何格子时 hex_at() 的返回值。轴坐标本身有负数，所以用哨兵而不是 -1。
const NO_TILE := Vector2i(9999, 9999)

## 像素 → 轴坐标，tile_center() 的逆运算；点在棋盘外返回 NO_TILE。
##
## 本文件的布局横距 36、纵距 20、隔行错半格，于是相邻格的偏移只有
## (±36, 0) 和 (±18, ±20) 两类 —— 把纵向按 36·√3/2 ÷ 20 ≈ 1.559 拉回去之后
## 这六个偏移的长度全等于 36，也就是说**这是一张被压扁的标准正六边形网格**。
## 所以在拉正的空间里找「最近的顶面中心」就等于真正的六边形命中判定
## （正六边形网格的最近点划分正是它自己），不用去解压扁投影的反函数。
##
## 比到自身外接圆半径 36/√3 还远就算没点中 —— 这一条挡掉棋盘外缘之外的点击，
## 否则边上的格子会把整个屏幕外侧都吸进来。
## 127 格全遍历，一次点击几微秒，没有建索引的必要。
func hex_at(p: Vector2) -> Vector2i:
	var squash: float = distance_x * sqrt(3.0) / 2.0 / distance_y
	var best := NO_TILE
	var best_d: float = distance_x / sqrt(3.0)
	for c in CWData.all_coords(radius - 1):
		var d: Vector2 = p - tile_center(c)
		var dist := Vector2(d.x, d.y * squash).length()
		if dist < best_d:
			best_d = dist
			best = c
	return best


## ── 点选输入 ────────────────────────────────────────────────────
## 「鼠标在哪一格」只有渲染层答得上来（hex_at 和格子的像素位置都在这儿），
## 所以输入落在这里，而不是让上层自己反算一遍投影。
## 棋盘只报「点了哪一格 / 停在哪一格」——**这一格能不能选、选了做什么，
## 全部由 CWUIBridge 决定**，棋盘不掺和规则。
signal tile_clicked(coord: Vector2i)
signal tile_hovered(coord: Vector2i)   ## 移出棋盘时给 NO_TILE
## 左键抬起。路径规划器靠「按下 → 划过若干格 → 抬起」这一串认拖动；
## 别的询问不接它，所以不影响原有交互。
signal drag_ended

var hovered := NO_TILE

## 「指针此刻是不是被某个界面控件占着」。默认问视口（4.2 起有这个查询）；无头测试里视口不跟踪悬停控件
## （喂事件也不更新，2026-09-06 探过），所以做成可替换的 Callable —— 和 CWMainMenu.guide_done_check 同一个套路。
var pointer_on_control: Callable = func() -> bool:
	return get_viewport().gui_get_hovered_control() != null


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouse):
		return
	## 坐标一律取事件自带的，别去问 get_global_mouse_position()——
	## 那读的是**真实光标**，模拟输入（截图工具、自动化测试）喂进来的位置它看不见。
	## make_input_local() 顺带把相机与画布变换也算进去了。
	var at: Vector2 = (make_input_local(event) as InputEventMouse).position
	if event is InputEventMouseMotion:
		var over := hex_at(at)
		if over != hovered:
			hovered = over
			tile_hovered.emit(over)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			drag_ended.emit()
			return
		var hit := hex_at(at)
		if hit != NO_TILE:
			tile_clicked.emit(hit)


## 最上面的图层说了算（Kevin 2026-09-06 截图：固定态技能框的详情和底下那一格的详情叠在一起）。
## 指针一进任何 STOP / PASS 过滤的控件（右栏、技能框、行动栏、手牌、日志、引导面板……），Godot 就把鼠标事件
## 标成已处理，上面的 _unhandled_input 收不到「移出了格子」，hovered 会停在进控件前的最后一格。
## 所以每帧问一下「指针是不是被控件占着」：占着就当没停在任何格上，报一次 NO_TILE（格子详情立即收起、
## 桥的高亮照常重画）；指针回到棋盘后第一次移动会照常重报那一格，详情从头计时，和平时移进一格一样。
func _process(_delta: float) -> void:
	if hovered != NO_TILE and pointer_on_control.call():
		hovered = NO_TILE
		tile_hovered.emit(NO_TILE)


## ── 高亮层 ──────────────────────────────────────────────────────
## 高亮 = 在格子上叠一张同贴图的纯色剪影，alpha 即混合比例。
## 比例和颜色是从设计稿 board_pick.png 逐像素反解出来的：改动过的每个像素
## 都正好等于 lerp(原色, #30D1FA, 0.43)，而叠一层 alpha=0.43 的纯色就是这个 lerp。
## 所以高亮**不是描边**，是整格染色。
const SILHOUETTE := preload("res://assets/shaders/silhouette.gdshader")


## ── 站在格子上的东西该用什么 z_index ──────────────────────────
## 组织块自己是 z = 贴图中心的 y，**前一排是 +20**。所以 above 只能取 1..19：
## 比自己那格高（不会被脚下这块盖住），又低于前一排（会被前排正确遮住）。
##
## **别在别处自己算这个数。** tile_center() 给的是**顶面**中心，比贴图中心高 4px，
## 拿它的 y 直接当 z 用就会比自己那格低 4，东西会掉到棋盘后面去 ——
## 骰子就是这么掉下去的（2026-08-27，团队试玩时发现）。
## 黏液覆膜：贴在格子顶面上，**比自己那格高、比剪影低**。
## 它是「地上有东西」，不是「这格被选中」—— 剪影、细胞、骰子都该压在它上面。
const Z_MUCUS := 0
const Z_MARK := 1    ## 高亮剪影
const Z_CELL := 2    ## 细胞
const Z_DICE := 3    ## 骰子

## **横跨好几排的一次性演出**（【免疫猎杀】准星）用这个，别走 tile_z()。
## 上面那套是给「站在一格上」的东西排深浅的；准星起手半径 72px，横跨四五排，
## 按排给它一个 z，下半圈就会被前排格子压掉 —— 2026-09-09 渲图逐帧确认过。
## 它本来就是个瞄准框，该盖在所有格子上面。
const Z_OVER_BOARD := 4096   ## RenderingServer.CANVAS_ITEM_Z_MAX


func tile_z(a: Vector2i, above: int) -> int:
	var key := axial_to_rc(a)
	if not map.has(key):
		return 0
	return int(map[key]["position"].y) + above

const MARK_MOVE := Color("30d1fa6e")     ## 可迁移/可移动：免疫青，0x6E ≈ 0.43
const MARK_ATTACK := Color("ffb03a6e")   ## 可攻击：癌方橙，同混合比例
const MARK_HOVER := Color("eaf8fc8f")    ## 鼠标所在格：提亮到 0.56
## 规划器画的路径：走得通用免疫青加深一档（比 MARK_MOVE 更实，一眼看出「这几格是我选的」），
## 走不通的那一步用癌方橙 —— 和「可攻击」同色不冲突：规划态里没有攻击格
const MARK_PLAN := Color("30d1fabf")
const MARK_PLAN_BAD := Color("ffb03abf")
const MARK_SELF := Color("eaf8fc47")     ## 当前行动的细胞脚下：淡到 0.28

var _marks: Node2D                  ## 高亮剪影与过场用的临时叠层
var _mucus_root: Node2D             ## 黏液覆膜层（见 set_mucus）
var _mucus_nodes := {}              ## 轴坐标 -> 那一格的覆膜 Sprite2D
var _necro_root: Node2D             ## 坏死纹理层（见 set_necrosis），压在黏液膜下面
var _necro_nodes := {}              ## 轴坐标 -> 那一格的坏死 Sprite2D
var _necro_tex: ImageTexture
var _mucus_tex: ImageTexture        ## 覆膜贴图，第一次用到时烤一张，之后所有格共用
var _mark_material: ShaderMaterial  ## 所有剪影共用一份

## 高亮的淡入淡出时长。**不能直接建/删节点**——候选格「啪」地整片出现太硬
## （团队 2026-08-27 反馈）。所以节点要复用：每帧重建的话补间永远走不完。
const MARK_FADE := 0.22
## 新出现的一批高亮**按同心圆由内向外逐环亮起**，和开场癌组织绽开是同一个语汇
## （团队 2026-08-27 要求）。每往外一环推迟这么多秒。
const MARK_RING_DELAY := 0.045

var _mark_nodes := {}    ## 轴坐标 -> Sprite2D
var _mark_target := {}   ## 轴坐标 -> 目标颜色；set_marks 传进来的那个
## fade_to_healthy() 建的过渡叠层。**必须留着句柄**：它们虽然挂在 `_marks` 下，
## 却不在 `_mark_target` / `_mark_nodes` 里，`set_marks({})` 清不掉。
## 而 board 是跨局复用的 —— 不主动取消的话，补间的回调会在**下一局**里把格子刷成健康贴图，
## 且贴图只在 `set_tissue()` 时更新、不是每帧重刷，那一格会一直错到它下次变状态为止。
var _fade_overs: Array[Sprite2D] = []
## 叠层身上那几条补间。**必须单独存着**，不能指望 `queue_free()` 顺手杀掉它们 ——
## `queue_free()` 是**延迟**删除（帧末才真删），而补间在同一帧里照跑。
## 机器负载高时单帧 delta 会远超淡出时长，补间当场跑完、回调落下
## （`tile.texture = want`），然后才轮到删节点 —— 于是 `cancel_fade()` 形同虚设。
## 这正是 2026-09-01 那条「一次红、五次绿」的不稳定断言的根因：
## 它不是随机失败，是**只在机器被压满时**失败。
var _fade_tweens: Array[Tween] = []
var _mark_tweens := {}   ## 轴坐标 -> 正在跑的补间


## 设置高亮：marks = { 轴坐标: 颜色 }。每次调用整体替换，传空字典即清空。
## 颜色的 alpha 就是与原格的混合比例（设计稿的候选格是 #30D1FA、alpha 0.43）。
##
## 一格一个节点、而不是一次性 _draw() 画完，是为了让高亮也吃组织块那套画家算法：
## 剪影的 z 只比自己那格高 1，仍然低于前一排，前排会正确盖住高亮的下半截 ——
## 高亮贴在棋盘上，而不是浮在整张棋盘上面。
##
## **本方法每帧都会被调用**（CWMatch 是全量刷新），所以目标没变时必须什么都不做，
## 否则补间会被无限重启、永远淡不完。
func set_marks(marks: Dictionary) -> void:
	for c: Vector2i in _mark_target.keys():
		if not marks.has(c):
			_mark_target.erase(c)
			var leaving: Sprite2D = _mark_nodes[c]
			_animate(c, Color(leaving.modulate.r, leaving.modulate.g,
				leaving.modulate.b, 0.0), true, 0.0)
	var fresh: Array[Vector2i] = []
	for c: Vector2i in marks:
		var want: Color = marks[c]
		if _mark_target.get(c) == want:
			continue
		_mark_target[c] = want
		if _mark_nodes.has(c):
			_animate(c, want, false, 0.0)   ## 已经在场的（比如悬停改色）立刻跟上，不排队
			continue
		var made := _make_mark(c, want)
		if made == null:
			_mark_target.erase(c)
			continue
		_mark_nodes[c] = made
		fresh.append(c)
	var delays := ring_delays(fresh, MARK_RING_DELAY)
	for c: Vector2i in fresh:
		_animate(c, marks[c], false, delays[c])


## 一批格子各自的入场延迟：按「离这批格子的**重心**几环」由内向外排队。
##
## 圆心取重心而不是棋盘中心，是为了让一条规则覆盖两种情况 ——
## 开局落子时整张棋盘都是候选，重心就是棋盘中心；
## 选迁移目标时只有周围几格，重心就是那个细胞。
## 抽成 static 是为了能直接测：环序错了肉眼只看得出「顺序怪」，说不清哪儿怪。
static func ring_delays(coords: Array, step: float) -> Dictionary:
	var out := {}
	if coords.is_empty():
		return out
	var cq := 0.0
	var cr := 0.0
	for c: Vector2i in coords:
		cq += c.x
		cr += c.y
	cq /= coords.size()
	cr /= coords.size()
	for c: Vector2i in coords:
		var dq: float = c.x - cq
		var dr: float = c.y - cr
		out[c] = (absf(dq) + absf(dr) + absf(dq + dr)) / 2.0 * step
	return out


## 把癌性组织交叉淡回健康组织（返回主菜单时用）。
## 直接换贴图会「啪」地一下；而两种贴图的**图案**不同，单靠调色也淡不过去 ——
## 所以在每格上盖一张健康贴图、alpha 0→1，淡完再把底下那张换掉、撤掉盖的那张。
func fade_to_healthy(seconds: float) -> void:
	for c in CWData.all_coords():
		var key := axial_to_rc(c)
		if not map.has(key):
			continue
		var tile: Sprite2D = map[key]["instance"]
		var want: Texture2D = TISSUE_TEX[CWData.special_of(c)][0]
		if tile.texture == want:
			continue
		var over := Sprite2D.new()
		over.texture = want
		over.position = tile.position
		over.z_index = tile_z(c, Z_MARK)
		over.modulate.a = 0.0
		_marks.add_child(over)
		_fade_overs.append(over)
		var tw := over.create_tween()
		_fade_tweens.append(tw)
		tw.tween_property(over, "modulate:a", 1.0, seconds)
		tw.tween_callback(func() -> void:
			tile.texture = want
			_fade_overs.erase(over)
			_fade_tweens.erase(tw)
			over.queue_free())


## 取消还没演完的「淡回健康」。开新局时必须调 —— 理由见 `_fade_overs` 的注释。
## 叠层一 free，绑在它身上的补间跟着死，回调也就不会再落到下一局的格子上。
func cancel_fade() -> void:
	## **先杀补间再删节点**，顺序不能反：queue_free() 帧末才生效，
	## 那之前补间还有机会跑完并把回调落到格子上。kill() 是立即的。
	for tw in _fade_tweens:
		if tw != null and tw.is_valid():
			tw.kill()
	_fade_tweens.clear()
	for o in _fade_overs:
		if is_instance_valid(o):
			o.queue_free()
	_fade_overs.clear()


func _make_mark(c: Vector2i, want: Color) -> Sprite2D:
	var key := axial_to_rc(c)
	if not map.has(key):
		return null
	var tile: Sprite2D = map[key]["instance"]
	var s := Sprite2D.new()
	s.texture = tile.texture
	s.material = _mark_material
	s.position = tile.position
	s.z_index = tile_z(c, Z_MARK)
	s.modulate = Color(want.r, want.g, want.b, 0.0)   ## 从全透明淡进来
	_marks.add_child(s)
	return s


func _animate(c: Vector2i, to: Color, leaving: bool, delay: float) -> void:
	var s: Sprite2D = _mark_nodes[c]
	var running: Tween = _mark_tweens.get(c)
	if running != null and running.is_valid():
		running.kill()                ## 半路改目标（比如悬停）时接着当前值走
	var tw := s.create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.tween_property(s, "modulate", to, MARK_FADE)
	_mark_tweens[c] = tw
	if leaving:
		tw.tween_callback(func() -> void:
			_mark_nodes.erase(c)
			_mark_tweens.erase(c)
			s.queue_free())


## ── 按对局状态换贴图 ────────────────────────────────────────────
## 贴图表：每种特殊组织一对 [健康, 癌性]。
## **固化癌组织暂时和普通癌组织同贴图**（硬化外壳还没画），靠 set_marks() 的色标区分——这处仍等美术。
## 癌变血管 2026-09-08 补上：顶面取普通癌组织那个红（Kevin 拍的 A 案），
## 青色血管图标与侧面照另两对的变色规律，所以四种癌变格仍能一眼分清。
const TISSUE_TEX := {
	CWData.Special.NONE: [HEALTH, CANCER],
	CWData.Special.CORE: [ENERGYH, ENERGYC],
	CWData.Special.MARROW: [MARROWH, MARROWC],
	CWData.Special.VESSEL: [VESSELH, VESSELC],
}
## 骨髓**空仓**时改用这一对（Kevin 2026-09-08：「把卡抽了以后贴图不变」）。
## 积累进度那圈其实是变的（1.0 → 0），但一圈细边不够醒目 —— 图标里的骨头有没有，
## 隔着半个屏幕都看得出。**只有骨髓分两套**：代谢核心存的是连续的能量、
## 没有「有 / 没有」这种二态，它继续靠进度环表达。
const MARROW_EMPTY_TEX := [MARROWH_E, MARROWC_E]
const MARROW_PENDING_TEX := [MARROWH_P, MARROWC_P]


## 贴图没变就什么都不做，所以对局那边可以每帧无脑全刷 127 格，不必自己记脏标记。
## `stocked` / `pending` 只对**骨髓**有意义：仓里有没有卡 / 进度到头但卡还没结算
## （`CWData.store_pending`，pending 压过 stocked）。其余组织忽略它们。
func set_tissue(a: Vector2i, tissue: int, special: int, stocked: bool = true,
		solid: float = 0.0, pending: bool = false) -> void:
	var key := axial_to_rc(a)
	if not map.has(key):
		return
	var t: Sprite2D = map[key]["instance"]
	var i: int = 0 if tissue == CWData.Tissue.HEALTHY else 1
	var tex: Texture2D = TISSUE_TEX[special][i]
	if special == CWData.Special.MARROW:
		if pending:
			tex = MARROW_PENDING_TEX[i]
		elif not stocked:
			tex = MARROW_EMPTY_TEX[i]
	if solid > 0.0:
		var stone: Texture2D = _solid_tex(a, tissue, special, stocked, solid, pending)
		if stone != null:
			tex = stone
	if t.texture != tex:
		t.texture = tex


## 一次把石化族全读进来。**按命名约定拼路径**而不是写 28 行 preload ——
## 生成器改变体数时这边只改 SOLIDIFY_BASES 的数字，不必跟着抄一遍文件名。
## （导出预设是 `export_filter="all_resources"`、只排除 `tests/*`，所以 load() 的也进包。）
func _load_solidify() -> void:
	for base: String in SOLIDIFY_BASES:
		var steps: Array = []
		for c: int in SOLIDIFY_STEPS:
			var variants: Array[Texture2D] = []
			for v in int(SOLIDIFY_BASES[base]):
				variants.append(load("res://assets/art/solidify/%s_%02d_%d.png" % [base, c, v]))
			steps.append(variants)
		_solidify[base] = steps


## 这一格该用石化族里的哪一张；不该石化（健康 / 血管）返回 null。
##
## **档位向上取整**：任何非零进度都至少画第一档 —— 刚攒上 0.5 的格子和干净格子长得一样
## 的话，这套贴图就白做了。
## **变体按格坐标定，不掷骰子**：这个函数每帧对 127 格各跑一次，
## 用随机数的话同一格的图案会逐帧乱跳。
func _solid_tex(a: Vector2i, tissue: int, special: int, stocked: bool,
		solid: float, pending: bool = false) -> Texture2D:
	if tissue == CWData.Tissue.HEALTHY:
		return null
	var base: String = SOLID_BASE_OF.get(special, "")
	if special == CWData.Special.MARROW and pending:
		base = "marrow_pending_cancer"
	elif special == CWData.Special.MARROW and not stocked:
		base = "marrow_empty_cancer"
	if not _solidify.has(base):
		return null
	var steps: Array = _solidify[base]
	var step: int = clampi(int(ceil(solid * steps.size())) - 1, 0, steps.size() - 1)
	var variants: Array = steps[step]
	return variants[absi(a.x * 7 + a.y * 13) % variants.size()]


## 代谢核心 / 骨髓的积累进度外圈：`frac` 0~1，**负数 = 不是特殊组织，不画**。
## `tissue` 挑健康 / 病变那一对贴图（固化格算病变，同 set_tissue）。
## 骨髓「进度到头但卡还没结算」那一档**不在这里表达**：环照常画满，只有图标淡
## （`set_tissue` 的 pending；Kevin 2026-09-11 定的）。
## 满仓不再另换亮色：贴图只有「底 / 满」两档，「可以来拿了」靠整圈亮 + 骨髓图标里的骨头。
##
## 同 `set_tissue()` 的用法：对局那边每帧无脑全刷。
func set_store(a: Vector2i, frac: float, special: int, tissue: int = CWData.Tissue.HEALTHY) -> void:
	var key := axial_to_rc(a)
	if not map.has(key):
		return
	var t: Sprite2D = map[key]["instance"]
	var show: bool = frac >= 0.0 and STORE_LIT.has(special)
	var ring := t.get_node_or_null("StoreRing") as Sprite2D
	if ring == null:
		return
	ring.visible = show
	if not show:
		return
	var i: int = 0 if tissue == CWData.Tissue.HEALTHY else 1
	var lit: Texture2D = STORE_LIT[special][i]
	if ring.texture != lit:
		ring.texture = lit
	var mat := ring.material as ShaderMaterial
	mat.set_shader_parameter("track_tex", STORE_TRACK[special][i])
	mat.set_shader_parameter("progress", frac)


## 直接指定某格的贴图（【E-侵蚀】过场用）。
##
## **不留状态**：`set_tissue()` 下一帧就会把它换回按组织算的那张，
## 所以调用方必须**每帧**都调 —— 停了自动还原。这样棋盘不必知道「谁在演什么」，
## 也不会和高亮剪影抢 Z_MARK 那一层（过场是把格子本身画成别的样子，不是盖一层）。
func set_tile_tex(a: Vector2i, tex: Texture2D) -> void:
	var key := axial_to_rc(a)
	if not map.has(key):
		return
	var t: Sprite2D = map[key]["instance"]
	if t.texture != tex:
		t.texture = tex


## 给一格挂上进度外圈的覆盖层。**只有核心和骨髓有**，别的格连节点都不建 ——
## 127 格里只有 9 格用得上，全建等于白养 118 个带 shader 的节点。
func _add_store_ring(s: Sprite2D) -> void:
	var ring := Sprite2D.new()
	ring.name = "StoreRing"    ## 贴图（「满」）与「底」由 set_store() 按组织 / 健康病变每帧给
	ring.z_index = 1
	ring.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var mat := ShaderMaterial.new()
	mat.shader = STORE_SHADER
	ring.material = mat
	ring.visible = false
	s.add_child(ring)


func new_tissue(i, j, x, y):
	var new_t = TISSUE.instantiate()
	new_t.position = Vector2(x, y)
	new_t.z_index = y
	if Vector2(i, j) in energy_position or Vector2(i, j) in marrow_position:
		_add_store_ring(new_t)
	if Vector2(i, j) in vessel_position:
		new_t.texture = VESSELH
	elif Vector2(i, j) in energy_position:
		new_t.texture = ENERGYH
		##new_t.texture = ENERGYC
	elif Vector2(i, j) in marrow_position:
		new_t.texture = MARROWH
		##new_t.texture = MARROWC
	else:
		new_t.texture = HEALTH
		##new_t.texture = CANCER
	map[Vector2(i, j)] = {
		"instance": new_t,
   		"position": Vector2(x, y)
	}
	add_child(new_t)
	
func _ready():
	_load_solidify()
	vessel_position = CWData.VESSELS.map(axial_to_rc)
	energy_position = CWData.CORES.map(axial_to_rc)
	marrow_position = CWData.MARROWS.map(axial_to_rc)
	_grid()
	_mark_material = ShaderMaterial.new()
	_mark_material.shader = SILHOUETTE
	_marks = Node2D.new()
	_marks.name = "Marks"
	add_child(_marks)
	## 黏液覆膜挂在高亮剪影**前面**建：两者的 z 只差 1（Z_MUCUS 0 / Z_MARK 1），
	## 万一以后有人把它们调成一样，先建的在下 —— 覆膜本来就该在剪影底下
	_necro_root = Node2D.new()
	_necro_root.name = "Necrosis"
	add_child(_necro_root)
	move_child(_necro_root, _marks.get_index())
	_mucus_root = Node2D.new()
	_mucus_root.name = "Mucus"
	add_child(_mucus_root)
	move_child(_mucus_root, _marks.get_index())


## 按棋盘半径重建组织格网格（教程小棋盘用；正式局仍是 127 格一张不变）。
## Main 只有一张棋盘，教程跨章换半径时全量重建：先清旧格、复位游标、再铺新格。
func build_for(board_radius: int) -> void:
	var want: int = board_radius + 1
	if want == radius and not map.is_empty():
		return
	for key in map:
		var t: Node = map[key]["instance"]
		if t != null:
			t.queue_free()
	map.clear()
	radius = want
	first_x = -100
	first_y = -120
	_grid()


func _grid() -> void:
	for i in range(0, radius*2-1):
		if i < radius-1:
			for j in range(0, radius+i):
				new_tissue(i+1, j+1, first_x+distance_x*j, first_y+distance_y*i)
		else:
			for j in range(0, radius*3-i-2):
				new_tissue(i+1, j+1, first_x+distance_x*j, first_y+distance_y*i)
		if i < radius-1:
			first_x -= distance_x/2
		else:
			first_x += distance_x/2


# ============ 黏液覆膜 ============
#
# 印戒【黏液破裂】留下的「黏液侵染」。**照 `tools/art-preview` 的「黏液纹理 A」**
# （`catalog.js` 的 `initialSelections.mucus = 0`，README：「保留用户原页面已选的黏液纹理 A」）
# —— 选稿那句标注写得很清楚：**半透明覆膜 · 保留底层组织识别**。
#
# 所以它不是给格子换一种颜色，而是**在顶面上摊一层薄膜**：两片压扁的橄榄色椭圆
# 错开叠着，加两道高光流痕和一个亮点。底下是健康还是癌变照样看得出来，
# 这正是它和「色标」的区别 —— 色标会把整格染成一个颜色，那样癌组织就不像癌组织了。
#
# 选稿那份画在 canvas 上，坐标单位和这里**完全一样**：`tools/art-preview/draw.js`
# 的 `tile()` 直接贴的就是 `game/assets/art/tissue_normal.png`，缩放 1，
# 而它把贴图摆在 `y+4` —— 也就是说选稿里的 (x, y) 就是本文件的 `tile_center()`。
# 下面的半径、偏移、颜色是逐个照抄的，改之前先回去看那份选稿。

## 覆膜贴图在本地坐标里的原点偏移（贴图左上角相对顶面中心）。
## 画的东西横跨 x∈[-11,12)、y∈[-5,7)，所以是 23×12 的一张小图。
const MUCUS_ORIGIN := Vector2i(11, 5)
const MUCUS_SIZE := Vector2i(23, 12)
const MUCUS_ALPHA := 0.68           ## 选稿里的 globalAlpha


## 哪些格子有黏液。传轴坐标的数组；没变就什么都不做。
func set_mucus(cells: Array) -> void:
	var want := {}
	for c: Vector2i in cells:
		want[c] = true
	for c: Vector2i in _mucus_nodes.keys():
		if not want.has(c):
			var gone: Sprite2D = _mucus_nodes[c]
			_mucus_nodes.erase(c)
			if is_instance_valid(gone):
				gone.queue_free()
	for c: Vector2i in want:
		if _mucus_nodes.has(c) or not map.has(axial_to_rc(c)):
			continue
		var s := Sprite2D.new()
		s.texture = _mucus_film()
		s.centered = false
		s.position = tile_center(c) - Vector2(MUCUS_ORIGIN)
		s.z_index = tile_z(c, Z_MUCUS)
		_mucus_root.add_child(s)
		_mucus_nodes[c] = s


## 烤一张覆膜贴图，之后所有格共用。**只烤一次** —— 每格一张的话 19 格就是 19 份
## 一模一样的像素，而这层膜每格长得完全一样（选稿里也没有随格变化的项）。
##
## 为什么烤成贴图而不是每帧 `_draw()`：选稿那两片椭圆是**逐像素**填的
## （`draw.js` 的 `disc` 就是双重循环），一格两百多个 1px 方块，十九格就是四千多次
## 绘制调用。烤成 23×12 的贴图之后每格只剩一次 `draw_texture`。
## 坏死格的纹理（issue #15，2026-09-11；选稿 textures.js necrosis v0「灰色干枯」）：整格灰褐底、
## 两处短裂纹、两点淡色。此前坏死**根本没画**（只有悬停详情栏说一句），T 细胞放完毒素地上什么都看不出。
## 覆在组织贴图上、压在黏液膜下面；贴图**只烤一次**，理由同 _mucus_film。
const NECRO_ORIGIN := Vector2i(16, 10)
const NECRO_SIZE := Vector2i(33, 29)
const Z_NECRO := 0


func set_necrosis(cells: Array) -> void:
	var want := {}
	for c: Vector2i in cells:
		want[c] = true
	for c: Vector2i in _necro_nodes.keys():
		if not want.has(c):
			var gone: Sprite2D = _necro_nodes[c]
			_necro_nodes.erase(c)
			if is_instance_valid(gone):
				gone.queue_free()
	for c: Vector2i in want:
		if _necro_nodes.has(c) or not map.has(axial_to_rc(c)):
			continue
		var s := Sprite2D.new()
		s.texture = _necrosis_film()
		s.centered = false
		s.position = tile_center(c) - Vector2(NECRO_ORIGIN)
		s.z_index = tile_z(c, Z_NECRO)
		_necro_root.add_child(s)
		_necro_nodes[c] = s


func _necrosis_film() -> ImageTexture:
	if _necro_tex != null:
		return _necro_tex
	var img := Image.create(NECRO_SIZE.x, NECRO_SIZE.y, false, Image.FORMAT_RGBA8)
	var base := Color("686761")
	var dark := Color("393d3b")
	var light := Color("939084")
	## 选稿的 tissueHex：先铺侧面（−10..18 行），再铺顶面（−10..10 行），行宽按六边形收窄
	for row in range(-10, 19):
		var span := floori(16.0 - maxf(0.0, maxf(float(-row - 5), float(row - 13))) * 3.2)
		_necro_line(img, -span, row, span, row, dark)
	for row in range(-10, 11):
		var span := floori(16.0 - maxf(0.0, float(absi(row) - 5)) * 3.2)
		_necro_line(img, -span, row, span, row, base)
	_necro_line(img, -9, -2, -3, 0, dark)
	_necro_line(img, -3, 0, 2, -3, dark)
	_necro_line(img, 5, 4, 10, 3, dark)
	for j in 2:
		for i in 2:
			_necro_px(img, -8 + i, 4 + j, light)
			_necro_px(img, 7 + i, -5 + j, light)
	_necro_tex = ImageTexture.create_from_image(img)
	return _necro_tex


func _necro_line(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	var n: int = maxi(maxi(absi(x1 - x0), absi(y1 - y0)), 1)
	for i in range(n + 1):
		var t := float(i) / float(n)
		_necro_px(img, roundi(lerpf(x0, x1, t)), roundi(lerpf(y0, y1, t)), col)


func _necro_px(img: Image, x: int, y: int, col: Color) -> void:
	var px: int = x + NECRO_ORIGIN.x
	var py: int = y + NECRO_ORIGIN.y
	if px < 0 or py < 0 or px >= NECRO_SIZE.x or py >= NECRO_SIZE.y:
		return
	img.set_pixel(px, py, col)


func _mucus_film() -> ImageTexture:
	if _mucus_tex != null:
		return _mucus_tex
	var img := Image.create(MUCUS_SIZE.x, MUCUS_SIZE.y, false, Image.FORMAT_RGBA8)
	## 选稿的 `mucus(c, x, y, 0)`，逐笔照抄（颜色与半径见那边的 textures.js）
	_film_disc(img, 0, 1, 11.0, 0.5, Color("789a42"))
	_film_disc(img, -3, 0, 8.0, 0.45, Color("b6c970"))
	_film_line(img, -9, 1, -6, -2, Color("e1eaaa"))
	_film_line(img, 5, 3, 9, 1, Color("e1eaaa"))
	_film_rect(img, 3, -2, 2, Color("dfeaaa"))
	_mucus_tex = ImageTexture.create_from_image(img)
	return _mucus_tex


## 压扁的实心椭圆，判据和取整方式和选稿的 `disc()` 一模一样
func _film_disc(img: Image, cx: int, cy: int, r: float, squash: float, col: Color) -> void:
	var ry: int = int(ceil(r * squash))
	for j in range(-ry, ry + 1):
		for i in range(-int(ceil(r)), int(ceil(r)) + 1):
			if float(i * i) / (r * r) + float(j * j) / (r * r * squash * squash) <= 1.0:
				_film_px(img, cx + i, cy + j, col)


## 选稿的 `line()`：按较长那一边的步数走，逐点落 1px（不是抗锯齿直线）
func _film_line(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	var n: int = maxi(maxi(absi(x1 - x0), absi(y1 - y0)), 1)
	for i in range(n + 1):
		var t := float(i) / float(n)
		_film_px(img, int(round(lerpf(x0, x1, t))), int(round(lerpf(y0, y1, t))), col)


## 选稿的 `pixel(..., size)`：从 (x, y) 往右下铺 size×size
func _film_rect(img: Image, x: int, y: int, size: int, col: Color) -> void:
	for j in size:
		for i in size:
			_film_px(img, x + i, y + j, col)


## 往图上落一点。**source-over 合成**，和 canvas 里 `globalAlpha` 逐笔叠的结果一致
## （合成有结合律：先把几笔叠成一张膜、再整张盖到格子上，等于一笔笔盖过去）。
func _film_px(img: Image, x: int, y: int, col: Color) -> void:
	var px: int = x + MUCUS_ORIGIN.x
	var py: int = y + MUCUS_ORIGIN.y
	if px < 0 or py < 0 or px >= MUCUS_SIZE.x or py >= MUCUS_SIZE.y:
		return
	var dst := img.get_pixel(px, py)
	var sa := MUCUS_ALPHA
	var out_a: float = sa + dst.a * (1.0 - sa)
	if out_a <= 0.0:
		img.set_pixel(px, py, Color(0, 0, 0, 0))
		return
	img.set_pixel(px, py, Color(
		(col.r * sa + dst.r * dst.a * (1.0 - sa)) / out_a,
		(col.g * sa + dst.g * dst.a * (1.0 - sa)) / out_a,
		(col.b * sa + dst.b * dst.a * (1.0 - sa)) / out_a,
		out_a))
