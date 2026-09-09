extends SceneTree
## 热更 manifest 的签名密钥工具。开发工具，不是测试（放 tests/ 是因为导出预设排除这个目录）。
##
## ## 为什么要签名
##
## manifest 是整套热更的**信任锚** —— 它说「装哪个包、哈希是多少」。
## 补丁包本身走明文 HTTP 没关系（哈希钉死在 manifest 里，改一个字节就装不上），
## 但 manifest 自己要是能被中间人换掉，攻击者就能指定装什么代码 = 任意代码执行。
##
## Kevin 2026-09-09 定了「不加 DNS、用签名」这条路：manifest 也放自家服务器走明文，
## 但带一份 RSA 签名；公钥烧进客户端，没有私钥就伪造不了。
## 这样传输层完全不需要可信 —— 也就不受「这台机器的证书老是过期」影响。
##
## ## 私钥**绝不进仓库**
##
## 默认写到 `~/.cellwar/patch_key.pem`。
## · 丢了 = 发不了新补丁（重新生成一对、全量发版换掉公钥即可，玩家无感）
## · 泄漏了 = 别人能给所有玩家发代码。**当密码看待。**
##
## 用法：
##   生成一对（只做一次）：godot --headless --path game --script res://tests/patch_key.gd -- gen
##   给文件签名：          godot --headless --path game --script res://tests/patch_key.gd -- sign <文件> <签名输出>


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		printerr("用法：gen | sign <文件> <签名输出> [私钥路径]")
		quit(2)
		return
	match a[0]:
		"gen":
			_gen(a[1] if a.size() > 1 else default_key_path())
		"sign":
			if a.size() < 3:
				printerr("用法：sign <文件> <签名输出> [私钥路径]")
				quit(2)
				return
			_sign(a[1], a[2], a[3] if a.size() > 3 else default_key_path())
		_:
			printerr("不认识的命令：", a[0])
			quit(2)


static func default_key_path() -> String:
	var home := OS.get_environment("USERPROFILE")
	if home == "":
		home = OS.get_environment("HOME")
	return home.replace("\\", "/") + "/.cellwar/patch_key.pem"


func _gen(path: String) -> void:
	if FileAccess.file_exists(path):
		printerr("✘ %s 已经存在。**不覆盖** —— 换钥匙会让所有已发出去的客户端认不出新签名，" % path)
		printerr("  必须连着一次全量发版把新公钥带出去。真要换就先手动改名备份。")
		quit(3)
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var key := Crypto.new().generate_rsa(2048)
	var err := key.save(path, false)        ## false = 连私钥一起存
	if err != OK:
		printerr("✘ 写私钥失败：", error_string(err))
		quit(4)
		return
	print("✔ 私钥写到 %s —— **不要进仓库、不要发给别人**" % path)
	print("---PUBLIC-KEY-BEGIN---")
	print(key.save_to_string(true))         ## true = 只要公钥
	print("---PUBLIC-KEY-END---")
	quit(0)


func _sign(src: String, out: String, key_path: String) -> void:
	var key := CryptoKey.new()
	if key.load(key_path, false) != OK:
		printerr("✘ 读不到私钥 %s（没生成过就先跑一次 gen）" % key_path)
		quit(3)
		return
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty():
		printerr("✘ 读不到 ", src)
		quit(3)
		return
	## 签的是**文件内容的 SHA-256**。算法必须和客户端那边逐字一致
	## （`PatchState.verify_manifest`），差一点就全都验不过。
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	var sig := Crypto.new().sign(HashingContext.HASH_SHA256, ctx.finish(), key)
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		printerr("✘ 写不了 ", out)
		quit(4)
		return
	f.store_string(Marshalls.raw_to_base64(sig))   ## base64：签名要跟着 HTTP 走，别留二进制
	f.close()
	print("✔ 签名写到 %s（%d 字节 → base64）" % [out, sig.size()])
	quit(0)
