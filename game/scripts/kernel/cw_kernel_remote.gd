## cw_kernel_remote.gd —— 联机路的句柄（口径二 · 批 0 步 11：**只读适配器，不接进 match.gd**）
##
## 一一对上今天的代码：句柄本体 = CWNetClient（cw_net_client.gd）· 镜像 = shadow · observe 的装载 = shadow.restore(view)
## · 条目队列 = stream + STREAM_KINDS（cw_net_client.gd:44-45）· answer(ask_id, index)（:204-207）· 换局边界 m["game"] != _game_no · close = dispose()。
## 批 0 只做一件事：把 client.stream 里的报文翻成协议条目（只读、旁路），证明形状对得上。
## 对端不可知：只认「一条有序报文流 + 一个 answer 出口」，Godot 房间还是 C# 服务都行 —— 服务器走 (a) 还是 (b) 不阻塞这里。
## 报文 → 条目：state → sync{envelope}（批 0 先原样装报文，观测协议 v1 落地后换成 envelope）；ask / game_over 照字段；十种演出报文字段本来就同形（cw_net_bridge.gd:34-80）。
class_name CWKernelRemote
extends CWKernel

var client                       ## CWNetClient（鸭子类型：要有 stream: Array、answer(ask_id, index)；测试用假客户端）
var _entries: Array = []
var _next_seq := 1
var _asks := {}                  ## ask_id → req（answer 按键翻下标要它）


func open(cfg: Dictionary) -> bool:
	client = cfg.get("client", null)
	if client == null:
		_set_fault(Fault.SPAWN_FAILED, "没有联机客户端")
		_set_state(State.UNAVAILABLE)
		return false
	_set_state(State.READY)
	return true


func close() -> void:
	if client != null and client.has_method("dispose"):
		client.dispose()
	client = null


func abort() -> void:
	_asks.clear()


func version() -> Dictionary:
	return { "host_abi": 1, "rules_build": "remote", "ruleset_digest": "" }


func caps() -> Dictionary:
	return { "stream_sync": true, "step_drive": false, "rollout": false, "save": false, "authority": false }


## 把客户端已收进 stream 的报文全部翻成条目（顺序不变，报文原样 pop 掉）。调用方在 pull 之前调一次
func drain() -> int:
	if client == null:
		return 0
	var n := 0
	while not client.stream.is_empty():
		_translate(client.stream.pop_front())
		n += 1
	return n


## 服务器发下来的已经按席位裁过（cw_net.gd view_for / 只把 ask 发给被问的席位），这里不再裁
func pull(_viewer: int, since_seq: int, limit := 64) -> Array:
	var out: Array = []
	for e: Dictionary in _entries:
		if int(e["seq"]) <= since_seq:
			continue
		out.append(e)
		if out.size() >= limit:
			break
	return out


## 内核发完就走（规格 A-3.4）：ack 在这条路上没有对端要通知
func ack(_seq: int) -> void:
	pass


func answer(ask_id: int, choice: Dictionary) -> bool:
	if client == null or not _asks.has(ask_id):
		return false
	var req: Dictionary = _asks[ask_id]
	var opts: Array = req["options"]
	var idx := -1
	if choice.has("key"):
		var want := String(choice["key"])
		for i in opts.size():
			if CWSemKey.key(req, opts[i]["data"]) == want:
				idx = i
				break
	if idx < 0 and choice.has("index"):
		idx = int(choice["index"])
	if idx < 0 or idx >= opts.size():
		return false
	_asks.erase(ask_id)
	client.answer(ask_id, idx)   ## 线上仍是下标（批 0 不碰报文，批 1 升号时改）
	if _state == State.AWAITING:
		_set_state(State.READY)
	return true


func _translate(m: Dictionary) -> void:
	var kind := String(m.get("t", ""))
	var e: Dictionary
	match kind:
		"state":
			e = { "envelope": m }
			kind = "sync"
		"ask":
			e = { "ask_id": int(m["ask_id"]), "req": m["req"], "left_ms": int(m.get("left_ms", -1)) }
			_asks[int(m["ask_id"])] = m["req"]
			_set_state(State.AWAITING)
		"game_over":
			e = { "winner": int(m["winner"]), "reason": String(m.get("reason", "")), "kind": String(m.get("kind", "")),
				"round": int(m.get("round", 0)), "replay": m.get("replay", {}) }
			_set_state(State.ENDED)
		"roll", "result", "notice", "erosion", "beam", "fx", "card_played", "event_drawn", "card_drawn", "world_event":
			e = m.duplicate()
			e.erase("t")
		_:
			return   ## room / chat / pong… 不是对局流，不进条目
	e["t"] = kind
	e["seq"] = _next_seq
	e["barrier"] = kind == "roll"
	_next_seq += 1
	_entries.append(e)
	entry_ready.emit()
