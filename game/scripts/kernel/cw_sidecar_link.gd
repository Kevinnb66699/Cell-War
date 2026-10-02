## cw_sidecar_link.gd —— 一个 sidecar 进程 + 一条本机回环连接，**多个句柄（会话）共用**（换内核，2026-10-01）
##
## 为什么要共用：教程通关一遍要装 17 次局（关首 + 关内换盘 + 间章），服务器同时开着很多房间 ——
## 每个句柄各起一个 .NET 进程，开局多 100 ms、内存成倍涨。sidecar 那边本来就是「一连接多会话」（报文带 sid）。
##
## 生命周期：同一份产物（dotnet + dll）只起一个进程；句柄 `acquire` 时引用 +1、`release` 时 −1。
## 降到 0 不立刻关 —— 空闲 LINGER_MS 之后还没人用才关（关内换盘是「先关旧句柄再开新的」，中间正好是 0）。
## 测试 / 退出时要立刻关就调 `shutdown_idle()`。
##
## 故障分两级：**链路级**（进程退出、连接断、回应超时、握手失败）记在这里，所有挂在上面的句柄都看得见、都转 FAULTED；
## **会话级**（某个答案被拒）只坏那一个句柄，链路照常给别的会话用。
## 链路死在某条**跑规则的**请求（RULE_OPS：作答 / AI 交一步 / 换手 / 投降…）半中间就记下那条请求的会话号 `fault_sid`：
## 服务器从检查点重起时按它分清是谁惹的（cw_net_pump.gd:recover 的「记账」）。每个句柄每帧都要 pull、推状态要 observe、
## 每步要 save —— 这些只读请求碰巧赶上进程死（多半死在别人的后台线程里）不算它惹的（10-01 二轮复核）。
## 限流（只在专用服务器上开：`limits`，server_main.gd 打开；桌面「继续对局」是玩家亲手点的，必须真去起 —— 10-01 二轮复核）：
## 握手卡死过（进程起来了却不连回来）SPAWN_BACKOFF_MS 内不再起；起来了却当场失败（起来就退了 / ABI 对不上…）FAILED_SPAWN_BACKOFF_MS 内不再起
##（所有房间共用这一次尝试，不各起各的）；DEATH_WINDOW_MS 内进程死了 DEATH_BURST 次也停 BREAKER_MS —— 服务器单线程，
## 每起一次卡住就是全服冻 9 秒。这期间 acquire 当场给一条起不来的链路（SPAWN_FAILED）。
## ⚠ 与补丁系统完全隔离：起不来只是 UNAVAILABLE，绝不计进 patch_state.gd 的 STRIKES。
extends RefCounted

const HOST_ABI := 1                 ## 与 C# ObservationV1Codec.HostAbi 同值：握手只闸它（硬不变量③）
const HANDSHAKE_MS := 8000
const REPLY_TIMEOUT_MS := 5000
const LINGER_MS := 30000
const SPAWN_BACKOFF_MS := 30000
const DEATH_WINDOW_MS := 60000
const DEATH_BURST := 5
const BREAKER_MS := 30000
const FAILED_SPAWN_BACKOFF_MS := 5000
## 跑规则的请求：链路死在这些请求半中间才记 fault_sid（见文件头）
const RULE_OPS := ["answer", "ai_step", "set_ai", "surrender", "log_msg", "open", "restore", "mark_player", "abort"]

static var limits := false          ## 限流开不开（见文件头）：专用服务器 server_main.gd 打开，桌面 / 局域网开服 / 测试缺省关

static var _links := {}             ## "dotnet|dll" → 活着的链路
static var _blocked_until := {}     ## "dotnet|dll" → 这个时刻（ms）之前不再起进程（见文件头「限流」）
static var _deaths := {}            ## "dotnet|dll" → 最近几次进程死掉的时刻（ms）

var dotnet := ""
var dll := ""
var pid := -1
var hello := {}
var fault := 0                      ## CWKernel.Fault；0 = 好的
var fault_msg := ""
var fault_sid := -1                 ## 链路死在哪个会话的请求半中间（-1 = 不在任何请求里，比如进程自己退了、下一条请求才发现）
var users := 0
var _server: TCPServer
var _peer: StreamPeerTCP
var _token := ""
var _buf := PackedByteArray()
var _next_id := 1
var _idle_since := -1               ## users 降到 0 的时刻（ms）；-1 = 有人在用


