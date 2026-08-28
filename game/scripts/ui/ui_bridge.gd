## ui_bridge.gd —— 表现层的询问桥：人类玩家的界面 + 掷骰演出
##
## **为什么继承启发式 AI 而不是 CWBridge。** 一局里通常只有部分位置是人，
## 其余仍要 AI 来下。让同一个桥对象兼任两者有三个好处：
##
## ① 掷骰演出只需要注册一次 —— `CWGame.roll_shown()` 会把演出广播给所有桥、
##    并按**对象**去重，所以「一个对象注册给全部玩家」正好演一遍，
##    「人类看得见 AI 掷的骰」这件事自然成立，不用另设一个旁观者桥。
## ② 没装界面时（无头测试、平衡模拟）整个退回 AI，对局照跑。
## ③ 一个人都没有时（human_pids 为空）就是一局带演出的 AI 互搏，可以直接看。
##
## 演出**无权决定结果**：value 是引擎先用 game.rng 掷好再传进来的（架构约定 #11）。
class_name CWUIBridge
extends CWHeuristicBridge

var board: Node2D          ## 取格子像素位置、收点选事件都只问它（架构约定 #10）
var dice: CWDice
var bar: CWActionBar
var panel: CWMatchPanel
var human_pids: Array[int] = []

## 开场绽开还没演完时，人类的询问界面先不出来 ——
## 团队定的三拍开场里，第三拍才把控制权交还玩家（CWMatch 演完后置回 false）。
var opening := false

## 本桥希望棋盘上高亮哪些格子：{ 轴坐标: 颜色 }。
## 由 CWMatch 每帧读走、和「组织状态色标」合并后一起交给 board.set_marks()。
## 做成「桥单向暴露、对局去读」而不是桥直接改棋盘，是为了不让两处各自往
## set_marks() 里写、互相把对方擦掉。
var marks := {}

## 行动栏按钮上的技能名。**费用一律现从 CWData 读，这里不写第二份数字**。
## 新增主动技能却忘了在这里登记，t_action_ui 会当场报出来。
const ACT_TITLE := {
	"move": "迁移", "draw": "基因表达", "differentiate": "分化",
	"antibody": "抗体", "toxin": "细胞毒素", "lyse": "裂解",
	"mutate": "突变", "blast": "自爆", "remodel": "基质重塑", "end": "结束回合",
}

var _tiles := {}       ## 当前这一问里，哪些格子可点 → 点了返回什么
var _enemy := -1       ## 当前提问者的敌对阵营，用来把「攻击格」标成橙色
var _pending: Answer   ## 正卡在「等玩家作答」上的那一次询问


## 一次交互的应答口。
## GDScript 的 await 只能等**一个**信号，而这里要同时等「点了棋盘上的格子」
## 和「点了行动栏的按钮」两路，所以两路都汇到这里的 done 上，谁先来算谁。
class Answer:
	extends RefCounted
	signal done(value: Variant)
	var _fired := false
	func fire(value: Variant) -> void:
		if _fired:
			return      ## 一次交互只认第一个答案
		_fired = true
		done.emit(value)


## 中途放弃这一局（返回主菜单）：把卡住的那次询问唤醒，好让 _prompt() 把信号断干净。
##
## 不这么做的话，`board.tile_hovered` 上会一直挂着那次询问的处理函数；
## 对局释放之后鼠标往棋盘上一动，它就去调用已经置空的 game ——
## **debug 模式下 Godot 会直接断在调试器里，表现就是「游戏卡死」**
## （2026-08-27 团队试玩报的就是这个）。
## 引擎那边由 CWGame.aborted 收摊，两边配合才能安全展开。
func abort() -> void:
	_clear_ui()
	if _pending != null:
		var p := _pending
		_pending = null
		p.fire(null)


func ask(req: Dictionary) -> int:
	if req["pid"] in human_pids and bar != null and board != null:
		return await _ask_human(req)
	_clear_ui()   ## 轮到别人：按钮和高亮一起收掉（定稿如此）
	return await super.ask(req)


