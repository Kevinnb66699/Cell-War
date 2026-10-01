## cw_kernel_sidecar.gd —— 本地 C# 内核进程（sidecar）的句柄（换内核 P1，docs/内核替换_重启计划.md §3.1 / §四 P1）
##
## 对消费者与 CWKernelInProc **同形**：同样 15 种条目、同样的 step_end → sync → ask 节拍、同样「有 decider 的席位不出 ask 条目」。
## 差别只在内核住在另一个进程里：
##   · 起法：先在 127.0.0.1 上开临时端口（TCPServer.listen(0)），再 OS.create_process 起
##     `dotnet exec CellWar.Sidecar.dll --connect 127.0.0.1:<端口> --token <一次性随机串>`，它连回来，第一行 hello 带回 token。
##   · 报文：一行一个 JSON，请求 {id, op, sid, …} → 回应 {re, ok, …}。本地回环毫秒级，所以这里**同步**等回应（与 InProc 的同步接口一致），
##     超时 REPLY_TIMEOUT_MS 就当进程坏了（FAULTED）。sidecar 从不主动推送：每帧在 SceneTree.process_frame 上 pull 一次。
##   · 坐标与数字：报文里坐标是 {q,r}、数字是 JSON 浮点；条目与 req 一律过 CWMirror._normalize（与镜像装 envelope 同一套归一化），
##     sync 里的 envelope 原样留着（镜像自己归一化）。
##   · 拆问（C# 组键 → GD 两问）在 C# 宿主里做完了，这里收到的 ask 已经是 GD 形状；选项自带 key，作答一律按 key 交回去。
##
## ⚠ 硬不变量：sidecar 起不来 = UNAVAILABLE + SPAWN_FAILED，**与补丁系统完全隔离**（绝不计进 patch_state.gd 的 STRIKES）。
## P1 还没有的（返回基类的「定义良好的空值」）：日志条目、查询四条、存读档、回放、单步驱动、mark_player / surrender / log_msg —— 见计划 P2 / P4。
class_name CWKernelSidecar
extends CWKernel

const HOST_ABI := 1                 ## 与 C# ObservationV1Codec.HostAbi 同值：握手只闸它（硬不变量③）
const HANDSHAKE_MS := 8000          ## 冷启动 + 连回来 + hello（实测 0.3～0.7 s，留足 CI 满载的余量）
const REPLY_TIMEOUT_MS := 5000
const PULL_LIMIT := 256

var deciders := {}                  ## pid → CWBridge：这一席的 ask 由它作答（与 InProc 同）；没有就入队等 answer()
var observe_viewer: Variant = null
var open_hands := false
var winner := -1

var _server: TCPServer
var _peer: StreamPeerTCP
var _pid := -1
var _token := ""
var _buf := PackedByteArray()
var _next_id := 1
var _sid := -1
var _hello := {}
var _pulled := 0                    ## sidecar 那边已拉到的最后一个 seq
var _entries: Array = []
var _next_seq := 1                  ## 本句柄自己的 seq（有 decider 的 ask 不入队，所以与 sidecar 的 seq 不一一对应）
var _open_ask := {}                 ## 正在等的那一问：{ask_id, req, decider}
var _decider_ask := {}              ## 拉到了、还没交给 decider 的那一问（由 _pump 去答，见那儿的注释）
var _pumping := false
var _ticking := false


