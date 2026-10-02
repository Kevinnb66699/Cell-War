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
var _viewed := false                ## 头一份观测拿到了没有：之前链路出的事都算「起不来」（见 `_link_fault`）
var _fault_mine := false            ## 这次 FAULTED 是不是本句柄惹的：自己那一局回了 broken，或链路死在自己那条请求的半中间（见 fault_is_mine）


# ---- 生命周期 ----
## cfg：factions / seed / observe_viewer / open_hands / decider / deciders（同 InProc）；
## 另有 dotnet / sidecar_dll 两个路径覆盖（测试用）；缺省由 cw_sidecar_locator.gd 找（开发期仓库产物 / 导出包首次解到用户目录）
## `ai: {席位: "normal" | "intent" | "search"}` + `ai_delay_ms`（换内核 P3）：那几席由 sidecar 进程里的 C# AI 作答，
## 不出 ask 条目（同有 decider 的席位），句柄照常每帧 pull —— 原样转给 sidecar 的 open。
func open(cfg: Dictionary) -> bool:
	if _state != State.IDLE:
		return false
	_set_state(State.STARTING)
	var loc := locate(cfg)
	if loc.has("error"):
		_remember_start_failure(Fault.SPAWN_FAILED, String(loc["error"]))
		return _unavailable(String(loc["error"]))
	_link = Link.acquire(String(loc["dotnet"]), String(loc["dll"]))
	if int(_link.fault) != 0:
		var f := int(_link.fault)
		var why := String(_link.fault_msg)
		_link = null
		_remember_start_failure(f, why)   ## 起进程 / 握手这一段没成（复用现成的活链路走不到这儿）
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
	if cfg.has("ai"):
		var ai := {}
		for seat in cfg["ai"]:
			ai[str(seat)] = String(cfg["ai"][seat])   ## JSON 的键只能是字符串
		open_cfg["ai"] = ai
		open_cfg["ai_delay_ms"] = int(cfg.get("ai_delay_ms", 0))
	## 服务器（换内核 P6）：AI 想好了也等 step_ai() 才交 —— 不看 ai 有没有席位，全真人房中途也会有人掉线、席位交给 AI（见 cw_net_pump.gd 头注）
	if bool(cfg.get("ai_paced", false)):
		open_cfg["ai_paced"] = true
	## 新手教程（换内核 P5）：舞台 resolve 好的一份 cwxworld/3 + 这一关的骰子带子 —— sidecar 从这份世界续跑。
	## 整数化：关卡 json 经 JSON.parse_string 读进来数字全是 float，C# 那边按整数字段严格读（300.0 读不进 int）
	if cfg.has("world"):
		open_cfg["world"] = _ints(cfg["world"])
		open_cfg["rolls"] = _ints(cfg.get("rolls", []))
	## 读档：cfg.world_state 是本句柄 save() 存的 {kernel: "cs", checkpoint}（match.gd 按 kernel 标记选的句柄）
	var ws: Variant = cfg.get("world_state", null)
	var r: Dictionary
	if ws is Dictionary and String(ws.get("kernel", "")) == SAVE_KERNEL:
		## 检查点里不记 AI 配置：AI 席与停顿照这一次的 cfg 再给一遍（match.gd 按存档里的档位与真人席算）
		var rq := { "checkpoint": String(ws["checkpoint"]), "observe_viewer": open_cfg.get("observe_viewer"), "open_hands": open_hands, "seed": open_cfg["seed"] }
		for k in ["ai", "ai_delay_ms", "ai_paced"]:
			if open_cfg.has(k):
				rq[k] = open_cfg[k]
		r = _call("restore", rq)
	else:
		r = _call("open", { "cfg": open_cfg })
	if not bool(r.get("ok", false)):
		_fail(Fault.PROTOCOL, "open 被拒：%s" % String(r.get("error", "无回应")))
		return false
	_sid = int(r["sid"])
	deciders = {}
	if cfg.has("decider") and cfg["decider"] != null:
		for pid in _seat_count(cfg):
			deciders[pid] = cfg["decider"]
	if cfg.has("deciders"):
		deciders.merge(cfg["deciders"], true)
	_set_state(State.READY)
	_start_ticking()
	_pump()   ## 开局那段（落子之前）sidecar 已经算完：第一问马上就在（autorun=false 时只拉、不答）
	return true


