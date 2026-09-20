## cw_kernel.gd —— 内核句柄抽象基类（口径二 · 批 0 步 9，docs/口径二_批0_底座规格.md A-3）
##
## 形制照今天已经在跑的联机路反推（Remote = cw_net_client.gd 的影子对局 + 报文流）：**镜像 + 有序条目队列 + 一个 answer**。
## InProc 把 CWGame 的桥回调翻译成入队；Sidecar / Remote 把报文翻译成入队。消费者只认「一条有序条目流 + 一个 answer 出口」，
## 不关心对端是本地 CWGame、本地 C# 进程还是服务器 —— 所以服务器走 (a) 还是 (b) 不阻塞这里。
##
## 条目形状（15 种，字段逐字照 cw_net_bridge.gd:34-80 的报文键，一个键都不改）：
##   演出 9 种：roll{reason,value,sides,pid,at} · result{text,at,linger} · notice{text} · card_played{pid,text,cell_id,pos,faction,card}
##              event_drawn{pid,cell_id,pos,faction,card} · card_drawn{pid,cell_id,pos,source}
##              erosion{at,dir} · beam{from,to,splash} · fx{kind,data}
##   另 4 种：log{index,text,secret_pid,public_text}（index 与上一条相同 = 就地改写末条，装得下 CWGame.log_run 的语义）
##            ask{ask_id,req,left_ms} · game_over{winner,reason,kind,round,replay} · sync{envelope}（传输层必发；InProc 在 cfg.observe_viewer 打开时也发，节拍见批 1 规格 A-1.5）
##   行动边界 2 种（p=2，Kevin 2026-09-19 拍演出播放形态 2）：step_begin{ask_id,seat}（一问答下之后）· step_end{rev}（下一问 / 终局之前，紧接着 sync）——
##            客户端把一步的演出当一个包顺序播完再落地 sync；引擎 / 服务器照旧不等演出。开局那段（落子 / 开局演出）也算一步，第一问之前先 step_end。
## 每条带 seq（单调、永不重编号）与 barrier（只有 roll 为 true：消费者 ack(seq) 之前内核不让后续条目生效，
## 批 0 不反转 await 语义 —— InProc 照旧真等，等价于今天 cw_game.gd:711-718 的 `await b.show_roll`）。
##
## 基类的默认实现全是「不可用态下定义良好的返回」：不抛、不崩 —— Sidecar 的 stub 与一致性套件靠它。
## UNAVAILABLE 是一等状态（路线A §5 第②档：基线内核起不来时单机 / 热座 / 教程 / 回放置灰、联机入口保持可用），
## 且**绝不能计进补丁系统的 STRIKES**（那是永久本地拉黑）。
class_name CWKernel
extends RefCounted

enum State { IDLE, STARTING, READY, AWAITING, ENDED, UNAVAILABLE, FAULTED }
enum Fault { NONE, SPAWN_FAILED, ABI_MISMATCH, SELFTEST_FAILED, HANDSHAKE_TIMEOUT, CRASHED, PROTOCOL }
const VIEWER_WATCHER := -1      ## 观众：手牌全占位、问答只给 kind / tag / seat / prompt
const VIEWER_OMNISCIENT := -2   ## 全知：明文、全给 —— **禁止过网**，只给本地宿主 / 热座
const STREAM_KINDS := ["roll", "result", "notice", "card_played", "event_drawn", "card_drawn",
	"erosion", "beam", "fx", "log", "ask", "game_over", "sync", "step_begin", "step_end"]

signal entry_ready()                          ## 队列里有新条目
signal state_changed(from: int, to: int)

var _state: int = State.IDLE
var _fault: int = Fault.NONE
var _fault_msg := ""


# ---- 生命周期 ----
## cfg = { factions, seed, cancer_types?, world_state?, record_replay?, deciders? / decider?, consumer?, step_drive?,
##         rules?（tune.restore_rules_state，排在 init 之后 world_state 之前）, autorun?（默认 true；false = 等 run()）,
##         adopt?（收养一个现成 CWGame：跳过 new+init、close() 不 dispose；没有 consumer 时不装 CWKernelBridge、不连 log_line）,
##         observe_viewer?（设了就在每次问人之前、终局之前各推一条 sync，批 1 规格 A-1.5）, open_hands? }
func open(_cfg: Dictionary) -> bool:
	return false


func close() -> void:
	pass


## autorun=false 的局从这里起跑（cw_room.gd 要保持「建局 → _name_seats() → _run()」的次序）
func run() -> void:
	pass