# ---- 生命周期 ----
## cfg：factions / seed / observe_viewer / open_hands / decider / deciders（同 InProc）；
## 另有 dotnet / sidecar_dll 两个路径覆盖（测试与打包用；缺省见 find_dotnet / find_sidecar_dll）；
## `ai: {席位: "normal" | "intent" | "search"}` + `ai_delay_ms`（换内核 P3）：那几席由 sidecar 进程里的 C# AI 作答，
## 不出 ask 条目（同有 decider 的席位），句柄照常每帧 pull —— 原样转给 sidecar 的 open。
func open(cfg: Dictionary) -> bool:
	if _state != State.IDLE:
		return false
	_set_state(State.STARTING)
	var dotnet := String(cfg.get("dotnet", find_dotnet()))
	var dll := String(cfg.get("sidecar_dll", find_sidecar_dll()))
	if dotnet == "" or dll == "" or not FileAccess.file_exists(dll):
		return _unavailable("找不到 sidecar（dotnet=%s，dll=%s）" % [dotnet, dll])
	if not _spawn(dotnet, dll):
		return false
	observe_viewer = cfg.get("observe_viewer", null)
	open_hands = bool(cfg.get("open_hands", false))
	var open_cfg := { "factions": cfg.get("factions", []), "seed": int(cfg.get("seed", 1)), "open_hands": open_hands }
	if observe_viewer != null:
		open_cfg["observe_viewer"] = int(observe_viewer)
	if cfg.has("ai"):
		var ai := {}
		for seat in cfg["ai"]:
			ai[str(seat)] = String(cfg["ai"][seat])   ## JSON 的键只能是字符串
		open_cfg["ai"] = ai
		open_cfg["ai_delay_ms"] = int(cfg.get("ai_delay_ms", 0))
	var r := _call("open", { "cfg": open_cfg })
	if not bool(r.get("ok", false)):
		_fail(Fault.PROTOCOL, "open 被拒：%s" % String(r.get("error", "无回应")))
		return false
	_sid = int(r["sid"])
	deciders = {}
	if cfg.has("decider") and cfg["decider"] != null:
		for pid in Array(cfg.get("factions", [])).size():
			deciders[pid] = cfg["decider"]
	if cfg.has("deciders"):
		deciders.merge(cfg["deciders"], true)
	_set_state(State.READY)
	_start_ticking()
	_pump()   ## 开局那段（落子之前）sidecar 已经算完：第一问马上就在
	return true


func close() -> void:
	_stop_ticking()
	if _peer != null and _sid >= 0:
		_call("close", { "sid": _sid })
	_sid = -1
	if _peer != null:
		_peer.disconnect_from_host()   ## 对端关连接 = sidecar 正常退出
		_peer = null
	if _server != null:
		_server.stop()
		_server = null
	if _pid > 0:
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(_pid) and Time.get_ticks_msec() - t0 < 1000:
			OS.delay_msec(10)
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		_pid = -1


func abort() -> void:
	if _sid >= 0 and _peer != null:
		_call("abort", { "sid": _sid })
	abort_ask()


func version() -> Dictionary:
	return { "host_abi": int(_hello.get("host_abi", 0)), "rules_build": String(_hello.get("rules_build", "")),
		"ruleset_digest": String(_hello.get("ruleset_digest", "")) }


func caps() -> Dictionary:
	return { "stream_sync": true, "step_drive": false, "rollout": false, "save": false, "authority": true, "query_sync": true }


## sidecar 进程号（测试看它退没退）
func process_id() -> int:
	return _pid


# ---- 观测 ----
func observe(viewer: int, logs_from := 0) -> RefCounted:
	var env := observe_envelope(viewer, logs_from)
	if env.is_empty():
		return null
	var m := CWMirror.new()
	var err := m.load_from(env)
	if err != "":
		push_error("CWKernelSidecar.observe：envelope 装不进镜像：%s" % err)
		return null
	return m


func observe_envelope(viewer: int, logs_from := 0) -> Dictionary:
	if _sid < 0:
		return {}
	var r := _call("observe", { "sid": _sid, "viewer": viewer, "logs_from": logs_from })
	return r.get("envelope", {}) if bool(r.get("ok", false)) else {}


func pull(viewer: int, since_seq: int, limit := 64) -> Array:
	var out: Array = []
	for e: Dictionary in _entries:
		if int(e["seq"]) <= since_seq:
			continue
		out.append(_crop(viewer, e))
		if out.size() >= limit:
			break
	return out


func entry_seq() -> int:
	return _next_seq - 1


func discard_after(seq: int) -> void:
	var n := _entries.size()
	while n > 0 and int(_entries[n - 1]["seq"]) > seq:
		n -= 1
	_entries.resize(n)


func discard_before(seq: int) -> void:
	var n := 0
	while n < _entries.size() and int(_entries[n]["seq"]) <= seq:
		n += 1
	if n > 0:
		_entries = _entries.slice(n)


