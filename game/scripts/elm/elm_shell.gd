## elm_shell.gd -- 外壳：状态机的**推动者**（事件源）。
##
## 状态机不等待；shell 读 state 决定发什么 msg 来推动它：
##   · state 在 ask（pending != null）-> 读 pending 构造 req 问桥，发 decision msg
##   · state 在内部环节（pending == null）-> 发 step msg 推进
##   · state 已 DONE -> 停
## effects 里：roll_show 进演出队列（不阻塞），log 打印，ask 是通知（shell 已读
## state.pending 驱动，不依赖此 effect，但 UI 可订阅它来高亮）。
class_name ElmShell
extends RefCounted

## 鸭子类型：桥只要有 `func ask(req) -> int` 即可
var bridge


func run(seed_value: int, n_players: int) -> Dictionary:
	var state := ElmCore.make_initial_state(seed_value, n_players)
	var chain: Array = [state]
	var rolls: Array = []  # 演出队列：UI 异步播，逻辑不等
	var steps := 0
	while state.pc != "DONE" and steps < 1000:
		# shell 是驱动者：读 state 决定发什么 msg
		var msg: Dictionary
		if state.pending != null:
			# state 停在 ask：外界读 pending 知道问什么，发 decision 推动
			var req: Dictionary = {
				"kind": state.pending["kind"],
				"options": state.pending["options"],
			}
			var idx: int = bridge.ask(req)
			msg = { "kind": "decision", "idx": idx }
		else:
			# state 在内部环节：发 step 推进
			msg = { "kind": "step" }
		var r := ElmCore.update(state, msg)
		state = r["state"]
		chain.append(state)
		for fx in r["effects"]:
			match fx["kind"]:
				"roll_show":
					rolls.append(fx)
				"log":
					print("[log] " + String(fx.get("text", "")))
				"ask":
					pass  # 通知；shell 已读 state.pending 驱动
		steps += 1
	return { "state": state, "chain": chain, "steps": steps, "rolls": rolls }


## 驱动 SETUP 阶段到 SETUP_DONE（迁移 cw_setup 的验证用）。
## 桥只被问 setup_place（返回落子下标）。
func run_to_setup(seed_value: int, faction_list: Array, tune) -> Dictionary:
	var state := ElmGame.make_initial_state(seed_value, faction_list, tune)
	var chain: Array = [state]
	var steps := 0
	while String(state.pc) != "SETUP_DONE" and steps < 1000:
		var msg: Dictionary
		if state.pending != null:
			var req: Dictionary = {
				"kind": state.pending["kind"],
				"options": state.pending["options"],
			}
			var idx: int = bridge.ask(req)
			msg = { "kind": "decision", "idx": idx }
		else:
			msg = { "kind": "step" }
		var r := ElmGame.update(state, msg)
		state = r["state"]
		chain.append(state)
		for fx in r["effects"]:
			if fx["kind"] == "log":
				print("[log] " + String(fx.get("text", "")))
		steps += 1
	return { "state": state, "chain": chain, "steps": steps }
