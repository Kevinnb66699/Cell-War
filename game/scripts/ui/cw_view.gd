## cw_view.gd —— 机位：把棋盘上的「看点」摆到屏幕的「锚点」，再按 zoom 放大
##
## 全工程只有一台相机。主菜单和对局共用它，「开始对局」的过场就是在
## 下面两组参数之间插值 —— 所以这两组参数必须放在一起，而不是各自散在两个界面里。
##
## 看点(look_at)：相对**中央格贴图中心**的偏移，单位是棋盘像素。
## 锚点(anchor)：这个看点要落在 960×540 画布上的哪个位置。
## 两者加 zoom 就唯一确定了相机位置，反解见 camera_pos_for()。
class_name CWView
extends RefCounted

## ── 菜单机位（定稿原型的 CAM_MENU）──
const MENU_ZOOM := 3.2
const MENU_LOOK_AT := Vector2(-40, -10)
const MENU_ANCHOR := Vector2(595, 227)

## ── 对局机位（定稿「方案戊」：右侧让出 264px 竖条；2026-09-07 起左侧再让出一条出牌列）──
##
## 棋盘包围盒 464×274 棋盘像素。原先 ×1.45 = 673×397，锚点 348，棋盘落在 x 12..685，
## 与设计稿逐像素一致 —— 但那样**左边一格空间都不剩**，2026-09-06 加的左侧事件列直接压住了
## 棋盘左上角 21 格（Kevin 看出来的）。所以 2026-09-07 起：
##   左边让出 LEFT_STRIP（出牌列 CWFeed，与手牌同宽 72）+ GUTTER，右边照旧让出 PANEL_WIDTH + GUTTER，
##   中间 600px 装棋盘 → zoom 1.27（比原来小 12%），锚点取中间那段的中点 388。
## 三个数是**一起算出来的**，改任何一个都要重算另外两个（`t_view_left_strip` 盯着这条关系）。
##
## 为什么是竖条而不是底部横条：横向自由空间的增长速度是纵向的两倍，
## 同样让出 264px，放在右边只要缩到 1.45，放在底部要缩到 1.01（团队 2026-08-27 定）。
const GAME_ZOOM := 1.27
const GAME_LOOK_AT := Vector2.ZERO       ## 看棋盘正中 —— 中央格的贴图中心正是包围盒中心
const GAME_ANCHOR := Vector2(388, 270)
const PANEL_WIDTH := 264                 ## 右侧竖条宽度，HUD 与本机位必须用同一个数
const LEFT_STRIP := 72                   ## 左侧出牌列宽度 = 手牌卡宽，CWFeed.RECT 必须用同一个数
const GUTTER := 8                        ## 棋盘与两侧竖条之间的缝


## ── 教程机位（新手教程 v2 · S3，2026-09-19）──
##
## 教程前三关只露两到二十格，用对局机位（1.27）它只有指甲盖大 ⇒ **按活跃格集合推近**。
## PRD 04:08 版给关卡模板加了「镜头变化」一项（PRD:9-22）：
##   `地图调中/左/右`   —— 让**整张活跃地图**落在镜头中央 / 偏左 / 偏右
##   `玩家调中/左/右`   —— 让**玩家那只细胞**落在镜头中央 / 偏左 / 偏右
##   竖直方向一律居中（PRD 的「默认情况下调整后竖直方向地图/角色是居中的」）。
## 数据里写成 `ui.camera = {"anchor":"map"|"player", "align":"center"|"left"|"right"}`。
const TUTOR_MAX_ZOOM := 4.0      ## 再近就能看出贴图边缘的插值（方向稿 A 第一关用的就是 4.0）
## 包围盒左右各让半格 **+ 1px**（2026-09-20）：第三关那条 13 格宽的横带按 18 算出来正好把可用区顶满
## （zoom 1.282），两端那格的边正好落在镜头框上，相机位置一取整就切掉一个亚像素、通用规则 13 判成
## 「不整格可见」（`t_tutor_c1` 真算一遍抓到的）。多让 1px 就是 1px 的余量，别的关看不出差别
const TUTOR_PAD_X := 19.0
const TUTOR_PAD_TOP := 34.0      ## 上边多让一个身位：格子上站着的细胞比顶面高一整个身位
const TUTOR_PAD_BOTTOM := 24.0
## 镜头的竖向可用带：上缘让过出牌列的顶（`CWFeed.RECT` y=76），下缘让到行动栏的顶
## （`CWActionBar.BAR_RECT` y=476）。**中点 276 不当锚点用** —— 锚点取 `GAME_ANCHOR.y`，
## 小棋盘与整盘机位的竖向位置才对得齐，第三关（推近）切第四关（整盘）时棋盘不上下跳
const TUTOR_BAND := Vector2(76.0, 476.0)
## 「偏左 / 偏右」= 把目标放在镜头横向的三分之一 / 三分之二处
const TUTOR_ALIGN := { "left": 1.0 / 3.0, "center": 0.5, "right": 2.0 / 3.0 }
## 一格**连缝**的半宽 / 半高（棋盘像素），取景与「整格可见」判定用：
## 横向邻格相距 36 ⇒ 半宽 18；行距 20 ⇒ 半高 10 ×（顶面比行距高的那一点）。
## 提亮层描的六边形框走的是贴图顶面本身（`cw_tutor_spot.gd` 的 `FACE_HALF_*`，32×26），比这个小一圈
const TILE_HALF := Vector2(18.0, 13.34)