## 拿一条能用的链路：同一份产物已有活着的就复用，否则起一个。返回的链路 `fault != 0` 就是没起来（调用方转 UNAVAILABLE / FAULTED）
static func acquire(dotnet_path: String, dll_path: String) -> RefCounted:
	var key := dotnet_path + "|" + dll_path
	var link = _links.get(key)
	if link != null and link.alive():
		link.users += 1
		link._idle_since = -1
		return link
	link = new()
	link.dotnet = dotnet_path
	link.dll = dll_path
	var now := Time.get_ticks_msec()
	if limits and now < int(_blocked_until.get(key, 0)):
		link.fault = CWKernel.Fault.SPAWN_FAILED
		link.fault_msg = "sidecar 刚刚起不来 / 连着崩了几次，%d 秒内不再起" % ceili((int(_blocked_until[key]) - now) / 1000.0)
		return link
	if link._spawn():
		link.users = 1
		_links[key] = link
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and not tree.process_frame.is_connected(link._idle_tick):
			tree.process_frame.connect(link._idle_tick)
	elif limits and int(link.fault) == CWKernel.Fault.HANDSHAKE_TIMEOUT:
		_blocked_until[key] = Time.get_ticks_msec() + SPAWN_BACKOFF_MS   ## 起来了却不连回来：下一次多半还是卡 8 秒，先别起
	elif limits and int(link.pid) > 0:
		_blocked_until[key] = Time.get_ticks_msec() + FAILED_SPAWN_BACKOFF_MS   ## 进程起来了却当场失败：别让每个房间各起一遍
	return link


## 清掉限流的记账（测试每支开跑前调：上一支故意崩的那几次不该让这一支起不来）
static func reset_limits() -> void:
	_blocked_until.clear()
	_deaths.clear()


## 空闲的链路立刻关（测试看进程退没退、游戏退出前）
static func shutdown_idle() -> void:
	for key in _links.keys():
		var link = _links[key]
		if link.users <= 0:
			link.shutdown()


func release() -> void:
	users = maxi(users - 1, 0)
	if users == 0:
		_idle_since = Time.get_ticks_msec()


func alive() -> bool:
	return fault == 0 and _peer != null and pid > 0 and OS.is_process_running(pid)


## 同步发一条请求、等它的回应（本机回环毫秒级；与 InProc 的同步接口一致）。链路坏了返回 {}，`fault` 说明原因
func request(op: String, args := {}) -> Dictionary:
	if not alive():
		if fault == 0:
			_die(CWKernel.Fault.CRASHED, "sidecar 进程已经不在了（退出码 %d）" % OS.get_process_exit_code(pid) if pid > 0 else "sidecar 没起来")
		return {}
	var id := _next_id
	_next_id += 1
	## id 排第一：报文坏到 sidecar 解析不了时，它从行首把号捞回来照样回（Program.Serve），这边不至于干等 5 秒。
	## JSON.stringify 缺省按键排序（"args" / "ask_id" 会排到 "id" 前面）—— 第三个参数 false 才照插入的次序写（10-01 三轮复核）
	var msg := { "id": id, "op": op }
	msg.merge(args)
	if _peer.put_data((JSON.stringify(msg, "", false) + "\n").to_utf8_buffer()) != OK:
		fault_sid = int(args.get("sid", -1)) if op in RULE_OPS else -1
		_die(CWKernel.Fault.CRASHED, "写不进 sidecar 连接（%s）" % op)
		return {}
	while true:
		var line := _read_line(REPLY_TIMEOUT_MS)
		if line == "":
			## 读不到有两种，分开记（给玩家的那句话按它挑，2026-10-01）：连接已经断了 = 进程没了（多半当场就断，
			## 不是等满 5 秒）；连接还在却等满了 = 它卡住了。以前一律记成 CRASHED「N ms 内没回」，两种都对不上
			fault_sid = int(args.get("sid", -1)) if op in RULE_OPS else -1   ## 死在这条跑规则的请求半中间（等回应时）
			if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				_die(CWKernel.Fault.REPLY_TIMEOUT, "sidecar %d ms 内没回 %s" % [REPLY_TIMEOUT_MS, op])
			else:
				_die(CWKernel.Fault.CRASHED, "sidecar 断开了连接（在等 %s 的回应）" % op)
			return {}
		var r = JSON.parse_string(line)
		if r is Dictionary and r.has("re") and int(r["re"]) == id:
			if not bool(r.get("ok", false)):
				push_error("CWSidecarLink：%s 被拒：%s" % [op, String(r.get("error", ""))])
			return r
	return {}


