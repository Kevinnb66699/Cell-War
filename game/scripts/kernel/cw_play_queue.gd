## cw_play_queue.gd —— 按 seq 顺序消费句柄条目、逐条播给消费者（口径二 · 批 0 步 11）
##
## 从 match.gd:965-1013 的 _net_loop 抽出的等价物，对三种句柄通用：roll 播完 ack(seq)（有消费者时引擎在等这一声）；
## sync 装镜像（回调）；ask / log / game_over 交回调。保留今天的两条短路：show_roll 由消费者自己短路（dice_anim 关着立即返回），
## from == to 的 beam、dir < 0 的 erosion 内核侧就不发。**一次只装一份 envelope、不合并条目**（规格 A-2.2 第 3 条：传送溶解演出靠 UI 自己差分认出来）。
## 批 0 只用无头假桥驱动它做测试，不改 match.gd。
class_name CWPlayQueue
extends RefCounted

var kernel: CWKernel
var viewer := CWKernel.VIEWER_OMNISCIENT
var consumer: CWBridge           ## 演出的消费者（界面桥 / 计数桥）；null = 不演，roll 立即 ack
var on_ask: Callable             ## func(entry: Dictionary)
var on_log: Callable             ## func(entry: Dictionary)
var on_sync: Callable            ## func(envelope: Dictionary)
var on_game_over: Callable       ## func(entry: Dictionary)
var since := 0
var played := 0
var running := false
var _over := false


## 协程：跑到 game_over 或 stop()。Remote 句柄每圈先 drain() 把报文翻成条目
func pump() -> void:
	running = true
	var tree := Engine.get_main_loop() as SceneTree
	while running and kernel != null:
		if kernel is CWKernelRemote:
			kernel.drain()
		var batch: Array = kernel.pull(viewer, since, 64)
		if batch.is_empty():
			if _over or tree == null:
				break
			await tree.process_frame
			continue
		for e in batch:
			since = int(e["seq"])
			await play_one(e)
			if not running:
				break
	running = false


func stop() -> void:
	running = false


func play_one(e: Dictionary) -> void:
	played += 1
	match String(e["t"]):
		"roll":
			if consumer != null:
				await consumer.show_roll(String(e["reason"]), int(e["value"]), int(e["sides"]), int(e["pid"]), e["at"])
			kernel.ack(int(e["seq"]))
		"result":
			if consumer != null:
				consumer.show_result(String(e["text"]), e["at"], bool(e.get("linger", false)))
		"notice":
			if consumer != null:
				consumer.show_notice(String(e["text"]))
		"card_played":
			if consumer != null:
				consumer.show_card_played(int(e["pid"]), String(e["text"]), _info(e, ["cell_id", "pos", "faction", "card"]))
		"event_drawn":
			if consumer != null:
				consumer.show_event_drawn(int(e["pid"]), _info(e, ["cell_id", "pos", "faction", "card"]))
		"card_drawn":
			if consumer != null:
				consumer.show_card_drawn(int(e["pid"]), _info(e, ["cell_id", "pos", "source"]))
		"world_event":
			if consumer != null:
				consumer.show_world_event(String(e["ev"]), { "left": int(e.get("left", 1)) })
		"erosion":
			if consumer != null:
				consumer.show_erosion(e["at"], int(e["dir"]))
		"beam":
			if consumer != null:
				consumer.show_beam(e["from"], e["to"], e.get("splash", []))
		"fx":
			if consumer != null:
				consumer.show_fx(String(e["kind"]), e.get("data", {}))
		"log":
			if on_log.is_valid():
				on_log.call(e)
		"ask":
			if on_ask.is_valid():
				on_ask.call(e)
		"sync":
			if on_sync.is_valid():
				on_sync.call(e["envelope"])
		"game_over":
			_over = true
			if on_game_over.is_valid():
				on_game_over.call(e)
			running = false


static func _info(e: Dictionary, keys: Array) -> Dictionary:
	var out := {}
	for k in keys:
		if e.has(k):
			out[k] = e[k]
	return out
