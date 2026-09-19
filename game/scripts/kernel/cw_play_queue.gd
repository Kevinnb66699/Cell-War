## cw_play_queue.gd —— 按 seq 顺序消费句柄条目、逐条播给消费者（口径二 · 批 0 步 11；批 1 步 4 按 Kevin 2026-09-19 拍板 2 改成顺序播）
##
## 从 match.gd:965-1013 的 _net_loop 抽出的等价物，对三种句柄通用：roll 播完 ack(seq)（有消费者时引擎在等这一声）；
## sync 装镜像（回调）；ask / log / game_over / step_* 交回调。保留今天的两条短路：show_roll 由消费者自己短路（dice_anim 关着立即返回），
## from == to 的 beam、dir < 0 的 erosion 内核侧就不发。**一次只装一份 envelope、不合并条目**（规格 A-2.2 第 3 条：传送溶解演出靠 UI 自己差分认出来）。
##
## **拍板 2（演出播放形态）**：引擎 / 服务器照旧不等演出；**客户端按条目顺序播**——
##   · 有时长的演出（fx：攻击 / 扑咬 / 传送溶解…、card_played 的飞卡、beam 射线）`await` 消费者播完再放下一条；
##     result / notice / log / erosion 便宜，不等。消费者的 show_* 协程只等「**阻塞时长**」，演出本身可以更长
##     （Kevin：小细胞波浪形移动别把队列堵住）—— 阻塞几毫秒由消费者（CWUIBridge）按种类定，队列不管。
##   · 一步行动的 sync 条目排在这一步的演出之后（内核侧 step_end → sync → ask 的次序），所以顺序播 = 演出播完盘面才落地。
##   · **快进把手**：`hurry = true`（回放倍速 / 观战）或一批拉到 ≥ hurry_backlog 条（积压）时退回「触发即走、不等」—— 就是今天的行为。
##   · step_begin{ask_id, seat} / step_end{rev} 只交 on_step 回调（UI 拿它分组、快进、跳过），队列自己不用。
## 形制事实：**InProc + decider 时永不产 ask 条目**（询问直接转交 decider），on_ask 只在 Remote 路上用 —— 一套代码两条 ask 路径是设计，不是 bug。
## 批 0 只用无头假桥驱动它做测试，不改 match.gd；接线在批 1 步 8。
class_name CWPlayQueue
extends RefCounted

var kernel: CWKernel
var viewer := CWKernel.VIEWER_OMNISCIENT
var consumer: CWBridge           ## 演出的消费者（界面桥 / 计数桥）；null = 不演，roll 立即 ack
var on_ask: Callable             ## func(entry: Dictionary)
var on_log: Callable             ## func(entry: Dictionary)
var on_sync: Callable            ## func(envelope: Dictionary)
var on_game_over: Callable       ## func(entry: Dictionary)
var on_step: Callable            ## func(entry: Dictionary)：step_begin / step_end 都走这里
var hurry := false               ## 手动快进（回放倍速 / 观战）：有时长的演出不等
var hurry_backlog := 24          ## 一批拉到这么多条就自动快进（积压 = 对面 AI 连打，人不该等它一条条演）
var since := 0
var played := 0
var running := false
var _over := false
var _inflight_seq := 0           ## 正在等消费者播完的 roll（stop() 要替它 ack，别把引擎吊死）
var _hurry_now := false


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
		_hurry_now = hurry or batch.size() >= hurry_backlog
		for e in batch:
			since = int(e["seq"])
			await play_one(e)
			if not running:
				break
		if kernel != null:
			kernel.discard_before(since)   ## 播完一批就丢：pull 每次从 _entries[0] 全量扫，不丢会越扫越慢
	running = false


## 停：若有在飞的 roll 先替它 ack —— 配合「abort 先、stop 后」的双保险，消费者循环没了引擎也不能吊在 barrier 上
func stop() -> void:
	running = false
	if _inflight_seq > 0 and kernel != null:
		kernel.ack(_inflight_seq)
	_inflight_seq = 0


func play_one(e: Dictionary) -> void:
	played += 1
	match String(e["t"]):
		"roll":
			var seq := int(e["seq"])
			if consumer != null:
				if _hurry_now:
					consumer.show_roll(String(e["reason"]), int(e["value"]), int(e["sides"]), int(e["pid"]), e["at"])
				else:
					_inflight_seq = seq
					await consumer.show_roll(String(e["reason"]), int(e["value"]), int(e["sides"]), int(e["pid"]), e["at"])
					_inflight_seq = 0
			if kernel != null:
				kernel.ack(seq)
		"result":
			if consumer != null:
				consumer.show_result(String(e["text"]), e["at"], bool(e.get("linger", false)))
		"notice":
			if consumer != null:
				consumer.show_notice(String(e["text"]))
		"card_played":
			if consumer != null:
				if _hurry_now:
					consumer.show_card_played(int(e["pid"]), String(e["text"]), _info(e, ["cell_id", "pos", "faction", "card"]))
				else:
					await consumer.show_card_played(int(e["pid"]), String(e["text"]), _info(e, ["cell_id", "pos", "faction", "card"]))
		"event_drawn":
			if consumer != null:
				consumer.show_event_drawn(int(e["pid"]), _info(e, ["cell_id", "pos", "faction", "card"]))
		"card_drawn":
			if consumer != null:
				consumer.show_card_drawn(int(e["pid"]), _info(e, ["cell_id", "pos", "source"]))
		"erosion":
			if consumer != null:
				consumer.show_erosion(e["at"], int(e["dir"]))
		"beam":
			if consumer != null:
				if _hurry_now:
					consumer.show_beam(e["from"], e["to"], e.get("splash", []))
				else:
					await consumer.show_beam(e["from"], e["to"], e.get("splash", []))
		"fx":
			if consumer != null:
				if _hurry_now:
					consumer.show_fx(String(e["kind"]), e.get("data", {}))
				else:
					await consumer.show_fx(String(e["kind"]), e.get("data", {}))
		"log":
			if on_log.is_valid():
				on_log.call(e)
		"ask":
			if on_ask.is_valid():
				on_ask.call(e)
		"sync":
			if on_sync.is_valid():
				on_sync.call(e["envelope"])
		"step_begin", "step_end":
			if on_step.is_valid():
				on_step.call(e)
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
