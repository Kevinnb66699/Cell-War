## cw_settings.gd —— 玩家偏好：AI 行动节奏 + 掷骰动画开关 + 传送演出开关 + 联机的昵称与服务器地址
##
## 只放**现在真的有东西可设**的几项。音量等 BGM/音效进了工程再加 ——
## 没有的东西不做空壳设置项（设置页里一排灰按钮比没有设置页更糟）。
## 静态存取，user://settings.cfg 持久化；设置页改一下就立即生效并落盘。
class_name CWSettings
extends RefCounted

const PATH := "user://settings.cfg"
## AI 每步停顿（毫秒）：快 / 标准 / 慢。标准档就是原来写死的 220。
const AI_DELAYS := [60, 220, 400]
const AI_DELAY_NAMES := ["快", "标准", "慢"]

static var ai_delay_ms := 220
static var dice_anim := true      ## false = 掷骰不演动画，结算说明照常弹
static var teleport_anim := true  ## false = 传送不演溶解、细胞直接瞬移（AI 互搏观战局紊乱频繁时的降噪开关，动画规格_传送 §三.4）
## 联机面板上一次填的昵称与服务器地址（host:port）。默认地址是团队那台服务器，内网自测时改掉
static var nick := ""
## 默认连哪台服务器。**网页版和桌面版不是同一个地址**（2026-09-14）：
## 网页版跑在 https:// 下，而 **HTTPS 页面连 ws:// 会被浏览器当混合内容直接拦掉** ——
## 所以它只能走 wss://，由 nginx 反代到本机的 8611（见 `docs/网页导出.md`）。
## 桌面版继续直连 ws://IP:8611：少一层 TLS 和反代，而且**不受证书死活影响** ——
## 这台机器上的证书历史上过期过好几次，没必要让桌面联机也跟着一起挂。
static var server := default_server()
static var lan_port := CWNet.DEFAULT_PORT   ## 局域网开服上一次用的端口（Kevin 2026-09-12）
## 新手教程换皮（方案 §5.4 末「换皮开关」，S3 2026-09-19）。**不上设置页**：
## 它不是玩家偏好，是做教程时现场 A/B 切的旋钮 —— 设置页里一排没人懂的选项比没有更糟。
## `bubble` = 皮 A 贴身气泡（缺省，Kevin 09-19 拍板「整体走 A」）；
## `plain` = 占位皮 P（零美术兜底）；`tally` = 计数皮 T（只记账不画，无头验收用）
const TUTOR_SKINS := ["bubble", "plain", "tally"]
static var tutor_skin := "bubble"
static var _loaded := false


static func load_prefs() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return   ## 第一次运行没有文件，用默认值
	ai_delay_ms = int(cfg.get_value("play", "ai_delay_ms", ai_delay_ms))
	dice_anim = bool(cfg.get_value("play", "dice_anim", dice_anim))
	teleport_anim = bool(cfg.get_value("play", "teleport_anim", teleport_anim))
	tutor_skin = str(cfg.get_value("play", "tutor_skin", tutor_skin))
	if not (tutor_skin in TUTOR_SKINS):
		tutor_skin = "bubble"   ## 存盘里是个不认识的皮名 ⇒ 退回缺省，别让教程开不出来
	nick = str(cfg.get_value("online", "nick", nick))
	server = str(cfg.get_value("online", "server", server))
	## **网页版上，存下来的非 wss 地址一律作废。**
	## 浏览器会把 HTTPS 页面发起的 ws:// 当混合内容直接拦掉 —— 留着它，玩家看到的是
	## 「连不上服务器」，而真正的原因在浏览器的存储里，谁也查不到。
	## 这不是防呆：网页版上线当天就撞上了 —— 先前开过页面的浏览器存的是 ws://IP:8611，
	## 新包的默认值根本轮不到生效。
	if OS.has_feature("web") and not server.begins_with("wss://"):
		server = default_server()
	lan_port = int(cfg.get_value("online", "lan_port", lan_port))


## 这个平台**默认**连哪台服务器。
##
## 网页版和桌面版不是同一个地址：网页版跑在 https:// 下，而 **HTTPS 页面连 ws:// 会被
## 浏览器当混合内容直接拦掉** —— 所以它只能走 wss://，由 nginx 反代到本机的 8611
## （见 `docs/网页导出.md`）。桌面版继续直连 ws://IP:8611：少一层 TLS 和反代，
## 而且**不受证书死活影响** —— 这台机器上的证书历史上过期过好几次，
## 没必要让桌面联机也跟着一起挂。
##
## 抽成函数是因为**有三个地方要用同一个答案**：这里的默认值、读盘时的作废判定、
## 面板上那个「默认」按钮。各写一份必漂。
static func default_server() -> String:
	if OS.has_feature("web"):
		return CWNet.WEB_HOST
	return "%s:%d" % [CWNet.DEFAULT_HOST, CWNet.DEFAULT_PORT]


static func save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("play", "ai_delay_ms", ai_delay_ms)
	cfg.set_value("play", "dice_anim", dice_anim)
	cfg.set_value("play", "teleport_anim", teleport_anim)
	cfg.set_value("play", "tutor_skin", tutor_skin)
	cfg.set_value("online", "nick", nick)
	cfg.set_value("online", "server", server)
	cfg.set_value("online", "lan_port", lan_port)
	cfg.save(PATH)