## C# 引擎不等动画（设计如此，计划 §3.2），roll 的 barrier 只是标记 —— 演出顺序由 CWPlayQueue 保证
func ack(_seq: int) -> void:
	pass


# ---- 决策 ----
## 键为准、下标兜底（同 InProc.answer）；有 decider 的那一问不收外面的答案
func answer(ask_id: int, choice: Dictionary) -> bool:
	if _open_ask.is_empty() or int(_open_ask["ask_id"]) != ask_id or bool(_open_ask.get("decider", false)):
		return false
	var opts: Array = _open_ask["req"]["options"]
	var key := ""
	if choice.has("key"):
		key = String(choice["key"])
	elif choice.has("index"):
		var i := int(choice["index"])
		if i < 0 or i >= opts.size():
			return false
		key = String(opts[i]["key"])
	if key == "" or not _submit(ask_id, key):
		return false
	_open_ask = {}
	_set_state(State.READY)
	_pump()   ## 这一步的演出与下一问马上就在（与 InProc 同步跑到下一问同义）
	return true


## 叫醒卡在 decider 里的那一问（拆局 / 教程跨章，同 InProc 的理由）；外面等着的那一问作废、不替它作答
func abort_ask() -> void:
	var seen: Array = []
	for d in deciders.values():
		if d != null and not seen.has(d) and d.has_method("abort"):
			seen.append(d)
			d.abort()
	_open_ask = {}
	_decider_ask = {}


func set_decider(b: Object) -> void:
	if b == null:
		return
	for pid in deciders.keys():
		deciders[pid] = b


# ---- 找 sidecar ----
## dotnet 宿主：环境变量 CW_DOTNET 优先，其次几个常见安装位置（Mac 上是 ~/.dotnet）。打包后的路由 P7 再加
static func find_dotnet() -> String:
	var env := OS.get_environment("CW_DOTNET")
	if env != "" and FileAccess.file_exists(env):
		return env
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	for p in [home.path_join(".dotnet/dotnet"), home.path_join(".dotnet/dotnet.exe"), "/usr/local/share/dotnet/dotnet",
			"/opt/homebrew/bin/dotnet", "/usr/share/dotnet/dotnet", "/usr/lib/dotnet/dotnet", "C:/Program Files/dotnet/dotnet.exe"]:
		if FileAccess.file_exists(p):
			return p
	return ""


## 开发期：仓库里 core/CellWar.Sidecar 的 Debug 产物（game/ 的上一层）。环境变量 CW_SIDECAR_DLL 覆盖
static func find_sidecar_dll() -> String:
	var env := OS.get_environment("CW_SIDECAR_DLL")
	if env != "":
		return env
	return ProjectSettings.globalize_path("res://").path_join("../core/CellWar.Sidecar/bin/Debug/net10.0/CellWar.Sidecar.dll").simplify_path()


# ---- 内部：进程与报文 ----
func _spawn(dotnet: String, dll: String) -> bool:
	_server = TCPServer.new()
	if _server.listen(0, "127.0.0.1") != OK:
		return _unavailable("回环端口开不了")
	var port := _server.get_local_port()
	_token = Crypto.new().generate_random_bytes(16).hex_encode()
	_pid = OS.create_process(dotnet, ["exec", dll, "--connect", "127.0.0.1:%d" % port, "--token", _token])
	if _pid <= 0:
		_pid = -1
		return _unavailable("起不了 sidecar 进程：%s %s" % [dotnet, dll])
	var t0 := Time.get_ticks_msec()
	while not _server.is_connection_available():
		if not OS.is_process_running(_pid):
			return _unavailable("sidecar 进程起来就退了（退出码 %d）" % OS.get_process_exit_code(_pid))
		if Time.get_ticks_msec() - t0 > HANDSHAKE_MS:
			_fail(Fault.HANDSHAKE_TIMEOUT, "sidecar %d ms 内没连回来" % HANDSHAKE_MS)
			return false
		OS.delay_msec(5)
	_peer = _server.take_connection()
	_server.stop()   ## 只等这一条连接：端口用完即关，别的本机进程再也连不进来
	_server = null
	var line := _read_line(HANDSHAKE_MS)
	var hello = JSON.parse_string(line) if line != "" else null
	if not (hello is Dictionary) or not (hello.get("hello") is Dictionary):
		_fail(Fault.HANDSHAKE_TIMEOUT, "没收到 hello")
		return false
	_hello = CWMirror._normalize(hello["hello"])
	if String(_hello.get("token", "")) != _token:
		_fail(Fault.PROTOCOL, "hello 的 token 对不上")
		return false
	if int(_hello.get("host_abi", 0)) != HOST_ABI:
		_fail(Fault.ABI_MISMATCH, "宿主 ABI %d，本客户端要 %d" % [int(_hello.get("host_abi", 0)), HOST_ABI])
		return false
	return true


