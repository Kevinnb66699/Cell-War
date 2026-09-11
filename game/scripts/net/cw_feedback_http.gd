## cw_feedback_http.gd —— 玩家「反馈 bug」的收件口（issue #19）：一个只认 POST 的最小 HTTP 服务
##
## 为什么不走 8611 那条 WebSocket：反馈要在**单机局**里也能发（那时没有联机会话），而且一份反馈
## 带一张截图（几十到几百 KB），比联机报文上限（CWNet.MAX_PACKET = 64 KB）大一个量级 ——
## 与其给联机协议开一个大包例外或做分片，不如另开一条只收 POST 的口。
## 云安全组只放了 80 / 8611，所以它只绑 **127.0.0.1**:8612，由 nginx 把 /cellwar/feedback 反代进来
## （站点 cellwar-patch 里的那段 location 见 server/nginx-feedback.conf）。
##
## 只认「POST /feedback」：请求头 8 KB 以内、正文 4 MB 以内、10 秒内收完、同时最多 8 条连接；
## 别的一律 4xx 后关连接。正文是客户端 `CWFeedback.pack()` 出来的报文（CWNet.encode 的格式），
## 这里**不解析游戏内容**、原样落盘 report.bin，只把截图另存一份 shot.png、要点写进 meta.json 方便翻。
##
## 纯 RefCounted，不进场景树：宿主（server/server_main.gd 或测试）每帧调 poll()，和 CWNetServer 同一套形制。
class_name CWFeedbackHTTP
extends RefCounted

const MAX_HEAD := 8192
const MAX_BODY := 4 << 20
const TIMEOUT_MS := 10000
const MAX_CONN := 8
const PATH := "/feedback"

var dir := "user://feedback"
var quiet := false
var received := 0                ## 收到并落盘的份数（日志与测试用）
var _server := TCPServer.new()
var _conns: Array = []           ## [{ peer, buf, since }]


func start(port: int, bind := "127.0.0.1", p_dir := "") -> Error:
	if p_dir != "":
		dir = p_dir
	var err := _server.listen(port, bind)
	if err != OK:
		return err
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return OK


func stop() -> void:
	for c in _conns:
		(c["peer"] as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	_server.stop()


func say(s: String) -> void:
	if not quiet:
		print("%s %s" % [Time.get_time_string_from_system(), s])


func poll() -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var p := _server.take_connection()
		if _conns.size() >= MAX_CONN:
			p.disconnect_from_host()
			continue
		_conns.append({ "peer": p, "buf": PackedByteArray(), "since": Time.get_ticks_msec() })
	var now := Time.get_ticks_msec()
	for c in _conns.duplicate():
		var p: StreamPeerTCP = c["peer"]
		p.poll()
		var connected := p.get_status() == StreamPeerTCP.STATUS_CONNECTED
		if connected:
			var n := p.get_available_bytes()
			if n > 0:
				var got: Array = p.get_data(n)      ## [err, bytes]
				if int(got[0]) == OK:
					## PackedByteArray 是值类型：从字典里取出来的是副本，追加完得写回去，
					## 直接 `(c["buf"] as PackedByteArray).append_array()` 改的是临时副本（第一版就这么白等了 5 秒）
					var buf: PackedByteArray = c["buf"]
					buf.append_array(got[1])
					c["buf"] = buf
		var r := parse(c["buf"])
		if r["status"] == "more":
			if not connected or now - int(c["since"]) > TIMEOUT_MS:
				_drop(c)
			continue
		if r["status"] == "ok":
			var start: int = r["body_start"]
			var body: PackedByteArray = (c["buf"] as PackedByteArray).slice(start, start + int(r["length"]))
			var saved := _store(body, p.get_connected_host())
			_reply(p, 200 if saved else 500, "ok" if saved else "store failed")
		else:
			_reply(p, int(r["code"]), str(r["status"]))
		_drop(c)


## 请求收全了吗。**纯函数**，无头测试直接喂字节。返回 { status: "more" | "ok" | "bad", code, body_start, length }：
## "more" = 还要等；"ok" = 头尾齐全，正文在 [body_start, body_start + length)；"bad" = 不是我们要的请求（code 是要回的状态码）。
static func parse(buf: PackedByteArray) -> Dictionary:
	var head_end := _find_head_end(buf)
	if head_end < 0:
		if buf.size() > MAX_HEAD:
			return { "status": "bad", "code": 431 }
		return { "status": "more" }
	var head := buf.slice(0, head_end).get_string_from_ascii()
	var lines := head.split("\r\n")
	var req := lines[0].split(" ")
	if req.size() < 2 or req[0] != "POST":
		return { "status": "bad", "code": 405 }
	if req[1] != PATH:
		return { "status": "bad", "code": 404 }
	var length := -1
	for i in range(1, lines.size()):
		var kv := lines[i].split(":", true, 1)
		if kv.size() == 2 and kv[0].strip_edges().to_lower() == "content-length":
			length = int(kv[1].strip_edges())
	if length < 0:
		return { "status": "bad", "code": 411 }
	if length > MAX_BODY:
		return { "status": "bad", "code": 413 }
	var body_start := head_end + 4
	if buf.size() < body_start + length:
		return { "status": "more" }
	return { "status": "ok", "code": 200, "body_start": body_start, "length": length }


## 头部结束符 \r\n\r\n 的位置；只在前 MAX_HEAD + 4 字节里找，正文可能是几 MB 的二进制，别逐次全扫
static func _find_head_end(buf: PackedByteArray) -> int:
	var n := mini(buf.size(), MAX_HEAD + 4)
	for i in range(0, n - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


## 落盘：<dir>/<时间>_<序号>/report.bin（原样）+ shot.png（截图）+ meta.json（昵称、版本、说明、回合…）。
## 解不出报文也照存 report.bin —— 收件箱的职责是「别丢」，看不懂留给人看。
func _store(body: PackedByteArray, ip: String) -> bool:
	received += 1
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "").replace(" ", "_")
	var folder := "%s/%s_%03d" % [dir, stamp, received]
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder)) != OK:
		return false
	var f := FileAccess.open(folder + "/report.bin", FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(body)
	f.close()
	var meta := { "ip": ip, "bytes": body.size(), "received": stamp }
	var msg := CWNet.decode(body)
	if not msg.is_empty():
		for k in ["nick", "version", "base", "patch", "text", "time", "round", "phase", "online", "replay"]:
			if msg.has(k):
				meta[k] = msg[k]
		var png: PackedByteArray = msg.get("png", PackedByteArray())
		if png.size() > 0:
			var pf := FileAccess.open(folder + "/shot.png", FileAccess.WRITE)
			if pf != null:
				pf.store_buffer(png)
				pf.close()
			meta["png_bytes"] = png.size()
		meta["snapshot"] = (msg.get("snapshot", {}) as Dictionary).size() > 0
	var mf := FileAccess.open(folder + "/meta.json", FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(meta, "  "))
		mf.close()
	say("收到反馈 #%d：%s「%s」（%d 字节）→ %s" % [received, str(meta.get("nick", "?")),
		str(meta.get("text", "")), body.size(), folder])
	return true


func _reply(p: StreamPeerTCP, code: int, text: String) -> void:
	var reason: String = { 200: "OK", 404: "Not Found", 405: "Method Not Allowed", 411: "Length Required",
		413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error" }.get(code, "Error")
	var payload := text.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" \
		% [code, reason, payload.size()]
	p.put_data(head.to_utf8_buffer())
	p.put_data(payload)


func _drop(c: Dictionary) -> void:
	(c["peer"] as StreamPeerTCP).disconnect_from_host()
	_conns.erase(c)
