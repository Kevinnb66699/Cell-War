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
## **崩溃重起**（10-01，计划 P6 欠的那一条；同日五路复核后改）：每泵完一批条目、会话停在顶层一问上（真人或 AI 的），
## 就存一份检查点（`kernel.save()`，约 45 KB、一次约 1 ms；8 房并发时占服务器主线程 7% 上下）。句柄坏了 —— 进程崩了 / 卡住不回 /
## 这一局在 sidecar 里出了内部错误 / 答案或换手被拒 / 拿不到 envelope —— 房间下一帧调 `recover()`：拿最近的检查点换一个新会话接着打
##（进程没了的话新开的句柄会拉起新进程，同服务器别的房间复用它）。
##   · 新会话停在检查点那一问上：真人那一问换房间新号重新问（客户端收到新 ask 就收掉旧界面），AI 那一问重新想；
##     日志里插一行「【系统】……接着打」，玩家看得懂为什么又问了一遍
##   · 检查点里不带日志：新会话的日志从第 0 行记起，这里把行号整体挪到检查点那一刻的总行数之后（`_log_base`），客户端的日志接着往下长；
##     房间同时把每人的日志游标压到检查点那一刻（回退过的话，新的这一支从那一行起覆盖）
##   · **记账**（RECOVER_MAX）：只记这一局自己惹的故障（见 recover 的注释）—— 一个房间把进程弄崩了，正等着真人作答的别的房间不该跟着记；
##     **「往前走了一步」要等走完的局面存住了才算**：答案收下了、推状态 / 存检查点那一下又坏了，不算往前走（不然同一处 bug 无限重起）
##   · 新会话开不出来（进程起不来 / 链路在限流，见 cw_sidecar_link.gd）就隔帧再试，从第一次失败起最多 RETRY_GIVE_UP_MS
##   · 出事那一下全票通过的投降不丢：记在 `_pending_surrender`，新会话一开先补上
##   · 检查点之后、崩之前已经推出去的那一步（极少：存检查点那一下本身失败）会被撤回 —— 新会话头一拍就把状态整份推一遍，客户端跟着回到那一问；
##     连着好多步都存不住会在服务器日志里说一声（STALE_WARN）
##   · 重起之后中途进来 / 重连的人看不到重起之前的日志（新会话里没有那些行）
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
## 崩溃重起（见文件头）
enum Recover { DONE, RETRY, GIVE_UP }
const RECOVER_MAX := 3           ## 记了账的重起连着几次、中间一步都没走成（存住）就放弃
const RETRY_GIVE_UP_MS := 60000  ## 新会话开不出来就再试，从第一次失败起最多这么久
const RETRY_INTERVAL_MS := 1000  ## 两次重试之间至少隔这么久（每帧都起一遍进程 = 全服跟着卡）
const STALE_WARN := 20           ## 连着这么多批条目都没存住检查点就在服务器日志里说一声
var recoveries := 0              ## 这一局重起过几次（统计与测试用）
var _cfg := {}                   ## open 时的 cfg（重起时 factions / seed / names / open_hands / cancer_types 照给，ai 现算）
var _checkpoint := {}            ## 最近一份能存的检查点（kernel.save() 的 blob）；空 = 还没有，坏了就只能中止
var _cp_log_total := 0           ## 存这份检查点那一刻，这一局的日志一共几行（绝对行号）
var _log_base := 0               ## 当前会话的第 0 行日志是这一局的第几行（重起过才非零）
var _log_total := 0              ## 这一局的日志一共几行（最近一份 envelope 的 from + 行数，绝对行号）
var _recover_streak := 0         ## 记了账的重起连着几次了（往前走了一步、而且存住了才清零）
var _progressed := false         ## 上一份检查点之后收下过答案 / AI 交过一步：下一份检查点存住时把 _recover_streak 清零
var _retry_since := -1           ## 这一次故障第一次 recover 的时刻（ms）；-1 = 没在重起
var _next_try_ms := 0            ## 这一次故障下一回最早什么时候再试
var _broken := ""                ## 房间判定的故障（答案 / 换手被拒、拿不到 envelope）或重起还没成：句柄自己没坏也当坏了
var _pending_surrender := -1     ## 出事那一下全票通过的投降（阵营）：重起时在新会话上补上
var _stale_batches := 0          ## 连着几批条目没存住检查点
var shard := -1                  ## 这一局在第几个 sidecar 进程里（开局 / 重起成了时记下；句柄坏了之后问不到了，重起要点名回这一个）


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
	_cfg = cfg.duplicate()
	kernel = CWKernelSidecar.new()
	if kernel.open(cfg):
		shard = kernel.link_shard()
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