## 这一局有几席（`decider` 要挂满每一席，同 InProc 按 `game.order` 挂）。
## 三种开局各有各的出处：新开局看 `factions`；教程从关卡世界开局（换内核 P5）不传 factions，席位在世界的 `players` 里；
## 读档（`world_state`）时 match.gd 照样带着 factions。都没有就是 0 席 —— 那种 cfg 本来也开不出局
static func _seat_count(cfg: Dictionary) -> int:
	if cfg.get("world") is Dictionary:
		return Array((cfg["world"] as Dictionary).get("players", [])).size()
	return Array(cfg.get("factions", [])).size()


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


## FAULTED 是不是本句柄自己惹的（服务器重起时记账用，cw_net_pump.gd:recover）：自己那一局在 sidecar 里出了内部错误，
## 或者链路死在自己那条请求的半中间。进程在别人的请求里 / 后台线程里死掉、本句柄只是下一帧看见 —— false
func fault_is_mine() -> bool:
	return _fault_mine


## 这一局在第几个 sidecar 进程里（服务器分进程时有意义，见 cw_sidecar_link.gd「分进程」；没连上是 -1）
func link_shard() -> int:
	return int(_link.shard) if _link != null else -1


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


## 开局的头一份镜像（全知）。open() 返回 true 还不算开成（2026-10-01 复核）：之后、头一份镜像落地之前 sidecar 照样可能
## 当场出事 —— open 里头一下拉条目、头一次观测就崩 / 超时 / 被拒。界面没有镜像画不出第一帧，match.gd 那道
## 「镜像还没到」的闸后面什么都不跑：不退回、也不报，棋盘就空在那儿。所以客户端开完先要这一份，要不到就照「起不来」走
##（新开局退回 GD、C# 存档回主菜单说明）。要不到时句柄转 FAULTED（已经 FAULTED 的保留原来的原因），会话与链路一并放掉；
## 断在链路上的（进程没了 / 卡住不回）还记成「起不来」（`_link_fault`），被拒的不记
func first_view() -> CWMirror:
	var m := observe(VIEWER_OMNISCIENT) as CWMirror
	if m == null:
		_fail(Fault.PROTOCOL, "开局要不到第一份观测")
	return m


func observe_envelope(viewer: int, logs_from := 0) -> Dictionary:
	if _sid < 0:
		return {}
	var r := _call("observe", { "sid": _sid, "viewer": viewer, "logs_from": logs_from })
	if not bool(r.get("ok", false)):
		return {}
	_viewed = true
	return r.get("envelope", {})


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


## 活局面导成一份 cwxworld/3（同 `cw_world_loader.gd:dump_world`；教程间章「重心平移」先导出、平移、再装回来）。
## **null 一律删掉**：C# 把没写的可选字段序列化成 `"type": null` / `"chemo": null`（它自己读的时候 null = 没写），
## 而 GD 这边的读法认的是「有没有这个键」—— 舞台 `_pin_specials` 见 `has("type")` 就不钉器官，平移之后器官会跳格
func dump_world() -> Dictionary:
	if _sid < 0:
		return {}
	var w: Variant = _call("dump_world", { "sid": _sid }).get("world", null)
	return _ints(_drop_nulls(w)) if w is Dictionary else {}


