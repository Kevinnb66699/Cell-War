## cw_kernel_bridge.gd —— InProc 句柄塞进 CWGame.bridges 的**唯一**桥（口径二 · 批 0 步 9）
##
## 每个 pid 都注册同一个对象：cw_game.gd:711-716 / _unique_bridges 按桥对象去重照常成立，演出只演一次。
## 十个 show_* 逐条翻译成条目入队（字段逐字照 cw_net_bridge.gd:34-80）；ask 转交 decider 或入队等 answer()；
## show_roll 入队后 await barrier（没有消费者时立即返回）。这些都在 CWKernelInProc 里做，这里只转发。
class_name CWKernelBridge
extends CWBridge

var kernel: CWKernelInProc


func ask(req: Dictionary) -> int:
	return await kernel._on_ask(req)


func show_roll(reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
	await kernel._on_roll({ "reason": reason, "value": value, "sides": sides, "pid": pid, "at": at })


func show_result(text: String, at: Vector2i, linger := false) -> void:
	kernel._push("result", { "text": text, "at": at, "linger": linger })


func show_card_played(pid: int, text: String, info := {}) -> void:
	var m := { "pid": pid, "text": text }
	m.merge(info)
	kernel._push("card_played", m)


func show_event_drawn(pid: int, info := {}) -> void:
	var m := { "pid": pid }
	m.merge(info)
	kernel._push("event_drawn", m)



func show_card_drawn(pid: int, info := {}) -> void:
	var m := { "pid": pid }
	m.merge(info)
	kernel._push("card_drawn", m)


func show_notice(text: String) -> void:
	kernel._push("notice", { "text": text })


func show_beam(from: Vector2i, to: Vector2i, splash: Array) -> void:
	kernel._push("beam", { "from": from, "to": to, "splash": splash })


func show_erosion(at: Vector2i, dir: int) -> void:
	kernel._push("erosion", { "at": at, "dir": dir })


func show_fx(kind: String, data: Dictionary) -> void:
	kernel._push("fx", { "kind": kind, "data": data })
