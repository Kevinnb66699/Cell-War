## cw_tissue.gd —— 组织状态转换的唯一入口
##
## 组织格仍是 CWSetup.make_tile() 建出的字典；这里仅维护 tissue 与其
## 生命周期字段的组合不变量。特殊组织库存（store/cards/prod）和黏液标记
## 属于独立机制，转换时必须保留。
class_name CWTissue
extends RefCounted


static func to_healthy(tile: Dictionary) -> void:
	tile["tissue"] = CWData.Tissue.HEALTHY
	tile["solid"] = 0
	tile["newborn"] = false
	tile["necrosis"] = 0


## 坏死是叠在健康组织上的倒计时，不是第四种 tissue；重复施加取较长时长。
static func to_necrotic(tile: Dictionary, rounds: int) -> void:
	var before: int = tile["necrosis"]
	to_healthy(tile)
	tile["necrosis"] = maxi(before, rounds)


## `newborn` 必须由调用方明确选择，避免旧组织被误当成当回合新生。
static func to_cancer(tile: Dictionary, newborn: bool) -> void:
	tile["tissue"] = CWData.Tissue.CANCER
	tile["solid"] = 0
	tile["newborn"] = newborn
	tile["necrosis"] = 0


static func to_solid(tile: Dictionary) -> void:
	tile["tissue"] = CWData.Tissue.SOLID
	tile["newborn"] = false
	tile["necrosis"] = 0


## 固化癌组织降级为已有癌组织，不应重新获得「新生」保护。
static func crack_to_cancer(tile: Dictionary) -> void:
	to_cancer(tile, false)


static func is_valid(tile: Dictionary) -> bool:
	match tile["tissue"]:
		CWData.Tissue.HEALTHY:
			return tile["solid"] == 0 and not tile["newborn"]
		CWData.Tissue.CANCER, CWData.Tissue.SOLID:
			return tile["necrosis"] == 0
	return false
