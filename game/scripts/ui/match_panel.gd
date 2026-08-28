## match_panel.gd —— 右侧竖条：常驻信息全在这儿
##
## 尺寸全部照搬定稿的「右侧竖条 · 尺寸与字号」标注稿，**一个数都别改**：
## 面板 264×540，内边距 16，块间距 10，各块高度写死
## 52（回合）/ 56（胜负进度）/ 44×人数（玩家列表）/ 44（免疫等级）/ 52（结束回合，钉底）。
## 6 人局合计 530，只余 10px —— 这套高度是按最挤的情况配平的，
## 随手把哪一块调高一点，6 人局就会溢出。
##
## 为什么是右侧竖条而不是底部横条：见 [CWView] 的对局机位注释。
##
## 刷新方式和棋盘一致：每帧全量刷（refresh），只改 Label 的 text。
## Godot 的 Label.text 在没变化时会直接返回，所以代价接近零，
## 而画面不可能和状态对不上。节点结构只在第一次 refresh 时按人数建一遍。
class_name CWMatchPanel
extends Control

## 「结束回合」被按下（面板底部那个按钮，或空格）
signal end_turn_pressed

const RECT := Rect2(696, 0, 264, 540)
const PAD := 16
const GAP := 10
const ROUND_H := 52
const SCORE_H := 56
const ROW_H := 44
const LEVEL_H := 44
const END_H := 52

const W := 232          ## 内容宽 = 264 - 16×2
const ROW_PAD := 6      ## 玩家行自己的左右内边距
const ICON := 32

## 手牌用小方块表示（团队 2026-08-28 定）：**总是画满 CWData.HAND_MAX 格**，
## 持有的填成阵营色、其余只留描边 —— 满没满一眼可见，比一个数字直观。
## 永久技能则**没有上限**（X 级免疫池光永久技能就有 9 张），所以只能用数字，不能也方块化。
const PIP := 6            ## 方块边长
const PIP_GAP := 2
const ENERGY_RESERVE := 52  ## 能量数字预留的宽度；「技 N」右对齐到它左边

## 玩家行里的种类图标。癌细胞没有美术，用占位图形（见 CWCancerBlob）。
const IMMUNE_ICON := {
	CWData.ImmuneType.BASIC: preload("res://assets/art/cells/immune.png"),
	CWData.ImmuneType.B_CELL: preload("res://assets/art/cells/bcell.png"),
	CWData.ImmuneType.T_CELL: preload("res://assets/art/cells/tcell.png"),
	CWData.ImmuneType.MACRO: preload("res://assets/art/cells/macrophage.png"),
	CWData.ImmuneType.DENDRITIC: preload("res://assets/art/cells/dendritic.png"),
}

var _round: Label
var _phase: Label
var _weighted: Label
var _weighted_max: Label
var _bar_fill: ColorRect
var _level: Label
var _memory: Label
var _bg: Panel
var _end: PanelContainer
var _rows: Array = []      ## 每项 { bg, fac, icon, blob, name, type, energy, pips, skills }
var _built := 0            ## 已按几人局建好（0 = 还没建）
var _level_y := 0.0        ## 免疫等级那一块的顶边；测试靠它核对 6 人局没溢出


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 面板要挡住底下的棋盘点击
	_chrome()


## 底板和「结束回合」按钮：都跟人数无关，所以和玩家列表分开建，
## 而且是**懒建**——程序化创建本面板时 _ready 要等到下一帧才跑，
## 而调用方（CWUIBridge）当帧就可能来调 show_end_turn()。
func _chrome() -> void:
	if _bg == null:
		_bg = Panel.new()
		## 只有左边一道描边（设计稿 border-left），所以不能用 set_border_width_all
		var box := CWStyle.box(0.45, CWStyle.PANEL)
		box.set_border_width_all(0)
		box.border_width_left = 2
		_bg.add_theme_stylebox_override("panel", box)
		_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_bg)
	if _end == null:
		_end = _build_end_button()
		_end.position = Vector2(PAD, RECT.size.y - PAD - END_H)
		_end.size = Vector2(W, END_H)
		_end.visible = false
		add_child(_end)


func _unhandled_key_input(event: InputEvent) -> void:
	## 设计稿把空格标成「结束回合」的快捷键
	if _end != null and _end.visible and event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		end_turn_pressed.emit()