func _call(op: String, args := {}) -> Dictionary:
	if _peer == null:
		return {}
	var id := _next_id
	_next_id += 1
	var msg := args.duplicate()
	msg["id"] = id
	msg["op"] = op
	if _peer.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer()) != OK:
		_fail(Fault.CRASHED, "写不进 sidecar 连接（%s）" % op)
		return {}
	while true:
		var line := _read_line(REPLY_TIMEOUT_MS)
		if line == "":
			_fail(Fault.CRASHED, "sidecar %d ms 内没回 %s" % [REPLY_TIMEOUT_MS, op])
			return {}
		var r = JSON.parse_string(line)
		if r is Dictionary and r.has("re") and int(r["re"]) == id:
			if not bool(r.get("ok", false)):
				push_error("CWKernelSidecar：%s 被拒：%s" % [op, String(r.get("error", ""))])
			return r
	return {}


## 读一行（不含换行）；连接断了或超时返回 ""
func _read_line(timeout_ms: int) -> String:
	var t0 := Time.get_ticks_msec()
	while true:
		var nl := _buf.find(10)
		if nl >= 0:
			var line := _buf.slice(0, nl).get_string_from_utf8()
			_buf = _buf.slice(nl + 1)
			return line
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return ""
		var n := _peer.get_available_bytes()
		if n > 0:
			var got: Array = _peer.get_partial_data(n)
			if int(got[0]) == OK:
				_buf.append_array(got[1])
			continue
		if Time.get_ticks_msec() - t0 > timeout_ms:
			return ""
		OS.delay_usec(200)
	return ""


func _submit(ask_id: int, key: String) -> bool:
	var r := _call("answer", { "sid": _sid, "ask_id": ask_id, "key": key })
	return bool(r.get("accepted", false))


# ---- 内部：条目 ----
func _start_ticking() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.process_frame.is_connected(_tick):
		tree.process_frame.connect(_tick)
		_ticking = true


func _stop_ticking() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if _ticking and tree != null and tree.process_frame.is_connected(_tick):
		tree.process_frame.disconnect(_tick)
	_ticking = false


func _tick() -> void:
	if _peer == null or _sid < 0 or _state == State.FAULTED or _state == State.UNAVAILABLE:
		return
	if _pid > 0 and not OS.is_process_running(_pid):
		_fail(Fault.CRASHED, "sidecar 进程退出了（退出码 %d）" % OS.get_process_exit_code(_pid))
		return
	_pump()


## 把 sidecar 那边的新条目全拉过来、翻成 GD 形状入队
func _drain() -> void:
	while _sid >= 0 and _peer != null:
		var r := _call("pull", { "sid": _sid, "viewer": VIEWER_OMNISCIENT, "since": _pulled, "limit": PULL_LIMIT })
		if not bool(r.get("ok", false)):
			return
		var batch: Array = r.get("entries", [])
		for raw: Dictionary in batch:
			_accept(raw)
		if batch.size() < PULL_LIMIT:
			return


