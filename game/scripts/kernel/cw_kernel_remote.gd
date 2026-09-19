## cw_kernel_remote.gd —— 联机路的句柄（口径二 · 批 0 步 11 只读适配器；批 1 步 4 补齐 observe / query / game_no / detach / answer 发 key）
##
## 一一对上今天的代码：句柄本体 = CWNetClient（cw_net_client.gd）· 镜像 = shadow → 批 1 换成 CWMirror（sync 条目进来就 load_from）
## · 条目队列 = stream + STREAM_KINDS（cw_net_client.gd:44-45）· answer(ask_id, index, key) · 换局边界 m["game"] != game_no · close = dispose()。
## 对端不可知：只认「一条有序报文流 + 一个 answer 出口」，Godot 房间还是 C# 服务都行 —— 服务器走 (a) 还是 (b) 不阻塞这里。
## 报文 → 条目：sync{envelope, hash, game} → sync{envelope}（hash / game 留在句柄字段上；步 8 之前服务器还发 state{view}，那种整份当 envelope 原样装，装不进镜像）；
## ask / game_over 照字段；十条演出报文 + step_begin / step_end 字段本来就同形（cw_net_bridge.gd:34-80）。
## query（批 1 E-1 (a)）：C→S query{qid, kind, args} / S→C query_result{qid, value}，按 (rev, kind, args) 缓存；没缓存就发 RPC、先返回 null，
## UI 按 caps().query_sync=false 降级（不画多步路线、不出灰格理由），下一帧缓存到了再画。每来一份 sync 缓存作废。
class_name CWKernelRemote
extends CWKernel

var client                       ## CWNetClient（鸭子类型：要有 stream: Array、answer(ask_id, index, key)、send(m)；测试用假客户端）
var game_no := -1                ## 报文外壳上的 games_played：换局边界（envelope 里没有等价物）
var last_hash := ""              ## 服务器的 state_hash（诊断用，不进协议）
var _entries: Array = []
var _next_seq := 1
var _asks := {}                  ## ask_id → req（answer 按键翻下标要它）
var _mirror: CWMirror = null     ## 最近一份 sync 装出来的镜像
var _last_envelope := {}
var _qid := 0
var _cache := {}                 ## 查询键 → value（只保留当前 rev 那一批）
var _inflight := {}              ## 查询键 → qid（在飞的 RPC，别重发）
var _qid_key := {}               ## qid → 查询键


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
	detach()


## 放开镜像与客户端引用、**不** dispose 客户端（联机面板还要用它回大厅）
func detach() -> void:
	client = null
	_mirror = null
	_last_envelope = {}
	_cache.clear()
	_inflight.clear()
	_qid_key.clear()


func abort() -> void:
	_asks.clear()


func version() -> Dictionary:
	return { "host_abi": 1, "rules_build": "remote", "ruleset_digest": "" }


func caps() -> Dictionary:
	return { "stream_sync": true, "step_drive": false, "rollout": false, "save": false, "authority": false, "query_sync": false }


# ---- 观测 ----
## 服务器已按席位裁好，viewer 与 logs_from 在这条路上不生效（日志随 envelope.logs 走）
func observe(_viewer: int, _logs_from := 0) -> RefCounted:
	return _mirror


func observe_envelope(_viewer: int, _logs_from := 0) -> Dictionary:
	return _last_envelope


## 把客户端已收进 stream 的报文全部翻成条目（顺序不变，报文原样 pop 掉）；query_result 另走一条口子。调用方在 pull 之前调一次
func drain() -> int:
	if client == null:
		return 0
	var n := 0
	while not client.stream.is_empty():
		_translate(client.stream.pop_front())
		n += 1
	if "query_results" in client:
		while not client.query_results.is_empty():
			_on_query_result(client.query_results.pop_front())
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


func entry_seq() -> int:
	return _next_seq - 1


## 这一问**还挂在我手上**（收到过、还没 answer 过）。issue #44 的判据：
## 服务器代打（超时 / 掉线即答）之后不会再给我发一条 ask，只推一条 step_begin{ask_id} 往下走 ——
## 那一拍如果这一问在我这儿还挂着，答它的人就不是我。自己答过的一定是 false（answer 里已经 erase）。
func asking(ask_id: int) -> bool:
	return _asks.has(ask_id)


func discard_before(seq: int) -> void:
	var n := 0
	while n < _entries.size() and int(_entries[n]["seq"]) <= seq:
		n += 1
	if n > 0:
		_entries = _entries.slice(n)


# ---- 决策 ----
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
	## 线上带 key + 下标（A-9：服务器按 key 现算反查、下标兜底；两端同源 CWSemKey）
	client.answer(ask_id, idx, CWSemKey.key(req, opts[idx]["data"]))
	if _state == State.AWAITING:
		_set_state(State.READY)
	return true


# ---- 纯查询（E-1 (a)：RPC + 按 rev 缓存）----
func query(kind: String, args: Dictionary) -> Variant:
	if client == null:
		return null
	var key := "%s|%s" % [kind, var_to_str(args)]
	if _cache.has(key):
		return _cache[key]
	if not _inflight.has(key) and client.has_method("send"):
		_qid += 1
		_inflight[key] = _qid
		_qid_key[_qid] = key
		client.send({ "t": "query", "qid": _qid, "kind": kind, "args": args })
	return null


func _on_query_result(m: Dictionary) -> void:
	var qid := int(m.get("qid", -1))
	if not _qid_key.has(qid):
		return   ## 上一份 sync 之前发的问，结果已经过期
	var key: String = _qid_key[qid]
	_qid_key.erase(qid)
	_inflight.erase(key)
	_cache[key] = m.get("value", null)


func _translate(m: Dictionary) -> void:
	var kind := String(m.get("t", ""))
	var e: Dictionary
	match kind:
		"state", "sync":
			if m.has("envelope"):
				e = { "envelope": m["envelope"] }
				_last_envelope = m["envelope"]
				var mm := CWMirror.new()
				var err := mm.load_from(m["envelope"])
				if err == "":
					_mirror = mm
				else:
					push_error("CWKernelRemote：sync 里的 envelope 装不进镜像：%s" % err)
			else:
				e = { "envelope": m }   ## 步 8 之前的 state{view}：整份当 envelope 原样装（批 0 形状测试），装不进镜像
			game_no = int(m.get("game", game_no))
			last_hash = String(m.get("hash", last_hash))
			## 盘面换了：上一份的查询结果作废（在飞的也作废，回来时对不上 qid 就扔）
			_cache.clear()
			_inflight.clear()
			_qid_key.clear()
			kind = "sync"
		"ask":
			e = { "ask_id": int(m["ask_id"]), "req": m["req"], "left_ms": int(m.get("left_ms", -1)) }
			_asks[int(m["ask_id"])] = m["req"]
			_set_state(State.AWAITING)
		"game_over":
			e = { "winner": int(m["winner"]), "reason": String(m.get("reason", "")), "kind": String(m.get("kind", "")),
				"round": int(m.get("round", 0)), "replay": m.get("replay", {}) }
			_set_state(State.ENDED)
		"query_result":
			_on_query_result(m)
			return
		"roll", "result", "notice", "erosion", "beam", "fx", "card_played", "event_drawn", "card_drawn", "step_begin", "step_end":
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