## 每帧调用。第一次会按人数把节点建出来，之后只改文字。
func refresh(game: CWGame) -> void:
	if game == null or game.players.is_empty():
		return
	if _built != game.players.size():
		_build(game.players.size())
	_round.text = "第 %d 回合" % game.round_no
	_phase.text = "%s · 世界事件 第 %d 回合" % [game.phase, _next_event_round(game.round_no)]

	var w := game.count_tissue(CWData.Tissue.CANCER) \
		+ 2 * game.count_tissue(CWData.Tissue.SOLID)
	var goal: int = game.tune.cancer_win_weighted
	_weighted.text = str(w)
	_weighted_max.text = " / %d" % goal
	_bar_fill.size.x = W * clampf(float(w) / float(goal), 0.0, 1.0)

	for pid in game.players.size():
		_refresh_row(game, pid)

	_level.text = CWData.LEVEL_NAMES[game.immune_level]
	_memory.text = "抗原记忆 %d" % game.memory


## 回到主菜单时清空：下一局人数可能不同，节点结构要按新人数重建。
func reset() -> void:
	_chrome()
	_end.visible = false
	for c in get_children():
		if c == _bg or c == _end:
			continue
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_built = 0


func show_end_turn(on: bool) -> void:
	_chrome()
	_end.visible = on


## 世界事件在第 3、6、10、15 个世界回合触发，之后每 5 个（判据在 CWData）。
## 这里只找「下一次是第几回合」，规则仍然只有 CWData 一处。
func _next_event_round(from: int) -> int:
	var r := from
	while not CWData.is_world_event_round(r):
		r += 1
	return r


func _refresh_row(game: CWGame, pid: int) -> void:
	var row: Dictionary = _rows[pid]
	var p: Dictionary = game.player(pid)
	var immune: bool = p["faction"] == CWData.Faction.IMMUNE
	var faction_color: Color = CWStyle.IMMUNE if immune else CWStyle.CANCER
	row["fac"].color = faction_color
	row["name"].text = p["name"]

	## 开局布置阶段是一个一个落子的：玩家已经建好，细胞还没有。
	## 这一行先只显示名字和阵营色，别去问一个还不存在的细胞。
	if pid >= game.cells.size():
		row["bg"].color = Color(faction_color, 0.0)
		row["name"].add_theme_color_override("font_color", CWStyle.TEXT_OFF)
		row["type"].text = "待落子"
		row["energy"].text = ""
		_set_pips(row, 0, CWStyle.TEXT_OFF_DIM)
		row["skills"].text = ""
		row["icon"].visible = false
		row["blob"].visible = false
		return

	var cell: Dictionary = game.cell_of(pid)
	var dead: bool = not cell["alive"]
	var on: bool = game.current_pid == pid
	row["bg"].color = Color(faction_color, 0.10 if on else 0.0)
	row["name"].add_theme_color_override("font_color",
		CWStyle.TEXT_OFF if dead else (CWStyle.TEXT_HI if on else CWStyle.TEXT))
	row["type"].text = CWData.IMMUNE_TYPE_NAMES[cell["itype"]] if immune \
		else CWData.CANCER_TYPE_NAMES[cell["ctype"]]
	row["energy"].text = CWData.fmt(maxi(cell["energy"], 0))
	row["energy"].add_theme_color_override("font_color",
		CWStyle.TEXT_OFF if dead else CWStyle.TEXT_HI)
	## 手牌方块：持有的填阵营色，其余留描边色
	_set_pips(row, cell["hand"].size(), CWStyle.TEXT_OFF if dead else faction_color)
	var n_skill: int = cell["equipped"].size()
	row["skills"].text = "技 %d" % n_skill
	row["skills"].add_theme_color_override("font_color",
		CWStyle.TEXT_HI if n_skill > 0 else CWStyle.TEXT_OFF)

	var icon: Sprite2D = row["icon"]
	var blob: Node2D = row["blob"]
	icon.visible = immune
	blob.visible = not immune
	icon.modulate.a = 0.35 if dead else 1.0
	blob.modulate.a = 0.35 if dead else 1.0
	if immune:
		icon.texture = IMMUNE_ICON[cell["itype"]]


# ============ 建节点（只跑一次）============