## 句柄坏了（进程退出 / 连接断 / 超时 / 这一局内部出错）或房间判过坏（mark_broken）就返回原因，好的返回 ""。
## 句柄自己的原因优先：进程崩了的那一帧房间常常同时看见一条「答案被拒」，日志里要的是真原因
func fault() -> String:
	if kernel != null and kernel.state() == CWKernel.State.FAULTED:
		return String(kernel.last_error().get("msg", "sidecar 故障"))
	return _broken


## 房间这边看出来的故障（答案被拒 / 换手被拒 / 拿不到 envelope）。**不当场重起**：这一下可能正在泵的半中间（泵 → 问人 → 换手 → 被拒），
## 等房间下一帧的 tick 统一处理；在那之前泵、作答、推 AI 都不再碰句柄
func mark_broken(why: String) -> void:
	if _broken == "":
		_broken = why


## 存这份检查点那一刻的日志总行数（房间重起前把每人的日志游标压到这儿，见 CWRoom._sc_recover）
func checkpoint_log_total() -> int:
	return _cp_log_total


## 从最近的检查点换一个新会话接着打（见文件头）。只由房间的 tick 调（不在泵的半中间）。返回 Recover：
## DONE = 接着打了；RETRY = 新会话这会儿开不出来，下一帧再试；GIVE_UP = 没有检查点 / 记账超了 / 重试太久，房间中止。
## `ai_turn` = 出事时房间没在问真人（某个 AI 席在想）。这一次故障记不记账，按谁惹的：
##   · 句柄还好、是房间判的坏（答案 / 换手被拒、拿不到 envelope）—— 这一局的事，记
##   · 句柄坏了：自己那一局回了 broken / 链路死在自己那条请求的半中间（fault_is_mine）—— 记；
##     进程在别人的请求里或后台线程里死掉：这一局在等真人就不记（它什么都没干）；在等 AI 就记（AI 在后台想，进程可能就死在它手里）
## 一次故障只记一次：开不出来隔帧再试不重复记
func recover(ai_turn: bool) -> int:
	if room == null or _checkpoint.is_empty():
		return Recover.GIVE_UP
	var now := Time.get_ticks_msec()
	if _retry_since < 0:
		_retry_since = now
		if _blame(ai_turn):
			_recover_streak += 1
		_progressed = false
	elif now < _next_try_ms:
		return Recover.RETRY
	if _recover_streak > RECOVER_MAX:
		return Recover.GIVE_UP
	if kernel != null:
		kernel.close()
	var cfg := _cfg.duplicate()
	cfg["world_state"] = _checkpoint
	cfg["ai"] = _ai_now()
	## 回自己原来那个进程（分进程时）：这一局的局面要是就是把进程弄崩的那个，别换着进程把别的房间也拖下水；
	## 那个进程被限流拦着就当场失败、隔秒再试（10-02 复核）
	if shard >= 0:
		cfg["sidecar_shard"] = shard
	kernel = CWKernelSidecar.new()
	var opened := kernel.open(cfg)
	## 下一次最早什么时候试：从**这一次试完**算（握手卡死一次就是 8 秒，从开始算的话下一帧又接着试，10-01 三轮复核）
	_next_try_ms = Time.get_ticks_msec() + RETRY_INTERVAL_MS
	if not opened:
		var f := int(kernel.last_error().get("fault", 0))
		_error = String(kernel.last_error().get("msg", ""))
		_broken = "重起开不出新会话：%s" % _error
		## 检查点被拒（restore 被拒 = PROTOCOL）/ 版本对不上：再试也是同一个结果，别白冻一分钟
		if f == CWKernel.Fault.PROTOCOL or f == CWKernel.Fault.ABI_MISMATCH or f == CWKernel.Fault.SELFTEST_FAILED:
			return Recover.GIVE_UP
		## 局域网开服（服务器跑在房主的客户端里，链路不限流）：起进程卡住堵的是房主自己的界面，试一次不成就放弃（同 _wants_sidecar 看 start_failure 的口径）
		if bool(room.server.lan_host) and (f == CWKernel.Fault.HANDSHAKE_TIMEOUT or f == CWKernel.Fault.SPAWN_FAILED or f == CWKernel.Fault.REPLY_TIMEOUT):
			return Recover.GIVE_UP
		return _retry_or_give_up()
	_broken = ""
	_stale_batches = 0
	_seen = 0
	_room_ids.clear()
	_log_base = _cp_log_total
	_log_total = _cp_log_total
	if _pending_surrender >= 0:
		kernel.surrender(_pending_surrender)   ## 出事那一下全票通过的投降：新会话上补上，下面这一泵就是终局
	pump()   ## 新会话头一拍 step_end → 每人一份状态；停在真人那一问上就是一条新 ask（换房间新号）
	if kernel == null:
		recoveries += 1
		return Recover.DONE   ## 这一泵就是终局（补上的投降）：房间已经收局、把泵拆了
	if kernel.state() == CWKernel.State.FAULTED or _broken != "":
		## 新会话刚开、这一泵里又坏了（进程又没了 / 推状态失败）：还算这一次故障，过一会儿再试，不另记账；
		## 房间那边别当成功（不发旧号 step_begin、不说「接着打了」）
		if _broken == "":
			_broken = "重起之后又坏了：%s" % fault()
		return _retry_or_give_up()
	## 真接上了才插那一行「【系统】」、再给每人推一份状态把它带过去 —— 插在重起那一泵之前的话，
	## 重试几次客户端就收到几行（10-01 三轮复核）
	kernel.log_msg("【系统】服务器的规则内核出了故障，已从第 %d 回合的这一步接着打" % round_no)
	room.push_state(-1)
	recoveries += 1
	_retry_since = -1
	if kernel.link_shard() >= 0:
		shard = kernel.link_shard()
	return Recover.DONE


