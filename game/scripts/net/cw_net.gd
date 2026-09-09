## cw_net.gd —— 联机协议：版本号、常量、报文编解码、视角快照（服务器与客户端共用）
##
## 拍板与全貌见 docs/联机设计_2026-09-02.md。要点：
##   · 服务器权威：规则、骰子、抽卡全在服务器的 CWGame 里跑；客户端只发「选第几项」。
##   · 报文 = 4 字节原长 + zstd(var_to_bytes(字典))。用 Godot 序列化而不是 JSON，
##     因为棋盘键是 Vector2i、演出坐标也是；解码禁对象（bytes_to_var 默认），报文里塞不进脚本。
##     压缩是因为整份快照 35~41 KB、压完约 2 KB（2026-09-02 实测，结构高度重复）。
##   · 视角快照 = snapshot() 去掉 rng、别人的手牌换成占位、别人的待决选项去掉 ——
##     客户端拿不到随机数状态与他人手牌，改客户端也算不出下一张牌。
##
## 报文一览（t = 类型；C→S 客户端发，S→C 服务器发）：
##   C→S  hello{ver, nick, room?, token?}   握手；带 room+token 即顺手重连
##        ping · list_rooms · create_room{players, timer, public, seed?} · join_room{code}
##        leave_room · reconnect{code, token} · sit{seat} · stand · ready{ready}
##        set_ai{seat, tier} · kick{seat} · start（后三个房主专用）· answer{ask_id, index}
##   S→C  welcome{client_id, ver, maintenance} · pong · lobby{rooms, maintenance}
##        room{...}（等待室全量视图，见 CWRoom.view_for）
##        state{view, logs, turn, hash, game}（视角快照 + 新增日志行 + 正在决策的席位）
##        ask{ask_id, req, left_ms}（只发给该席位）· roll · result · notice（三种演出）
##        game_over{winner, reason, kind, round} · left（离开房间的回执）· error{code, msg}
class_name CWNet
extends RefCounted

## 协议或规则一变就升号：服务器拒绝版本不符的客户端（error code=version）。
## v2（2026-09-09）：投降投票 —— 新增 surrender 上行与 surrender_vote 下行。
## v3（2026-09-09）：技能四条数值更新，其中【免疫记忆】III 级迁移耗能 0.7 → 0.8
##   动的是 `immune_move_cancerous` —— 它在 `CWTuning.RULE_FIELDS` 里、**进状态哈希**。
##   规则一变就必须升号：不升的话老客户端照样连得上，然后每一步的哈希都对不上，
##   表现为莫名其妙的不同步而不是一句「请更新」。
## v4（2026-09-09）：X 级不再有额外的迁移减免（沿用 III 级 0.8）。同一个旋钮，同样进哈希。
## v5（2026-09-09）：固化门槛 2.0 → 3.0（`solidify_threshold`，同样在 RULE_FIELDS 里）。
## v6（2026-09-09）：云端版同步第一批，四处，**都进状态哈希**：
##   · 有氧呼吸由平方式改回线性（`aerobic_level_step` 5 → 15）
##   · 【中和抗体】压制 1 → 2 世界回合（存在 cell["neutral_until"]，不是旋钮但进快照：
##     两边时长不一样时，第二个回合的技能可用性就分叉了）
##   · 「黏液侵染」迁移附加费 0.5 → 0.2（`mucus_move_surcharge`）
##   · 免疫【迁移】到癌性组织分档 1.0/1.0/0.8/0.8 → **1.0/0.8/0.7/0.7**（`immune_move_cancerous`）
##   · 免疫等级的记忆门槛**按人数分档**：四人局 6/16/30、六人局仍 10/20/30
##     （`CWData.level_min_memory`；不是旋钮，但两边表不一样就会在升级那一刻分叉）
##   · 【增生】新造的癌组织**本回合不作【侵蚀】的来源**（PRD 的「注」）——
##     不是旋钮，但两边读法不同时侵蚀会选中不同的格子，下一次哈希就对不上
##   · 癌症【S-复活】按 PRD 定稿放宽：依托只要求「没被免疫占据」，
##     **空着的固化格也开出整个 1 环**（从前只有队友踩着才开圈）。落点集合变了 = 选项下标变了，
##     旧客户端按自己那份选项作答会选到别的格子上
## 服务器对不认识的报文回 bad_message，所以**旧客户端必须更新才连得上**（Kevin 已同意）。
const NET_VERSION := 6
const DEFAULT_HOST := "124.221.78.13"
const DEFAULT_PORT := 8611
## 单条报文（压缩后）上限；超过即断开
const MAX_PACKET := 65536
## 解压后的上限（防解压炸弹）
const MAX_RAW := 4 * 1024 * 1024
## 房间码：6 位，字母表去掉 0/O/1/I
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LEN := 6
const PLAYER_CHOICES := [2, 4, 6]
## 每次决策的秒数（界面给的档位）；协议本身接受 0~TIMER_MAX 的任意整数，0 = 不限
const TIMER_CHOICES := [0, 30, 60, 90]
const TIMER_MAX := 600
const AI_TIERS := { "heur": "AI·新手", "mc": "AI·专家" }
const NICK_MAX := 12
const HEARTBEAT_MS := 5000            ## 客户端多久发一次 ping
const DEAD_MS := 20000                ## 服务器多久没收到任何报文就当掉线
const ROOM_IDLE_MS := 10 * 60 * 1000  ## 空房多久自动关
const RATE_PER_SEC := 30              ## 每连接每秒「非作答」报文上限（作答与 ping 不计）
const MAX_PER_IP := 8
const HIDDEN_CARD := "？"             ## 别人手牌的占位

