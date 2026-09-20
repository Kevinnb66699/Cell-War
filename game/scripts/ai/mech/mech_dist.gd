class_name MechDist
## 能量距离场（2026-09-20）：按引擎计价模型的多源 Dijkstra。
##
## 为什么不用六边形距离：迁移的真实成本由**组织类型 + tune 表**决定（健康/癌化价差悬殊），
## 「免疫几步能走到」和「免疫要走多少能量」是两回事——癌化地毯上免疫可能一步 0.5 地
## 摸进来，健康地上两格就要 2.4，六边形距离完全分不出来。人机局4 实测（2026-09-20）：
## 旧 `SAFETY_BY_DIST` 查六边形距离，癌被「远离免疫=安全」赶着 R1 四步直线退角、
## 6 回合被清场——几何安全 ≠ 战术安全。
##
## 简化（相对引擎 quote_path 的全价模型，二阶效应，启发式用途足够）：
## ① 不建模行走中的【定殖】/【净化】翻面对后续单价的影响；
## ② 不算费用修饰（【基质阻隔】等走 CWCost.quote，逐格调用太贵）。
##
## 用途边界：只喂**启发式评分**（候选排序 / 威胁度量）。要进叶估值必须先过数据拟合
## （项目纪律：eval 系数不许手拍）。

## 决策内缓存：场只依赖「免疫位姿 + 等级 + 回合」（翻面不建模，癌走位不影响免疫场），
## 同回合内被 evaluate_path / 启发式反复请求——不缓存的话每次评估都全盘 Dijkstra（实测 14s→49s）。
## 键含免疫逐只位姿：免疫在自己阶段走位后自动失配重算。确定性：场是状态纯函数，缓存不改变决策。
static var _ck := ""
static var _cf: Dictionary = {}

## 多源 Dijkstra：免疫方活细胞到全盘每格的**最小迁移能量成本**（十分位）。
## 返回 { Vector2i: cost }；免疫全灭返回 {}（调用方按「够不着」处理）。
static func immune_reach_field(g: CWGame) -> Dictionary:
	var key: String = "%d|%d|" % [g.round_no, g.immune_level]
	for c in g.living_cells(CWData.Faction.IMMUNE):
		key += str(c["pos"]) + ";"
	if key == _ck:
		return _cf
	var sources: Array = g.living_cells(CWData.Faction.IMMUNE)
	if sources.is_empty():
		return {}
	var lv: int = g.immune_level
	var healthy: int = int(g.tune.immune_move_healthy[lv])
	var cancerous: int = int(g.tune.immune_move_cancerous[lv])
	## Dial 桶队列：边权 ≥2、单格上限 ~14 → 成本有界（≤ 格数×14），按成本分桶递增处理，
	## 免掉线性取最小的 O(F²)（实测它就是 14s→24s 的差额）。
	var dist: Dictionary = {}
	var buckets: Dictionary = { 0: [] }
	var maxc := 0
	for c in sources:
		var p0: Vector2i = c["pos"]
		if int(dist.get(p0, 99999)) > 0:
			dist[p0] = 0
			buckets[0].append(p0)
	var cost := 0
	while cost <= maxc:
		if buckets.has(cost):
			for p in buckets[cost]:
				if cost > int(dist.get(p, 99999)):
					continue   ## 过期条目（更优路径已处理）
				for n in CWData.neighbors(p):
					if not g.is_on_board(n):
						continue
					var base: int = cancerous if g.is_cancerous(n) else healthy
					var nd: int = cost + base
					if nd < int(dist.get(n, 99999)):
						dist[n] = nd
						if not buckets.has(nd):
							buckets[nd] = []
						buckets[nd].append(n)
						if nd > maxc:
							maxc = nd
		cost += 1
	_ck = key
	_cf = dist
	return dist
