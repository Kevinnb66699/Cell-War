## guide_spotlight.gd —— 新手引导的「提亮区域」：把剧本每一步的 flag 变成屏幕上一圈脉冲描边
##
## 引导面板只负责说「看这里」（CWGuide.highlight_flag()），这里负责把「这里」找出来并画上：
## HUD 元素（右栏某一行、行动栏某个按钮、手牌抽屉、回合数……）用矩形描边，
## 棋盘格（特殊组织、癌细胞脚下、可落子的格……）用六边形描边。每帧由 CWMatch 喂当前 flag（sync），
## 目标每帧现算 —— 棋盘会缩放、按钮会出没、细胞会移动，缓存反而容易画在旧位置上。
##
## 只画不挡：mouse_filter 一律 IGNORE，压在 HUD 之上、引导面板之下。找不到目标（比如这一步教的按钮
## 此刻不在行动栏上）就什么都不画，不报错 —— 教程不硬锁步，提亮只是帮新手把视线放对地方。
## Kevin 2026-09-05 拍板做完整版：剧本用到的每个 flag 都在 FLAGS 表里有归宿，测试盯着不许漏。
class_name CWGuideSpotlight
extends Control

## 脉冲：一秒多一点走完一个亮暗周期，够醒目又不像报警
const PULSE_PERIOD := 1.2
const ALPHA_LO := 0.35
const ALPHA_HI := 0.95
const LINE_W := 2.0
const GROW := 4.0          ## 矩形描边往外让几像素，别压在元素自己的描边上
## 顶面六边形：横向邻格相距 36、行距 20、隔行错半格 —— 一张被竖向压扁的正六边形网格（board.gd hex_at 的推导）。
## 尖顶六边形外接圆半径 36/√3 ≈ 20.78，纵向再乘压扁比 20 ÷ (36·√3/2) ≈ 0.641，顶面高 ≈ 26.7px，和贴图顶面 26px 对上
const HEX_R := 36.0 / sqrt(3.0)
const HEX_SQUASH := 20.0 / (36.0 * sqrt(3.0) / 2.0)

## 剧本 flag → 目标种类（sync() 里 match 的分支名）。剧本新加 flag 必须先在这里登记，t_guide_spotlight 盯着；
## 空串 = 这一步刻意什么都不亮（收尾页）
const FLAGS := {
	"board": "board",                ## 整张棋盘一个包围框
	"special": "special",            ## 代谢核心 / 骨髓 / 血管各描一圈
	"place": "place",                ## 可落子且紧邻癌区的健康格（剧本建议的位置）
	"energy": "energy",              ## 右栏里你自己那一行（能量数在那）
	"move": "move",                  ## 行动栏「迁移」按钮
	"purify": "purify",              ## 你脚边可净化的癌组织
	"end": "end",                    ## 右栏「结束回合」按钮
	"attack": "enemy",               ## 癌细胞脚下
	"d6": "enemy",                   ## 骰子会落在目标格上方 —— 同样描癌细胞脚下
	"attack_limit": "bar",           ## 整条行动栏（攻击用完选项会从这里消失）
	"draw": "draw",                  ## 行动栏「基因表达」按钮
	"card_kinds": "hand",            ## 左下角手牌抽屉
	"hand_card": "hand",
	"hand_limit": "pips",            ## 右栏你那一行的手牌方块
	"differentiate": "differentiate",## 行动栏「分化」按钮；还没解锁就描右栏「免疫等级」块
	"round": "round",                ## 右栏顶部回合 / 阶段块
	"cancer_grow": "enemy",
	"immune_defend": "own",          ## 你的免疫细胞脚下
	"world_event": "world_event",    ## 右栏回合块（事件行在那）+ 左上角「对局日志」入口
	"graduated": "",
}

var rects: Array[Rect2] = []     ## 本帧要描的 HUD 矩形（屏幕坐标）
var hexes: Array[Vector2] = []   ## 本帧要描的格子顶面中心（屏幕坐标）
var zoom := 1.0                  ## 棋盘像素 → 屏幕像素
var _t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


