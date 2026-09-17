## cw_semkey.gd —— 跨内核动作**语义键**的 GD 侧唯一定义处（口径二 · 批 0 步 7，2026-09-18）
##
## 一条动作压成 `k=<kind>[|g=<tag>]|<field>=<v>|...`，两个内核各在自己的选项表里按这个字符串查回下标。
## 为什么不用下标运输：C# 的选项表是另一套顺序，拿下标对第一步就错位（对拍规格 §死结一）。
## 文法与 C# 侧 `core/CellWar.Core/SemanticKey.cs` 逐字相同，C# 那边有一条护栏读这个文件比 KEY_FIELDS。
##
## 三条硬规矩（对拍规格原文）：
##   1. **剔除 cost 与 anchor** —— 那是引擎算出来的报价与依托，不是玩家意图；留在键里，「C# 算费不同」会伪装成「动作不同」。
##   2. **cid 用席位不用 id**（GD 的 cells 下标从 0 起，C# 的 EntityId 从 1 起）。
##   3. 合并键：GD 两问 ↔ C# 一决策的三处走组键（`k=action+chemo_target|…`），由录制 / 重放两侧各自拼。
##
## 此前它住在 game/tests/xcheck_bridge.gd（测试工具），观测协议 v1 的作答口径「键为准、下标兜底」要在产品代码里用它，
## 所以上提到 scripts/kernel/；xcheck_bridge.gd 改为委托，**不许出现第三份**。
class_name CWSemKey
extends RefCounted

## 语义键用到的 data 字段，**固定顺序**（GD data 的 13 个键）。
const KEY_FIELDS := ["act", "card", "type", "to", "cid", "dir", "r",
	"pay", "get", "from", "to_cid", "stop", "skip"]


static func fmt(v: Variant) -> String:
	if v is Vector2i:
		return "%d,%d" % [v.x, v.y]
	if v is bool:
		return "1" if v else "0"
	return str(v)


## req 是 ask 的请求字典（kind / tag），data 是那一条选项的 data。
static func key(req: Dictionary, data: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append("k=" + str(req.get("kind", "")))
	var tag: String = str(req.get("tag", ""))
	if tag != "":
		parts.append("g=" + tag)
	for f in KEY_FIELDS:
		if data.has(f):
			parts.append(f + "=" + fmt(data[f]))
	return "|".join(parts)
