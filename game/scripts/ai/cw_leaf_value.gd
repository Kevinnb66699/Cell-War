## cw_leaf_value.gd —— 蒙特卡洛树搜索的「叶子评分器」抽象层
## 
## 树本体（`mcts_bridge._tree_search`）只认这一个接口：给一张叶子局面打一个标量，
## 不关心底下的口径是哪一种。这样第三档（真 MCTS）与将来第四档（AI-powered MCTS）
## **共用同一棵树的代码、只在叶子评分器上换装**，不需要复制整份树。
##
## 两个实现，口径各异：
##   · `CWClassicLeafValue` —— CWEval 静态估值（整数、带阵营视角、零和取负），
##     是第三档的默认，也是平衡标尺沿用至今的那只手；
##   · `CWNNLeafValue`      —— 神经网络胜率（[0,1]、根决策者视角、不分阵营），
##     由第四档 `CWMCTSValueBridge` 使用；未接真实网络前先回落经典，保证行为一致。
##
## ⚠ 线程契约：返回的评分器会被塞进 cfg 传进副线程（`_tree_search` 在 worker 上调用
## `leaf.score`），所以评分器必须是**无状态的**（纯函数式），不能带跨迭代可变成员。
class_name CWLeafValue
extends RefCounted

## 给 `image` 这张叶子局面打一个分，越大越好。口径由子类声明。
func score(_image: CWGame, _cfg: Dictionary) -> float:
	return 0.0
