## levels/demo.gd —— **示例钩子**（docs/新手引导v2_实现方案.md §3.7，S8，2026-09-19）
##
## 真钩子只有两只：间章 `interlude.gd`（S10）与第七关 `c3_l7.gd`（S11 的 `encircle` /
## `immune_turn` / `repeat_until_last_t`）。这一份是**链路样板**：证明
## 「数据里的 `{"do":"hook","call":"X"}` → 导演 `_run_hook` → `ctx` 九个方法」这条线通，
## 同时给 S9～S11 一份照着写的模板、给护栏 `t_tutor_hooks` 一份正面样本。
##
## 三条纪律（护栏逐条扫，写钩子的人照抄）：
## ① **零成员变量** —— 状态只能进 `ctx.state()`（那只字典随代际一起清空）；
## ② **每个 `while` 的条件都含 `ctx.alive()`** —— 代际一换，钩子自己从循环里退出来；
## ③ 只经 `ctx` 的九个方法：`beat` / `until` / `read` / `alive` / `frame` / `rng` / `state` / `log` / `fail`。
##    钩子够不着 kernel / mirror / game / view / stage —— 要说话就 `ctx.beat({"do":"say", …})`。
##
## **不带 class_name**（方案 §1.5）：钩子是天天在改的东西，要能走热更。
extends RefCounted


## 什么都不做，只证明「数据点名 → 真的调到这一支」。S9～S11 接手前的占位
func noop(ctx) -> void:
	ctx.log("noop")


## 读一下盘面记一笔：`read` 白名单 + `state()` 当计数器的样板。
## **不存成员变量** —— 第二次进来还能接着上次数下去，靠的是 `ctx.state()`
func peek_cells(ctx) -> void:
	var n := 0
	for c in ctx.read("cells"):
		if bool((c as Dictionary)["alive"]):
			n += 1
	var st: Dictionary = ctx.state()
	st["peek_n"] = int(st.get("peek_n", 0)) + 1
	ctx.log("盘上活着 %d 只（第 %d 次看）" % [n, int(st["peek_n"])])


## 每帧记一笔，直到代际作废。**护栏的正面样本**：`while` 条件含 `ctx.alive()`，
## 所以重置 / 跳关 / 换局之后这只协程自己就不再出账了（真正的收口在 `ctx.frame()` 的代际闸）
func tick_forever(ctx) -> void:
	while ctx.alive():
		ctx.log("tick")
		await ctx.frame()