## 棋盘可用的那一段横向区间 [左, 右]。机位、出牌列、右侧竖条三者的唯一真相。
static func board_span() -> Vector2:
	return Vector2(LEFT_STRIP + GUTTER * 2, screen_size().x - PANEL_WIDTH - GUTTER)


## 教程镜头的横向可用区间 [左, 右]：右栏关着的那几关（第一、二关）把那 264px 也让给棋盘
static func tutor_span(sidebar: bool) -> Vector2:
	if sidebar:
		return board_span()
	return Vector2(LEFT_STRIP + GUTTER * 2, screen_size().x - GUTTER)


## 镜头矩形：这一刻屏幕上真正归棋盘的那一块（通用规则 13 的「镜头框」就是它）
static func tutor_view_rect(sidebar: bool) -> Rect2:
	var span := tutor_span(sidebar)
	return Rect2(span.x, TUTOR_BAND.x, span.y - span.x, TUTOR_BAND.y - TUTOR_BAND.x)


## 一组格在**棋盘坐标**里的包围盒（已让出细胞的身位）。空集合 → 零矩形
static func tiles_box(board: Node2D, tiles: Array) -> Rect2:
	if tiles.is_empty():
		return Rect2()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c: Vector2i in tiles:
		var p: Vector2 = board.tile_center(c)
		lo = Vector2(minf(lo.x, p.x - TUTOR_PAD_X), minf(lo.y, p.y - TUTOR_PAD_TOP))
		hi = Vector2(maxf(hi.x, p.x + TUTOR_PAD_X), maxf(hi.y, p.y + TUTOR_PAD_BOTTOM))
	return Rect2(lo, hi - lo)


## 把包围盒塞进可用区要多大倍率。**纯函数**：顶到 `max_zoom` 封顶，低于对局机位也不再拉远
## —— 比 1.27 还远的机位在这套 HUD 里没有意义（棋盘会缩到出牌列与右栏之间的一条）
static func tutor_zoom(box: Rect2, avail: Vector2, max_zoom := TUTOR_MAX_ZOOM) -> float:
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return GAME_ZOOM
	return clampf(minf(avail.x / box.size.x, avail.y / box.size.y), GAME_ZOOM, max_zoom)


## 这一刻的取景参数 `{zoom, look_at, anchor}`。
## `tiles` = 棋盘的活跃格集合，`focus` = 「玩家调…」时玩家那一格（null = 「地图调…」）。
## **整盘就是对局机位**（第四关起）：不走近似，直接给 `GAME_*` 那三个数，
## 免得第三关切第四关时棋盘漂一两像素。
## ★ **「玩家调…」那几档除外**（S9a）：间章分镜 2 的重心平移靠的就是「重装前后玩家都在
## 屏幕同一点」—— 这时若退回整盘机位（看的是盘心），玩家换坐标那一瞬间整张图会跳一下。
## 所以有 `focus` 时看点仍取玩家那一格，**但倍率照样钉死在对局机位**：
## 127 格的包围盒按可用区算出来是 1.282、397 格的算出来是 1.27，跟着算就会在重装那一瞬间缩一下。
static func tutor_framing(board: Node2D, tiles: Array, align: String, focus: Variant,
		sidebar: bool) -> Dictionary:
	var full := tiles.size() >= CWData.all_coords().size()
	if full and focus == null:
		return { "zoom": GAME_ZOOM, "look_at": GAME_LOOK_AT, "anchor": GAME_ANCHOR }
	var span := tutor_span(sidebar)
	var avail := Vector2(span.y - span.x, TUTOR_BAND.y - TUTOR_BAND.x)
	var box := tiles_box(board, tiles)
	var zoom := GAME_ZOOM if full else tutor_zoom(box, avail)
	## 看点：地图 = 包围盒中心；玩家 = 他站的那一格顶面中心。两者都是相对**贴图中心**的偏移
	var at: Vector2 = box.get_center()
	if focus != null:
		at = board.tile_center(focus as Vector2i)
	var k: float = float(TUTOR_ALIGN.get(align, 0.5))
	return {
		"zoom": zoom,
		"look_at": at - board_origin(board),
		"anchor": Vector2(span.x + (span.y - span.x) * k, GAME_ANCHOR.y),
	}