func _retry_or_give_up() -> int:
	return Recover.GIVE_UP if Time.get_ticks_msec() - _retry_since > RETRY_GIVE_UP_MS else Recover.RETRY


## 这一次故障记不记到这一局的账上（见 recover）
## `_progressed` = 上一份检查点之后这一局往前走过一步、还没存住：坏在推这一步的状态 / 存这一步的检查点上，
## 多半就是这一步的局面惹的（10-01 三轮复核：save 不在 RULE_OPS 里，存检查点时进程崩了原来谁都不记，无限重起）
func _blame(ai_turn: bool) -> bool:
	if kernel == null or kernel.state() != CWKernel.State.FAULTED:
		return true
	return kernel.fault_is_mine() or ai_turn or _progressed


## 重起时这一刻谁归 AI：房间的 AI 席 + 掉线的真人席（掉线 = 整席交给 AI，见 CWRoom._sc_seat_offline；
## 计时到点只代答一问的那种不记 —— 新会话把那一问重新问他、重新计时）
func _ai_now() -> Dictionary:
	var ai := ai_tiers(room.seats)
	for pid in room.seats.size():
		var s: Dictionary = room.seats[pid]
		if s["kind"] == "human" and not bool(s["online"]):
			ai[pid] = TAKEOVER_TIER
	return ai


func ended() -> bool:
	return kernel == null or kernel.state() == CWKernel.State.ENDED


## 把句柄里还没翻过的条目全翻掉。**不递归**：条目里的 ask 可能当场被代打（tick 里），代打又会带出新条目 ——
## 这里只认「拉 → 翻 → 再拉」一个循环，嵌套调进来的直接返回，外层那一圈会接着拉到
func pump() -> void:
	if _pumping or kernel == null or _broken != "":
		return
	_pumping = true
	var moved := false
	while kernel != null and _broken == "" and kernel.state() != CWKernel.State.FAULTED:
		var batch: Array = kernel.pull(CWKernel.VIEWER_OMNISCIENT, _seen, BATCH)
		if batch.is_empty():
			break
		moved = true
		for e: Dictionary in batch:
			_seen = int(e["seq"])
			_dispatch(e)
			## 终局 / 中止：房间已经把泵拆了；房间判了坏 / 句柄这一下坏了（推状态时进程没了）：这一批剩下的别再翻 ——
			## 后面多半是下一问，发出去重起之后就成了没人收的界面
			if kernel == null or _broken != "" or kernel.state() == CWKernel.State.FAULTED:
				break
		if kernel != null and _broken == "":
			kernel.discard_before(_seen)   ## 翻过就不要了：句柄的队列别跟着一局的长度涨
	_pumping = false
	if moved and kernel != null and _broken == "":
		_snapshot()


