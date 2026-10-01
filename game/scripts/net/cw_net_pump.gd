## cw_net_pump.gd —— 服务器侧的**条目泵**：把 C# 内核句柄（CWKernelSidecar）的条目流翻成房间的报文（换内核 P6 · 真人半边，2026-10-01）
##
## 与 cw_net_bridge.gd 是同一个角色的两种做法：GD 路上引擎经桥回调「推」演出与询问，房间照着广播；
## 这条路上内核把一切排进一条有序条目流（cw_kernel.gd 头注的 15 种），这里每帧「拉」出来逐条翻：
##   · 演出 9 种（roll / result / notice / card_played / event_drawn / card_drawn / erosion / beam / fx）
##     → 去掉 seq / barrier 原样广播 —— 条目的键本来就是照 CWNetBridge 的报文键定的，报文逐字同形
##   · step_begin → 广播，ask_id 换成**房间自己的编号**（房间的号跨局递增、客户端 #44 的接管判定靠它；sidecar 的号每局从 1 起）
##   · step_end   → room.push_state()：每人一份自己视角的 step_end + sync{envelope}（与 GD 路「每问之前推一次」同一拍）
##   · ask        → room._sc_ask()：只发给被问的那一席，计时 / 掉线代打照旧归房间管
##   · game_over  → room._sc_finish()
##   · sync / log → 不转：sync 由 step_end 那一拍逐人现取；日志随 envelope.logs 走（同 GD 路，日志从不单发）
## 句柄是**消费者模式**（没有 decider、不设 observe_viewer）：真人席的每一问都是一条 ask 条目，答案经 answer() 交回去。
##
## **AI 席与代打**（换内核 P6 · 第二段，2026-10-01）：房里的 AI 席与掉线 / 超时的代打都由 sidecar 里的 C# AI 作答（不出 ask 条目）。
##   · 档位映射（TIER_OF）：房间的「heur」（AI·新手）→ normal、「mc」（AI·对抗搜索，09-20 起服务器上就是搜索配置）→ search；
##     网页单机房直接用三档名。代打一律 search（Kevin 09-20：专家档代打）
##   · **AI 的答案由房间推**（open 时 ai_paced）：sidecar 想好了也不交，等房间每帧一次 step_ai()。为什么非这样不可 ——
##     step_end 那一拍房间按人现取 envelope（每人视角不同，进不了条目流），它假定 sidecar 正停在这一步；
##     AI 在后台自己往下走的话，现取的就是几步之后的局面，盘面会先于演出跳过去。房间推，会话就只在房间的调用里动
##     （同 GD 路「引擎要么停在询问上、要么已结束」），节奏也同 GD 路「AI 每次决策之前让出一帧」：一帧一步
##   · 换手：set_ai(席位, 档) 把一席交给 AI（正问着他的那一问被收回、改由 AI 答，step_begin 照旧带那一问的号）、
##     set_ai(席位, "") 交还真人（AI 正想着他那一问就作废、改问人）
##
## 不带 class_name（同 cw_lan.gd：局域网开服时客户端进程里也跑房间，热更补丁里新增的全局类基线认不出来），cw_room.gd preload 它。
extends RefCounted

const BATCH := 256
## 房间席位的 tier → sidecar 的档名。前两个是联机房建房报文里的键（客户端还在发、改名要升协议），后三个是网页单机房的
const TIER_OF := { "heur": "normal", "mc": "search", "normal": "normal", "intent": "intent", "search": "search" }
## 掉线 / 超时代打用的档（Kevin 2026-09-20「换成专家级 ai 代打」，专家档 = 搜索配置）
const TAKEOVER_TIER := "search"

var room                         ## CWRoom（不写类型：免得两个脚本互相 preload 成环）
var kernel: CWKernelSidecar
var takeovers := 0               ## 把真人席交给 AI 的次数（掉线 / 超时，统计与测试用；GD 路对应 CWNetBridge.takeovers 数的是代答的问数）
var round_no := 1                ## 最近一份 envelope 的世界回合（投降冷却要用；sidecar 没有单独的查询口，取每步推送时顺手记下的）
var _seen := 0                   ## 已经翻过的最后一条条目的 seq（句柄自己的 seq）
var _room_ids := {}              ## sidecar 的 ask_id → 房间的 ask_id（step_begin 换号用）
var _pumping := false
var _error := ""


