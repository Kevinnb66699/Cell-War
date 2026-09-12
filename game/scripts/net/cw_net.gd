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
##        chat{text, scope}                 房内聊天。scope = "all" 全体 / "team" 己方（2026-09-09）
##        list_replays · get_replay{id}     服务器留着的最近几局回放（2026-09-09）
##   S→C  welcome{client_id, ver, maintenance} · pong · lobby{rooms, maintenance}
##        room{...}（等待室全量视图，见 CWRoom.view_for）
##        state{view, logs, turn, hash, game}（视角快照 + 新增日志行 + 正在决策的席位）
##        ask{ask_id, req, left_ms}（只发给该席位）· roll · result · notice（三种演出）
##        chat{nick, seat, faction, scope, text}
##                                          房内聊天：seat < 0 = 观众，faction < 0 = 没阵营
##        replays{list}                     回放目录（不含正文，只有一行摘要）
##        replay{id, data}                  一份回放的正文（CWReplay 的那个字典）
##        game_over{winner, reason, kind, round, replay} · left（离开房间的回执）· error{code, msg}
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
## v7（2026-09-09）：**房内聊天** + **从服务器下载回放**。这一号必须升，理由和前面几条不同 ——
##   这两样都是 **C→S 方向**的新报文（`chat` / `list_replays` / `get_replay`），
##   而服务器对不认识的上行报文回 `bad_message`：新客户端连老服务器会「发一句话就被断开」，
##   而不是一句「请更新」。升号让它在握手那一刻就说清楚。
##   （对照：`beam` / `live` / `game_over.replay` 都是 S→C 方向，老客户端 `match` 认不出
##   就静静落空、行为照旧，那几条都没升号。）
## v8（2026-09-10）：**动了卡池与卡面数值**（Kevin 一批）——
##   · 【趋化募集】免疫 I/II 池权重 4/3 → 2/2
##   · 【克隆增殖】由**事件改为即时技能**、转化格数 1/2/3 → 2/3/4
##   · 【上皮—间质转化】次数 1/2/3 → 2/3/4
##   · **新增【肿瘤增援】**（癌症池 3/3/3，把自己传送到队友身边）
##   报文一个字没改，升号纯粹是因为**规则不一样的两边不能同桌** ——
##   抽牌的加权轮盘吃的就是这张表、卡的类别决定它进不进手牌，
##   服务器和客户端各按各的表走，同一份状态推出来的下一步就不同，状态哈希当场分叉。
##   这条纪律和「碰了规则的热更必须同时升号 + 重部署服务器」是同一条
##   （见 `tools/build_patch.sh` 文件头）：这一版正是那种补丁。
## v9（2026-09-10 晚，issue #10）：又是**规则变了**，报文一个字没改。
##   · 【上皮—间质转化】的次数 2/3/4 → 1/2/3（当天早上刚从 1/2/3 抬上去，晚上改回来）
##   · 【细胞毒素】新增「每世界回合同一格子上仅能发动一次」，并为此**给每格加了
##     `toxin_round` 字段** —— 它进快照、也就进状态哈希，两边表不一样当场分叉
##   两边规则不一样就不能同桌，理由同 v8。
## v10（2026-09-10 晚，issue #13 + #14）：又是一批**规则**，报文仍然一个字没改。
##   · 【效应应答】每次 15 → **20** 效应记忆
##   · **X 级门槛**大幅抬高：四人 30 → 50、六人 30 → 60（III 级区间跟着变长）
##   · 【S-有氧呼吸】由线性式改成**按等级查表** 2 / 3 / 4.5 / 5（这四个数不等差）
##   · 【代谢耦联】的方向与数额**只有一种时也要问**（issue #14）——
##     它改的不是数值而是**作答串的长度**：同一局比从前多几个下标。
##     这一条同时逼着升 `CWReplay.VERSION`（旧回放按新代码放会整串错位）。
##   前三条两边表不一样就当场分叉；第四条两边问的次数不一样，下标直接对不上。
## v11（2026-09-10 深夜）**上过线又撤了**：对齐云端新版 PRD 的那批规则随 client-2026-09-10-7
##   发出去，2026-09-11 Kevin 拍板整批回滚（e7a7f3a / 626ea73 / 307d6e0 三个提交已 revert），
##   规则退回与 v10 逐字相同，号也退回 10 —— 拿 -6 的客户端照常能进。
##   **11 这个号已经烧掉，以后不能再用**：-7 客户端自认 v11，再发一版叫 11 的服务器
##   它就连得上、然后按不同的规则算哈希，当场分叉。下一次升号直接 12。
## v12（2026-09-11）：回滚之后按 issue #21 的 PRD(2)（+ #22）**重新对齐云端 PRD**，报文没动。
##   先把 v11 那三批原样捡回（cherry-pick e7a7f3a / 626ea73 / 307d6e0）：
##   · 攻击判定「失败」改称**「无效」**（只是文案，但 VERDICT_NAMES 进日志，两边要一致）
##   · 【克隆增殖】格数 2/3/4 → **1/2/3**；【糖酵解爆发】权重 3/4/5 → **3/4/6**
##   · 【裂解】目标由「相邻」放宽到**1 环内**（含脚下）—— 合法选项集合变了 = 下标会对不上
##   · 【BCL-2抗凋亡】改成**即时卡挂的一次性护盾**，且由「事后救回」改成
##     **免疫此次能量损失**：`actual` 归零，于是攻击方**不再拿抗原记忆**
##   · **世界事件默认关**（云端标了「暂时停止维护」）—— `world_events_on` 进 RULE_FIELDS
##   · 【骨样硬化】E-硬化新增「最后若不被免疫细胞占据」才转固化
##   不叫 11 的理由见上一段：那个号被 -7 客户端占着。
##   再加这一版新的规则（PRD(2) 与备份 PRD 逐条对出来的，同样全进哈希）：
##   · **环境恶化**：第 6 / 11 世界回合起肿瘤 II / III 期 —— 压迫 ×1.5 / ×2、增生 3.5%+1% / 4%+1%、
##     侵蚀 III 期 (3,5)、固化门槛 III 期 2.0、新增【根深蒂固】（固化格给相邻癌组织 +1.0，II 期 1 格 / III 期 3 格）
##   · 【E-增生】公式换形：相邻数 × (基数 + 每固化 × 相邻各块固化数之和)，I 期每固化 0.5%
##   · 【伪足穿透】基础费 0.5 − 0.1 × (相邻癌性组织数 − 3)（issue #22）
##   · 增生两档 / 侵蚀格数 / 固化门槛四个旋钮改成按分期的三档数组 —— 它们在 RULE_FIELDS 里，
##     快照形状变了：旧客户端还原快照时会把数组当标量用，第一步就分叉
## v13（2026-09-11）：免疫等级的记忆门槛改表（Kevin 按玩法 PRD）：四人 10/20/50、六人 10/30/70
##   （`CWData.level_min_memory`；不是旋钮、不进快照，但两边表不一样就会在升级那一刻分叉）。
## v14（2026-09-12）：PRD 覆盖版 + issue #27 的规则改动 —— 无氧每细胞兜底 2.0、六人指数 0.35、
##   II 期固化门槛 2.0、III 级迁移减免 0.7 删、【标记】第二次结算到期、巨噬净化回 0.2 / 吸血取整到十分位。
##   旋钮默认值（anaerobic_floor / anaerobic_block_exp）在 RULE_FIELDS 里，快照形状不变、值变了。
const NET_VERSION := 14

## 一条聊天最多多少字。定这个数不是怕刷屏（那有 RATE_PER_SEC 管），
## 是**排版**：聊天行和大厅房间行共用同一条定宽，超了就是省略号，
## 看不全的字发出去也没意义。
const CHAT_MAX := 60
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
	## 2026-09-09 起对局中也能进（进去是观众），所以 "playing" 只剩「观众满了」这一种拒绝
	"playing": "这个房间正在对局中",
	"watch_full": "这局的观众满了，等下一局吧",
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
	"empty_chat": "说点什么再发",
	"bad_scope": "只能发给全体或己方",
	"no_replay": "没有这份回放（服务器只留最近几局）",
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
