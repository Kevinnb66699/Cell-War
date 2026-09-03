## tile_info.gd —— 悬停格子详情：鼠标停在棋盘某格 0.25s 后浮出的小卡片
##
## 设计稿见「界面小块」画布（2026-08-29）。贴着格子摆而不是跟着鼠标走——
## 跟随会抖，而且卡片一动，里面的字就没法读。移出格子立即收起，
## 换格子重新计时（划过一串格子时不会闪一路卡片）。
##
## 内容（describe）与摆位（place）都是纯函数：无头测试直接查文案和不越界，
## 不用真渲染 —— 和 CWToast.place 是同一套打法。
class_name CWTileInfo
extends Control

const DELAY := 0.25    ## 悬停多久后浮出
const W := 208         ## **最小**宽；实际宽度按最长一行实测（见 width_for）
const PAD_V := 10
const PAD_H := 12
const GAP_FROM_TILE := 26   ## 卡片与格子中心的横向距离
const LINE_BODY := 24       ## 正文行高（20px 字）
const LINE_LABEL := 15      ## 小字行高（10px 字）

var _hover := Vector2i(9999, 9999)   ## 正悬停的格子；不在棋盘上就等于「没有」
var _wait := 0.0
var _key := ""   ## 上次搭内容用的键；没变就不重搭（每帧 sync，重搭是浪费）


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 信息卡不挡任何点击


## 接 board.tile_hovered。换格子先收起再重新计时。
func on_hover(c: Vector2i) -> void:
	if c == _hover:
		return
	_hover = c
	_wait = 0.0
	visible = false


func hide_now() -> void:
	_hover = Vector2i(9999, 9999)
	visible = false


## 每帧由 CWMatch 调（它手里有 game/board/camera）。blocked = 开场/返场演出中。
## costs / verb：正在选迁移目标时的每格耗能与用词，由 CWUIBridge 转手过来；
## 空字典 = 此刻不在迁移态，不显示耗能行。
func sync(delta: float, game: CWGame, board: Node2D, camera: Camera2D,
		blocked: bool, costs: Dictionary = {}, verb: String = "") -> void:
	if game == null or blocked or not game.tiles.has(_hover):
		visible = false
		return
	_wait += delta
	if _wait < DELAY:
		return
	var rows := describe(game, _hover, int(costs.get(_hover, -1)), verb)
	var key := "%s|%s" % [str(_hover), str(rows)]
	if key != _key:
		_key = key
		_rebuild(rows)
	var anchor: Vector2 = CWView.board_to_screen(camera, board.tile_center(_hover))
	position = place(anchor, size, CWView.screen_size())
	visible = true


## 这一格该显示什么：[{ text, size, color }]。纯函数，供测试直接核对文案。
## 字段取舍见设计稿：组织 + 坐标 / **迁移耗能** / 固化进度 / 特殊组织 / 坏死 / 占据者。
##
## move_cost < 0 表示「此刻不在迁移态，或这一格不可达」，那一行就不出。
## verb 分「迁移」（免疫）和「移动」（癌症）—— 规则里是两个词，不能混用。
##
## **微环境压迫行**（2026-09-01 加）：只在「玩家正在为这一格做决定」时出 ——
## 要么它是迁移候选（move_cost >= 0），要么上面站着免疫细胞。
## 加它的理由是五局手打的实测：执行者死了 6 次，**4 次是没算这一刀**，
## 而它是完全确定、算得出的数（`CWWorld.pressure_at`），界面此前一个字不给。
## 而且免疫方净化效率最高的位置（六面皆癌）**正好**是压迫最大的位置（2.0）——
## 这个张力设计得好，但它必须看得见。
static func describe(game: CWGame, c: Vector2i, move_cost := -1, verb := "") -> Array:
	var t: Dictionary = game.tile(c)
	var rows: Array = []
	var tissue: int = t["tissue"]
	var tissue_color: Color = CWStyle.TEXT if tissue == CWData.Tissue.HEALTHY else CWStyle.CANCER
	rows.append({ "text": CWData.TISSUE_NAMES[tissue], "size": CWStyle.SIZE_BODY,
		"color": tissue_color, "right": str(c) })
	## 耗能紧跟在组织名后面：选目标时这是玩家唯一真正在比较的数。
	## 用高亮色（和格子高亮同一个青）表示「这格现在可选、价钱是这些」。
	if move_cost >= 0:
		rows.append({ "text": "%s耗能 %s" % [verb, CWData.fmt(move_cost)],
			"size": CWStyle.SIZE_BODY, "color": CWStyle.IMMUNE })
	## 压迫只落在免疫细胞身上：癌方选目标时（verb =「移动」）这一行不出（2026-09-03 Kevin 截图报的）
	rows.append_array(pressure_rows(game, c, move_cost, verb != "移动"))
	if tissue == CWData.Tissue.CANCER and t["solid"] > 0:
		## ⚠ 固化计数存的是**十分整数**（`SOLIDIFY_THRESHOLD = 20` 即 2.0）——
		## PRD 里它不是整数：衰减 -0.5、【骨样硬化】+1.5、【基质硬化】+1/+1.5/+2。
		## 这里必须走 `CWData.fmt()`，用 %d 直接打会显示成「固化 15 / 30」
		## （2026-09-01 队友截图报的）
		rows.append({ "text": "固化 %s / %s" % [CWData.fmt(t["solid"]),
			CWData.fmt(game.tune.solidify_threshold)],
			"size": CWStyle.SIZE_BODY, "color": CWStyle.TEXT })
	match t["special"]:
		CWData.Special.CORE:
			rows.append({ "text": "代谢核心 · 储量 %s" % CWData.fmt(t["store"]),
				"size": CWStyle.SIZE_BODY, "color": CWStyle.IMMUNE })
		CWData.Special.MARROW:
			rows.append({ "text": "骨髓 · 卡牌 %d" % t["cards"],
				"size": CWStyle.SIZE_BODY, "color": CWStyle.IMMUNE })
		CWData.Special.VESSEL:
			rows.append({ "text": "血管", "size": CWStyle.SIZE_BODY, "color": CWStyle.IMMUNE })
	if t["necrosis"]:
		rows.append({ "text": "坏死", "size": CWStyle.SIZE_LABEL, "color": CWStyle.TEXT_DIM })
	for cell in game.cells_at(c):
		var immune: bool = cell["faction"] == CWData.Faction.IMMUNE
		var tname: String = CWData.IMMUNE_TYPE_NAMES[cell["itype"]] if immune \
			else CWData.CANCER_TYPE_NAMES[cell["ctype"]]
		rows.append({ "text": "%s · %s" % [game.player(cell["pid"])["name"], tname],
			"size": CWStyle.SIZE_BODY,
			"color": CWStyle.IMMUNE if immune else CWStyle.CANCER, "rule": true })
		var mark := "　标记 ×%d" % cell["mark_left"] if cell["marked"] else ""
		rows.append({ "text": "能量 %s%s" % [CWData.fmt(maxi(cell["energy"], 0)), mark],
			"size": CWStyle.SIZE_BODY, "color": CWStyle.TEXT })
	return rows


