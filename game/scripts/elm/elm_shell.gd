## elm_shell.gd -- 外壳：唯一接触外部世界。
##
## 循环 update -> 执行 effects -> 把决策变 msg 喂回。
##   · ask    -> 问桥拿 idx（唯一让逻辑停的点）
##   · roll_show -> 进演出队列，不 await（逻辑不等动画，UI 异步追赶）
##   · log    -> 打印
## core 不碰桥，桥是 shell 的插件。状态链 append 每步新 state。
class_name ElmShell
extends RefCounted

## 鸭子类型：桥只要有 `func ask(req) -> int` 即可（AI / UI / 联机对端是不同实现）
var bridge


func run(seed_value: int, n_players: int) -> Dictionary:
	var state := ElmCore.make_initial_state(seed_value, n_players)
	var chain: Array = [state]
	var rolls: Array = []  # 演出队列：roll_show effect 收集于此，UI 异步播，逻辑不等
	var msg: Dictionary = {}
	var steps := 0
	while state.pc != "DONE" and steps < 1000:
		var r := ElmCore.update(state, msg)
		state = r["state"]
		chain.append(state)
		msg = {}  # 默认空（纯推进）；若遇到 ask 则填 decision
		for fx in r["effects"]:
			match fx["kind"]:
				"ask":
					var idx: int = bridge.ask(fx["req"])
					msg = { "kind": "decision", "idx": idx }
				"roll_show":
					rolls.append(fx)  # 不 await，逻辑继续
				"log":
					print("[log] " + String(fx.get("text", "")))
		steps += 1
	return { "state": state, "chain": chain, "steps": steps, "rolls": rolls }
