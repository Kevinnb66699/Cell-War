## cw_settings.gd —— 玩家偏好：AI 行动节奏 + 掷骰动画开关
##
## 只放**现在真的有东西可设**的两项。音量等 BGM/音效进了工程再加 ——
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


static func save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("play", "ai_delay_ms", ai_delay_ms)
	cfg.set_value("play", "dice_anim", dice_anim)
	cfg.save(PATH)
