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
extends CWBridge

## 语义键的 GD 侧唯一定义处上提到了 `scripts/kernel/cw_semkey.gd`（口径二 · 批 0 步 7，2026-09-18）：这里只做委托，**不许出现第二份**。
const KEY_FIELDS := CWSemKey.KEY_FIELDS

var lcg := 12345
var log: Array = []      ## 每一问一条 {kind, pid, tag, n, pick, idx, opts}，顶层与中途的都在
var mark := 0            ## 上一次 take() 的位置


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


## 自上次 take() 以来录到的那些问答（一步里可能不止一问：中途选择都在）
func take() -> Array:
	var out: Array = log.slice(mark)
	mark = log.size()
	return out