## 每帧由 CWMatch 调用：flag 是引导当前步骤的提亮键，m 是对局（读它的 HUD 节点与引擎状态）
func sync(flag: String, m) -> void:
	rects = []
	hexes = []
	if flag == "" or m == null or m.game == null or m.camera == null or m.board == null:
		return
	zoom = m.camera.zoom.x
	var pid: int = m.human_players[0] if not m.human_players.is_empty() else -1
	match str(FLAGS.get(flag, "")):
		"board":
			_rect(_board_rect(m))
		"special":
			for c in CWData.all_coords():
				if CWData.special_of(c) != CWData.Special.NONE:
					_hex(m, c)
		"place":
			for c in place_tiles(m.game):
				_hex(m, c)
		"energy":
			if m.panel != null and pid >= 0:
				_rect(m.panel.rect_of("row:%d" % pid))
		"move":
			_bar_button(m, CWData.ACT_NAMES["move"])
		"purify":
			for c in purify_tiles(m.game, pid):
				_hex(m, c)
		"end":
			if m.panel != null:
				_rect(m.panel.rect_of("end"))
		"enemy":
			for c in cell_tiles(m.game, CWData.Faction.CANCER):
				_hex(m, c)
		"own":
			for c in cell_tiles(m.game, CWData.Faction.IMMUNE):
				_hex(m, c)
		"bar":
			if m.action_bar != null:
				_rect(m.action_bar.bar_rect())
		"draw":
			_bar_button(m, CWData.ACT_NAMES["draw"])
		"hand":
			_rect(hand_rect())
		"pips":
			if m.panel != null and pid >= 0:
				_rect(m.panel.rect_of("pips:%d" % pid))
		"differentiate":
			if not _bar_button(m, CWData.ACT_NAMES["differentiate"]) and m.panel != null:
				_rect(m.panel.rect_of("level"))
		"round":
			if m.panel != null:
				_rect(m.panel.rect_of("round"))
		"world_event":
			if m.panel != null:
				_rect(m.panel.rect_of("round"))
			if m._log_hint != null and m._log_hint.visible:
				_rect(m._log_hint.get_global_rect())


func _rect(r: Rect2) -> void:
	if r.size != Vector2.ZERO:
		rects.append(r)


func _hex(m, c: Vector2i) -> void:
	hexes.append(CWView.board_to_screen(m.camera, m.board.tile_center(c)))


## 行动栏上标题为 title 的按钮；此刻没有（栏收着 / 这一问没它）→ false，调用方自己找退路
func _bar_button(m, title: String) -> bool:
	if m.action_bar == null:
		return false
	var r: Rect2 = m.action_bar.button_rect(title)
	if r.size == Vector2.ZERO:
		return false
	rects.append(r)
	return true


## 整张棋盘的屏幕包围框：全部格子顶面中心的极值，再让出半格
func _board_rect(m) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in CWData.all_coords():
		var p: Vector2 = CWView.board_to_screen(m.camera, m.board.tile_center(c))
		lo = lo.min(p)
		hi = hi.max(p)
	var half := Vector2(HEX_R * sqrt(3.0) / 2.0, HEX_R * HEX_SQUASH) * zoom
	return Rect2(lo - half, hi - lo + half * 2.0)


## 可落子且紧邻癌区的健康格 —— 剧本建议「选在紧邻癌区外侧的健康组织上」，提亮的就是这些
static func place_tiles(game: CWGame) -> Array:
	var out: Array = []
	for c: Vector2i in game.tiles:
		if game.tiles[c]["tissue"] != CWData.Tissue.HEALTHY or not game.cells_at(c).is_empty():
			continue
		for n in CWData.neighbors(c):
			if game.tiles.has(n) and game.is_cancerous(n):
				out.append(c)
				break
	return out


## 玩家细胞旁边可净化的癌组织（固化格不算：那要【裂解】）
static func purify_tiles(game: CWGame, pid: int) -> Array:
	var out: Array = []
	if pid < 0 or pid >= game.cells.size():
		return out
	var cell: Dictionary = game.cell_of(pid)
	if not cell["alive"]:
		return out
	for n in CWData.neighbors(cell["pos"]):
		if game.tiles.has(n) and game.tiles[n]["tissue"] == CWData.Tissue.CANCER:
			out.append(n)
	return out


static func cell_tiles(game: CWGame, faction: int) -> Array:
	var out: Array = []
	for c in game.cells:
		if c["alive"] and c["faction"] == faction:
			out.append(c["pos"])
	return out


## 左下角手牌抽屉静止时的那一条（卡抬起会更高，但「卡在哪」看这一条就够）
static func hand_rect() -> Rect2:
	var s := CWView.screen_size()
	return Rect2(CWHand.LEFT, CWHand.REST_TOP, CWHand.SPAN, s.y - CWHand.REST_TOP)


## 一格顶面六边形的 7 个顶点（首尾相接），屏幕坐标
static func hex_points(center: Vector2, p_zoom: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 7:
		var a := deg_to_rad(30.0 + 60.0 * (i % 6))
		pts.append(center + Vector2(cos(a), sin(a) * HEX_SQUASH) * HEX_R * p_zoom)
	return pts


func _draw() -> void:
	if rects.is_empty() and hexes.is_empty():
		return
	var k := 0.5 + 0.5 * sin(_t * TAU / PULSE_PERIOD)
	var col := Color(CWStyle.IMMUNE, lerpf(ALPHA_LO, ALPHA_HI, k))
	for r in rects:
		draw_rect(r.grow(GROW), col, false, LINE_W)
	for h in hexes:
		draw_polyline(hex_points(h, zoom), col, LINE_W)