func _build(n: int) -> void:
	_chrome()
	for c in get_children():
		if c == _bg or c == _end:
			continue      ## 底板和结束回合按钮跟人数无关，留着
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_built = n

	# ① 回合 / 阶段
	_round = _put(CWStyle.label("", CWStyle.SIZE_BIG, CWStyle.TEXT_HI), PAD, PAD, W)
	_phase = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, PAD + 36, W)

	# ② 胜负进度：一行标签 + 一条进度条
	var y := PAD + ROUND_H + GAP
	_put(CWStyle.label("癌性加权", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, y + 10, 100)
	_weighted_max = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		PAD, y + 10, W, HORIZONTAL_ALIGNMENT_RIGHT)
	_weighted = _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.CANCER),
		PAD, y, W - 36, HORIZONTAL_ALIGNMENT_RIGHT)
	var track := ColorRect.new()
	track.color = Color("0a0f16")
	track.position = Vector2(PAD, y + 28)
	track.size = Vector2(W, 8)
	add_child(track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = CWStyle.CANCER
	_bar_fill.position = Vector2(PAD, y + 28)
	_bar_fill.size = Vector2(0, 8)
	add_child(_bar_fill)

	# ③ 玩家列表
	y = PAD + ROUND_H + GAP + SCORE_H + GAP
	for i in n:
		_rows.append(_build_row(y + i * ROW_H))

	# ④ 免疫等级（上面一道分隔线）
	y += n * ROW_H + GAP
	_level_y = y
	var rule := ColorRect.new()
	rule.color = Color(CWStyle.LINE, 0.25)
	rule.position = Vector2(PAD, y)
	rule.size = Vector2(W, 1)
	add_child(rule)
	_put(CWStyle.label("免疫等级", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, y + 20, 80)
	_level = _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.IMMUNE),
		PAD, y + 12, W - 92, HORIZONTAL_ALIGNMENT_RIGHT)
	_memory = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		PAD, y + 20, W, HORIZONTAL_ALIGNMENT_RIGHT)

	## ⑤「结束回合」钉在底部（设计稿 margin-top:auto），在 _chrome() 里建


func _build_row(y: float) -> Dictionary:
	var bg := ColorRect.new()
	bg.position = Vector2(PAD, y)
	bg.size = Vector2(W, ROW_H)
	bg.color = Color(0, 0, 0, 0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var x: float = PAD + ROW_PAD
	var fac := ColorRect.new()            ## 阵营色条 4×30
	fac.position = Vector2(x, y + (ROW_H - 30) / 2.0)
	fac.size = Vector2(4, 30)
	add_child(fac)
	x += 4 + 8

	## 免疫用贴图（24 和 32 两种尺寸，居中摆、不缩放 —— 非整数倍会糊）；
	## 癌细胞没有美术，用占位图形。两个都建好，按阵营切 visible。
	var icon := Sprite2D.new()
	icon.position = Vector2(x + ICON / 2.0, y + ROW_H / 2.0)
	add_child(icon)
	var blob := CWCancerBlob.new()
	blob.position = Vector2(x + ICON / 2.0, y + ROW_H / 2.0 + CWCancerBlob.R)
	add_child(blob)
	x += ICON + 8

	var nm := _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT), x, y + 4, 110)
	var ty := _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), x, y + 26, 110)
	var right: float = PAD + W - ROW_PAD
	var en := _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI),
		x, y + 4, right - x, HORIZONTAL_ALIGNMENT_RIGHT)
	## 手牌方块：右对齐贴到行的右缘，占行底那一行
	var pips: Array = []
	var total: float = CWData.HAND_MAX * (PIP + PIP_GAP) - PIP_GAP
	for k in CWData.HAND_MAX:
		var pip := ColorRect.new()
		pip.position = Vector2(right - total + k * (PIP + PIP_GAP), y + 30)
		pip.size = Vector2(PIP, PIP)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pip)
		pips.append(pip)
	## 「技 N」放**能量那一行**（团队 2026-08-28 选的右边那版），右对齐到能量左侧
	var sk := _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		x, y + 10, right - ENERGY_RESERVE - x, HORIZONTAL_ALIGNMENT_RIGHT)
	return { "bg": bg, "fac": fac, "icon": icon, "blob": blob,
		"name": nm, "type": ty, "energy": en, "pips": pips, "skills": sk }


func _build_end_button() -> PanelContainer:
	var p := PanelContainer.new()
	## 设计稿 .btn.go：底与描边同色，字反过来用深色
	var box := CWStyle.box(1.0, CWStyle.IMMUNE, 6, 8)
	box.border_color = CWStyle.IMMUNE
	p.add_theme_stylebox_override("panel", box)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var dark := Color("0d1620")
	for pair in [["结束回合", CWStyle.SIZE_BODY], ["空格", CWStyle.SIZE_LABEL]]:
		var l := CWStyle.label(pair[0], pair[1], dark)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			end_turn_pressed.emit())
	return p


## 摆一个 Label 到面板内的绝对位置。
## 本面板全部绝对定位：各块高度是设计稿钉死的数，用容器反而要靠一堆 size_flags
## 才能复现同样的值，改起来还看不出跟标注稿的对应关系。
## 填 n 个方块。空格子不留白 —— 画成暗色描边，让「一共 8 格」这件事始终看得见。
func _set_pips(row: Dictionary, n: int, accent: Color) -> void:
	for k in row["pips"].size():
		var pip: ColorRect = row["pips"][k]
		pip.color = accent if k < n else CWStyle.TEXT_OFF_DIM
		pip.modulate.a = 1.0 if k < n else 0.45


func _put(l: Label, x: float, y: float, w: float,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	l.position = Vector2(x, y)
	l.size = Vector2(w, 0)
	l.horizontal_alignment = align
	add_child(l)
	return l
