extends RefCounted
## 补丁的落盘状态：装了哪一版、上次启动有没有活下来。
##
## **故意不给 class_name**，也故意不引用任何游戏里的东西 —— 启动器 `boot.gd`
## 在挂载补丁包**之前**就要用它，而被引用到的脚本会在那一刻被解析、进缓存。
## 引用了 `CWData` 之类的话，游戏本体就会先于补丁加载，补丁再也覆盖不上
## （实测：先 load 再挂包，拿到的仍是旧版）。
##
## 副作用是它**自己永远打不了补丁** —— 这是好事：坏补丁不该有机会关掉自己的回滚。
## 要改这个文件只能全量发版。
##
## 一律 `preload("res://scripts/patch_state.gd")` 按路径引用，别指望 class_name。

const DIR := "user://patch"
const PCK := DIR + "/current.pck"
const STATE := DIR + "/state.cfg"
const INCOMING := DIR + "/incoming.pck"   ## 下载中的临时文件，校验通过才改名成 current.pck
## 这个包是哪一次**全量发版**出来的。补丁的 manifest 用 min_base 和它比，
## 太老就让玩家去下完整包而不是硬套一个用不了的补丁。
##
## ⚠ **必须在挂载补丁之前读**：它是一个普通资源，补丁完全可以覆盖它 ——
## 挂完再读就成了「补丁自己说自己能装」。boot.gd 的顺序保证了这一点。
const BASE_BUILD := "res://base_build.txt"
## 挂上补丁之后活过这么久，才认为它是好的。够长到能盖住主场景构建与首帧渲染，
## 又不至于长到「随手开一下就关」都算失败（那种误判由 STRIKES 兜底）。
const PROVE_SEC := 3.0
## 连续失败几次才把这一版永久拉黑。
##
## **一次不算数**：玩家开了游戏 3 秒内关掉，也会留下「没活到 mark_good」的旗子 ——
## 2026-09-09 用截图工具验链路时就这么误伤过一个好补丁（进程 5 秒被杀）。
## 真坏的补丁每次都起不来，两次就够认出来；好补丁被随手关一次不该判死刑。
const STRIKES := 2


static func _cfg() -> ConfigFile:
	var c := ConfigFile.new()
	c.load(STATE)   ## 没有就是空的，各 get 走默认值
	return c


static func _save(c: ConfigFile) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	c.save(STATE)


## 已装补丁的版本号；0 = 没装
static func installed_build() -> int:
	return int(_cfg().get_value("patch", "build", 0))


## 这个客户端包的基线版本号（随全量发版更新，补丁改不动 —— 见 BASE_BUILD 的注释）
static func base_build() -> int:
	if not ResourceLoader.exists(BASE_BUILD) and not FileAccess.file_exists(BASE_BUILD):
		return 0
	var f := FileAccess.open(BASE_BUILD, FileAccess.READ)
	if f == null:
		return 0
	var v := int(f.get_as_text().strip_edges())
	f.close()
	return v


## 装崩过、已经被永久拉黑的那个补丁版本号。
##
## **没有这条会死循环**：坏补丁挂了 → 下次启动隔离掉 → 但 manifest 还在推同一版 →
## 又下下来 → 又挂。所以确认它真坏（连续 STRIKES 次）之后要把版本号记下来，之后不再碰。
static func blocked_build() -> int:
	return int(_cfg().get_value("patch", "blocked", 0))


## 已装补丁的指纹，用来在挂载前核对文件没被换过
static func installed_sha() -> String:
	return str(_cfg().get_value("patch", "sha256", ""))


## 上一次带着补丁启动，有没有活到 `mark_good()`。
## true = 没活下来 —— 那个补丁要么崩了要么把 Godot 挂死了（实测过：坏补丁会**挂死**
## 而不是报错退出，所以不能指望捕获异常，只能靠「下次启动发现旗子还在」这条外部证据）。
static func boot_failed() -> bool:
	return bool(_cfg().get_value("patch", "pending", false))


static func mark_pending() -> void:
	var c := _cfg()
	c.set_value("patch", "pending", true)
	_save(c)


## 由启动器在换场景前挂一个 SceneTreeTimer 调过来。**必须是 static** ——
## 那时启动器节点已经随场景切换被释放，绑在实例上的回调不会触发。
static func mark_good() -> void:
	var c := _cfg()
	c.set_value("patch", "pending", false)
	c.set_value("patch", "fails", 0)        ## 起来了就把之前的误伤计数清零
	c.set_value("patch", "last_bad", 0)
	_save(c)


static func record(build: int, sha256: String) -> void:
	var c := _cfg()
	c.set_value("patch", "build", build)
	c.set_value("patch", "sha256", sha256)
	c.set_value("patch", "pending", false)
	_save(c)



## 把没能正常启动的补丁挪开（不删：留着好查为什么坏的），跑原版。
##
## **攒够 STRIKES 次才永久拉黑**：只失败一次的话下次会重新下回来，给它第二次机会 ——
## 那一次很可能只是玩家随手把游戏关了。真坏的补丁两次都起不来，照样拉黑。
## 补丁只有几十 KB，多下一次的代价可以忽略；误伤一个好补丁的代价是玩家永远收不到修复。
static func quarantine() -> void:
	var bad := installed_build()
	var prev := _cfg()
	var fails := int(prev.get_value("patch", "fails", 0)) + 1 		if int(prev.get_value("patch", "last_bad", 0)) == bad else 1
	if FileAccess.file_exists(PCK):
		DirAccess.rename_absolute(PCK, DIR + "/bad.pck")
	var c := ConfigFile.new()
	c.set_value("patch", "build", 0)
	c.set_value("patch", "sha256", "")
	c.set_value("patch", "pending", false)
	c.set_value("patch", "last_bad", bad)
	c.set_value("patch", "fails", fails)
	if bad > 0 and fails >= STRIKES:
		c.set_value("patch", "blocked", bad)   ## 见 blocked_build()：不记就会无限重下同一个坏包
	_save(c)


## 整个文件的 SHA-256。补丁是**可执行代码**，挂载前必须核对指纹。
static func sha256_of(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var chunk := f.get_buffer(1 << 20)
		if chunk.size() > 0:
			ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()
