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
	tile["ossify_at"] = 0   ## 净化即取消【骨样硬化】的标记


## 坏死是叠在健康组织上的倒计时，不是第四种 tissue；重复施加取较长时长。
##
## **代谢核心 / 骨髓坏死了要清库存**（Kevin 2026-09-13，issue #31：「能量核心和骨髓「坏死」时
## 清除所有储备产出，不再积累进度」）。这是本文件头「转换时必须保留库存」的**唯一例外** ——
## 坏死不是组织转换，是组织死了：存着的能量 / 卡和攒到一半的进度一起没。
## 「不再积累」那半句在 CWWorld._tissue_production（坏死期间整格跳过）。
static func to_necrotic(tile: Dictionary, rounds: int) -> void:
	var before: int = tile["necrosis"]
	to_healthy(tile)
	tile["necrosis"] = maxi(before, rounds)
	tile["store"] = 0
	tile["cards"] = 0
	tile["prod"] = 0


## `newborn` 必须由调用方明确选择，避免旧组织被误当成当回合新生。
static func to_cancer(tile: Dictionary, newborn: bool) -> void:
	tile["tissue"] = CWData.Tissue.CANCER
	tile["solid"] = 0
	tile["newborn"] = newborn
	tile["necrosis"] = 0
	tile["ossify_at"] = 0


static func to_solid(tile: Dictionary) -> void:
	tile["tissue"] = CWData.Tissue.SOLID
	tile["newborn"] = false
	tile["necrosis"] = 0
	tile["ossify_at"] = 0   ## 已经是固化了，标记完成使命


## 固化癌组织降级为已有癌组织，不应重新获得「新生」保护。
static func crack_to_cancer(tile: Dictionary) -> void:
	to_cancer(tile, false)


## 这一格能不能固化：**血管永远不能**（Kevin 2026-09-06，PRD「特殊组织」节同步）。
## 三条固化入口（【E-固化】计数 / 卡【基质硬化】/ 骨肉瘤【骨样硬化】的标记）、【原发灶】旋钮
## 与 AI 的蹲点判断都认它；**选目标那一侧也要拦** —— 只在结算处拦就是「用了没反应」
## （团队 2026-09-05 报过的形状，见 CWGame.solid_frozen 的注释）。
static func solidifiable(tile: Dictionary) -> bool:
	return tile["special"] != CWData.Special.VESSEL


static func is_valid(tile: Dictionary) -> bool:
	match tile["tissue"]:
		CWData.Tissue.HEALTHY:
			return tile["solid"] == 0 and not tile["newborn"]
		CWData.Tissue.CANCER, CWData.Tissue.SOLID:
			return tile["necrosis"] == 0
	return false
