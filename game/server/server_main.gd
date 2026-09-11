## server_main.gd —— 联机服务器入口（无头常驻进程）
##
## 启动：godot --headless --path game --script res://server/server_main.gd -- port=8611 drain=/home/ubuntu/cellwar/DRAIN
## 参数：port=8611      监听端口（云安全组只放了 TCP 8611）
##       bind=*         绑定地址
##       drain=<路径>   排空标记文件：存在即进入维护中（拒绝建房与开局），最后一局打完就退出，
##                      systemd Restart=always 拉起新版（docs/联机设计 §八）
##       fps=30         主循环帧率（空转时的 CPU 占用由它决定）
##       feedback_port=8612    「反馈 bug」收件口（issue #19，CWFeedbackHTTP）；0 = 不开
##       feedback_bind=127.0.0.1  只绑本机，由 nginx 反代 /cellwar/feedback 进来（server/nginx-feedback.conf）
##       feedback_dir=<目录>   反馈落盘目录（默认 user://feedback；run.sh 给的是 ~/cellwar/feedback）
extends SceneTree

var server := CWNetServer.new()
var feedback := CWFeedbackHTTP.new()
var drain_path := ""
var _last_drain_check := 0


func _initialize() -> void:
	var port := CWNet.DEFAULT_PORT
	var bind := "*"
	var fps := 30
	var fb_port := 8612
	var fb_bind := "127.0.0.1"
	var fb_dir := ""
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"port": port = int(kv[1])
			"bind": bind = kv[1]
			"drain": drain_path = kv[1]
			"fps": fps = int(kv[1])
			"feedback_port": fb_port = int(kv[1])
			"feedback_bind": fb_bind = kv[1]
			"feedback_dir": fb_dir = kv[1]
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
	## 收件口起不来不影响联机：反馈是锦上添花，别让它把主服务拖死
	if fb_port > 0:
		var ferr := feedback.start(fb_port, fb_bind, fb_dir)
		if ferr != OK:
			printerr("反馈收件口 %s:%d 起不来：%d（反馈功能不可用，联机照常）" % [fb_bind, fb_port, ferr])
		else:
			server.say("反馈收件口 %s:%d → %s" % [fb_bind, fb_port, feedback.dir])


func _process(_delta: float) -> bool:
	server.poll()
	feedback.poll()
	if drain_path != "":
		var now := Time.get_ticks_msec()
		if now - _last_drain_check > 1000:
			_last_drain_check = now
			var d := FileAccess.file_exists(drain_path)
			if d != server.drain:
				server.drain = d
				server.say("维护中" if d else "维护解除")
	return false
