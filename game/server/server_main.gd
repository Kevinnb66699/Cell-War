## server_main.gd —— 联机服务器入口（无头常驻进程）
##
## 启动：godot --headless --path game --script res://server/server_main.gd -- port=8611 drain=/home/ubuntu/cellwar/DRAIN
## 参数：port=8611      监听端口（云安全组只放了 TCP 8611）
##       bind=*         绑定地址
##       drain=<路径>   排空标记文件：存在即进入维护中（拒绝建房与开局），最后一局打完就退出，
##                      systemd Restart=always 拉起新版（docs/联机设计 §八）
##       fps=30         主循环帧率（空转时的 CPU 占用由它决定）
extends SceneTree

var server := CWNetServer.new()
var drain_path := ""
var _last_drain_check := 0


func _initialize() -> void:
	var port := CWNet.DEFAULT_PORT
	var bind := "*"
	var fps := 30
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"port": port = int(kv[1])
			"bind": bind = kv[1]
			"drain": drain_path = kv[1]
			"fps": fps = int(kv[1])
	Engine.max_fps = fps
	var err := server.start(port, bind)
	if err != OK:
		printerr("监听 %s:%d 失败：%d" % [bind, port, err])
		quit(1)
		return
	server.drained.connect(func() -> void:
		server.say("排空完成，退出")
		quit(0))
	server.say("Cell War 联机服务器 协议 v%d 监听 %s:%d%s" % [CWNet.NET_VERSION, bind, port,
		"（排空标记 %s）" % drain_path if drain_path != "" else ""])


func _process(_delta: float) -> bool:
	server.poll()
	if drain_path != "":
		var now := Time.get_ticks_msec()
		if now - _last_drain_check > 1000:
			_last_drain_check = now
			var d := FileAccess.file_exists(drain_path)
			if d != server.drain:
				server.drain = d
				server.say("维护中" if d else "维护解除")
	return false
