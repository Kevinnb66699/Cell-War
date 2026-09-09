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
## 挂上补丁之后活过这么久，才认为它是好的。够长到能盖住主场景构建与首帧渲染。
const PROVE_SEC := 6.0


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
	_save(c)


static func record(build: int, sha256: String) -> void:
	var c := _cfg()
	c.set_value("patch", "build", build)
	c.set_value("patch", "sha256", sha256)
	c.set_value("patch", "pending", false)
	_save(c)


## 把坏补丁挪开（不删：留着好查为什么坏的），并清空记录
static func quarantine() -> void:
	if FileAccess.file_exists(PCK):
		DirAccess.rename_absolute(PCK, DIR + "/bad.pck")
	var c := ConfigFile.new()
	c.set_value("patch", "build", 0)
	c.set_value("patch", "sha256", "")
	c.set_value("patch", "pending", false)
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
