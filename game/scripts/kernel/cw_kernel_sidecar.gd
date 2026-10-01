## cw_kernel_sidecar.gd —— 本地 C# 内核进程（sidecar）的句柄（换内核 P1，docs/内核替换_重启计划.md §3.1 / §四 P1）
##
## 对消费者与 CWKernelInProc **同形**：同样 15 种条目、同样的 step_end → sync → ask 节拍、同样「有 decider 的席位不出 ask 条目」。
## 差别只在内核住在另一个进程里：
##   · 进程与连接住在 `cw_sidecar_link.gd`（2026-10-01 起**多个句柄共用一个进程**，各持自己的会话号 sid）：
##     起法是先开回环临时端口、再 `dotnet exec CellWar.Sidecar.dll --connect 127.0.0.1:<端口> --token <一次性随机串>`，它连回来核 hello。
##   · 报文：一行一个 JSON，请求 {id, op, sid, …} → 回应 {re, ok, …}。本地回环毫秒级，所以这里**同步**等回应（与 InProc 的同步接口一致）；
##     链路坏了（进程退出 / 超时）= FAULTED。sidecar 从不主动推送：每帧在 SceneTree.process_frame 上 pull 一次。
##   · 坐标与数字：报文里坐标是 {q,r}、数字是 JSON 浮点；条目与 req 一律过 CWMirror._normalize（与镜像装 envelope 同一套归一化），
##     sync 里的 envelope 原样留着（镜像自己归一化）。
##   · 拆问（C# 组键 → GD 两问）在 C# 宿主里做完了，这里收到的 ask 已经是 GD 形状；选项自带 key，作答一律按 key 交回去。
##
## ⚠ 硬不变量：sidecar 起不来 = UNAVAILABLE + SPAWN_FAILED，**与补丁系统完全隔离**（绝不计进 patch_state.gd 的 STRIKES）。
## P2（2026-10-01）补上：查询四条、开局 names / cancer_types、mark_player、surrender。
## 还没有的（返回基类的「定义良好的空值」）：日志条目与 log_msg（日志通道在做）、存读档、回放、单步驱动、state_hash —— 见计划 P2 / P4。
class_name CWKernelSidecar
extends CWKernel

const Link := preload("res://scripts/kernel/cw_sidecar_link.gd")
const Locator := preload("res://scripts/kernel/cw_sidecar_locator.gd")
const HOST_ABI := Link.HOST_ABI     ## 与 C# ObservationV1Codec.HostAbi 同值：握手只闸它（硬不变量③）
const PULL_LIMIT := 256

var deciders := {}                  ## pid → CWBridge：这一席的 ask 由它作答（与 InProc 同）；没有就入队等 answer()
var observe_viewer: Variant = null
var open_hands := false
var winner := -1

var _link: RefCounted = null        ## 共用的那条链路（cw_sidecar_link.gd）；close / 出故障时 release
var _pid := -1                      ## 记下来：close 之后测试还要看那个进程退没退
var _sid := -1
var _hello := {}
var _pulled := 0                    ## sidecar 那边已拉到的最后一个 seq
var _entries: Array = []
var _next_seq := 1                  ## 本句柄自己的 seq（有 decider 的 ask 不入队，所以与 sidecar 的 seq 不一一对应）
var _open_ask := {}                 ## 正在等的那一问：{ask_id, req, decider}
var _decider_ask := {}              ## 拉到了、还没交给 decider 的那一问（由 _pump 去答，见那儿的注释）
var _pumping := false
var _started := true                ## autorun=false 的局：open() 只拉条目、不替 decider 作答，等 run()（同 InProc：队列与第一份镜像先就位）
var _ticking := false


