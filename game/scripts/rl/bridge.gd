extends CWBridge
## 无头 RL 决策桥：所有顶层和中途询问都在这里暂停，答案先经环境校验再交还引擎。
## 不新增 class_name，避免把仅训练使用的桥加入客户端全局类表。

signal answered(index: int)
var environment: Node

func ask(req: Dictionary) -> int:
	environment.offer(req)
	return await answered