## 站在这一格，本世界回合末会因【微环境压迫】损失多少 —— 该不该显示，以及怎么措辞。
##
## **算式不在这里**：调 `CWWorld.pressure_at()`，和 E 阶段结算用的是同一个函数。
## 界面抄第二份必然漂（本项目 2026-09-01 已因「两份口径不一致」栽过三次）。
##
## ⚠ 措辞用「**至少**」不是精确值：癌方在免疫之后行动、会在它周围铺新格，
## 所以回合末的真实值只会**大于等于**此刻这个数。写成精确值会骗人。
static func pressure_rows(game: CWGame, c: Vector2i, move_cost: int, mover_immune := true) -> Array:
	var here_immune := false
	for cell in game.cells_at(c, CWData.Faction.IMMUNE):
		here_immune = true
	## 只在「正在为这一格做决定」时出：**免疫的**迁移候选，或者上面站着免疫细胞。
	## 【E-微环境压迫】只扣免疫细胞的能量，癌细胞的移动候选格没有这一刀，写出来是骗人
	if (move_cost < 0 or not mover_immune) and not here_immune:
		return []
	var loss: int = game.world.pressure_at(c)
	if loss <= 0:
		return [{ "text": "回合末压迫 无", "size": CWStyle.SIZE_LABEL,
			"color": CWStyle.TEXT_DIM }]
	return [{ "text": "回合末压迫 至少 %s" % CWData.fmt(loss),
		"size": CWStyle.SIZE_BODY, "color": CWStyle.CANCER }]


## 卡片宽度：按最长一行的**实测**宽度撑开，W 只是下限。
## 定宽 208 在「代谢核心 · 储量 0.0」这类行上差十几像素，文字压到框外
## （2026-08-30 对局内试玩第一轮报的）。首行右侧还挂着坐标小签，一并算进去。
static func width_for(rows: Array) -> float:
	var w := float(W)
	for r in rows:
		var tw: float = CWStyle.FONT.get_string_size(r["text"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, r["size"]).x
		if r.has("right"):
			tw += 8.0 + CWStyle.FONT.get_string_size(str(r["right"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
		w = maxf(w, tw + PAD_H * 2)
	return w


## 摆位：优先放在格子右侧、垂直居中；会压到右栏（x≥696-宽）就翻到左侧；
## 上下钳进画布。纯函数，测试核对「贴右栏的格子翻左、不越界」。
static func place(anchor: Vector2, box: Vector2, screen: Vector2) -> Vector2:
	var panel_left := screen.x - 264.0   ## 右侧竖条的左缘，信息卡不进那条
	var x := anchor.x + GAP_FROM_TILE
	if x + box.x > panel_left - 8.0:
		x = anchor.x - GAP_FROM_TILE - box.x
	var y := clampf(anchor.y - box.y / 2.0, 8.0, screen.y - box.y - 8.0)
	return Vector2(maxf(x, 8.0), y)


func _rebuild(rows: Array) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var h := PAD_V
	for r in rows:
		h += LINE_BODY if r["size"] == CWStyle.SIZE_BODY else LINE_LABEL
		if r.has("rule"):
			h += 6
	h += PAD_V
	var w := width_for(rows)
	size = Vector2(w, h)
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var y := PAD_V
	for r in rows:
		if r.has("rule"):
			var rule := ColorRect.new()
			rule.color = Color(CWStyle.LINE, 0.25)
			rule.position = Vector2(PAD_H, y + 2)
			rule.size = Vector2(w - PAD_H * 2, 1)
			rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(rule)
			y += 6
		var label := CWStyle.label(r["text"], r["size"], r["color"])
		label.position = Vector2(PAD_H, y)
		add_child(label)
		if r.has("right"):
			var tag := CWStyle.label(r["right"], CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
			tag.size = Vector2(w - PAD_H * 2, 14)
			tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			tag.position = Vector2(PAD_H, y + 6)
			add_child(tag)
		y += LINE_BODY if r["size"] == CWStyle.SIZE_BODY else LINE_LABEL