# ---- 生命周期 ----
## cfg：factions / seed / observe_viewer / open_hands / decider / deciders（同 InProc）；
## 另有 dotnet / sidecar_dll 两个路径覆盖（测试用）；缺省由 cw_sidecar_locator.gd 找（开发期仓库产物 / 导出包首次解到用户目录）
func open(cfg: Dictionary) -> bool:
	if _state != State.IDLE:
		return false
	_set_state(State.STARTING)
	var loc: Dictionary = {} if cfg.has("sidecar_dll") else Locator.locate()
	if loc.has("error"):
		return _unavailable(String(loc["error"]))
	var dotnet := String(cfg.get("dotnet", loc.get("dotnet", Locator.dev_dotnet())))
	var dll := String(cfg.get("sidecar_dll", loc.get("dll", "")))
	if dotnet == "" or dll == "" or not FileAccess.file_exists(dll):
		return _unavailable("找不到 sidecar（dotnet=%s，dll=%s）" % [dotnet, dll])
	_link = Link.acquire(dotnet, dll)
	if int(_link.fault) != 0:
		var f := int(_link.fault)
		var why := String(_link.fault_msg)
		_link = null
		if f == Fault.SPAWN_FAILED:
			return _unavailable(why)
		_fail(f, why)
		return false
	_pid = int(_link.pid)
	_hello = _link.hello
	observe_viewer = cfg.get("observe_viewer", null)
	open_hands = bool(cfg.get("open_hands", false))
	_started = bool(cfg.get("autorun", true))
	var open_cfg := { "factions": cfg.get("factions", []), "seed": int(cfg.get("seed", 1)), "open_hands": open_hands }
	for k in ["cancer_types", "names"]:   ## 癌种按癌席顺序钉死（同 InProc 的 tune.cancer_types）；names = 显示名（空串 = 默认名）
		if cfg.has(k):
			open_cfg[k] = cfg[k]
	if observe_viewer != null:
		open_cfg["observe_viewer"] = int(observe_viewer)
	## 新手教程（换内核 P5）：舞台 resolve 好的一份 cwxworld/3 + 这一关的骰子带子 —— sidecar 从这份世界续跑。
	## 整数化：关卡 json 经 JSON.parse_string 读进来数字全是 float，C# 那边按整数字段严格读（300.0 读不进 int）
	if cfg.has("world"):
		open_cfg["world"] = _ints(cfg["world"])
		open_cfg["rolls"] = _ints(cfg.get("rolls", []))
	## 读档：cfg.world_state 是本句柄 save() 存的 {kernel: "cs", checkpoint}（match.gd 按 kernel 标记选的句柄）
	var ws: Variant = cfg.get("world_state", null)
	var r: Dictionary
	if ws is Dictionary and String(ws.get("kernel", "")) == SAVE_KERNEL:
		r = _call("restore", { "checkpoint": String(ws["checkpoint"]), "observe_viewer": open_cfg.get("observe_viewer"), "open_hands": open_hands })
	else:
		r = _call("open", { "cfg": open_cfg })
	if not bool(r.get("ok", false)):
		_fail(Fault.PROTOCOL, "open 被拒：%s" % String(r.get("error", "无回应")))
		return false
	_sid = int(r["sid"])
	deciders = {}
	if cfg.has("decider") and cfg["decider"] != null:
		for pid in Array(cfg.get("factions", [])).size():
			deciders[pid] = cfg["decider"]
	if cfg.has("deciders"):
		deciders.merge(cfg["deciders"], true)
	_set_state(State.READY)
	_start_ticking()
	_pump()   ## 开局那段（落子之前）sidecar 已经算完：第一问马上就在（autorun=false 时只拉、不答）
	return true


## autorun=false 的局从这里起跑（match.gd：队列与第一份镜像就位之后）。sidecar 那边开局早算完了，这里只是开始替 decider 作答
func run() -> void:
	if _started or _sid < 0:
		return
	_started = true
	_pump()


## 关这一局的会话、放掉链路。进程不一定马上退：别的句柄可能还在用；没人用了也要空闲 30 秒才关（见 cw_sidecar_link.gd）
func close() -> void:
	_stop_ticking()
	_release_link()


## 空闲链路立刻关掉（测试看进程退没退 / 退出游戏前）
static func shutdown_idle_links() -> void:
	Link.shutdown_idle()


func abort() -> void:
	if _sid >= 0 and _link != null:
		_call("abort", { "sid": _sid })
	abort_ask()


func version() -> Dictionary:
	return { "host_abi": int(_hello.get("host_abi", 0)), "rules_build": String(_hello.get("rules_build", "")),
		"ruleset_digest": String(_hello.get("ruleset_digest", "")) }


func caps() -> Dictionary:
	return { "stream_sync": true, "step_drive": false, "rollout": false, "save": true, "authority": true, "query_sync": true }


# ---- 持久化（换内核 P4 前置，2026-10-01）----
## 存档 blob 里的内核标记：match.gd 读档时按它选句柄（GD 快照与 C# 检查点互相装不进对方）
const SAVE_KERNEL := "cs"


## 同 InProc：停在顶层问答边界、没终局（拆问的第二问里不能存 —— sidecar 那边判）
func can_save() -> bool:
	if _sid < 0:
		return false
	return bool(_call("can_save", { "sid": _sid }).get("can_save", false))


