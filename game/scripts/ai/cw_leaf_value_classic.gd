## cw_leaf_value_classic.gd —— 经典叶子评分器：包一层 CWEval 静态估值
## 
## 第三档 MCTS 的默认评分器。行为与 `mcts_bridge.gd` 重构前完全一致：
## 调用 `CWEval.score(image, my_faction, death_cost)`，返回那个整数估值。
## 这是平衡标尺沿用至今的手，**任何一个数字都不许动**；改 AI 行为要升号重量平衡基线。
class_name CWClassicLeafValue
extends CWLeafValue

func score(image: CWGame, cfg: Dictionary) -> float:
	return float(CWEval.score(image, int(cfg["my_faction"]), bool(cfg.get("death_cost", true))))
