## mech_bridge.gd —— 意图 AI 桥：action 用意图规划器选迁移，其余回落启发式
##
## 第一版意图级 AI：把 MechIntent（生成候选 → 评估「做完后的地图能量」→ 选最好）
## 接进 CWBridge。只接管 action 顶层询问：癌方用癌方 scorer、免疫方用免疫方 scorer，
## 卡牌 / 中途询问 / 开局 / 复活等一律回落启发式（super.ask）。
##
## 确定性：best_by 对并列取第一个最大值；evaluate_path 快照→试走→读数→回滚，
## rng 状态随快照复原 —— 同种子同配置同决策，可复现。
##
## ⚠ scorer 是**品味**不是规则：权重先全 1，等强度对局（mech_strength.gd）标定。
## ⚠ 免疫侧 metrics 尚不如癌侧完整（缺压迫/免疫视角杠杆），强度对局会暴露。
class_name MechBridge
extends CWHeuristicBridge


func ask(req: Dictionary) -> int:
	if req["kind"] == "action":
		var fac: int = game.player(req["pid"])["faction"]
		var scorer: Callable = MechBridge._cancer_score if fac == CWData.Faction.CANCER \
			else MechBridge._immune_score
		var intent := MechIntent.new()
		var best: Dictionary = await intent.best_by(game, req["pid"], scorer)
		## 只在「动过确实更好」时接管：best 为空路径（不动基线赢）→ 回落启发式
		if best.has("path") and best["path"].size() > 0:
			var idx := _find_move_option(req, best["path"][0])
			if idx >= 0:
				return idx
	return await super.ask(req)


## 癌方视角：地盘（胜利进度）+ 供给 + 能量银行差。
## ⚠ 实验记录（2026-09-20）：曾试「供给 × 剩余回合折现 + 能量差降权」→ 移动率 6.7%→33% 但
##    对普通免胜率反而 27.5%→15%（60 局实锤）。癌方弱不是「移动不够」；折现导致过度扩张、
##    能量被掏空送免收割，方向错误，已回退。真正缺的是固化/生存/免疫威胁的评估（下一步）。
static func _cancer_score(m: Dictionary) -> float:
	return float(m["win_progress"]) + float(m["cancer_supply"]) \
		+ float(m["cancer_energy"]) - float(m["immune_energy"])


## 免疫方视角：与癌方相反（-癌地盘 -癌供给）+ 免疫能量银行 + 记忆进度。权重先全 1。
static func _immune_score(m: Dictionary) -> float:
	return float(m["immune_energy"]) - float(m["cancer_energy"]) \
		- float(m["cancer_supply"]) - float(m["win_progress"]) \
		+ float(m["memory"])


func _find_move_option(req: Dictionary, to: Vector2i) -> int:
	for i in req["options"].size():
		var d: Dictionary = req["options"][i]["data"]
		if d.get("act", "") == "move" and d.get("to", Vector2i(-999, -999)) == to:
			return i
	return -1