func _accept(raw: Dictionary) -> void:
	_pulled = int(raw["seq"])
	var kind := String(raw["t"])
	match kind:
		"sync":
			_push("sync", { "envelope": raw["envelope"] })   ## envelope 原样：镜像自己归一化
		"ask":
			var req: Dictionary = CWMirror._normalize(raw["req"])
			var ask_id := int(raw["ask_id"])
			var pid := int(req.get("pid", -1))
			if deciders.has(pid):
				_open_ask = { "ask_id": ask_id, "req": req, "decider": true }   ## 有 decider 的席位不出 ask 条目（同 InProc）
				_decider_ask = { "ask_id": ask_id, "req": req }
				_set_state(State.AWAITING)
			else:
				_open_ask = { "ask_id": ask_id, "req": req, "decider": false }
				_set_state(State.AWAITING)
				_push("ask", { "ask_id": ask_id, "req": req, "left_ms": int(raw.get("left_ms", -1)) })
		"game_over":
			var g: Dictionary = CWMirror._normalize(raw)
			winner = int(g["winner"])
			_push("game_over", { "winner": winner, "reason": String(g.get("reason", "")), "kind": String(g.get("kind", "")),
				"round": int(g.get("round", 0)), "replay": g.get("replay", {}) })
			_set_state(State.ENDED)
		_:
			var e: Dictionary = CWMirror._normalize(raw)
			var barrier := bool(e.get("barrier", false))
			e.erase("t")
			e.erase("seq")
			e.erase("barrier")
			_push(kind, e, barrier)


## 拉条目 + 替 decider 作答的唯一循环。**不许递归**：同步作答的 decider（无头测试、脚本 NPC）一局几千问，
## 「拉到 ask → 作答 → 再拉」要是层层调用，几千层就爆栈。所以拉条目（_drain）只把 decider 那一问记进 _decider_ask，
## 由这里一问一问地答；decider 要等人（界面桥）时这条协程挂起，期间 _tick 再进来直接返回（_pumping）。
func _pump() -> void:
	if _pumping:
		return
	_pumping = true
	while _sid >= 0 and _peer != null:
		_drain()
		if _decider_ask.is_empty():
			break
		var a: Dictionary = _decider_ask
		_decider_ask = {}
		var ask_id := int(a["ask_id"])
		var req: Dictionary = a["req"]
		var idx: int = await deciders[int(req["pid"])].ask(req)
		if _open_ask.is_empty() or int(_open_ask["ask_id"]) != ask_id or _sid < 0:
			break   ## 等的时候被 abort / close 了
		_open_ask = {}
		var opts: Array = req["options"]
		if opts.is_empty() or not _submit(ask_id, String(opts[clampi(idx, 0, opts.size() - 1)]["key"])):
			_fail(Fault.PROTOCOL, "decider 的答案被 sidecar 拒了（ask %d）" % ask_id)
			break
		if _state == State.AWAITING:
			_set_state(State.READY)
	_pumping = false


func _push(kind: String, m: Dictionary, barrier := false) -> int:
	var e := m.duplicate()
	e["t"] = kind
	e["seq"] = _next_seq
	e["barrier"] = barrier
	_next_seq += 1
	_entries.append(e)
	entry_ready.emit()
	return int(e["seq"])


## 同 InProc._crop：ask 只给主人完整选项，观众 / 别的席位只留 kind / tag / seat / prompt（P1 没有日志条目，没有秘密行要换）
func _crop(viewer: int, e: Dictionary) -> Dictionary:
	if viewer == VIEWER_OMNISCIENT or String(e["t"]) != "ask":
		return e
	var req: Dictionary = e["req"]
	if int(req.get("pid", -1)) == viewer:
		return e
	var c := e.duplicate()
	var r := req.duplicate()
	r["options"] = []
	c["req"] = r
	return c


func _unavailable(msg: String) -> bool:
	_set_fault(Fault.SPAWN_FAILED, msg)
	_set_state(State.UNAVAILABLE)
	_cleanup_process()
	return false


func _fail(fault: int, msg: String) -> void:
	if _state == State.FAULTED:
		return
	push_error("CWKernelSidecar：%s" % msg)
	_set_fault(fault, msg)
	_set_state(State.FAULTED)
	_stop_ticking()
	_open_ask = {}
	_cleanup_process()


func _cleanup_process() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
		_server = null
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_sid = -1
