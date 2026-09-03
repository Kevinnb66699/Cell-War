## net_play.gd —— 无界面联机客户端（机器人）：连服务器、建房/加入、坐下、由 AI 桥作答打完一局
##
## 用来在没有界面的时候验证服务器（本机两开、跨网、部署后冒烟）。
##   建房：godot --headless --path game --script res://tests/net_play.gd -- \
##             url=ws://124.221.78.13:8611 nick=甲 create=2 timer=0 public=1 seat=0 fill=heur
##   加入：godot --headless --path game --script res://tests/net_play.gd -- url=... nick=乙 join=ABCDEF seat=1
## 参数：create=<人数>    建房（2/4/6）；timer= 每次决策秒数（0 不限）；public=1/0；seed= 测试种子
##       join=<房间码>   加入已有房间
##       seat=<席位>     坐哪一席（默认第一个空席）
##       fill=heur|mc    （房主）把其余空席放 AI，然后所有真人准备好就开局
##       bot=heur|mc     自己用哪档 AI 作答（默认 heur）
##       games=1         打几局后退出（房主每局结束后再开）
##       codefile=<路径> 拿到房间码就写进这个文件（给脚本编排用：stdout 重定向到文件时是全缓冲的）
extends SceneTree

var url := "ws://%s:%d" % [CWNet.DEFAULT_HOST, CWNet.DEFAULT_PORT]
var nick := "机器人"
var create := 0
var timer := 0
var public := true
var seed_no := 0
var join_code := ""
var seat := -1
var fill := ""
var bot := "heur"
var games := 1
var codefile := ""

var client := CWNetClient.new()
var last_round := -1
var _room_code := ""
var _done := 0
var _sat_for := -1       ## 已请求坐席的是第几局（房间视图的 games）
var _ready_for := -1
var _started_for := -1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"url": url = kv[1]
			"nick": nick = kv[1]
			"create": create = int(kv[1])
			"timer": timer = int(kv[1])
			"public": public = kv[1] != "0"
			"seed": seed_no = int(kv[1])
			"join": join_code = kv[1]
			"seat": seat = int(kv[1])
			"fill": fill = kv[1]
			"bot": bot = kv[1]
			"games": games = int(kv[1])
			"codefile": codefile = kv[1]
	client.autoplay = CWMonteCarloBridge.new() if bot == "mc" else CWHeuristicBridge.new()
	client.message.connect(_on_message)
	client.disconnected.connect(func(c: int, r: String) -> void:
		print("连接关闭 %d %s" % [c, r])
		quit(0))
	print("连接 %s …" % url)
	if client.connect_to(url, nick) != OK:
		printerr("连不上 %s" % url)
		quit(1)
		return
	_loop()


func _loop() -> void:
	while true:
		await client.poll()
		await process_frame


func _on_message(m: Dictionary) -> void:
	match m["t"]:
		"welcome":
			print("已连接，编号 #%d" % m["client_id"])
			if create > 0:
				client.create_room(create, timer, public, seed_no)
			elif join_code != "":
				client.join(join_code)
			else:
				client.list_rooms()
		"lobby":
			print("公开房间：%s" % str(m["rooms"]))
			quit(0)
		"room":
			if m["code"] != _room_code:
				_room_code = m["code"]
				print("房间 %s（%s，%d 人，计时 %d s）" % [m["code"], "公开" if m["public"] else "私密", m["players"], m["timer"]])
				if codefile != "":
					var f := FileAccess.open(codefile, FileAccess.WRITE)
					if f != null:
						f.store_string(m["code"])
			_on_room(m)
		"error":
			print("错误：%s（%s）" % [m["msg"], m["code"]])
			if m["code"] in ["version", "no_room", "playing", "room_closed", "kicked"]:
				quit(1)
		"state":
			var v: Dictionary = m["view"]
			if v["round_no"] != last_round:
				last_round = v["round_no"]
				print("第 %d 回合 · 癌组织 %d 格 · 轮到席位 %d" % [v["round_no"],
					client.shadow.count_tissue(CWData.Tissue.CANCER), m["turn"]])
		"game_over":
			_done += 1
			print("终局：%s（第 %d 回合）" % [m["reason"], m["round"]])
			if _done >= games:
				client.leave()
				quit(0)
		"notice":
			print("通报：%s" % m["text"])


func _on_room(m: Dictionary) -> void:
	if m["state"] == "playing":
		return
	var g: int = m["games"]
	if m["you_seat"] < 0:
		if _sat_for == g:
			return
		var target := seat
		if target < 0:
			for i in m["seats"].size():
				if m["seats"][i]["kind"] == "":
					target = i
					break
		if target >= 0:
			_sat_for = g
			client.sit(target)
		return
	if _ready_for != g:
		_ready_for = g
		client.ready(true)
		return
	if not m["you_host"]:
		return
	## 房主：补 AI，全员准备好就开局
	var all_ready := true
	for i in m["seats"].size():
		var s: Dictionary = m["seats"][i]
		if s["kind"] == "" and fill != "":
			client.set_ai(i, fill)
			return
		if s["kind"] == "" or (s["kind"] == "human" and not s["ready"]):
			all_ready = false
	if all_ready and _started_for != g:
		_started_for = g
		print("开局（第 %d 局）" % (g + 1))
		client.start()
