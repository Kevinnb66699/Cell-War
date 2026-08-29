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
var toast: CWToast     ## 骰子旁边那行字
var camera: Camera2D   ## 棋盘坐标 → 屏幕坐标要用它（提示挂在 CanvasLayer 上）
var human_pids: Array[int] = []

## 开场绽开还没演完时，人类的询问界面先不出来 ——
## 团队定的三拍开场里，第三拍才把控制权交还玩家（CWMatch 演完后置回 false）。
var opening := false

## 本桥希望棋盘上高亮哪些格子：{ 轴坐标: 颜色 }。
## 由 CWMatch 每帧读走、和「组织状态色标」合并后一起交给 board.set_marks()。
## 做成「桥单向暴露、对局去读」而不是桥直接改棋盘，是为了不让两处各自往
## set_marks() 里写、互相把对方擦掉。
var marks := {}

## 结算说明在屏幕上停留多久
const RESULT_HOLD := 1.1

## 行动栏按钮上的技能名。**费用一律现从 CWData 读，这里不写第二份数字**。
## 新增主动技能却忘了在这里登记，t_action_ui 会当场报出来。
const ACT_TITLE := {
	"move": "迁移", "draw": "基因表达", "differentiate": "分化",
	"antibody": "抗体", "toxin": "细胞毒素", "lyse": "裂解",
	"mutate": "突变", "end": "结束回合",
	## 癌细胞种类专属（PRD 四种真实癌症）
	"homing": "血行转移", "mucus": "黏液破裂", "jump": "转移",
	## 手牌（按钮不进行动栏，由手牌交互出；名字给日志和护栏测试用）
	"play": "打出手牌", "discard": "弃牌",
}

var _tiles := {}       ## 当前这一问里，哪些格子可点 → 点了返回什么
var _enemy := -1       ## 当前提问者的敌对阵营，用来把「攻击格」标成橙色
## 「迁移」是**切换式**的：走完一步继续停在选目标格上，不必每步都重点一次按钮
## （团队 2026-08-27 要求）。退出条件只有三个：右键/Esc、能量不够没有可达格、换人。
var _sticky_move := false
var _sticky_pid := -1    ## 上面那个开关属于谁
var _sticky_round := -1  ## 属于哪个世界回合。**换人或换回合都作废** ——
                         ## 一个人每个世界回合只行动一次，所以「新回合」就是「这人的下一个回合」，
                         ## 不清掉的话新回合一开始就莫名其妙直接进了选目标格（团队反馈）
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
	var pid: int = req["pid"]
	var cell: Dictionary = game.cell_of(pid)
	if pid != _sticky_pid or game.round_no != _sticky_round:
		_sticky_pid = pid
		_sticky_round = game.round_no
		_sticky_move = false
	var moves: Array = []
	for i in options.size():
		if options[i]["data"]["act"] == "move":
			moves.append(i)
	if moves.is_empty():
		_sticky_move = false        ## 能量不够、一格也去不了，自己退回按钮栏
	while not game.aborted:
		## 上一步选的就是迁移 → 直接回到选目标格，不再经过按钮栏
		if _sticky_move:
			var again: Variant = await _pick_move(cell, options, moves)
			if again == null:
				return 0            ## 这一局被中途放弃了（返回主菜单）
			if not (again is String):
				return again as int
			_sticky_move = false    ## 右键 / Esc / 「结束迁移」
			continue
		## **按钮不消失，只变暗**（团队 2026-08-28 定）。
		## 按钮集合来自 `CWActions.action_kinds()`（只看细胞种类和免疫等级），
		## 而不是来自当前合法选项 —— 否则花掉能量会让按钮凭空少一个，
		## 行动栏宽度跟着跳，连数字快捷键的编号都会变。
		var groups := {}
		var end_value: Variant = null
		for i in options.size():
			var a: String = options[i]["data"]["act"]
			if a == "end":
				end_value = i      ## 有右侧竖条时挪去面板底部，没有时下面补一个按钮
				continue
			if not groups.has(a):
				groups[a] = []
			groups[a].append(i)
		var buttons: Array = []
		var values: Array = []
		for act in game.actions.action_kinds(cell):
			var live: bool = groups.has(act)
			buttons.append({
				"title": _move_title(cell) if act == "move" else ACT_TITLE.get(act, act),
				"cost": _move_cost_text(options, moves) if act == "move" \
					else _cost_text(cell, act),
				"disabled": not live,
			})
			values.append(act if live else "")
		## 没有右侧竖条时（纯行动栏形态），「结束回合」退回按钮栏占一格
		if panel == null and end_value != null:
			buttons.append({ "title": ACT_TITLE["end"], "cost": "" })
			values.append(end_value)
			end_value = null
		var got: Variant = await _prompt("", "", buttons, values, {}, end_value)
		if got == null:
			return 0
		if not (got is String):
			return got as int          ## 「结束回合」的下标
		var act: String = got as String
		if act == "":
			continue               ## 灰掉的按钮，理论上点不到；兜一道
		if act == "move":
			_sticky_move = true
			continue
		## 一个技能只有一种打法 → 直接执行，不必再问
		var picks: Array = groups[act]
		if picks.size() == 1:
			return picks[0] as int
		## 有多种打法（分化选种类、裂解要不要顺带净化、血行转移/跃进选落点）→ 第二段
		var sub: Variant = await _pick_sub(act, options, picks)
		if sub == null:
			return 0
		if sub is String:
			continue                   ## 退出子选择，回到按钮栏
		return sub as int
	return 0                        ## 放弃这一局时从 while 条件退出来