## 错误码 → 给玩家看的话
const ERRORS := {
	"version": "客户端版本与服务器不符，请更新游戏",
	"bad_message": "报文格式错误",
	"maintenance": "服务器维护中，暂不能开新局",
	"no_room": "没有这个房间",
	"playing": "这个房间正在对局中",
	"not_in_room": "你不在房间里",
	"not_host": "只有房主能这么做",
	"not_waiting": "对局进行中不能这么做",
	"seat_taken": "这个席位已经有人了",
	"bad_seat": "没有这个席位",
	"seat_empty": "还有席位空着",
	"no_human": "至少要有一位真人",
	"not_ready": "还有人没准备",
	"not_seated": "你没有坐下",
	"stale": "这次询问已经过期",
	"bad_index": "选项不存在",
	"bad_token": "重连令牌无效",
	"bad_param": "参数不合法",
	"kicked": "你被房主请出了房间",
	"room_closed": "房间已关闭",
	"rate": "发送过于频繁",
	"no_vote": "没有正在进行的投降投票",
	"voted": "你已经投过票了",
	"vote_cooldown": "刚投过一次，等一个世界回合再来",
}

# ---- 投降投票（2026-09-09）----
## 一人发起，**同阵营全票通过**才认输（Kevin 定案，照王者荣耀那套）。
##
## 谁必须投票：本阵营**在线的真人**席位。
## · AI 席位一律同意 —— 否则单机式的「带 AI 队友」永远投不了降，而那正是最想要这功能的场合。
## · **主动离开**的席位不计入（他人已经走了，本局由 AI 代打）。
## · **网络断开**的席位仍要计入（Kevin 定）：他可能马上回来，不该替他做决定。
##   代价是断线期间投不出去 —— 所以断线超过 DROP_TO_LEFT_MS 自动转成「已离开」，
##   否则一个再也不回来的人能把队友永远锁在这一局里。
const SURRENDER_VOTE_MS := 30000        ## 投票时限，到点算否决
const SURRENDER_COOLDOWN_ROUNDS := 1    ## 否决后隔几个世界回合才能再发起
const DROP_TO_LEFT_MS := 150000         ## 断线满 2.5 分钟 → 视同主动离开（不再计入投票）


static func encode(msg: Dictionary) -> PackedByteArray:
	var raw := var_to_bytes(msg)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out


## 解不出来返回空字典（调用方按坏报文处理）
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 5:
		return {}
	var n := bytes.decode_u32(0)
	if n == 0 or n > MAX_RAW:
		return {}
	var raw := bytes.slice(4).decompress(n, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != n:
		return {}
	var v: Variant = bytes_to_var(raw)
	if v is Dictionary and v.has("t") and v["t"] is String:
		return v
	return {}


static func make_code(rng: RandomNumberGenerator) -> String:
	var s := ""
	for i in CODE_LEN:
		s += CODE_ALPHABET[rng.randi_range(0, CODE_ALPHABET.length() - 1)]
	return s


static func make_token(rng: RandomNumberGenerator) -> String:
	return "%08x%08x%08x" % [rng.randi(), rng.randi(), rng.randi()]


static func clean_nick(n: Variant) -> String:
	var s := str(n).strip_edges().replace("\n", " ").replace("\r", " ")
	if s.length() > NICK_MAX:
		s = s.substr(0, NICK_MAX)
	return s if s != "" else "玩家"


static func error_text(code: String) -> String:
	return ERRORS.get(code, code)


## 某个席位看到的对局：rng 去掉、他人手牌占位、他人的待决选项去掉。pid=-1 = 没坐下的人。
static func view_for(game: CWGame, pid: int) -> Dictionary:
	var v := game.snapshot()
	v["rng"] = 0
	for c in v["cells"]:
		if c["pid"] != pid:
			var hidden: Array = []
			for i in c["hand"].size():
				hidden.append(HIDDEN_CARD)
			c["hand"] = hidden
	var p: Dictionary = v["pending"]
	if not p.is_empty() and p.get("pid", -1) != pid:
		v["pending"] = { "kind": p["kind"], "pid": p["pid"], "prompt": p.get("prompt", ""), "options": [] }
	return v


## 从第 from 行起的对局日志，秘密行（别人抽到什么牌）换成公开替身
static func logs_for(game: CWGame, pid: int, from: int) -> PackedStringArray:
	var out: PackedStringArray = []
	for i in range(from, game.logs.size()):
		var who: int = game.log_secret[i] if i < game.log_secret.size() else -1
		if who < 0 or who == pid:
			out.append(game.logs[i])
		else:
			out.append(game.log_public[i])
	return out