## 关连接（sidecar 读到 EOF 正常退出），等它最多 1 秒，还在就杀掉
func shutdown() -> void:
	## 只摘自己：进程崩了之后重起的那条新链路登记在同一个键上 —— 旧链路 30 秒后空闲关掉时不能把新的摘了（10-01 复核）
	var key := dotnet + "|" + dll
	if _links.get(key) == self:
		_links.erase(key)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_idle_tick):
		tree.process_frame.disconnect(_idle_tick)
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
		_server = null
	if pid > 0:
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(pid) and Time.get_ticks_msec() - t0 < 1000:
			OS.delay_msec(10)
		if OS.is_process_running(pid):
			OS.kill(pid)


# ---- 内部 ----
## 先在 127.0.0.1 上开临时端口，再起 `dotnet exec <dll> --connect 127.0.0.1:<端口> --token <随机串>`，等它连回来、核 hello
func _spawn() -> bool:
	_server = TCPServer.new()
	if _server.listen(0, "127.0.0.1") != OK:
		return _die(CWKernel.Fault.SPAWN_FAILED, "回环端口开不了")
	var port := _server.get_local_port()
	_token = Crypto.new().generate_random_bytes(16).hex_encode()
	pid = OS.create_process(dotnet, ["exec", dll, "--connect", "127.0.0.1:%d" % port, "--token", _token])
	if pid <= 0:
		pid = -1
		return _die(CWKernel.Fault.SPAWN_FAILED, "起不了 sidecar 进程：%s %s" % [dotnet, dll])
	var t0 := Time.get_ticks_msec()
	while not _server.is_connection_available():
		if not OS.is_process_running(pid):
			return _die(CWKernel.Fault.SPAWN_FAILED, "sidecar 进程起来就退了（退出码 %d）" % OS.get_process_exit_code(pid))
		if Time.get_ticks_msec() - t0 > HANDSHAKE_MS:
			return _die(CWKernel.Fault.HANDSHAKE_TIMEOUT, "sidecar %d ms 内没连回来" % HANDSHAKE_MS)
		OS.delay_msec(5)
	_peer = _server.take_connection()
	_server.stop()   ## 只等这一条连接：端口用完即关，别的本机进程再也连不进来
	_server = null
	var line := _read_line(HANDSHAKE_MS)
	var h = JSON.parse_string(line) if line != "" else null
	if not (h is Dictionary) or not (h.get("hello") is Dictionary):
		return _die(CWKernel.Fault.HANDSHAKE_TIMEOUT, "没收到 hello")
	hello = CWMirror._normalize(h["hello"])
	if String(hello.get("token", "")) != _token:
		return _die(CWKernel.Fault.PROTOCOL, "hello 的 token 对不上")
	if int(hello.get("host_abi", 0)) != HOST_ABI:
		return _die(CWKernel.Fault.ABI_MISMATCH, "宿主 ABI %d，本客户端要 %d" % [int(hello.get("host_abi", 0)), HOST_ABI])
	return true


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


## 链路级故障：记下来、杀进程。挂在上面的句柄下一次请求 / 下一帧就看见
func _die(f: int, msg: String) -> bool:
	if fault == 0:
		fault = f
		fault_msg = msg
		push_error("CWSidecarLink：%s" % msg)
		if limits and (f == CWKernel.Fault.CRASHED or f == CWKernel.Fault.REPLY_TIMEOUT) and not hello.is_empty():
			_note_death()
	## 卡住不回的进程不会自己退：当场杀掉，不白等 shutdown 那 1 秒（服务器单线程，这 1 秒全服都冻着）
	if f == CWKernel.Fault.REPLY_TIMEOUT and pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	shutdown()
	return false


## 握手过的进程死了一次：DEATH_WINDOW_MS 内攒够 DEATH_BURST 次就停 BREAKER_MS 不再起（见文件头「限流」）
func _note_death() -> void:
	var key := dotnet + "|" + dll
	var now := Time.get_ticks_msec()
	var recent: Array = (_deaths.get(key, []) as Array).filter(func(t: int) -> bool: return now - t < DEATH_WINDOW_MS)
	recent.append(now)
	_deaths[key] = recent
	if recent.size() >= DEATH_BURST:
		_blocked_until[key] = now + BREAKER_MS
		_deaths[key] = []
		push_error("CWSidecarLink：sidecar %d 秒内死了 %d 次，%d 秒内不再起" % [int(DEATH_WINDOW_MS / 1000.0), DEATH_BURST, int(BREAKER_MS / 1000.0)])


func _idle_tick() -> void:
	if users <= 0 and _idle_since >= 0 and Time.get_ticks_msec() - _idle_since > LINGER_MS:
		shutdown()