## 字典里值为 null 的键整条删掉（递归；数组里的元素原样留着，cwxworld/3 的数组里没有 null）
static func _drop_nulls(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v:
			if v[k] != null:
				out[k] = _drop_nulls(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for x in v:
			arr.append(_drop_nulls(x))
		return arr
	return v


## 教程骰子带子的账（换内核 P5（三））：`{size, at, overrun, bad_range}`，与 GD `cw_roll_tape.gd` 的四个量同义。
## 只有从关卡世界开的局有带子，别的局（以及链路坏了）给 {}
func tape_stats() -> Dictionary:
	if _sid < 0:
		return {}
	var r := _call("tape", { "sid": _sid })
	if not bool(r.get("ok", false)):
		return {}
	return { "size": int(r["size"]), "at": int(r["at"]), "overrun": int(r["overrun"]), "bad_range": int(r["bad_range"]) }


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


## 中途换一席的作答方（换内核 P6：服务器的掉线 / 超时代打交给 sidecar 里的 AI、重连交还）。
## tier = "normal" / "intent" / "search" 交给 AI，"" 交还真人；once = 只代答这一席眼下那一问（计时到点）。
## 这一席正被问着的话那一问被收回（改由 AI 答，AI 的 step_begin 照旧带它的号）：本句柄这边那一问作废、answer 不再收它。
## 交还真人时 AI 若正想着他那一问，sidecar 当场改问人 —— 那条 ask 条目下一帧 pull 过来。
func set_ai(seat: int, tier: String, once := false) -> bool:
	if _sid < 0:
		return false
	var r := _call("set_ai", { "sid": _sid, "seat": seat, "tier": tier if tier != "" else null, "once": once })
	if not bool(r.get("ok", false)):
		return false
	var withdrawn := int(r.get("withdrawn", -1))
	if withdrawn >= 0 and not _open_ask.is_empty() and int(_open_ask["ask_id"]) == withdrawn:
		_open_ask = {}
		_set_state(State.READY)
	return true


## open 时设了 ai_paced：AI 想好了的那一问这就交（还在想 / 眼下问的不是 AI = false）。交了就把这一步的条目拉过来
func step_ai() -> bool:
	if _sid < 0:
		return false
	if not bool(_call("ai_step", { "sid": _sid }).get("stepped", false)):
		return false
	_pump()
	return true


func set_decider(b: Object) -> void:
	if b == null:
		return
	for pid in deciders.keys():
		deciders[pid] = b


# ---- 新开局默认走不走 sidecar（换内核 P8 切换，docs/内核替换_重启计划.md §八 第 1 条）----
## 默认走 C# 内核。**`tools/publish_release.sh` 第 ⑥ 闸认这一行**：是 true 时包里缺载荷 / 运行时就不许发版。
## 环境变量 `CW_KERNEL=gd` 强制走 GD 内核：观察期的逃生口，也是无头测试的缺省（headless_test.gd 开跑前设好 ——
## 那批界面测试要钻进 GD 引擎看内部状态；测 C# 路的测试自己设 `sidecar`、测完设回 `gd`）。
## 只管**新开局**：桌面新开局（match.gd:_new_local_kernel）、教程换盘（cw_tutorial_stage.gd:_open_spec）、
## 服务器建局（cw_room.gd:_wants_sidecar）与网页单机房（cw_net_server.gd:_create_solo）都只问 `wanted()`。
## 读档不问：存档自己说是哪个内核存的。这一次运行里起不来过（`start_failure`）照旧由各调用方自己看
const SIDECAR_DEFAULT := true


## 网页包里起不了本地进程：恒 false（网页单机走服务器的单机房）
static func wanted() -> bool:
	if OS.has_feature("web"):
		return false
	match OS.get_environment("CW_KERNEL"):
		"gd":
			return false
		"sidecar":
			return true
	return SIDECAR_DEFAULT


# ---- 找 sidecar（开发期；导出包的路由在 cw_sidecar_locator.gd）----
## 这一次去哪儿起 sidecar：`{dotnet, dll}`，找不到给 `{error}`（原话，只进日志）。cfg 里的 dotnet / sidecar_dll 覆盖（测试用），
## 缺省由 cw_sidecar_locator.gd 找。open() 起进程之前就是这么判的；main.gd「继续对局」推镜头之前也先问一句（找不到就没得试，当场说）。
## **不是纯查询**：导出包里它会把 pck 里的 .NET 运行时与载荷解到 user://sidecar/（`Locator.unpack`，第一次要解几秒）、补宿主的可执行位、
## 删掉旧版本的目录。这些都是幂等的 —— 解好的目录有 `.ok` 标记就直接用，问几次落到盘上的都是同一份，所以先问一句不会多出什么。
## 它不记 `start_failure`（那归真去开的 open()）
static func locate(cfg := {}) -> Dictionary:
	var loc: Dictionary = {} if cfg.has("sidecar_dll") else Locator.locate()
	if loc.has("error"):
		return loc
	var dotnet := String(cfg.get("dotnet", loc.get("dotnet", Locator.dev_dotnet())))
	var dll := String(cfg.get("sidecar_dll", loc.get("dll", "")))
	if dotnet == "" or dll == "" or not FileAccess.file_exists(dll):
		return { "error": "找不到 sidecar（dotnet=%s，dll=%s）" % [dotnet, dll] }
	return { "dotnet": dotnet, "dll": dll }


## 这一次运行里 sidecar 起不来过没有：第一次起不来就记下 `{fault, msg}`，记到退出游戏；空 = 没有过。
## 「起不来」= 头一份观测拿到之前就没了：找不到产物 / 进程起不来 / 握手没成（open() 当场记），以及（2026-10-01 三轮复核补）
## 握上手了、却死在 open / restore / 头一次观测上 —— 进程没了或卡住不回（`_link_fault` 记）。被拒（不认这份检查点）不算：内核是好的。
## 为什么要记（2026-10-01 复核）：客户端每个新开局都会再试一次，教程通关一遍要换 17 次盘、每次换盘都试 ——
## 找不到文件当场就失败，没感觉；卡在握手上的那种每试一次就把主线程堵 Link.HANDSHAKE_MS（8 秒），卡在 open 上的堵 Link.REPLY_TIMEOUT_MS（5 秒）再加收进程。
## **句柄只记不拦**，看不看归调用方：
##   · 看（见它就直接走 GD）：客户端的自动路 —— match.gd 新开局、教程舞台换盘；局域网开服的房间（服务器跑在客户端进程里，
##     cw_room.gd:_wants_sidecar 看 `server.lan`）—— 每试一次堵的都是房主自己的界面。
##   · 不看：玩家亲手点的「继续对局」（main.gd:_continue 先清掉、真去试一次：开成了就空着，没起来由这一次重新记下）；
##     专用服务器（server_main.gd 起的无头进程）每开一间房照旧重试 —— 它一开就是好几天（systemd 常驻、部署才重启），
##     记一次就要到下次部署才清，期间每间房都悄悄走 GD 路、网页单机房（只走 C#）一律答 solo_off。不是因为它没有退路：普通房起不来照样走 GD。
## 开局之后（头一份观测之后）才出的事不记：那不是「起不来」，下一局照样值得一试。测试每支开跑前清空（headless_test.gd）
static var start_failure := {}


static func _remember_start_failure(fault: int, msg: String) -> void:
	if start_failure.is_empty():
		start_failure = { "fault": fault, "msg": msg }


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
		_fault_mine = _sid >= 0 and int(_link.fault_sid) == _sid
		_link_fault(int(_link.fault), String(_link.fault_msg))
		return {}
	## 这一局在 sidecar 那边出了内部错误（规则 / 宿主的 bug，Dispatcher 接住了、没让整个进程退出）：会话已停用，
	## 句柄转 FAULTED（会话级：链路照常给别的局用）。服务器的房间据此从检查点重起（cw_net_pump.gd:recover），桌面弹「对局中断」
	if bool(r.get("broken", false)):
		_fault_mine = true
		_fail(Fault.PROTOCOL, "sidecar 这一局出了内部错误：%s" % String(r.get("error", "")))
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
		## 链路自己记过故障就照它的种类：同一条链路上别的句柄等满了 5 秒（REPLY_TIMEOUT）、链路随即收掉进程，
		## 这里只是晚一帧看见 —— 改记成 CRASHED 的话，通知就从「没有响应」变成了「意外退出了」（10-01 三轮复核）。
		## 链路还没记过（这一帧才发现进程不在了）才是 CRASHED
		if int(_link.fault) == 0:
			## 这一帧才发现进程不在了：让链路自己记一笔（进「一分钟死几次」的账、从共用表里摘掉），别的句柄下一帧照它的种类记
			_link._die(Fault.CRASHED, "sidecar 进程退出了（退出码 %d）" % OS.get_process_exit_code(_pid))
		_fault_mine = false
		_link_fault(int(_link.fault), String(_link.fault_msg))
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


## 链路级故障（进程退出 / 连接断 / 卡住不回：记在共用链路上，挂在上面的句柄都看得见）→ 本句柄 FAULTED；
## 头一份观测之前出的同时记成「起不来」（10-01 三轮复核，理由见 `start_failure`）。会话级的拒绝（ok=false）不走这里，直接 `_fail`
func _link_fault(fault: int, msg: String) -> void:
	if not _viewed:
		_remember_start_failure(fault, msg)
	_fail(fault, msg)


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