## 开一局：名字照 CWRoom._name_seats 的口径（真人昵称去首尾空白；AI 席与空串 = 内核默认名「免疫A / 癌症A…」——
## AI 席的 nick 是档位名，两个同档 AI 会重名）。AI 席按 TIER_OF 换成 sidecar 的档名；网页单机房钉的癌种（cancer_types）原样转过去。
## open_hands 在开局时定死 —— 观众视角那一档建房时就拨好了，协议里没有中途改它的报文（C# 宿主也只在 open 时收这个参数）
func open(p_room, seed_value: int) -> bool:
	room = p_room
	var names: Array = []
	for s: Dictionary in room.seats:
		names.append(String(s["nick"]).strip_edges() if s["kind"] == "human" else "")
	var cfg := { "factions": CWData.FACTION_ORDER[int(room.player_count)], "seed": seed_value,
		"open_hands": bool(room.watch_hands), "names": names, "ai": ai_tiers(room.seats), "ai_paced": true }
	if not Array(room.cancer_types).is_empty():
		cfg["cancer_types"] = Array(room.cancer_types)
	kernel = CWKernelSidecar.new()
	if kernel.open(cfg):
		return true
	_error = String(kernel.last_error().get("msg", ""))
	close()
	return false


func error_text() -> String:
	return _error


func close() -> void:
	if kernel != null:
		kernel.close()
	kernel = null
	room = null   ## 房间也持着泵：两头都断开，RefCounted 才放得掉


## 句柄坏了（进程退出 / 连接断 / 超时）就返回原因，好的返回 ""
func fault() -> String:
	if kernel != null and kernel.state() == CWKernel.State.FAULTED:
		return String(kernel.last_error().get("msg", "sidecar 故障"))
	return ""


func ended() -> bool:
	return kernel == null or kernel.state() == CWKernel.State.ENDED


## 把句柄里还没翻过的条目全翻掉。**不递归**：条目里的 ask 可能当场被代打（tick 里），代打又会带出新条目 ——
## 这里只认「拉 → 翻 → 再拉」一个循环，嵌套调进来的直接返回，外层那一圈会接着拉到
func pump() -> void:
	if _pumping or kernel == null:
		return
	_pumping = true
	while kernel != null:
		var batch: Array = kernel.pull(CWKernel.VIEWER_OMNISCIENT, _seen, BATCH)
		if batch.is_empty():
			break
		for e: Dictionary in batch:
			_seen = int(e["seq"])
			_dispatch(e)
			if kernel == null:
				break   ## 终局 / 中止：房间已经把泵拆了
		if kernel != null:
			kernel.discard_before(_seen)   ## 翻过就不要了：句柄的队列别跟着一局的长度涨
	_pumping = false


## 一问的答案交回句柄（index 已经由房间按「键为准、下标兜底」解析过），然后把这一步的条目泵出去
func answer(sidecar_ask_id: int, index: int) -> bool:
	if kernel == null or not kernel.answer(sidecar_ask_id, { "index": index }):
		return false
	pump()
	return true


## 把一席交给 sidecar 里的 AI（tier = TIER_OF 的值）或交还真人（tier = ""）。不在这儿泵：
## 交给 AI 的那一问要等房间下一次 step_ai() 才有动静；交还真人的那条 ask 由句柄下一帧拉过来、房间的 tick 泵出去
func set_ai(pid: int, tier: String, once := false) -> bool:
	return kernel != null and kernel.set_ai(pid, tier, once)


## 推 AI 一步（房间每帧一次，只在没有真人被问着的时候）：sidecar 里想好了的那个答案这就交，交了就把这一步泵出去。
## 一帧最多一步 —— 同 GD 路「AI 每次决策之前让出一帧」，也正是 step_end 那一拍现取的 envelope 对得上这一步的原因（见文件头）
func step_ai() -> void:
	if kernel != null and kernel.step_ai():
		pump()


