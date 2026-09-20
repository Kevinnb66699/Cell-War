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
var heur := CWHeuristicBridge.new()     ## 新手档 AI（超时 / 离线的代打 2026-09-20 起改走专家档，见 take_over）
## 专家档 AI（席位 tier 仍叫 "mc"：那是建房报文里的键，客户端还在发，改名要升协议）。
## 2026-09-02 起是扁平蒙特卡洛（rollouts=2 · horizon=40）；**2026-09-19 Kevin「把意图级 AI 部署到服务器上，
## 代替目前的专家级 AI」** ⇒ 换成 MechBridge（PR #59 的第四档：迁移走意图规划器、其余回落启发式）。
## 评估只在独立副本上（t_mech_bridge_quiet），单问耗时见同一条测试打印的数。
## **2026-09-20 Kevin「把服务器专家档 AI 也更新为这一版意图模型」**：开成 PR #69 的「搜索」配置
## （alpha-beta v2、叶 = 回合边界、E4 拟合估值），与单机第五档同款。
## **线程化（2026-09-20）**：服务器进程是 SceneTree（server_main.gd extends SceneTree），search_best 整体
## 抛副线程、主线程只在 next_frame / process_frame 出帧等结果 → 不再有 bench_search 那几秒「全服房间一起停」。
## 卸本地守护：无线程构建 / 拿不到 SceneTree 时自动退同步路径（代价回到原注释里的量级）。
var mc: CWHeuristicBridge = MechBridge.new()


func _init() -> void:
	var m := mc as MechBridge
	m.use_search = true
	m.use_fit_eval = true
	m.use_threading = true
	MechBridge._fit_linear_on = false


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
	if s["kind"] == "human":
		return await take_over(req)   ## 离线的真人席：专家档代打
	if s["tier"] == "mc":
		return await mc.ask(req)
	return await heur.ask(req)


## 代打（离线 / 超时的真人席）：**走专家档**（Kevin 2026-09-20「如果是新手级，帮我换成专家级 ai 代打」；
## 此前两条代打路都是新手档 heur）。房间的超时路（`CWRoom._tick` 到点）也从这儿走，计数给测试与统计
var takeovers := 0

func take_over(req: Dictionary) -> int:
	takeovers += 1
	return await mc.ask(req)


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
