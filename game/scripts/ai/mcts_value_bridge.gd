## mcts_value_bridge.gd —— 第四档「AI 强化」蒙特卡洛树搜索桥：叶子估值交给神经网络
##
## 与 `CWMCTSBridge`（第三档）**同源的子类**：树本体、`_sim`、`_select_child`、
## 确定性骨架、预算口径、副线程入口……**全部继承，一行不重写**。
## 唯一的分歧点 = 叶子评分器：
##   · 第三档用经典 `CWEval`（整数、阵营视角取负）——第三档默认；
##   · 本档把 `_leaf_tag` 改成 "nn"，`_tree_search` 因此用 `CWNNLeafValue`
##     （根决策者胜率 [0,1]、不分阵营）评估每一片叶子。
## 这样「AI 强化」完全旁路在叶子层，第三档（标尺主线的近亲）一位不变。
##
## ⚠ 现状：`CWNNLeafValue` 尚未接真实 pytorch 服务，先回落 `CWEval`。
## 因此本档一旦装配，行为与第三档**逐位一致**、可回归验证；等推理链路通了，
## 只需要在 `CWNNLeafValue.score()` 里接线并记日志，树与桥都不用再动。
class_name CWMCTSValueBridge
extends CWMCTSBridge

## 本档的叶子评分器种类标签。覆写基类默认（&"classic"）为神经网络。
## 因为 `cfg["leaf"]` 只穿这根字符串进 `_tree_search`，所以这与线程化的单份代码兼容。
var _leaf_tag := &"nn"


func version_tag() -> String:
	return "%s-mcts-value" % AI_VERSION