## ★ 检查点含 rng 与明文手牌：只进本机存档、绝不过网
func save() -> Dictionary:
	if _sid < 0:
		return {}
	var cp: Variant = _call("save", { "sid": _sid }).get("checkpoint", null)
	if not (cp is String) or String(cp) == "":
		return {}
	return { "kernel": SAVE_KERNEL, "checkpoint": cp, "rules_build": String(_hello.get("rules_build", "")) }


## sidecar 进程号（测试看它退没退）
func process_id() -> int:
	return _pid


# ---- 观测 ----
func observe(viewer: int, logs_from := 0) -> RefCounted:
	var env := observe_envelope(viewer, logs_from)
	if env.is_empty():
		return null
	var m := CWMirror.new()
	var err := m.load_from(env)
	if err != "":
		push_error("CWKernelSidecar.observe：envelope 装不进镜像：%s" % err)
		return null
	return m


func observe_envelope(viewer: int, logs_from := 0) -> Dictionary:
	if _sid < 0:
		return {}
	var r := _call("observe", { "sid": _sid, "viewer": viewer, "logs_from": logs_from })
	return r.get("envelope", {}) if bool(r.get("ok", false)) else {}


func pull(viewer: int, since_seq: int, limit := 64) -> Array:
	var out: Array = []
	for e: Dictionary in _entries:
		if int(e["seq"]) <= since_seq:
			continue
		out.append(_crop(viewer, e))
		if out.size() >= limit:
			break
	return out


func entry_seq() -> int:
	return _next_seq - 1


func discard_after(seq: int) -> void:
	var n := _entries.size()
	while n > 0 and int(_entries[n - 1]["seq"]) > seq:
		n -= 1
	_entries.resize(n)


func discard_before(seq: int) -> void:
	var n := 0
	while n < _entries.size() and int(_entries[n]["seq"]) <= seq:
		n += 1
	if n > 0:
		_entries = _entries.slice(n)


## C# 引擎不等动画（设计如此，计划 §3.2），roll 的 barrier 只是标记 —— 演出顺序由 CWPlayQueue 保证
func ack(_seq: int) -> void:
	pass


# ---- 决策 ----
## 键为准、下标兜底（同 InProc.answer）；有 decider 的那一问不收外面的答案
func answer(ask_id: int, choice: Dictionary) -> bool:
	if _open_ask.is_empty() or int(_open_ask["ask_id"]) != ask_id or bool(_open_ask.get("decider", false)):
		return false
	var opts: Array = _open_ask["req"]["options"]
	var key := ""
	if choice.has("key"):
		key = String(choice["key"])
	elif choice.has("index"):
		var i := int(choice["index"])
		if i < 0 or i >= opts.size():
			return false
		key = String(opts[i]["key"])
	if key == "" or not _submit(ask_id, key):
		return false
	_open_ask = {}
	_set_state(State.READY)
	_pump()   ## 这一步的演出与下一问马上就在（与 InProc 同步跑到下一问同义）
	return true


## 叫醒卡在 decider 里的那一问（拆局 / 教程跨章，同 InProc 的理由）；外面等着的那一问作废、不替它作答。
## **先清再叫醒**：decider 的 abort() 会当场把它那一问答掉（ui_bridge 的 Answer.fire），`_pump` 在同一个调用栈里就醒过来往下走 ——
## 那时 `_open_ask` 还在的话，它会把答案交给已经中止的 sidecar（2026-10-01 热座冒烟拆局时抓到）
func abort_ask() -> void:
	_open_ask = {}
	_decider_ask = {}
	var seen: Array = []
	for d in deciders.values():
		if d != null and not seen.has(d) and d.has_method("abort"):
			seen.append(d)
			d.abort()


## 观测协议 §5.3 的四条查询，返回与 InProc.query 同形（plan_next_dests：Vector2i 数组；quote_path：{steps, total, …}；
## cost_effects_for：[{name, changes, targets, total}]，批量 `acts` 是 {act: […]}；move_block_reason：字符串）。
## 参数里的 Vector2i 发成 {q,r}（CWObsCodec._plain），回来的坐标再换回 Vector2i（CWMirror._normalize）。
func query(kind: String, args: Dictionary) -> Variant:
	if _sid < 0 or not args.has("cid"):
		return null
	var r := _call("query", { "sid": _sid, "kind": kind, "args": CWObsCodec._plain(args) })
	if not bool(r.get("ok", false)):
		return null
	return CWMirror._normalize(r.get("result"))


