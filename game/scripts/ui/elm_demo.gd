## elm_demo.gd —— Elm 化对局可视化导演（挂在 Main 根节点）
##
## 让「整个项目在新架构下运行」落地到场景：用 ElmSession 驱动一局 AI vs AI，
## 逐步 step + 渲染棋盘，掷骰演出异步播（逻辑不等动画），日志滚动显示。
##
## 结构：导演只做四件事 —— 推进（session.step）、渲染（board.refresh）、
## 演出（roll_show -> CWDice 动画，fire-and-forget）、UI（回合/胜方/日志）。
## 不碰任何规则：规则全在 ElmGame.update 纯函数里。
class_name ElmDemo
extends Node2D

const N_PLAYERS := 4
const SEED := 20260828
const STEP_EVERY := 0.08   ## 每次推进的间隔秒
const STEP_COUNT := 2      ## 每次推进几步（逻辑快于渲染，演出追赶）
const SHOW_LOGS := 14      ## 日志面板显示最近多少条

var session: ElmSession
var board: Node2D
var dice: CWDice
var _tick := 0.0
var _done := false
var _roll_queue: Array = []   ## 待播的 roll_show 队列（单骰子串行播放）

var _status_label: Label
var _log_label: Label


func _ready() -> void:
	board = get_node_or_null("Board")
	# 骰子：挂在棋盘下，参与组织块的 z 排序
	dice = CWDice.new()
	dice.pixelate = true
	board.add_child(dice)
	_build_ui()
	# 建对局（默认启发式 AI 桥，全部玩家）
	session = ElmSession.new()
	session.on_roll = _on_roll
	session.init_game(CWData.FACTION_ORDER[N_PLAYERS], SEED)
	board.refresh(session.state)
	_update_ui()
	print("[ElmDemo] 开局：%d 人局 seed=%d（ElmSession 驱动）" % [N_PLAYERS, SEED])


func _process(delta: float) -> void:
	# 串行播骰子：上一颗静止（visible=false）再播下一颗
	if not dice.visible and _roll_queue.size() > 0:
		var fx: Dictionary = _roll_queue.pop_front()
		dice.place_at(board.tile_center(fx.get("at", Vector2i.ZERO)))
		dice.play(fx["value"], fx["sides"], true)
	if _done:
		return
	_tick += delta
	if _tick >= STEP_EVERY:
		_tick = 0.0
		_advance()


func _advance() -> void:
	for i in STEP_COUNT:
		session.step()
		if String(session.pc) == "DONE":
			_done = true
			break
	board.refresh(session.state)
	_update_ui()
	if _done:
		var wname: String = "免疫" if session.state["winner"] == CWData.Faction.IMMUNE else "癌症"
		print("[ElmDemo] 对局结束：%s 胜（回合 %d，logs %d，渲染细胞 %d）" % [
			wname, session.state["round_no"], session.state["logs"].size(), board._cells.size()])


## 演出通知（逻辑不等）：排队播放骰子动画。at=目标格（引擎给，表现层猜不出来）。
func _on_roll(fx: Dictionary) -> void:
	_roll_queue.append(fx)


func _update_ui() -> void:
	var st: Dictionary = session.state
	if _done:
		var wname: String = "免疫" if st["winner"] == CWData.Faction.IMMUNE else "癌症"
		_status_label.text = "对局结束：%s 胜利（回合 %d）· 回车重开" % [wname, st["round_no"]]
	else:
		var who: String = ""
		if st["pending"] != null:
			who = "　等待：%s（%s）" % [
				st["players"][st["pending"]["pid"]]["name"], st["pending"]["kind"]]
		_status_label.text = "第 %d 回合 · %s%s" % [st["round_no"],
			"免疫记忆 %d 级 %d" % [st["memory"], st["immune_level"]], who]
	var logs: Array = st["logs"]
	var start: int = maxi(0, logs.size() - SHOW_LOGS)
	_log_label.text = "\n".join(logs.slice(start, logs.size()))


func _unhandled_key_input(event: InputEvent) -> void:
	# 回车重开一局（新的同种子对局，方便反复观看）
	if event is InputEventKey and event.pressed and event.keycode == KEY_ENTER:
		_restart()


func _restart() -> void:
	for cid in board._cells.keys():
		board._cells[cid].queue_free()
	board._cells.clear()
	_done = false
	_roll_queue.clear()
	session.init_game(CWData.FACTION_ORDER[N_PLAYERS], SEED)
	board.refresh(session.state)
	_update_ui()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var panel := Panel.new()
	panel.position = Vector2(10, 10)
	panel.size = Vector2(330, 210)
	layer.add_child(panel)
	_status_label = Label.new()
	_status_label.position = Vector2(16, 14)
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	panel.add_child(_status_label)
	_log_label = Label.new()
	_log_label.position = Vector2(16, 42)
	_log_label.size = Vector2(300, 150)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_log_label.add_theme_font_size_override("font_size", 11)
	_log_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	panel.add_child(_log_label)