## aborted = true，并**释放所有 barrier 与悬着的 ask**（_fading / teardown / 教程跨章都是消费者循环没在跑的窗口）
func abort() -> void:
	pass


func state() -> int:
	return _state


func last_error() -> Dictionary:
	return { "fault": _fault, "msg": _fault_msg }


## 三个字段**必须分开**（迁移计划 §三 硬不变量③）：host_abi 是握手闸，rules_build 与 ruleset_digest 只上报、不闸
func version() -> Dictionary:
	return { "host_abi": 0, "rules_build": "", "ruleset_digest": "" }


func caps() -> Dictionary:
	return { "stream_sync": false, "step_drive": false, "rollout": false, "save": false, "authority": false }


# ---- 观测 ----
## 按席位裁剪过的镜像（CWMirror，步 8 落地后改返回类型）；不可用 / 还没开局返回 null
func observe(_viewer: int, _logs_from := 0) -> RefCounted:
	return null


## 原始 envelope（不经镜像校验 / 装载）：服务器逐 viewer 各编一份时省一次往返；logs_from 透给编码器
func observe_envelope(_viewer: int, _logs_from := 0) -> Dictionary:
	return {}


func logs_for(_viewer: int, _from: int) -> PackedStringArray:
	return PackedStringArray()


## seq > since_seq 的条目，按 viewer 裁剪（ask 只给主人完整选项；秘密日志行换公开替身）
func pull(_viewer: int, _since_seq: int, _limit := 64) -> Array:
	return []


## 播完一条 barrier 条目后回执
func ack(_seq: int) -> void:
	pass


## 最后一条已发出的 seq（0 = 还没有条目）
func entry_seq() -> int:
	return 0


## 丢掉 seq > 给定值的条目（回放快退后重推，免得同一段演出重复入队）；seq 永不重编号
func discard_after(_seq: int) -> void:
	pass


## 丢掉 seq <= 给定值的条目（播放队列播完一批调一次）
func discard_before(_seq: int) -> void:
	pass


# ---- 决策 ----
## choice = { key: String, index: int }：语义键为准、下标兜底（回放只有下标）
func answer(_ask_id: int, _choice: Dictionary) -> bool:
	return false


## = 今天的 bridge.abort()（match.gd:1026）：正在等的那一问作废
func abort_ask() -> void:
	pass


# ---- 持久化 ----
## 停在顶层 pending 边界且未终局（cw_save.gd:35 的判据）；中途询问期间 _pending 为空 ⇒ 自动为 false
func can_save() -> bool:
	return false


## ★ 含 rng 与明文手牌：宿主专用、绝不过网、绝不裁剪
func save() -> Dictionary:
	return {}


func restore(_blob: Dictionary) -> bool:
	return false


## CWReplay.of 的那十项（cw_replay.gd:71-85：version / players / seed / rules / cancer_types / answers / round / winner / win_reason / at）
func replay_tape() -> Dictionary:
	return {}


# ---- 回放 / 单步驱动（caps.step_drive）----
func pending() -> Dictionary:
	return {}


func step(_idx: int) -> void:
	pass


## 往前一步（pending → ask → step 三步收进内核，回放驱动只剩这一个游标）。放完 / 到终局返回 false
func step_once() -> bool:
	return false


## 中途换 decider（回放 Player.attach）：所有席位都换成 b
func set_decider(_b: Object) -> void:
	pass


# ---- 权威侧（Remote 实现里为空）----
## 产品逻辑**写**内核日志的唯一入口（cw_room.gd:567,624 投降投票要插两行）
func log_msg(_text: String, _secret_pid := -1, _public_text := "") -> void:
	pass


## 给某一席的名字加后缀（单机局真人席的「（我）」，Kevin 2026-09-19）。**纯装饰**，不进规则；
## 已经带了就不重复加。只有进程内句柄做得到；网络句柄名字归服务器（昵称），回 false
func mark_player(_pid: int, _suffix: String) -> bool:
	return false


func surrender(_faction: int) -> void:
	pass


func state_hash() -> String:
	return ""


# ---- 纯查询 ----
func query(_kind: String, _args: Dictionary) -> Variant:
	return null


# ---- AI 推演（caps.rollout；批 0 只占槽，政策归 AI 批）----
func fork_for_rollout() -> CWKernel:
	return null


func _set_state(next: int) -> void:
	if next == _state:
		return
	var prev := _state
	_state = next
	state_changed.emit(prev, next)


func _set_fault(fault: int, msg: String) -> void:
	_fault = fault
	_fault_msg = msg