## 同 InProc.mark_player：给一席的名字加后缀（已带了不重复加）。纯装饰，sidecar 那边改的是同一个名字字段，之后的观测都用新名字
func mark_player(pid: int, suffix: String) -> bool:
	if _sid < 0:
		return false
	return bool(_call("mark_player", { "sid": _sid, "pid": pid, "suffix": suffix }).get("ok_mark", false))


## 同 InProc.surrender：对方阵营直接获胜。sidecar 当场收局，这里马上泵一次把 step_end / sync / game_over 拉过来
func surrender(faction: int) -> void:
	if _sid < 0:
		return
	_call("surrender", { "sid": _sid, "faction": faction })
	_pump()


## 活局面导成一份 cwxworld/3（同 `cw_world_loader.gd:dump_world`；教程间章「重心平移」先导出、平移、再装回来）
func dump_world() -> Dictionary:
	if _sid < 0:
		return {}
	var w: Variant = _call("dump_world", { "sid": _sid }).get("world", null)
	return _ints(w) if w is Dictionary else {}


## JSON 来回之后整数都成了 float：整数值的 float 换回 int（坐标、能量十分位、计数都是整数；真小数原样留着）
static func _ints(v: Variant) -> Variant:
	if v is float:
		return int(v) if v == floor(v) else v
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _ints(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for x in v:
			arr.append(_ints(x))
		return arr
	return v


## 产品逻辑写内核日志的入口（同 InProc：服务器投降投票那两行）。sidecar 插完那一行就泵，`log` 条目当场进流
func log_msg(text: String, secret_pid := -1, public_text := "") -> void:
	if _sid < 0:
		return
	_call("log_msg", { "sid": _sid, "text": text, "secret_pid": secret_pid, "public_text": public_text })
	_pump()


func set_decider(b: Object) -> void:
	if b == null:
		return
	for pid in deciders.keys():
		deciders[pid] = b


# ---- 找 sidecar（开发期；导出包的路由在 cw_sidecar_locator.gd）----
static func find_dotnet() -> String:
	return Locator.dev_dotnet()


## 环境变量 CW_SIDECAR_DLL 覆盖，否则仓库里 core/CellWar.Sidecar 的 Debug 产物
static func find_sidecar_dll() -> String:
	var env := OS.get_environment("CW_SIDECAR_DLL")
	return env if env != "" else Locator.dev_dll()


# ---- 内部：报文 ----
## 链路级故障（进程退出 / 超时）由链路记下，这里转成本句柄的 FAULTED；会话级的拒绝（ok=false）原样交给调用方
func _call(op: String, args := {}) -> Dictionary:
	if _link == null:
		return {}
	var r: Dictionary = _link.request(op, args)
	if int(_link.fault) != 0:
		_fail(int(_link.fault), String(_link.fault_msg))
		return {}
	return r


func _submit(ask_id: int, key: String) -> bool:
	var r := _call("answer", { "sid": _sid, "ask_id": ask_id, "key": key })
	return bool(r.get("accepted", false))


# ---- 内部：条目 ----
func _start_ticking() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.process_frame.is_connected(_tick):
		tree.process_frame.connect(_tick)
		_ticking = true


func _stop_ticking() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if _ticking and tree != null and tree.process_frame.is_connected(_tick):
		tree.process_frame.disconnect(_tick)
	_ticking = false


func _tick() -> void:
	if _link == null or _sid < 0 or _state == State.FAULTED or _state == State.UNAVAILABLE:
		return
	if not _link.alive():
		_fail(Fault.CRASHED, String(_link.fault_msg) if int(_link.fault) != 0 else "sidecar 进程退出了（退出码 %d）" % OS.get_process_exit_code(_pid))
		return
	_pump()


## 把 sidecar 那边的新条目全拉过来、翻成 GD 形状入队
func _drain() -> void:
	while _sid >= 0 and _link != null:
		var r := _call("pull", { "sid": _sid, "viewer": VIEWER_OMNISCIENT, "since": _pulled, "limit": PULL_LIMIT })
		if not bool(r.get("ok", false)):
			return
		var batch: Array = r.get("entries", [])
		for raw: Dictionary in batch:
			_accept(raw)
		if batch.size() < PULL_LIMIT:
			return


func _accept(raw: Dictionary) -> void:
	_pulled = int(raw["seq"])
	var kind := String(raw["t"])
	match kind:
		"sync":
			_push("sync", { "envelope": raw["envelope"] })   ## envelope 原样：镜像自己归一化
		"ask":
			var req: Dictionary = CWMirror._normalize(raw["req"])
			var ask_id := int(raw["ask_id"])
			var pid := int(req.get("pid", -1))
			if deciders.has(pid):
				_open_ask = { "ask_id": ask_id, "req": req, "decider": true }   ## 有 decider 的席位不出 ask 条目（同 InProc）
				_decider_ask = { "ask_id": ask_id, "req": req }
				_set_state(State.AWAITING)
			else:
				_open_ask = { "ask_id": ask_id, "req": req, "decider": false }
				_set_state(State.AWAITING)
				_push("ask", { "ask_id": ask_id, "req": req, "left_ms": int(raw.get("left_ms", -1)) })
		"game_over":
			var g: Dictionary = CWMirror._normalize(raw)
			winner = int(g["winner"])
			_push("game_over", { "winner": winner, "reason": String(g.get("reason", "")), "kind": String(g.get("kind", "")),
				"round": int(g.get("round", 0)), "replay": g.get("replay", {}) })
			_set_state(State.ENDED)
		_:
			var e: Dictionary = CWMirror._normalize(raw)
			var barrier := bool(e.get("barrier", false))
			e.erase("t")
			e.erase("seq")
			e.erase("barrier")
			_push(kind, e, barrier)


## 拉条目 + 替 decider 作答的唯一循环。**不许递归**：同步作答的 decider（无头测试、脚本 NPC）一局几千问，
## 「拉到 ask → 作答 → 再拉」要是层层调用，几千层就爆栈。所以拉条目（_drain）只把 decider 那一问记进 _decider_ask，
## 由这里一问一问地答；decider 要等人（界面桥）时这条协程挂起，期间 _tick 再进来直接返回（_pumping）。
func _pump() -> void:
	if _pumping:
		return
	_pumping = true
	while _sid >= 0 and _link != null:
		_drain()
		if _decider_ask.is_empty() or not _started:
			break
		var a: Dictionary = _decider_ask
		_decider_ask = {}
		var ask_id := int(a["ask_id"])
		var req: Dictionary = a["req"]
		var idx: int = await deciders[int(req["pid"])].ask(req)
		if _open_ask.is_empty() or int(_open_ask["ask_id"]) != ask_id or _sid < 0:
			break   ## 等的时候被 abort / close 了
		_open_ask = {}
		var opts: Array = req["options"]
		if opts.is_empty() or not _submit(ask_id, String(opts[clampi(idx, 0, opts.size() - 1)]["key"])):
			_fail(Fault.PROTOCOL, "decider 的答案被 sidecar 拒了（ask %d）" % ask_id)
			break
		if _state == State.AWAITING:
			_set_state(State.READY)
	_pumping = false


func _push(kind: String, m: Dictionary, barrier := false) -> int:
	var e := m.duplicate()
	e["t"] = kind
	e["seq"] = _next_seq
	e["barrier"] = barrier
	_next_seq += 1
	_entries.append(e)
	entry_ready.emit()
	return int(e["seq"])


## 同 InProc._crop：ask 只给主人完整选项，观众 / 别的席位只留 kind / tag / seat / prompt（P1 没有日志条目，没有秘密行要换）
## 逐字照 InProc 的 `_crop`：本地只拉一份全知流，按观看者裁 —— 别人的问答不给选项、别人的秘密日志行换成公开替身
func _crop(viewer: int, e: Dictionary) -> Dictionary:
	if viewer == VIEWER_OMNISCIENT:
		return e
	match String(e["t"]):
		"ask":
			var req: Dictionary = e["req"]
			if int(req.get("pid", -1)) == viewer:
				return e
			var c := e.duplicate()
			var r := req.duplicate()
			r["options"] = []
			c["req"] = r
			return c
		"log":
			if int(e["secret_pid"]) >= 0 and int(e["secret_pid"]) != viewer:
				var c := e.duplicate()
				c["text"] = e["public_text"]
				return c
	return e


func _unavailable(msg: String) -> bool:
	_set_fault(Fault.SPAWN_FAILED, msg)
	_set_state(State.UNAVAILABLE)
	_release_link()
	return false


func _fail(fault: int, msg: String) -> void:
	if _state == State.FAULTED:
		return
	push_error("CWKernelSidecar：%s" % msg)
	_set_fault(fault, msg)
	_set_state(State.FAULTED)
	_stop_ticking()
	_open_ask = {}
	_release_link()


## 关掉自己的会话（链路还活着才发 close）、引用 −1。链路本身坏了的话它自己已经杀过进程了
func _release_link() -> void:
	if _link != null:
		if _sid >= 0 and _link.alive():
			_link.request("close", { "sid": _sid })
		_link.release()
		_link = null
	_sid = -1