func _ask_human(req: Dictionary) -> int:
	while opening and board != null and board.is_inside_tree():
		await board.get_tree().process_frame
	_enemy = CWData.Faction.CANCER if game.player(req["pid"])["faction"] \
		== CWData.Faction.IMMUNE else CWData.Faction.IMMUNE
	var picked: int
	if req["kind"] == "action":
		picked = await _ask_action(req)
	else:
		picked = await _ask_generic(req)
	_clear_ui()
	return picked


# ============ 「选行动」：两段式 ============
# 定稿的行动栏里「迁移」也是一个按钮，点了它才高亮可达格、再点格子确认。
# 引擎那边每个相邻格是一个独立选项，所以这里要把它们合成一个按钮，
# 选完格子再还原成对应的那个选项下标。

func _ask_action(req: Dictionary) -> int:
	var options: Array = req["options"]
	var cell: Dictionary = game.cell_of(req["pid"])
	var moves: Array = []
	for i in options.size():
		if options[i]["data"]["act"] == "move":
			moves.append(i)
	while not game.aborted:
		var buttons: Array = []
		var values: Array = []
		if not moves.is_empty():
			buttons.append({ "title": _move_title(cell), "cost": _move_cost_text(options, moves) })
			values.append("move")
		## 「结束回合」定稿是钉在右侧竖条底部的，不占行动栏；没有面板时才退回按钮栏
		var end_value: Variant = null
		for i in options.size():
			var act: String = options[i]["data"]["act"]
			if act == "move":
				continue
			if act == "end" and panel != null:
				end_value = i
				continue
			buttons.append({ "title": ACT_TITLE.get(act, act), "cost": _cost_text(cell, act) })
			values.append(i)
		var got: Variant = await _prompt("", "", buttons, values, {}, end_value)
		if got == null:
			return 0             ## 这一局被中途放弃了（返回主菜单）
		if not (got is String):
			return got as int
		## 进目标选择态；取消就回到按钮栏重来
		var tiles := {}
		for i in moves:
			tiles[options[i]["data"]["to"]] = i
		var t: Variant = await _prompt(
			"选择要%s到的组织" % _move_title(cell).substr(0, 2),
			"高亮 %d 格可达 · 右键或 Esc 取消" % tiles.size(),
			[{ "title": "取消", "cost": "右键 / Esc" }], ["cancel"], tiles, null, 0)
		if t == null:
			return 0             ## 同上
		if not (t is String):
			return t as int
	return 0                     ## 放弃这一局时从 while 条件退出来


# ============ 其余询问：有 to 的进棋盘，没 to 的进按钮 ============
# setup_place / revive / remodel_target 的选项带坐标 → 点棋盘；
# attack_target / differentiate / confirm 不带 → 全是按钮。
# 这条规则一写，六种询问就都覆盖到了，不必各写一套。

func _ask_generic(req: Dictionary) -> int:
	var options: Array = req["options"]
	var tiles := {}
	var buttons: Array = []
	var values: Array = []
	for i in options.size():
		var data: Dictionary = options[i]["data"]
		if data.has("to"):
			tiles[data["to"]] = i
		else:
			buttons.append({ "title": options[i]["label"], "cost": "" })
			values.append(i)
	var hint := "" if tiles.is_empty() else "高亮 %d 格可选" % tiles.size()
	var got: Variant = await _prompt(req["prompt"], hint, buttons, values, tiles)
	return 0 if got == null else int(got)


