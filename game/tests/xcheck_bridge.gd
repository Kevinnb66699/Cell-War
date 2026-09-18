## xcheck_bridge.gd —— 对拍轨迹的决策者：**确定性脚本策略** + 逐问录制
##
## 为什么不能用启发式 / MC 桥：`heuristic_bridge.gd:334` 会读 `game.rng.state` 做平局决胜，
## 一旦决策者偷看随机数内部状态，「换个 rng 实现」就会换掉决策 —— 轨迹不再可复现。
##
## 策略：把这一问的**语义键**去重、排序，用一条与引擎无关的 LCG 挑一个。
## 按排序后的键挑（而不是按引擎给的下标挑），两边各自改了选项生成次序，轨迹也不会整串错位。
## LCG 的常数、种子、去重 —— 三样都要和 C# 侧 `KeyWalk` 逐字相同，缺一样两边就走不同的路：
##   lcg = (lcg * 1103515245 + 12345) & 0x7fffffff ；初值 = seed & 0x7fffffff ；键先去重再排序。
##
## 单独成文件是因为**测试脚本里的内部类不能 extends 全局类**（fx_recorder.gd 同因）。
##
## `policy = "chemo"`（2026-09-19，Kevin 要一条树突建源的夹具）：LCG 之上叠一层**只看语义键与盘面**的
## 脚本偏好 —— 免疫等级不到 III 就优先攻击（攒记忆）、能分化就分树突、能建源就建、选源址取离全场细胞
## 最近的一格；其余照 LCG。仍然不碰 rng，所以 C# 教师强制重放照样逐问对得上（它只认 pick，不重算策略）。
extends CWBridge

## 语义键的 GD 侧唯一定义处上提到了 `scripts/kernel/cw_semkey.gd`（口径二 · 批 0 步 7，2026-09-18）：这里只做委托，**不许出现第二份**。
const KEY_FIELDS := CWSemKey.KEY_FIELDS

var lcg := 12345
var log: Array = []      ## 每一问一条 {kind, pid, tag, n, pick, idx, opts}，顶层与中途的都在
var mark := 0            ## 上一次 take() 的位置
var policy := ""         ## "" = 纯 LCG；"chemo" = 树突建源偏好（见文件头）
var chemo_built := false ## chemo 策略：已经建过一次源
var goal_done := false   ## chemo 策略：源已消散且冷却归零（一整个周期录完），exporter 据此收尾


static func fmt(v: Variant) -> String:
	return CWSemKey.fmt(v)


## 一条动作的跨内核语义键（定义见 CWSemKey）
static func key(req: Dictionary, data: Dictionary) -> String:
	return CWSemKey.key(req, data)


func seed_policy(seed_value: int) -> void:
	lcg = seed_value & 0x7fffffff


func ask(req: Dictionary) -> int:
	var keys := PackedStringArray()
	for o in req["options"]:
		keys.append(key(req, o["data"]))
	## 去重再排序：同一个键在选项表里可能出现多次（癌方复活的多个依托被剔掉 anchor 之后就是），
	## C# 侧用 SortedDictionary 天然去重，这边不去重的话 `lcg % n` 的 n 就不一样，整串错位
	var uniq := {}
	for k in keys:
		uniq[k] = true
	var sorted := PackedStringArray(uniq.keys())
	sorted.sort()
	lcg = (lcg * 1103515245 + 12345) & 0x7fffffff
	var pick: String = sorted[lcg % sorted.size()]
	if policy == "chemo":
		var forced := _chemo_pick(req, sorted)
		if forced != "":
			pick = forced
	var idx := 0
	for i in keys.size():
		if keys[i] == pick:
			idx = i    ## 同键多条时取第一条 —— 两边都这么取，才是同一步
			break
	log.append({
		"kind": str(req.get("kind", "")), "pid": int(req.get("pid", -1)),
		"tag": str(req.get("tag", "")),
		"n": sorted.size(), "pick": pick, "idx": idx,
		"opts": Array(sorted),
	})
	return idx


## chemo 策略的偏好，从上到下第一条命中的就是答案；都不命中返回 "" 回落 LCG。
## 等级下标：0 = I、1 = II、2 = III（分化门槛 differentiate_min_level）、3 = X。
func _chemo_pick(req: Dictionary, sorted: PackedStringArray) -> String:
	if str(req.get("kind", "")) == "chemo_target":
		return _nearest_to_cells(req, sorted)
	if chemo_built and game.chemo.is_empty() and not _any_chemo_cd():
		goal_done = true
	for k in sorted:
		if k.begins_with("k=action|act=chemo"):
			chemo_built = true
			return k
	var dendritic := "k=action|act=differentiate|type=%d" % CWData.ImmuneType.DENDRITIC
	for k in sorted:
		if k.begins_with(dendritic):
			return k
	if game.immune_level < 2:
		for k in sorted:
			if k.begins_with("k=action|act=attack"):
				return k
	return ""


## 源址：离全场活细胞距离和最小的一格（并列取键小的），让后面的迁移大概率朝它走 / 离它远
func _nearest_to_cells(req: Dictionary, sorted: PackedStringArray) -> String:
	var best := ""
	var best_d := 1 << 30
	for o in req["options"]:
		var to: Variant = o["data"].get("to")
		if not (to is Vector2i):
			continue
		var d := 0
		for c in game.cells:
			if bool(c["alive"]):
				d += CWData.hex_dist(to, c["pos"])
		var k := key(req, o["data"])
		if d < best_d or (d == best_d and k < best):
			best_d = d
			best = k
	return best if best != "" else sorted[0]


func _any_chemo_cd() -> bool:
	for c in game.cells:
		if int(c.get("chemo_cd", 0)) > 0:
			return true
	return false


## 自上次 take() 以来录到的那些问答（一步里可能不止一问：中途选择都在）
func take() -> Array:
	var out: Array = log.slice(mark)
	mark = log.size()
	return out
