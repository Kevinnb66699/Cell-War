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
## ⚠ **写成常量，不要放进 .txt**：2026-09-09 第一版放在 `res://base_build.txt`，
## 导出预设是 `export_filter="all_resources"`，而**没有导入器的散文件不算 resource**，
## 于是那个 txt 根本没进包 —— 线上客户端读出来是 0、每次都判「基线太老」，
## 补丁一个也收不到。脚本一定进包，所以改成常量。
##
## 补丁能覆盖本文件，但**读取发生在挂载之前**（boot.gd 的顺序），
## 所以拿到的永远是基线包里的值，补丁没法自己给自己开绿灯。
##
## **全量发版时往上改**，用**发版时刻** `YYYYMMDDHHMM`（`date +%Y%m%d%H%M`）。
## 别用当天日期 —— 2026-09-09 一天发了九个包，九个包的基线号全是 20260909，
## 于是 min_base 谁也拦不住：给第九版打的补丁会照样装进第七版的客户端。
## 这条纪律现在由 `tools/publish_release.sh` 的第 ⑤ 项闸住，不再靠人记得。
## 补丁不必动它（也改不动 —— 读取发生在挂载之前）。
const BASE_BUILD := 202609110943
## manifest 的验签公钥（Kevin 2026-09-09 定：manifest 也放自家服务器，靠签名而不是 TLS）。
##
## **为什么不靠 HTTPS**：那台机器上的证书老是过期（查的时候四个站死了两个、剩一个 10 天后到期），
## 热更不该因为谁忘了续证就静默失效。签名把信任从「传输层」挪到了「这把钥匙」——
## 传输随便中间人怎么看、怎么改，没有私钥就伪造不出一份能过验的 manifest。
##
## 私钥在 `~/.cellwar/patch_key.pem`（**不进仓库**），签名由 `tests/patch_key.gd` 做。
## 换钥匙必须连着一次**全量发版**把新公钥带出去 —— 老客户端只认烧在自己包里的这一把。
const PUBLIC_KEY_PEM := """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4DYTY+jOLOOrhyONI+6A
PsFov7glPtsJo91vElY5Utg44jBSF1duP3D+u1HMUA0QvvsG36OGqYmlFrCnQEMz
yrAvBSpZ5r3VoQ7X6cROeBf81ikFOkwNLaPiNk33Lu2jh85rvfcyiCtEKr2hG6pO
jHPpT/FTSt54JpQYjjrZpzSaal+tnFwPu8uPnkld3zxqz37QepwPf2Ddqc1UDQzZ
9aonfkFEvaQq+50xnaTX76+r8MCgQB3OM0qitaa+RkhN+jjhfX7A+R+tVw8Ou/oH
QQ2vtrwibhsywwqj+JM1YD14sH85aYVAwGhF2cn7AxsqJ0DW8X/zF4EHaI60eXF7
MwIDAQAB
-----END PUBLIC KEY-----"""


## 这份 manifest 是不是我们自己签的。**验不过一律当没看见** ——
## 宁可收不到更新，也不能装一份来路不明的代码。
static func verify_manifest(body: PackedByteArray, sig_b64: String) -> bool:
	if body.is_empty() or sig_b64.strip_edges() == "":
		return false
	var key := CryptoKey.new()
	if key.load_from_string(PUBLIC_KEY_PEM, true) != OK:
		return false
	var sig := Marshalls.base64_to_raw(sig_b64.strip_edges())
	if sig.is_empty():
		return false
	## 与 tests/patch_key.gd 的签名口径必须逐字一致：签的是**文件内容的 SHA-256**
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	return Crypto.new().verify(HashingContext.HASH_SHA256, ctx.finish(), sig, key)


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
	return BASE_BUILD


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


## 顺手记下**这份补丁是给哪个基线打的**（就是当时的 BASE_BUILD）：换完整包之后 boot.gd 拿它判「还能不能挂」。
static func record(build: int, sha256: String) -> void:
	var c := _cfg()
	c.set_value("patch", "build", build)
	c.set_value("patch", "sha256", sha256)
	c.set_value("patch", "base", BASE_BUILD)
	c.set_value("patch", "pending", false)
	_save(c)


## 已装补丁是给哪个基线打的；0 = 没记（2026-09-11 之前的状态文件），boot.gd 一律当「不是这一版的」处理
static func installed_base() -> int:
	return int(_cfg().get_value("patch", "base", 0))


## 弃掉已装的补丁（换完整包之后旧补丁不能再挂，见 boot.gd 的 stale_patch）。
## 和 quarantine() 不同：这不是「补丁坏了」，不计失败、不拉黑 —— 同一个补丁号将来给新基线重打时照常能装。
## 文件挪开而不删，和 quarantine 同一条纪律：留着好查。
static func discard() -> void:
	if FileAccess.file_exists(PCK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + "/stale.pck"))
		DirAccess.rename_absolute(PCK, DIR + "/stale.pck")
	var c := _cfg()
	c.set_value("patch", "build", 0)
	c.set_value("patch", "sha256", "")
	c.set_value("patch", "base", 0)
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
