## cw_lan.gd —— 局域网自动发现（Kevin 2026-09-12，照 Minecraft「对局域网开放」的房间列表）
##
## 房主：每 INTERVAL_MS 往 255.255.255.255:PORT 广播一条「我在 端口 开服」（昵称、协议号）；
## 客户端：连接页期间监听 PORT，把听到的按「ip:端口」记下来，TTL_MS 没再听到就当人走了。
## 传输是 UDP 广播：同一个路由器下才收得到（AP 开了客户端隔离就收不到，那就手填地址）。
## 首次监听 Windows 会问防火墙 —— 和开服那条一样，选允许。
##
## **发送口按网卡各起一只**（2026-09-12 Kevin 报「附近搜不到」，实测是网卡出口）：不 bind 的 socket 往 255.255.255.255 发，
## 系统只挑默认路由那块网卡出去 —— Kevin 的机器上那是 VPN / VMware / Hyper-V 的虚拟网卡，真正连着路由器的 WLAN 反而没份。
## 现在每个本机 IPv4 各绑一只 socket（回环、169.254 自动配置的跳过），从它发出的有限广播就走那块网卡；
## 再补一发 x.y.z.255 的定向广播（按 /24 猜，猜错也只是多发一个没人收的包）。
##
## **没有 class_name**：这份要走热更，补丁里新增的全局类基线认不出来（架构说明书「热更新」那行），
## 调用方 `preload("res://scripts/net/cw_lan.gd")`。报文用 var_to_bytes（同 CWNet.encode 的底子），
## 收到先验形状：字典、MAGIC 对上、端口是 1024~65535 的整数，其余一律扔 —— 局域网里什么包都可能飘过来。
extends RefCounted

const PORT := 8619            ## 发现用的 UDP 端口（8611 是对局的 TCP，8612 是服务器的反馈收件口）
const INTERVAL_MS := 1000
const TTL_MS := 4000
const MAGIC := "cellwar_lan"
const BROADCAST := "255.255.255.255"
const MAX_LEN := 512          ## 我们的包几十字节，超过这个数的不是我们的

var _udp: PacketPeerUDP = null        ## 客户端那只：监听
var _senders: Array = []              ## 房主那几只：[{ udp, directed }]，每块网卡一只
var _dest := BROADCAST
var _beacon := PackedByteArray()
var _last_sent := -INTERVAL_MS
var found := {}               ## "ip:port" -> { ip, port, nick, ver, seen }


## 本机能发广播的 IPv4：回环、169.254 自动配置、IPv6 都不要。**纯函数**。
static func host_ips(all: Array) -> Array:
	var out: Array = []
	for a in all:
		var s := str(a)
		if s.contains(":") or not s.is_valid_ip_address():
			continue
		if s.begins_with("127.") or s.begins_with("169.254."):
			continue
		out.append(s)
	return out


## 定向广播地址（按 /24 猜）。**纯函数**。
static func directed_of(ip: String) -> String:
	var b := ip.split(".")
	return "%s.%s.%s.255" % [b[0], b[1], b[2]] if b.size() == 4 else ""


static func make_beacon(port: int, nick: String, ver: int) -> PackedByteArray:
	return var_to_bytes({ "t": MAGIC, "port": port, "nick": nick, "ver": ver })


## 收到的一包 → 条目；不是我们的、形状不对 → 空字典。**纯函数**。
static func parse_beacon(bytes: PackedByteArray, ip: String, now: int) -> Dictionary:
	if bytes.size() == 0 or bytes.size() > MAX_LEN:
		return {}
	var v: Variant = bytes_to_var(bytes)
	if not (v is Dictionary) or v.get("t", "") != MAGIC:
		return {}
	var port: Variant = v.get("port", 0)
	if not (port is int) or int(port) < 1024 or int(port) > 65535:
		return {}
	return { "ip": ip, "port": int(port), "nick": CWNet.clean_nick(v.get("nick", "")),
		"ver": int(v.get("ver", 0)), "seen": now }


## TTL 之内没再听到的条目摘掉。**纯函数**（返回新字典）。
static func prune(entries: Dictionary, now: int) -> Dictionary:
	var out := {}
	for k in entries:
		if now - int(entries[k]["seen"]) <= TTL_MS:
			out[k] = entries[k]
	return out


## 房主：每块网卡各起一只发送口（见文件头）。dest 让测试能指回环 —— 那时一只不 bind 的就够。
func start_host(port: int, nick: String, ver: int = CWNet.NET_VERSION, dest: String = BROADCAST) -> Error:
	stop()
	_beacon = make_beacon(port, nick, ver)
	_last_sent = -INTERVAL_MS
	_dest = dest
	if dest != BROADCAST:
		var u := PacketPeerUDP.new()
		u.set_broadcast_enabled(true)
		if u.set_dest_address(dest, PORT) != OK:
			return ERR_CANT_CREATE
		_senders.append({ "udp": u, "directed": "" })
		return OK
	for ip in host_ips(Array(IP.get_local_addresses())):
		var u := PacketPeerUDP.new()
		u.set_broadcast_enabled(true)
		if u.bind(0, ip) != OK:      ## 端口 0 = 系统给临时端口；绑在这块网卡上，广播就从它出去
			continue
		_senders.append({ "udp": u, "directed": directed_of(ip) })
	if _senders.is_empty():
		## 一块能绑的网卡都没有：退回不 bind 的那一只，让系统挑
		var u := PacketPeerUDP.new()
		u.set_broadcast_enabled(true)
		_senders.append({ "udp": u, "directed": "" })
	return OK


func poll_host(now: int) -> void:
	if _senders.is_empty() or _beacon.is_empty():
		return
	if now - _last_sent < INTERVAL_MS:
		return
	_last_sent = now
	for s in _senders:
		var u: PacketPeerUDP = s["udp"]
		u.set_dest_address(_dest, PORT)
		u.put_packet(_beacon)
		if s["directed"] != "":
			u.set_dest_address(s["directed"], PORT)
			u.put_packet(_beacon)


## 客户端：监听 PORT。绑不上 = 本机已经有一个在听（多半是另一个客户端），报错给调用方，功能照常缺席。
func start_listen() -> Error:
	stop()
	_udp = PacketPeerUDP.new()
	var err := _udp.bind(PORT, "0.0.0.0")   ## 只听 IPv4：广播是 IPv4 的事，双栈 socket 报上来的地址还带 ::ffff: 前缀
	if err != OK:
		_udp = null
	return err


## 收包 + 过期；返回名单有没有变（变了界面才重画）
func poll_listen(now: int) -> bool:
	if _udp == null:
		return false
	var changed := false
	while _udp.get_available_packet_count() > 0:
		var bytes := _udp.get_packet()
		var e := parse_beacon(bytes, _udp.get_packet_ip().trim_prefix("::ffff:"), now)
		if not e.is_empty():
			found["%s:%d" % [e["ip"], e["port"]]] = e
			changed = true
	var kept := prune(found, now)
	if kept.size() != found.size():
		changed = true
	found = kept
	return changed


## 给界面的名单：按昵称、再按地址排，稳定
func entries() -> Array:
	var out: Array = found.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["nick"] != b["nick"]:
			return a["nick"] < b["nick"]
		return "%s:%d" % [a["ip"], a["port"]] < "%s:%d" % [b["ip"], b["port"]])
	return out


func stop() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	for s in _senders:
		(s["udp"] as PacketPeerUDP).close()
	_senders = []
	_beacon = PackedByteArray()
	found = {}