## 由「看哪儿 / 摆到屏幕哪儿 / 放多大」反推相机该站在哪儿。
## 是 static 的，好让无头测试直接核对这套换算，不用真开窗口。
## 第一个参数别叫 look_at —— Node2D 自带同名方法，会报遮蔽警告。
static func camera_pos_for(focus: Vector2, anchor: Vector2, zoom: float, screen: Vector2) -> Vector2:
	return focus - (anchor - screen / 2.0) / zoom


## 工程设置里的设计分辨率（架构约定 #12：960×540，不要改）
static func screen_size() -> Vector2:
	return Vector2(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))


## 棋盘包围盒的中心，也就是中央格的**贴图中心**。
## tile_center() 给的是顶面中心，要加回那 4px —— 看点偏移都是相对贴图中心量的。
static func board_origin(board: Node2D) -> Vector2:
	return board.tile_center(Vector2i.ZERO) + Vector2(0, board.TOP_FACE_DY)


## 棋盘上的一点 → 屏幕坐标。
## HUD 挂在 CanvasLayer 上、用的是屏幕坐标系，所以「从棋盘上某个细胞身上飞出一张卡」
## 这类跨层动画必须先换算一次。
static func board_to_screen(camera: Camera2D, p: Vector2) -> Vector2:
	return screen_size() / 2.0 + (p - camera.position) * camera.zoom.x


## 把相机摆到指定机位。
static func apply(camera: Camera2D, board: Node2D, zoom: float,
		look_at: Vector2, anchor: Vector2) -> void:
	camera.zoom = Vector2(zoom, zoom)
	camera.position = camera_pos_for(
		board_origin(board) + look_at, anchor, zoom, screen_size())


## 在菜单机位和对局机位之间插值：k=0 菜单，k=1 对局。开场推进与返场都走这里。
##
## **插的是「看点 / 锚点 / zoom」这三个取景参数，不是相机的 position。**
## 投影是 `(点 - 相机) × zoom`，position 和 zoom 各自线性插的话，乘出来并不线性 ——
## 实测棋盘横移的「最快 / 平均」速度比会到 1.76（插取景参数只有 1.26），
## 前半程就走完 70% 的横移、后半程在爬；再叠上 easeOutCubic 就是开头很冲、结尾拖沓。
## 两端都对、中间不对，正是这类「取景游走」最难查的地方。
##
## **zoom 走几何（对数）插值**：视觉上的缩放速度取决于每帧的**倍率**而不是差值，
## 线性插 3.2→1.45 的话倍率不匀。
static func blend(camera: Camera2D, board: Node2D, k: float) -> void:
	var zoom: float = MENU_ZOOM * pow(GAME_ZOOM / MENU_ZOOM, k)
	apply(camera, board, zoom,
		MENU_LOOK_AT.lerp(GAME_LOOK_AT, k), MENU_ANCHOR.lerp(GAME_ANCHOR, k))


## 两组**任意**取景参数之间插值（教程关间 / 关内换 step 的镜头补间走它）。
## 口径与 `blend()` 一字不差：插的是「看点 / 锚点 / zoom」，**不是相机的 position**，
## 而且 zoom 走几何（对数）插值 —— 理由见 `blend()` 上面那三段，这里不再抄一遍
static func blend_to(camera: Camera2D, board: Node2D, a: Dictionary, b: Dictionary,
		k: float) -> void:
	var za: float = float(a["zoom"])
	var zb: float = float(b["zoom"])
	apply(camera, board, za * pow(zb / za, k),
		(a["look_at"] as Vector2).lerp(b["look_at"] as Vector2, k),
		(a["anchor"] as Vector2).lerp(b["anchor"] as Vector2, k))


## **PRD 通用规则 13**（PRD:65，04:08 版新增）：禁止玩家向镜头外 / 被镜头框切割的格子迁移。
## 「整格在镜头内」= 这一格顶面的外接矩形**完全**落在镜头矩形里；擦着边也算切到。
## **纯函数**：教程镜头会补间，这条每次都拿**当下**的相机算 —— 补间没走完就还没放开
## （测试 `t_tutor_camera` 正反两面各一条）
static func tile_fully_visible(camera: Camera2D, board: Node2D, at: Vector2i,
		view: Rect2) -> bool:
	if camera == null or board == null:
		return true
	var half: Vector2 = TILE_HALF * camera.zoom.x
	var c: Vector2 = board_to_screen(camera, board.tile_center(at))
	return view.encloses(Rect2(c - half, half * 2.0))
