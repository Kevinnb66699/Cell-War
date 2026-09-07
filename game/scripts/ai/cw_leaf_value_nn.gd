## cw_leaf_value_nn.gd —— 神经网络叶子评分器：估「根决策者胜率」∈ [0,1]，不分阵营
##
## 第四档 `CWMCTSValueBridge` 用的评分器。输出语义与经典（整数、阵营视角取负）**刻意不同**：
##   · 经典 = `CWEval`，从一开始就是「癌方优势 → 免疫取负」的零和整数；
##   · 本类 = 一根决策者（`image.current_pid` 那位）的胜率，0~1 **∈ [0,1]**、
##     **没有阵营头、不分阵营**——视角全部落进输入特征（喂「当前决策者是谁/哪边」），
##     因此同一个网络、同一套权重，各路玩家复用，只靠身份特征区分「为谁估胜率」。
## 这就把 MCTS 树发给我们的语义对齐：整棵树从头到尾只用一个视角，backprop 不翻号。
##
## ⚠ 现状是**占位**：真实推理走「本地常驻 pytorch 服务 + state_hash 缓存」是下一步、
## 尚未接线。在网关通之前 `score()` 直接回落 `CWClassicLeafValue`（CWEval），
## 保证第四档一旦装配、行为与第三档一致、可回归验证。推理接上后只改这里，
## 树本体一行不动。
##
## ⚠ 线程契约：本对象会被放进 cfg 传进副线程，必须无状态。`_client` 一旦接入
## 必须是线程安全的（批处理 + 缓存，不能在 worker 上阻塞出网）。
class_name CWNNLeafValue
extends CWLeafValue

## 占位：尚未接真实网络，先回落经典估值，保证行为一致、可回归。
var _fallback := CWClassicLeafValue.new()

func score(image: CWGame, cfg: Dictionary) -> float:
	## TODO(nn)：在此处加 state_hash 缓存命中；未命中再走推理客户端。
	return _fallback.score(image, cfg)