## 投降投票全票通过：对方阵营直接获胜。句柄当场收局，step_end / game_over 这就泵出去
func surrender(faction: int) -> void:
	if kernel == null:
		return
	kernel.surrender(faction)
	pump()


func query(kind: String, args: Dictionary) -> Variant:
	return kernel.query(kind, args) if kernel != null else null


## 投降投票那两行日志：句柄的 log_msg 让 sidecar 往对局日志里插一行（10-01 起），随各人视角的 envelope.logs 下发
func log_line(text: String) -> void:
	if kernel != null:
		kernel.log_msg(text)


## 某一席 / 观众的 envelope，过网之前整成与 GD 路**逐类型相同**的形状：
##   · 数字整数化：C# 那边经 JSON 过来，数字全是浮点；GD 路发的是整数（观测协议零浮点）。坐标仍是 {q, r} 两键字典 ——
##     转 Vector2i 是客户端镜像装载时的事（CWMirror._normalize），这里不替它做
##   · ask.ask_id 置 0：GD 路这里恒为 0（收养模式下句柄不经手询问）；sidecar 的 ask 序号是会话内部的，过网没有意义，
##     客户端作答认的是 ask 报文里那个房间编号
func envelope(viewer: int, logs_from: int) -> Dictionary:
	if kernel == null:
		return {}
	var env: Dictionary = ints(kernel.observe_envelope(viewer, logs_from))
	if env.is_empty():
		return {}
	round_no = int(env["state"]["g"]["round_no"])
	if env.get("ask") is Dictionary:
		env["ask"]["ask_id"] = 0
	return env


# ---- 内部 ----
func _dispatch(e: Dictionary) -> void:
	var kind := String(e["t"])
	match kind:
		"ask":
			var sid_ask := int(e["ask_id"])
			_room_ids[sid_ask] = room._sc_ask(sid_ask, wire_req(e["req"]))
		"step_begin":
			## 找不到编号就发 -1：客户端的接管判定要求 ask_id >= 0，-1 天然不命中（不会误收别人的界面）。
			## AI 席自己的问没有房间号（那一问从没发给谁），都是 -1；AI 接管的真人那一问沿用 sidecar 的号，这里换回房间给他的号
			var sid_ask := int(e["ask_id"])
			room.broadcast({ "t": "step_begin", "ask_id": int(_room_ids.get(sid_ask, -1)), "seat": int(e["seat"]) })
			_room_ids.erase(sid_ask)
		"step_end":
			room.push_state(-1)
		"game_over":
			room._sc_finish(e)
		"sync", "log":
			pass
		_:
			var m := e.duplicate()
			m.erase("seq")
			m.erase("barrier")
			room.broadcast(m)


# ---- 纯函数 ----
## 房间席位表里的 AI 席 → sidecar open 的 `ai`：{席位: 档名}（按 TIER_OF 换名；真人席不出现）
static func ai_tiers(seats: Array) -> Dictionary:
	var ai := {}
	for pid in seats.size():
		if seats[pid]["kind"] == "ai":
			ai[pid] = TIER_OF[String(seats[pid]["tier"])]
	return ai


## ask 报文的 req：sidecar 的选项多带一个 `key`（宿主替作答方省一次拼键）。过网前去掉 —— GD 路的 req 选项只有 {label, data}，
## 两端照旧各自 CWSemKey.key(req, data) 现算（规格 §0.4 #2），报文与 GD 路同形
static func wire_req(req: Dictionary) -> Dictionary:
	var out := req.duplicate()
	var opts: Array = []
	for o: Dictionary in req.get("options", []):
		var c := o.duplicate()
		c.erase("key")
		opts.append(c)
	out["options"] = opts
	return out


## 整数值的浮点 → int，递归（{q, r} 字典保持字典）
static func ints(v: Variant) -> Variant:
	if v is float:
		return int(v) if v == floor(v) else v
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = ints(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for x in v:
			arr.append(ints(x))
		return arr
	return v