## 停在顶层一问上（真人或 AI 的）就存一份检查点；拆问的第二问里、终局之后存不了，留着上一份。
## 存住了、而且上一份之后往前走过一步，记账才清零（见文件头「记账」）
func _snapshot() -> void:
	if kernel.state() == CWKernel.State.FAULTED:
		return
	var blob := kernel.save()
	if blob.is_empty():
		_stale_batches += 1
		if _stale_batches == STALE_WARN:
			push_warning("CWNetPump：房间 %s 连着 %d 批条目没存住检查点（save 被拒？），崩了会回退好几步" % [room.code, STALE_WARN])
			room.server.say("房间 %s：连着 %d 批条目没存住检查点，崩了会回退好几步" % [room.code, STALE_WARN])
		return
	_stale_batches = 0
	_checkpoint = blob
	_cp_log_total = _log_total
	if _progressed:
		_recover_streak = 0
		_progressed = false


## 一问的答案交回句柄（index 已经由房间按「键为准、下标兜底」解析过），然后把这一步的条目泵出去
func answer(sidecar_ask_id: int, index: int) -> bool:
	if kernel == null or _broken != "" or not kernel.answer(sidecar_ask_id, { "index": index }):
		return false
	_progressed = true   ## 往前走了一步 —— 等这一步走完的局面存住了才清记账（_snapshot）
	pump()
	return true


## 把一席交给 sidecar 里的 AI（tier = TIER_OF 的值）或交还真人（tier = ""）。不在这儿泵：
## 交给 AI 的那一问要等房间下一次 step_ai() 才有动静；交还真人的那条 ask 由句柄下一帧拉过来、房间的 tick 泵出去
func set_ai(pid: int, tier: String, once := false) -> bool:
	return kernel != null and _broken == "" and kernel.set_ai(pid, tier, once)


## 推 AI 一步（房间每帧一次，只在没有真人被问着的时候）：sidecar 里想好了的那个答案这就交，交了就把这一步泵出去。
## 一帧最多一步 —— 同 GD 路「AI 每次决策之前让出一帧」，也正是 step_end 那一拍现取的 envelope 对得上这一步的原因（见文件头）
func step_ai() -> void:
	if kernel != null and _broken == "" and kernel.step_ai():
		_progressed = true
		pump()


## 投降投票全票通过：对方阵营直接获胜。句柄当场收局，step_end / game_over 这就泵出去。
## 先记下来：这一下 sidecar 已经坏着或正好坏了，重起时在新会话上补上（recover）—— 终局一泵出去房间就把泵拆了，这条记账跟着没了
func surrender(faction: int) -> void:
	if kernel == null:
		return
	_pending_surrender = faction
	if fault() != "":
		return
	kernel.surrender(faction)
	pump()
	## 收了局房间就把泵拆了（kernel 成了 null）。还在、句柄也没坏 = sidecar 没收这次投降（普通拒绝）：
	## 不报的话房间这时没有悬着的问、也没有计时，一局就这么停住了 —— 当坏了处理，重起时在新会话上补上
	if kernel != null and fault() == "":
		mark_broken("投降没收局（sidecar 拒了投降）")


func query(kind: String, args: Dictionary) -> Variant:
	return kernel.query(kind, args) if kernel != null else null


## 投降投票那两行日志：句柄的 log_msg 让 sidecar 往对局日志里插一行（10-01 起），随各人视角的 envelope.logs 下发
func log_line(text: String) -> void:
	if kernel != null and fault() == "":
		kernel.log_msg(text)


## 某一席 / 观众的 envelope，过网之前整成与 GD 路**逐类型相同**的形状：
##   · 数字整数化：C# 那边经 JSON 过来，数字全是浮点；GD 路发的是整数（观测协议零浮点）。坐标仍是 {q, r} 两键字典 ——
##     转 Vector2i 是客户端镜像装载时的事（CWMirror._normalize），这里不替它做
##   · ask.ask_id 置 0：GD 路这里恒为 0（收养模式下句柄不经手询问）；sidecar 的 ask 序号是会话内部的，过网没有意义，
##     客户端作答认的是 ask 报文里那个房间编号
##   · 日志行号按这一局的绝对行号进出（重起过的话当前会话差 `_log_base` 行，见文件头）
func envelope(viewer: int, logs_from: int) -> Dictionary:
	if kernel == null:
		return {}
	var env: Dictionary = ints(kernel.observe_envelope(viewer, maxi(logs_from - _log_base, 0)))
	if env.is_empty():
		return {}
	var logs: Dictionary = env["logs"]
	logs["from"] = int(logs["from"]) + _log_base
	_log_total = maxi(_log_total, int(logs["from"]) + Array(logs["lines"]).size())
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
