## cw_net_bridge.gd —— 服务器侧的席位桥：一个实例注册给房间里所有 pid
##
## 引擎问谁，就按席位表分流：真人席 → 发给客户端等作答（CWRoom.ask_human）；
## AI 席 → 现有的启发式/蒙特卡洛桥；离线的真人席 → 启发式即时代打。
## 演出（掷骰、结算说明、通报）广播给房里所有客户端。
## **只用一个桥对象**，和 CWUIBridge 一样：引擎的 roll_shown/announce/notice 按桥对象去重，
## 每席一个对象的话同一次掷骰会广播 N 遍。
##
## 每次询问之前先把最新状态推给所有人（push_state）：每一步之后必然接着一次询问或终局，
## 所以「询问前推一次」= 每步都推到了，还省了在引擎里加钩子。
class_name CWNetBridge
extends CWBridge

var room: CWRoom
var heur := CWHeuristicBridge.new()     ## 新手档 AI，也是超时 / 离线的代打
## 专家档 AI（席位 tier 仍叫 "mc"：那是建房报文里的键，客户端还在发，改名要升协议）。
## 2026-09-02 起是扁平蒙特卡洛（rollouts=2 · horizon=40）；**2026-09-19 Kevin「把意图级 AI 部署到服务器上，
## 代替目前的专家级 AI」** ⇒ 换成 MechBridge（PR #59 的第四档：迁移走意图规划器、其余回落启发式）。
## 它在服务器主线程同步跑、不起线程，评估只在独立副本上（t_mech_bridge_quiet），单问耗时见同一条测试打印的数。
var mc: CWHeuristicBridge = MechBridge.new()


func _init() -> void:
	## 专家档升级（2026-09-20）：与单人第五档「搜索」同款——alpha-beta v2 + E5 拟合估值
	## （单人实测：对最强免疫 0%→55.6%，见 docs/汇报_AI线_2026-09-21晨.md；本地未推）。
	## 延续 09-19 Kevin「意图级 AI 上服务器」的原地升级模式：tier 键仍是 "mc"，协议不动。
	## 代价：AI 决策同步跑在服务器主线程，单问 ~2-5s（回合制可接受）；评估只在独立副本（t_mech_bridge_quiet）。
	mc.use_search = true
	mc.use_fit_eval = true


func ask(req: Dictionary) -> int:
	var pid: int = req["pid"]
	room.push_state(pid)
	var s: Dictionary = room.seats[pid]
	if s["kind"] == "human" and s["online"]:
		return await room.ask_human(pid, req)
	## AI 席 / 离线代打：先让出一帧给网络轮询，再想（理由见 CWNetServer 文件头）
	await room.server.next_frame()
	if room.game == null or room.game.aborted:
		return 0            ## 让帧期间房间被关了
	if s["kind"] == "ai" and s["tier"] == "mc":
		return await mc.ask(req)
	return await heur.ask(req)


func show_roll(reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
	room.broadcast({ "t": "roll", "reason": reason, "value": value, "sides": sides, "pid": pid, "at": at })


func show_result(text: String, at: Vector2i, linger := false) -> void:
	room.broadcast({ "t": "result", "text": text, "at": at, "linger": linger })


func show_card_played(pid: int, text: String, info := {}) -> void:
	var m := { "t": "card_played", "pid": pid, "text": text }
	m.merge(info)
	room.broadcast(m)


func show_event_drawn(pid: int, info := {}) -> void:
	var m := { "t": "event_drawn", "pid": pid }
	m.merge(info)
	room.broadcast(m)



func show_card_drawn(pid: int, info := {}) -> void:
	var m := { "t": "card_drawn", "pid": pid }
	m.merge(info)
	room.broadcast(m)


func show_notice(text: String) -> void:
	room.broadcast({ "t": "notice", "text": text })


func show_beam(from: Vector2i, to: Vector2i, splash: Array) -> void:
	room.broadcast({ "t": "beam", "from": from, "to": to, "splash": splash })


func show_erosion(at: Vector2i, dir: int) -> void:
	room.broadcast({ "t": "erosion", "at": at, "dir": dir })


## 技能演出（issue #15）：S→C 方向的新报文，老客户端认不出就静静落空（不升协议号，同 beam）
func show_fx(kind: String, data: Dictionary) -> void:
	room.broadcast({ "t": "fx", "kind": kind, "data": data })