## 摆出一栏按钮 + 一组可点的格子，等玩家二选一，返回被选中那项的值。
## title 为空 = 技能栏形态（靠右一条）；否则 = 目标选择态（整条横过来，左边带提示）。
## end_value 非 null 时，右侧竖条底部的「结束回合」也算这一问的一个答案，
## 按下它就返回该值。选目标格时传 null，那个按钮会一起收掉。
## cancel 指出 buttons 里哪一个是「取消」（右键 / Esc 的快捷方式）；-1 = 不能取消。
func _prompt(title: String, hint: String, buttons: Array, values: Array,
		tiles: Dictionary, end_value: Variant = null, cancel := -1) -> Variant:
	_tiles = tiles
	_repaint_marks()
	bar.show_bar(title, hint, buttons, cancel)
	var ans := Answer.new()
	_pending = ans
	var on_button := func(i: int) -> void: ans.fire(values[i])
	var on_end := func() -> void: ans.fire(end_value)
	if panel != null:
		panel.show_end_turn(end_value != null)
		if end_value != null:
			panel.end_turn_pressed.connect(on_end)
	var on_tile := func(c: Vector2i) -> void:
		if tiles.has(c):
			ans.fire(tiles[c])
	var on_hover := func(_c: Vector2i) -> void: _repaint_marks()
	bar.chosen.connect(on_button)
	board.tile_clicked.connect(on_tile)
	board.tile_hovered.connect(on_hover)
	var got: Variant = await ans.done
	_pending = null
	if panel != null and end_value != null:
		panel.end_turn_pressed.disconnect(on_end)
	bar.chosen.disconnect(on_button)
	board.tile_clicked.disconnect(on_tile)
	board.tile_hovered.disconnect(on_hover)
	return got


## 候选格用免疫青；落着敌人的那一格用癌方橙 —— 那一下是攻击，不是迁移，
## 颜色得先说出来。鼠标停着的那格再提亮一档。
func _repaint_marks() -> void:
	if game == null:
		marks = {}
		return              ## 对局已经拆了；防的是「信号还没断干净」那一瞬
	var m := {}
	for c: Vector2i in _tiles:
		if board.hovered == c:
			m[c] = board.MARK_HOVER
		elif _enemy >= 0 and not game.cells_at(c, _enemy).is_empty():
			m[c] = board.MARK_ATTACK
		else:
			m[c] = board.MARK_MOVE
	marks = m


func _clear_ui() -> void:
	marks = {}
	_tiles = {}
	if bar != null:
		bar.clear()
	if panel != null:
		panel.show_end_turn(false)


# ---- 按钮文案 ----

func _move_title(cell: Dictionary) -> String:
	## 规则里免疫叫「迁移」、癌症叫「移动」，是两个词，别混用
	return "迁移" if cell["faction"] == CWData.Faction.IMMUNE else "移动"


## 迁移费用随目的地不同（健康 / 癌性，还看免疫等级），所以直接从各个选项里
## 把实际费用收齐去重，显示成设计稿那样的「0.5 / 1.0」。不另算一遍。
func _move_cost_text(options: Array, moves: Array) -> String:
	var costs: Array = []
	for i in moves:
		var c: int = options[i]["data"]["cost"]
		if c not in costs:
			costs.append(c)
	costs.sort()
	var parts: PackedStringArray = []
	for c in costs:
		parts.append(CWData.fmt(c))
	return " / ".join(parts)


func _cost_text(cell: Dictionary, act: String) -> String:
	match act:
		"draw":
			var c: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
				else CWData.CANCER_DRAW_COST
			return "%s 抽卡" % CWData.fmt(c)
		"differentiate":
			return "免费"
		"antibody":
			return CWData.fmt(CWData.ANTIBODY_COST)
		"toxin":
			return CWData.fmt(CWData.TOXIN_COST)
		"lyse":
			return CWData.fmt(CWData.LYSE_COST)
		"mutate":
			return CWData.fmt(CWData.MUTATE_COST)
		"remodel":
			return CWData.fmt(CWData.REMODEL_COST)
		"blast":
			return "耗尽能量"
	return ""


## 把骰子摆到目标格旁边演一次。AI 掷的骰走快档，免得旁观太磨。
func show_roll(_reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
	if dice == null or board == null:
		return
	dice.place_at(board.tile_center(at), board.tile_z(at, board.Z_DICE))
	await dice.play(value, sides, pid not in human_pids)
