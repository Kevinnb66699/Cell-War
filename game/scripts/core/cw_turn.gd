## cw_turn.gd —— 玩家回合循环：按行动顺序，反复询问「下一个行动」直到结束回合
##
## 规则：回合内可以任意顺序发动任意次主动技能，因此这里是「选行动→执行→再选」的循环。
## guard 上限防止桥实现异常时死循环（正常对局远达不到）。
class_name CWTurn
extends RefCounted

const MAX_ACTIONS_PER_TURN := 80

var game: CWGame


func run_all() -> void:
	for pid in game.order:
		if game.winner >= 0 or game.aborted:
			return
		var cell: Dictionary = game.cell_of(pid)
		if not cell["alive"]:
			game.log_msg("（%s 已死亡，跳过回合）" % game.player(pid)["name"])
			continue
		await _run_player_turn(pid, cell)


func _run_player_turn(pid: int, cell: Dictionary) -> void:
	game.current_pid = pid    ## 只给界面看，见 CWGame.current_pid
	game.log_msg("▶ %s 的回合（能量 %s）" % [game.player(pid)["name"], CWData.fmt(cell["energy"])])
	var guard := 0
	while guard < MAX_ACTIONS_PER_TURN and game.winner < 0 \
			and cell["alive"] and not game.aborted:
		guard += 1
		var options: Array = game.actions.build_options(cell)
		if options.size() <= 1:
			break  # 只剩「结束回合」
		var idx: int = await game.ask(pid, {
			"kind": "action", "prompt": "选择行动", "options": options,
		})
		var data: Dictionary = options[idx]["data"]
		if data["act"] == "end":
			break
		await game.actions.execute(cell, data)
	game.log_msg("　%s 结束回合（能量 %s）" % [game.player(pid)["name"], CWData.fmt(cell["energy"])])
	game.current_pid = -1