## 技能的第二段：同一个 act 有多个选项时，让玩家挑一个。
##
## 为什么会有第二段：引擎那边为了让 AI 能把一个行动当成原子来推演，
## 把「分化成哪种」「裂解要不要顺带净化」「转移到哪一格」全摊成了顶层选项。
## 行动栏容不下那么多按钮，所以界面这边再把它们收回一个按钮 + 一次追问 ——
## 和「迁移」的两段式是同一套语汇。
##
## 带 `to` 的走棋盘点选，其余走按钮栏。返回选项下标；退出返回 "cancel"；放弃对局返回 null。
func _pick_sub(act: String, options: Array, picks: Array) -> Variant:
	var title: String = ACT_TITLE.get(act, act)
	var tiles := {}
	var buttons: Array = []
	var values: Array = []
	for i in picks:
		var data: Dictionary = options[i]["data"]
		if data.has("to"):
			tiles[data["to"]] = i
		else:
			buttons.append({ "title": _sub_label(act, data), "cost": "" })
			values.append(i)
	buttons.append({ "title": "取消", "cost": "右键 / Esc" })
	values.append("cancel")
	var hint := "" if tiles.is_empty() else "高亮 %d 格可选 · 右键或 Esc 退出" % tiles.size()
	return await _prompt("选择%s的目标" % title, hint, buttons, values, tiles,
		null, buttons.size() - 1)


## 子选项的按钮标题。分化给种类名，裂解给「顺带净化 / 暂不」，其余退回引擎给的 label。
func _sub_label(act: String, data: Dictionary) -> String:
	match act:
		"differentiate":
			return CWData.IMMUNE_TYPE_NAMES[data["type"]]
		"lyse":
			return "顺带净化" if data["purge"] else "暂不净化"
	return str(data)


## 目标选择态：高亮可达格，等玩家点一格或退出。
## 返回格子对应的选项下标；退出则返回 "cancel"；对局被放弃返回 null。
func _pick_move(cell: Dictionary, options: Array, moves: Array) -> Variant:
	var tiles := {}
	for i in moves:
		tiles[options[i]["data"]["to"]] = i
	var verb := _move_title(cell)
	return await _prompt("选择要%s到的组织" % verb,
		"高亮 %d 格可达 · 可以连着走 · 右键或 Esc 退出" % tiles.size(),
		[{ "title": "结束%s" % verb, "cost": "右键 / Esc" }], ["cancel"], tiles, null, 0)


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
		"homing":
			return CWData.fmt(CWData.MELANOMA_HOMING_COST)
		"jump":
			return CWData.fmt(CWData.METASTASIS_COST)
		"mucus":
			return "耗尽能量"
	return ""


## 把骰子摆到目标格旁边演一次，同时在它上方标出这次掷的是什么（"攻击"/"突变"/"抗体"）。
## **AI 和人类同一档速度**（团队 2026-08-27 定）：原先 AI 走快档，
## 结果同一件事在不同回合有两种节奏，反而显得乱。
## `CWDice.play()` 的快档参数保留着，将来做「加速观战」时直接接上。
func show_roll(reason: String, value: int, sides: int, _pid: int, at: Vector2i) -> void:
	if dice == null or board == null:
		return
	var ground: Vector2 = board.tile_center(at)
	if toast != null and camera != null:
		## hold=0：一直留着，等骰子停稳后被结算说明顶掉
		toast.show_at(reason, _dice_rect(ground), 0.0)
	dice.place_at(ground, board.tile_z(at, board.Z_DICE))
	await dice.play(value, sides)


## 掷骰的结算说明。文字是引擎给的，这里只负责把它摆到那一格上方。
func show_result(text: String, at: Vector2i) -> void:
	if toast == null or board == null or camera == null:
		return
	## 沿用掷骰时那个位置：骰子这会儿已经收了，但玩家的视线还在那儿，
	## 让「攻击」和「攻击大成功」出现在同一个地方比各自找最优位置更好读。
	toast.show_at(text, _dice_rect(board.tile_center(at)), RESULT_HOLD)


## 骰子落在某格时，它在**屏幕**上占的那块矩形。提示靠它避让。
func _dice_rect(ground: Vector2) -> Rect2:
	var span: Vector2 = dice.size * camera.zoom.x
	var origin: Vector2 = CWView.board_to_screen(camera, ground) - Vector2(
		span.x * 0.5, CWDice.contact_y(dice.size.y) * camera.zoom.y)
	return Rect2(origin, span)
