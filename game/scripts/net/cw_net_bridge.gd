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
var mc := CWMonteCarloBridge.new()      ## 专家档 AI：人机对战参数（rollouts=2 · horizon=40，Kevin 2026-09-02 定）


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


func show_result(text: String, at: Vector2i) -> void:
	room.broadcast({ "t": "result", "text": text, "at": at })


func show_notice(text: String) -> void:
	room.broadcast({ "t": "notice", "text": text })
