<!-- 本文由一次多视角工作流产出：5 套方案 → 逐套对抗核查（5 条承重论点被推翻 4 条）→ 综合。
     文中的实测数字来自 agent 在本机做的真机实验与对 61 个已发补丁包的解析。
     Kevin 的 AI 另行独立抽查了 §6.3 的三条规则偏离（无氧指数 0.35/0.3、2 人局系数、人数系数 k），
     三条全部属实。 -->

# 路线 A 本地 C# 内核的热更新方案

> 2026-09-15 ｜ 依据：Cell-War 工作树 `718f676`、cellwar-next 当前 HEAD、本机 Godot 4.5-stable 实机实验、dist/patch 下 61 个已发补丁包的目录表全解
> 本文回答的问题：路线 A 里那个跑在玩家机器上的 C# 内核（sidecar），自己怎么热更新。

---

## 一、结论

**让 `CellWar.Core.dll` 搭客户端 .pck 补丁的车：编译产物压成 `res://sidecar/core.dll.zst` 用 `PCKPacker.add_file` 塞进现有补丁包，和 GDScript 一起走同一个 `build`、同一份 RSA 签名、同一次 SHA-256 校验、同一次原子改名、同一次 quarantine。`latest.json` 的 schema 一个字段都不加，`decide()` 一行不改。宿主进程（ALC 加载器 + loopback + 授权）和 .NET 运行时只随全量发版走，永不热更。**

选它的理由是排除法，不是偏好。五套方案里，只有这一套的承重论点在对抗核查中**站住了**，而且是靠本机真机实验站住的（见 §7）。其余四套各自的支点都被盘上事实推翻：

| 方案 | 支点 | 结果 |
|---|---|---|
| 一份 manifest、两个载荷（kernel 子对象，boot.gd 不动） | 共用 build ⇒ 原子生效/原子回滚 | ❌ 两条管道两次事务，不原子；且 pck 无降级路径，内核 quarantine 后 `NEED_KERNEL` 永久钉在坏 build 上，玩家单机**打不开且无法自愈** |
| DLL 单独下载到 `<install>/kernel/` | 坏补丁自动回落到安装目录那份 | ❌ Windows 是 `embed_pck=true` 的单文件 exe（99,664,776 B），**今天根本没有安装目录**这个落脚点 |
| 规则表外置成数据、只推数据 | 坏数据补丁走 quarantine 原路、零新机制 | ❌ `mark_good` 触发点要么被 3 秒定时器抢先（新证据成死代码），要么在安卓/网页/只看知识之书的会话上大面积假阳性 → 好补丁五次启动后被永久拉黑 |
| 内核不热更、规则当天只走服务器 | 不热更是零成本 | ❌ **61 个已发补丁里 45 个（74%）含 `game/scripts/core/` 规则脚本**。这道闸会关掉现役产品跑得最勤的通道，把 ~0.4 MB 的自家服务器补丁换成 ~100 MB 的 GitHub 重装 |

同时必须直说三件不在"热更机制"账上、但决定这条路线成败的事（§6、§9）：

1. **网页版和安卓永远不可能有 sidecar**，所以 GDScript core 必须永久留着能跑。于是在相当长一段时间里，每次规则改动要落两遍（GDScript 一遍、C# 一遍），这是路线 A 的真实成本大头，热更机制只是让它暴露得更快。
2. **今天连编都编不出来**：本机 `dotnet --list-sdks` 为空，Core 是 net8.0 而 Server/Console/Tests 是 net10.0，cellwar-next 零 tag、零 `global.json`、全仓无 `.dll` 产物。所有体积数字都是估算。
3. **C# 内核规则今天与 GDScript 已有四处确切偏离**（§6.3），而两边都没有对拍。在把它当权威内核发给玩家之前，这四处必须先归零。

---

## 二、分层机制：哪一类改动走哪条路

三层，按"改动频率 × 体积"分。层与层之间不允许有独立的下发通道——这是 `b74b47c`（抗体表 `[2,3]` → `[[2,3],[2,3],[3,5],[4,6]]` 必须连着新增访问器和调用点改写）那类**表变形**教出来的：数据和代码在 54.5% 的规则提交里同进同出，分成两条通道就会在中间态炸掉。

### 第 1 层：规则数据 + GDScript 逻辑 + C# 规则程序集 —— 同一个 .pck 补丁

| 项 | 内容 | 体积 |
|---|---|---|
| GDScript 改动 | `scripts/core/*.gd` 等，现状不变 | 现有补丁中位数 **489,248 B**，最大 1,026,376 B（61 个包实测） |
| `res://sidecar/core.dll.zst` | 唯一热更的托管程序集 | 裸 IL **估** 150~300 KB；zstd 后**实测口径** 110 KB 量级（本机用 220,034 B 伪 IL 实测压到 112,255 B，真 IL 压缩比通常更好） |
| 合计（碰内核的补丁） | | **约 110~150 KB 增量**，落在既有补丁大小分布的中段 |

**生效时机**：下一次客户端启动。`boot.gd` 挂完 pck 后多一步 `_stage_core()`——若 `res://sidecar/core.dll.zst` 存在就解压写到 `user://sidecar/live/CellWar.Core.dll`，并把它的 SHA-256 记进 `state.cfg` 新字段 `core_sha256`。没有补丁时解出来的就是基线包里那份，**运行路径只有一条**，不存在"有补丁走 A、没补丁走 B"的分叉。

**不做对局中途热替换**。`MatchSession` 是有状态的，`CheckpointCodec` 的 `Schema/Ruleset` 闸也会当场拒。同一局必须同一套规则。

**明确排除进程内 ALC 卸载式重载**：宿主任何一个缓存过 Core 类型的 `JsonSerializerOptions`（`JsonTypeInfo` 缓存）、任何一个 static、Timer、订阅中的事件都会把 collectible ALC 永久钉住，`Unload()` 立即返回而回收可能永远不发生——你以为规则换了，其实没换。这与 2026-09-02→09-10 那八天"每步报成功、一个字节没换"是同一类 bug 换了个位置。`godot-client/CellWar.Client.csproj` 上的 `EnableDynamicLoading=true` 不是"这很容易"的证据，那是 Godot 自己维护了一整套 ALC 生命周期。

### 第 2 层：宿主 + .NET 运行时 + 宿主↔规则接口（`HostAbi`）—— 只随全量发版

自包含 .NET 8 控制台程序，与 `CellWar.exe` 并排放在发版包里。实测本机 `shared/Microsoft.NETCore.App/8.0.15` = **70.0 MB / 184 文件**，自包含发布约等于这个数。`dist/win` 从 96 MB 涨到约 **167 MB**。

**这笔账必须单独跟你讲，不能被"日常只推 110 KB"掩盖**：全量发版这一侧是变差的，而且走的是 GitHub Release——`tools/build_patch.sh:125` 自己写着"补丁包放自家服务器，国内比 GitHub 快一个量级"。

三条不能走的捷径，各有确切死因：

- **框架依赖式**（产物几百 KB）⇒ 要求国内玩家自己先装 .NET 8 桌面运行时，等于第二道安装，不接受。
- **`PublishTrimmed`** ⇒ 裁剪器按发布那一刻的 Core 决定 BCL 保留哪些成员，几周后某个补丁的 Core 调到被裁掉的 API，玩家机器上抛 `MissingMethodException`，只为一张卡；叠加 `CheckpointCodec` 与全部 observation DTO 走反射式 `System.Text.Json`（无 source-gen），record 元数据被裁 ⇒ `MatchObservation` 序列化成 `{}`。
- **`PublishSingleFile` / NativeAOT** ⇒ **直接杀死整条路线**。Core 不再是可单独替换的文件，热更载荷从 110 KB 变成几十 MB。AOT 还会让 `AssemblyLoadContext.LoadFromAssemblyPath` 抛 `PlatformNotSupportedException`。

⚠ 这三条要写成 `CellWar.Core.csproj` / `CellWar.Sidecar.csproj` 上的硬纪律 **+ 一道发版闸**（见 §3），因为它们恰恰是 .NET 桌面发布的默认推荐姿势，队友随手一开就开了。

### 第 3 层：规则数据外置 —— 做，但不按"热更方案"立项

把 `cw_data.gd` 的 168 条常量与 `cw_card_data.gd` 的卡表整成一份 `CWRules.snapshot()`（JSON ≈ 11 KB，gzip 3~4 KB），开局握手时推给 sidecar。

**它省不掉任何一次发版**：按 200 提交窗口，22 次规则改动里纯数据只有 4 次 = 18.2%；把分档表提前开维最多再收编 2 次 ≈ 27%。而发版是批的——一天约 3.7 次规则改动，一批 4 个全是纯数据的概率 ≈ 0.4%。**几乎每一批发版仍然要推程序集。**

它的真实价值是 **`ruleset_digest` 一个 digest 打三个孔**：checkpoint 的 `ImageData.Ruleset`、sidecar `/version`、联机 `welcome` 报文。任何一处对不上就断在那一处，不存在"两套规则悄悄并行跑着"的中间态——而那恰恰是今天真实存在的状态（§6.3）。所以它按**一致性工程**立项，排在对拍之后、热更机制之前。

---

## 三、复用什么、新建什么

### 原样复用，一行不改

| 机制 | 位置 | 为什么不用动 |
|---|---|---|
| `decide()` 四道闸（防降级 / 黑名单 / `min_base` / `build<=base` / manifest 清洁度） | `boot.gd:123-155` | 纯函数，四个 int + 两个 string，一个字节都不碰载荷。被 `headless_test.gd:6115-6137` 十一条护栏钉死，不该动 |
| `verify_manifest` RSA 验签 | `patch_state.gd:56-69` | 签的是 manifest 字节的 SHA-256，完全不看载荷 |
| 签名侧口径 | `patch_key.gd:83-88` | 同一把钥匙、同一份 `latest.json.sig`，**绝不新增第二把** |
| `PUBLIC_KEY_PEM` 烧死、私钥在 `~/.cellwar/patch_key.pem` | `patch_state.gd:43-51` / `patch_key.gd:45-57` | 换钥匙仍必须连着一次全量发版 |
| `pinned()` 地址白名单 | `boot.gd:160-168` | 纯字符串前缀判断 |
| `sha256_of` 流式指纹 | `patch_state.gd:214-225` | — |
| 下到 INCOMING → 校 SHA → 才改名 | `boot.gd:183-192` | 单载荷设计下继续成立 |
| `stale_patch()` 换包弃旧补丁 | `boot.gd:284-288, 309-310` | 两个 int 比较 |
| `reset_if_version_changed()` 换版清缓存 | `patch_state.gd:103-112` | 判据是状态文件上盖的基线号；`user://sidecar/` 要加进 108 行那份文件名清单 |
| `quarantine` / `STRIKES` / `blocked_build` | `patch_state.gd:196-210` | 单载荷 ⇒ 一次改名退全部 |
| `BASE_BUILD` + `min_base` 抽取 + 发版单调递增闸 | `patch_state.gd:34` / `build_patch.sh:124` / `publish_release.sh:105-130` | 纯版本算术 |
| 绝不 `await request_completed`、超时 `cancel_request` 返回空 | `boot.gd:225-266` | HTTPRequest 的坑，与下什么无关 |
| `latest.json` schema `{build, min_base, pck, sha256, notes}` | `build_patch.sh:137-145` | **一个字段都不加**——这是单包设计最大的一条红利 |
| `build_patch.sh` 骨架 S1~S10 + `patch_live.gd` 六条回读 + `DRY=1` | 全文 | 只在"打包"那一格前面插一步 `dotnet build` |
| 控制字符扫描护栏 | `headless_test.gd:6082-6107` | — |
| `settings_page.gd:341-457` 第二 UI 入口 | 同一条信任链、只重写 HTTP 管道 | — |
| `tools/deploy_server.sh` + `server/run.sh` DRAIN 排空 | 服务器侧 | 信任模型不同（ssh 钥匙 + systemd），**不要把它的做法搬到玩家机器上** |

### 必须改（全部是加行，且爆炸半径已压到最小）

| 文件 | 改什么 | 量 |
|---|---|---|
| `game/export_presets.cfg` 四预设 | 加 `include_filter="sidecar/*"` | 4 行。**实测必需**：`export_filter="all_resources"` 单独带不动非资源散文件（`patch_state.gd:21-24` 那课） |
| `game/scripts/boot.gd` ⚠**不可热更** | `_stage_core()` 解压落盘 + 记 `core_sha256`；spawn 前核指纹；`mark_good` 换成平台分档回调 | 约 +35 行 |
| `game/scripts/patch_state.gd` ⚠**不可热更** | `core_sha256` 字段、`CORE_STRIKES`、`note_core_ok()` / `mark_good_if_core_ok()` / `core_failed()` 三个 **static** 函数、`user://sidecar/*` 进清缓存清单 | 约 +30 行 |
| `tools/build_patch.sh` | `dotnet build -c Release` → zstd 压 → 写进 `game/sidecar/`；探针第 7 档；纪律注释改写 | +40 行 |
| `game/tests/build_patch.gd` | `res://sidecar/*` 走白名单（现有 `_needs_import` 只认 13 种媒体扩展名，非 `.gd` 在 `:169` 直接 continue，天然放行——但要显式加断言，别靠巧合） | +10 行 |
| `tools/publish_release.sh` | 第 ⑥ 闸：sidecar 产物存在且比 HEAD 新、自报版本 == `BASE_BUILD`、csproj 零 `PublishTrimmed/SingleFile/Aot`、`CellWar.Core.csproj` 零 `PackageReference` | +25 行 |
| `game/tests/headless_test.gd` | 见 §3 新护栏 | +150 行 |
| `docs/架构说明书.md` 第 445 行那一节 + `docs/开发日志.md` | 同一次提交 | — |

### 必须新建

- **`core/CellWar.Sidecar/`**（250~400 行）：`AssemblyLoadContext.Default.LoadFromAssemblyPath(绝对路径)` 加载外部 Core → loopback HTTP/WS → seat token 授权 → 串行化 `ISession`。形状照 `core/CellWar.Server/Program.cs`(24 行) + `Services/GameSessionManager.cs`(~60 行)，但那两个写死 `new MatchSession(DemoScenario.Create())`，不走 `MatchSession.Start(playerCount, seed)`，没暴露 `Save`/`Restore`/`Advance`，更没暴露 `PlanNextDests`/`QuotePath`（而 `godot-client/scripts/Main.cs:291,318` 正在用后两个）——等于重写。
  ⚠ **宿主目录里绝不能有第二份 `CellWar.Core.dll`**，否则默认探测可能优先拿它，热更的那份永远不生效。这条要由探针证伪，不能靠自觉。
  ⚠ `Main` 方法体里不许出现任何 `CellWar.Core` 类型（JIT 按方法首次调用解析类型），真正的入口标 `[MethodImpl(MethodImplOptions.NoInlining)]`。这是 `boot.gd:12-17`"挂载必须早于首次 load"在 C# 里的同一条纪律，护栏照抄 `headless_test.gd:6041-6050` 扫源码。
- **`core/CellWar.Core/RulesVersion.cs`**（生成文件）：`Build`（由 `build_patch.sh` 写入，与 manifest 同源）、`HostAbi`（手写，接口一变 +1）、`NetVersion`（从 `cw_net.gd:131` 抄，`--check` 闸住）、`CheckpointSchema`、`RulesEpoch`。把在 `CheckpointCodec.cs:61,70` 和 `Server/Program.cs:10` **手抄了两遍**的 `"core-slice-1"` 收编成常量。生成器加 `--check` 挂到 `publish_release.sh:76-80` 旁边。
- **`game/scripts/core_bridge.gd`**（可热更）：`OS.create_process` + 端口文件（避端口冲突）+ token + 握手 + 8 秒超时 + `core_failed()` + 主菜单降级置灰 + 孤儿进程清理。⚠ `OS.execute`/`OS.create_process` 在 `game/` 里 **grep 零命中**，这是全新表面，所有坑都是新的：孤儿进程、端口占用、`--parent-pid` watchdog、玩家用任务管理器强杀。
- **探针第 7 档**（最贵、最不能省）：用 `$BASE` 那个 tag 的**宿主二进制**加载补丁里那份 DLL，`GET /version` 读回 `RulesVersion.Build`，不等于本次 `$BUILD` 就 die。等价物精髓照抄 `patch_probe.gd` 文件头两条：判据落在基线里已存在的东西上；挂载前一个 `load()` 都不许有。
- **确定性自检夹具**：固定种子 `MatchSession.Start(4, 12345)` → `Advance(2048)` → `Save()` → `CheckpointCodec.Encode` → SHA-256。⚠ 见 §9 浮点确定性那条。
- **新护栏 `t_core_payload`**：`res://sidecar/core.dll.zst` 只能由打包器写；`user://sidecar` 不在 `user://patch` 下；`PayloadCodec.Types`（`CheckpointCodec.cs:10-15` 那 18 个类型的白名单）用反射扫 `IDecision` 实现类逐个比对——**新增一种 `IDecision` 忘了登记，checkpoint 当场抛异常**，这是现成会咬人的点；正向自测：造一个假改动清单跑闸，断言退出码（⚠ `build_patch.sh:81-85` 那条类表闸因为 heredoc 吃反斜杠**从写出来那天起一天都没生效过**，新闸不配正向自测就是白写）。

### 前置：Core 必须并进 Cell-War 仓库

`build_patch.sh:51` 的判据是 `git diff --name-only --diff-filter=d $BASE..HEAD -- game/`，`publish_release.sh:83-92` 的"工作树干净 / HEAD == origin/main"也只管这个仓库。Core 留在 cellwar-next 里的话，"这次补丁改了什么"这个最基础的问题答不上来，`min_base`、跨基线闸、`BASE_BUILD` 算术全部落空。**subtree 并进来是动手前的前置条件，不是收尾。**

---

## 四、版本矩阵怎么收口

**三个数，第三个是既有的，不为 sidecar 发明任何新版本号。**

| 数 | 位置 | 管什么 | 谁闸 |
|---|---|---|---|
| `BASE_BUILD`（`YYYYMMDDHHMM`，现 `202609140141`） | `patch_state.gd:34` ⚠不可热更 | 一次全量发版 = Godot 运行时 + .NET 运行时 + **宿主 exe** + `HostAbi` + 基线那份 Core.dll | `publish_release.sh:105-130` 单调递增 |
| `build`（`YYYYMMDDHHMM`） | `latest.json` | **一个补丁 = GDScript + Core.dll，原子** | `build_patch.sh` |
| `NET_VERSION`（现 24） | `cw_net.gd:131` | 联机闸 | 纪律扩展：碰内核 DLL 必升 + 重部署 |

**关键在于"客户端 pck ≠ 本地内核"在构造上不可能**——因为它们就是同一个文件。这正是方案五那条"sidecar 版本 ≡ `BASE_BUILD`"收口失败的地方：`BASE_BUILD` 按设计就打不了补丁（`build_patch.gd:163-166` 的 G7 判死 `patch_state.gd`），而 45/61 的补丁含规则代码 ⇒ 客户端已是新规则、`BASE_BUILD` 却没变、握手仍然"相等" ⇒ 继续用过期内核跑新规则局，静默错。搭车进 pck 之后，`PatchState.installed_build()` **就是**本地内核的真实版本，这个漏洞不存在。

能造出不一致的只剩三条路，每条都堵死：

1. 玩家手工替换 `user://sidecar/live/CellWar.Core.dll` → `state.cfg` 里的 `core_sha256` 在 spawn 前核一次，不符走 `quarantine()`（写法同 `boot.gd:289-294` 核 pck 指纹）。
2. 上次内核证明失败、已回退基线 DLL 而 pck 还是新的 → **这是唯一的真不一致态**，所以 `core_failed()` 绝不带病继续（§5 第 1 档）。
3. 跨基线：补丁的 DLL 要新宿主接口、玩家停在老基线 → 由**已有的 `min_base`** 挡住。宿主随基线出厂 ⇒ "宿主 ABI 兼容性" 天然就是 `min_base` 语义，**不需要第二个字段**。

**四道拒绝（自外向内）：**

| 谁 | 拒什么 | 代码 | 玩家看到 |
|---|---|---|---|
| ① `Boot.decide()` | 降级/黑名单/基线太老/manifest 不干净 | `boot.gd:123-155` **零改动** | too_old 用 `boot.gd:176` 现成文案；其余静默 |
| ② 宿主 | `HostAbi` 不符 → 退出码 **65**；DLL 加载失败 → **64**；selftest 抛异常 → **66** | 新 | 见 ③ |
| ③ `core_bridge.gd` | `/version` 回的 `Build != installed_build()`、8 秒未握手、宿主非零退出 | 新，可热更 | 「规则内核没能启动，已回退到原版，%d 秒后重启」 |
| ④ 服务器 | `hello.ver != NET_VERSION` | `cw_net_server.gd:232-236` **零改动** | `cw_net.gd:165` 现成文案 |

**第三方（服务器内核）**：联机时**本地 sidecar 完全不参与规则**，服务器那份权威。这一条砍掉了半张矩阵。`welcome` 报文加 `core_build` 字段——**S→C 方向的新字段，老客户端读不到、行为照旧，不用升 `NET_VERSION`**（先例：开发日志 3273 / 3548）。客户端进房间若 `welcome.core_build != installed_build()`，**不拒绝**，只挂一行灰字「服务器规则 %d / 本地 %d」，纯报障用。`deploy_server.sh` 跑完加一口自动核对（仿 `patch_live.gd` 连 WS 发 hello，断言 `ver` 与 `core_build`），不符 die。

⚠ **「补丁先、服务器后」这条顺序要重新拍一次**。现在的理由是少一段窗口；内核补丁下，被踢的是没打补丁的人，而服务器切换前还在用旧 DLL 跑没打完的局，若补丁同时改了 `CheckpointSchema`，排空期的存档可能跨不过去。

**存档轴单独记账**：`CheckpointCodec` 的 `Schema` 只在 `WorldState` 形状变时 +1；`RulesEpoch` 只在某次规则改动确实让在飞的局失效时 +1。把 `Ruleset` 改成每次补丁都变的字符串会让所有存档在每次热更后作废——那是错的。

---

## 五、回滚路径

**载荷只有一个，所以回滚动作只有一个**：坏补丁里的 GDScript 和 DLL 一起被 `quarantine()` 掉，整个退回基线包（基线 GDScript + 基线 DLL）。**不存在"回滚了一半"的中间态**——这是单包设计最大的实际收益。

### 证明期的证据来源必须重造，且必须按平台分档

今天的判据是"客户端进程自己活过 `PROVE_SEC = 3.0`"（`boot.gd:300-301` + `patch_state.gd:141-142`），依据是"坏补丁会让 Godot 挂死而不是抛异常"。sidecar 是独立进程，**客户端活着不能证明内核好**。

```gdscript
# patch_state.gd（不可热更），+30 行
static var _core_ok := false
static func note_core_ok() -> void: _core_ok = true
static func mark_good_if_core_ok() -> void:   # 接到 boot.gd:301 的 SceneTreeTimer 上
    if _core_ok or not _needs_core(): mark_good()   # 否则旗子留着 → 下次启动 boot_failed() 兜住
static func core_failed() -> void: quarantine(CORE_STRIKES)
```

⚠ **`_needs_core()` 这条平台分档不能省**。方案三在对抗核查里正是死在这里：`boot.gd` / `patch_state.gd` 里 `OS.` 与 `has_feature` **grep 零命中**，整条热更链今天没有任何平台分支；而 `game/android/build/assets/scripts/boot.gd:300-301` 与桌面版**逐字相同**，`dist/android/CellWar.apk`（29,848,854 B）已在出货管线里。安卓机上永远起不了 .NET sidecar ⇒ 不分档就是每个安卓补丁必被隔离、五次后永久拉黑。网页版侥幸无事只是因为 nginx 把 `latest.json` 404 掉、pending 压根没立起来——那是运气不是设计。

`mark_good_if_core_ok` 与 `core_failed` **必须是 static**，理由同 `patch_state.gd:151-152`：换场景后 Boot 节点已释放。

### 三档回滚阶梯

**① 补丁的 DLL 坏**（握手失败 / 退出码 64/65/66 / 8 秒超时）
→ `core_failed()` → `quarantine(CORE_STRIKES)`：`current.pck` 挪成 `bad.pck`（不删，留着好查），`build`/`sha256`/`core_sha256` 清零，`fails` 累加（同一个 build 连续才累加，`patch_state.gd:199`）
→ **立刻 `OS.set_restart_on_exit(true); quit()`，不带病继续玩**。pck 已经挂上、`load_resource_pack` 在会话内撤不掉，继续玩就是"新 GDScript + 旧规则"的不一致态。文案与倒计时复用 `settings_page.gd:448-457`。
→ 新常量 **`CORE_STRIKES := 2`**（不是 `STRIKES = 5`）。5 次是为了兜"玩家 3 秒内随手关掉"这种误伤；内核失败拿到的是退出码或握手超时这种**硬证据**，误判概率低得多，5 次 = 逼玩家吃 5 次自动重启。攒够 2 次写 `blocked`，`decide()` 的黑名单闸照旧——**没有这条会死循环**（挂了→隔离→manifest 还推同一版→又下）。

**② 基线 DLL 也起不来**（杀软隔离、端口全占）
→ 没补丁可退了，这是环境问题。客户端**不退出**，进**降级可玩态**：单机/热座/教程/回放置灰 +「规则内核启动失败（%d），单机暂不可用」，**联机入口保持可用**（规则跑在服务器上）。这是路线 A 一个真实好用的兜底：联机能玩、单机不能玩，而不是整个游戏打不开。

**③ 完全离线 + 内核起不来** → 只剩菜单、设置、知识之书。给一个"导出诊断信息"，复用 `cw_feedback_http.gd`（它已经在报 `version/base/patch` 三个字段，`:146`）。

**对局中途宿主崩溃**（不是启动失败）：宿主每次 `Submit` 后把 `ISession.Save()` 的 Checkpoint 推给客户端，落 `user://sidecar/resume.json` + 同名 `.build`。socket 断 → 重起宿主 → `MatchSession.Restore()` 续上。`resume.json` **只在同一个 build 内有效**。同一局连崩两次 → 按第 ① 档处理，这一局作废，不要假装能救。

**发版侧回滚**：重跑一次 `build_patch.sh`，`$BUILD` 是 `date +%Y%m%d%H%M` 天然更大，内容退回上一版——和 `9c8ed98` 回滚 `63ffe69` 的手法完全一样。

---

## 六、被对抗核查推翻的论点（以及由此而来的限制）

### 6.1 "共用一个 build ⇒ 两个载荷原子生效、原子回滚" —— **假**

共用 build 只给到两件事：同一份签名、同一条防降级算术。**它不给原子性**，因为两半边是两条独立管道上的两次独立事务。而且**已装好且能正常启动的 pck 没有任何卸载/降级路径**：`quarantine()` 只被 `boot.gd:275/293/296` 调到，`discard()` 只在换完整包时走，`decide()` 的 `build <= installed → skip` 禁止装更老的。一旦 pck build X 装上并正常启动，客户端就永久停在 X。

→ **限制**：要原子就必须把两个载荷做成**一个文件**（本方案）或者**改 boot.gd 把两口下载做成一次事务**（触发 G7、必须全量发版）。「boot.gd 一行不动」与「原子生效/原子回滚」是二选一，不能同时宣称。本方案选前者：**DLL 进 pck，天然一个文件**。

### 6.2 "坏内核时握手拦住不开局" —— **在 boot.gd 不动的前提下是自锁**

`boot.gd:60-63` 写着 Kevin 署名的纪律：「**查不到就照原样进游戏** —— 联网是锦上添花，不该让一个断网的人打不开单机（Kevin 的队友常在手机热点下玩）」。把"kernel 没下到"变成单机开不了局，等于给纯离线功能加了联网前置。

→ **限制**：本方案的第 ② 档降级（单机置灰、联机可用）是对这条纪律的妥协版；真正的解是"基线 DLL 永远可开局"。因此**基线 DLL 必须随全量包出厂并永远可用**，第 ② 档只在环境故障时出现。

### 6.3 "C# 内核与 GDScript 规则是一致的" —— **今天已有四处确切偏离，而且没有任何东西在看**

| # | 项 | GDScript | C# |
|---|---|---|---|
| ① | `IMMUNE_MOVE_CANCEROUS` | `[10, 8, 8, 8]`（09-12 PRD 覆盖版删了 III 级的 0.7） | `RulePolicies.cs:97` `I=>10, II=>8, _=>7` |
| ② | 无氧指数 | `{2:30, 4:30, 6:30}`（issue #29 当晚改回 0.3） | `RulePolicies.cs:260` `six ? 0.35 : 0.3`，停在 09-12 早上那版 |
| ③ | 无氧系数 2 人局 | 2.8 | 无 2 人分支，2.0 |
| ④ | 09-14 issue #43 人数系数 k `ANAEROBIC_CELLS_K := [80,100,120]` | 有 | **完全不存在** |

`contracts/README.md` 自己写着「当前无已验证的真实规则 fixture」；`CardRules.cs` 的 `Registry` 只有 48 条 lambda，而 `CardImplementation.Implemented` 是 67 个卡名、`CardCatalog.All` 是 82 条。

→ **限制（这是最硬的一条）**：**对拍先行**。在同种子 + 同作答串下让 C# 的 checkpoint 与 `CWStateCodec.state_hash()` 对齐之前，不要把 C# 内核当权威内核发给任何玩家。热更链路做完了 ≠ 内核可以上线了——前者管"装不装得上、回不回得去"，后者管"规则算得对不对"。

### 6.4 "数据外置能让 sidecar 二进制不动" —— **只覆盖 19%（乐观 27%）**

按行数加权数据:逻辑 = 26%:74%；混合类提交占 54.5%，主因是**最常见的 PRD 改动不是"改数"而是"给表加一个维度"**（6 天里 `cw_data.gd` 新增 3 个访问器，`290f554` 一次给 5 张表加"肿瘤分期"维度）。

→ **限制**：数据外置不能作为热更主方案，只能按一致性工程立项（§2 第 3 层）。而且在没有黄金回归的内核上做 60~80 处字面量查表化，本身就是最大的规则事故来源——写错了是**静默的数值偏差**，不抛异常、不崩，玩家只觉得"手感变了"。

### 6.5 "不给 sidecar 做热更是零成本" —— **会关掉现役主通道**

61 个已发补丁里 **45 个（74%）**含 `game/scripts/core/`。最新那个 `patch-202609142017.pck`（442,704 B / 60 条目）里就有 `cw_world.gd` 63,759 B、`cw_data.gd` 71,631 B、`cw_card_fx.gd` 60,493 B、`cw_card_data.gd` 19,459 B。峰值包各含 10 个 core 文件。

→ **限制**：给 sidecar 做热更的价值不是"新好处"，是**保住今天已经有的东西**。

### 6.6 "Windows 有安装目录可以放 kernel/" —— **今天没有**

`export_presets.cfg:26` `binary_format/embed_pck=true`，`dist/win/` 里只有一个 99,664,776 B 的 `CellWar.exe`；`publish_release.sh:32-33,161` 的产物就是 `CellWar.exe` + `CellWar.zip`。

→ **限制**：Windows 分发必须从"单 exe"改成"目录/zip"，连带 `export_presets`、`publish_release.sh` 的产物清单与闸③、以及新的失败模式（玩家只拖走 exe 就打不开）。这笔账和引入 sidecar 的那次全量发版一起算。

---

## 七、已经实测过的（别再重新讨论）

本机 Godot 4.5-stable（`D:\Godot\Godot_v4.5-stable_win64.exe\...console.exe`），临时工程四趟真机实验：

1. **`PCKPacker` 收任意二进制**：220,034 B 伪 IL（MZ 头 + 半高熵）→ `FileAccess.open_compressed(ZSTD)` 得 112,255 B → `pck_start` / `add_file("res://sidecar/core.dll.zst", 绝对磁盘路径)` / 再 add 一个 `.gd` / `flush` **全 OK**，pck 共 112,536 B。**打包开销只有 281 字节。**
2. **读回不走资源通道**：`load_resource_pack(...,true)=true`；`FileAccess.file_exists("res://sidecar/core.dll.zst")=true` 而 `ResourceLoader.exists=false`。⇒ **2026-09-02→09-10 那个 `.remap` 绕过去的坑对这个载荷不适用**。`open_compressed(ZSTD)` 读回 220,034 B，头两字节仍是 `MZ`。
3. **`include_filter` 是必需且有效的**：同一工程两个预设真导出——`include_filter=""`（线上现状）→ pck **5,448 B，DLL 不在里面**；`include_filter="sidecar/*"` → pck **117,764 B，DLL 在里面**。线上四个预设现在都是 `""`（`export_presets.cfg:10/55/126/154`）。
4. **补丁对非资源文件的覆盖生效**：先挂基线包（220,034 B，首字节 0x4D）→ 再挂同路径不同内容的补丁包 `replace=true` → 读到 4,096 B、首字节 0x42。**"运行路径只有一条"成立。**

管线侧同样核过：`.gitignore` 没排除 `game/sidecar/*.zst`；`build_patch.sh:51` 的清单会**自动**收进提交了的 `core.dll.zst`；`build_patch.gd` 的 `_reject` 不会拦它（`_needs_import` 只认 13 种媒体扩展名，`:256-261`；非 `.gd` 在 `:169` 直接 continue）。护栏那组不等式容得下 `NET_TIMEOUT` 10→30（`headless_test.gd:6147-6153` 只钉 `SKIP_AFTER < CHECK_BUDGET` 与 `NET_TIMEOUT >= CHECK_BUDGET`）。

**关于 `NET_TIMEOUT`**：61 个包中位数 489,248 B、最大 1,026,376 B 一直在走这口 10 秒无续传的下载，所以再加 ~110 KB **不必然**要改常量。代价是最坏挂钟从 manifest 10 + pck 10 = 20 秒变成同口多 10~20%。建议先不动，等灰度数据说话。

---

## 八、分阶段落地（每阶段可独立验证）

**阶段 0 · 工具链收口 + 对拍**（2~3 天）｜**硬阻塞，不做完后面一步都跑不了**
- 装 .NET 8 SDK；把 `CellWar.Server`/`Console`/`Tests` 从 net10.0 回落 net8.0（或另建 `global.json` 只服务 Core + Sidecar）；确认 `Godot.NET.Sdk/4.7.2` 与文档说的 4.4.1 mono 哪个是真的（`git status` 干净 ⇒ 是文档与 csproj 对不上）。
- Core subtree 并进 Cell-War 仓库。
- **路 D 对拍**：同种子 + 同作答串，C# checkpoint ↔ `CWStateCodec.state_hash()`，产出"C# 内核到底差什么"的确切清单，先把 §6.3 那四处归零。
- ✅ 验证：`dotnet publish -r win-x64 --self-contained` 真的产出一个目录；对拍脚本在 N 局上输出 diff 清单；Core.dll 的**真实字节数**（今天全是估算）。

**阶段 1 · 宿主可跑，不进客户端**（2~3 天）
- `core/CellWar.Sidecar/`：ALC 外部加载 + loopback + token + `/version` + `/selftest` + `Start/Save/Restore/Advance/PlanNextDests/QuotePath` 全暴露 + 退出码 64/65/66。
- `RulesVersion.cs` 生成器 + `--check`，收编 `"core-slice-1"`。
- ✅ 验证：命令行起宿主打完一整局；`--selftest` 退出码正确；**把宿主目录里的 Core 删掉、只留外部路径那份，确认仍能跑**（证明 `LoadFromAssemblyPath` 真的顶掉了探测路径）。

**阶段 2 · 全量发版形态改造**（1~1.5 天）
- Windows 从单 exe 改目录/zip；`dist/win/kernel/` 带宿主与基线 Core；四预设 `include_filter="sidecar/*"`；`publish_release.sh` 产物清单、闸③、新增第⑥闸。
- ✅ 验证：干净机器上解压双击能起 sidecar；第⑥闸对着一个故意开了 `PublishTrimmed` 的 csproj 会 die。

**阶段 3 · 打包器 + 探针第 7 档**（2 天）｜**最贵也最不能省**
- `build_patch.sh` 插 `dotnet build` + zstd；探针用 `$BASE` 的宿主二进制加载补丁 DLL 读回 `RulesVersion.Build`。
- ✅ 验证：`DRY=1` 全流程跑通；**故意压进上一次的 DLL，探针必须 die**（这是 2026-09-10 那一课的等价物，不做这个反向测试等于没做探针）。

**阶段 4 · 客户端接线**（2.5 天）
- `boot.gd` `_stage_core()` + 指纹核对 + 平台分档证明期；`patch_state.gd` 三个 static；`core_bridge.gd` 全部握手/超时/降级逻辑。
- ✅ 验证：headless 新护栏全绿；真机杀掉 sidecar 进程，单机局按第 ② 档降级、联机仍可用；模拟坏 DLL → 自动重启 → 退回原版；**安卓包与网页版打一个含 DLL 的补丁，确认 `_needs_core()` 分档让它们照常 `mark_good`**。

**阶段 5 · 灰度第一个内核补丁**（1 天 + 观察）
- 先发一个只改一个常量的 Core 补丁，用 `kernel_live.gd` 回读线上；在 Kevin 和队友的真机上各跑一轮。
- ✅ 验证：握手报回的 `Build` == 本次 `$BUILD`；夹具哈希与打包机一致。

合计 **10~13 个工作日**，其中阶段 0 有 2~3 天是路线 A 无论选哪个热更方案都要付的。

---

## 八点四、队友的反馈把方案砍掉了一大块（2026-09-15）

重构项目的队友给了四条建议。**第一条是对的，而且它一句话把整个 ALC 问题取消了。**

### ① 「原版也没有热更，只是增量更新，不是热更新」—— 成立

核过了，精确版本是：

* **启动那条路**：`boot.gd` 在 `_ready()` 里下载 + `load_resource_pack`（:295），
  **然后**才 `change_scene_to_file(MAIN_SCENE)`（:113）—— **当次就生效，玩家不用重启**。
* **游戏内手动检查**：`settings_page.gd:28-37` 写着「补丁要重启才生效」，有重启倒计时。

两条路的共同点才是要害：**永远有一个进程边界可用**。我们从来没有、也不需要
「进程运行中把代码换掉」的能力。本文前面一直用「热更」这个词，
**准确的说法是「增量更新」**。

⇒ **于是 §3 里那套 `AssemblyLoadContext` + `LoadFromAssemblyPath` 整个不需要了。**
sidecar 是独立进程，换内核 = 下次 spawn 换个目录。

### 实测：换目录就行，零 ALC 代码

```
verA/  Host.exe + RuleLib.dll(V1)      →  V1-BASELINE
verB/  Host.exe + RuleLib.dll(V2)      →  V2-PATCHED      ← 两个完整目录只差一个 dll
dotnet exec verA/Host.dll              →  V1-BASELINE
dotnet exec verB/Host.dll              →  V2-PATCHED
```

`dotnet` 按 **app dll 所在目录**探测依赖，所以「换内核」就是「spawn 时指向另一个目录」。
不用 `LoadFromAssemblyPath`、不用自定义 ALC、不和 TPA 打架，
而且**天然避开文件锁** —— 永远不覆盖正在使用的 DLL，只是写一个新目录、下次指过去。

⇒ §8.5 实测 2 里那套「`<Private>false</Private>` + 启动自检核 `Assembly.Location`」
**不再是承重机制**。`Location` 自检可以留着当廉价的完整性检查，但它守的东西已经没有了。

### ② 「启动器 + 主进程」—— sidecar 用不上，但对**更新宿主本身**有用

sidecar 不需要单独的启动器：**Godot 客户端本身就是启动器**（它 `OS.create_process` 起 sidecar），
所以「趁 sidecar 没在跑的时候换目录」天然成立。

这条真正的用处在别处：本方案第 2 层说「宿主 + .NET 运行时只随全量发版」。
有了独立启动器，那两样也能做增量更新（启动器在主进程起来之前换文件）。
代价是多一个进程和一套自己的更新逻辑。**先不做**，等宿主接口真的开始频繁变再说。

### ③ 「独立 AssemblyLoadContext」—— 诊断对，但有更简单的答案

如果坚持进程内加载，自定义 ALC（+ `AssemblyDependencyResolver`）确实是正解，
我实测失败的那套用的是 `AssemblyLoadContext.**Default**`，它受 TPA 约束。
但既然有进程边界（①），就没有「坚持进程内加载」的理由。**更简单的赢。**

### ④ HybridCLR / AOT —— 方向相反，别走

HybridCLR 是 **Unity il2cpp** 的解药：Unity 打 AOT 包之后不能再加载新 IL，
它加一层解释器把这个能力补回来。

**我们没有那个病。** sidecar 是 .NET 8 的独立进程、JIT，本来就能直接加载程序集 ——
上面 verA/verB 那个实验就是证明。

而且 **AOT 在我们这儿是主动有害的**：一旦开 `PublishAot` / `PublishSingleFile`，
`CellWar.Core` 就被熔进一个不可分割的产物，增量更新的载荷从 **112 KB 变成几十 MB**，
整条路线的经济性归零（本方案 §2 第 2 层已经把这条列为三条「不能走的捷径」之一）。

⇒ 所以不是「考虑上 AOT + HybridCLR」，而是**别开 AOT，就不需要 HybridCLR**。
这条要写进 §10 的硬纪律（已经在第 1 条里了，这里补上「为什么不需要 HybridCLR」的理由）。

---

## 八点五、2026-09-15 实测补录（装上 .NET 10 SDK 之后）

Kevin 装了 **.NET SDK 10.0.401**（运行时 10.0.12 + 原有 8.0.15 并存）。§9 里前两条
「还需要实测」当天就测了，**第 2 条的结论推翻了 §3 的机制**。

### 实测 1：`CellWar.Core.dll` 的真实体积 —— 估算落在上限，结论不变

```
dotnet build core/CellWar.Core/CellWar.Core.csproj -c Release   → 0 警告 0 错误
裸 IL     300,032 字节
gzip -9   112,667 字节（2.7×）
```

对照 `dist/patch/` 的 61 个已发补丁：最小 5,508 / **中位 489,248** / 最大 1,026,376。
压缩后的 DLL 只占中位补丁的 **23%**。§2 第 1 层那个「110 KB 量级」的估算成立，
`NET_TIMEOUT` 不必改。§9 第 1 条建议的「> 1.5 MB 就 die」这道闸仍然要加 —— 现在有了真实基数，
闸值可以定成 **300 KB**（裸）/ **150 KB**（压缩后），留一倍余量。

### 实测 2：⛔ `LoadFromAssemblyPath` **顶不掉**探测路径 —— §3 的机制按原样写会静默失效

搭了最小实验（`scratchpad/alctest/`）：宿主 `ProjectReference` 一个 `RuleLib`（= 探测路径那份，
内容 `V1-BASELINE`），外部路径上放另一份同名、内容 `V2-PATCHED` 的，然后
`AssemblyLoadContext.Default.LoadFromAssemblyPath(外部路径)`。

两种顺序**都失败**：

```
实验 A（先 LoadFromAssemblyPath、再用类型 —— 即 §3 那条 NoInlining 纪律要求的顺序）
  LoadFromAssemblyPath 返回：V1-BASELINE
  之后按类型直接调用：    V1-BASELINE
  已加载的 RuleLib 份数：1
    来自 <宿主目录>\RuleLib.dll          ← 外部那份根本没进来

实验 B（先用类型、再 LoadFromAssemblyPath）：同样全是 V1-BASELINE
```

原因：`AssemblyLoadContext.Default` 先查 **TPA（Trusted Platform Assemblies）**，
宿主的 `deps.json` 把 `RuleLib.dll` 列了进去（实测 `Host.deps.json` 里有 `RuleLib/1.0.0` 与
`RuleLib.dll`），路径加载被它顶掉。

**⚠ §3 里那条「`Main` 方法体里不许出现任何 `CellWar.Core` 类型 + `[MethodImpl(NoInlining)]`」
的纪律与这个失败无关，救不了它。** 实验 A 正是按那条纪律写的，照样拿到基线那份。

**解法（实测有效）：宿主目录里不能有 `CellWar.Core.dll`。** 把基线那份挪走之后：

```
  LoadFromAssemblyPath 返回：V2-PATCHED
  之后按类型直接调用：    V2-PATCHED      ← 编译期引用也解析到了外部那份
    来自 <外部路径>/RuleLib.dll
```

于是 §3「必须新建」里那条 ⚠ 要从「宿主目录里绝不能有第二份」**升格为硬机制**：

1. 宿主**仍然**编译期引用 Core（要有类型可用），但必须
   `<ProjectReference ... ><Private>false</Private></ProjectReference>`
   或 `ExcludeAssets="runtime"`，**保证输出目录里没有那个 dll**。
2. **不能靠「文件恰好不在」**：实测表明 TPA 是按文件实际存在构建的（`deps.json` 里还列着它
   也照样工作），但哪天构建顺手把它拷进去，热更就**静默停止生效** —— 一个字节都不会换，
   而每一步都报成功。这与 2026-09-02→09-10 那八天是同一类 bug。
3. 所以 sidecar **启动自检必须核 `Assembly.Location`**：加载回来的 Core 的 `Location`
   不等于外部那个路径就 `Environment.Exit(65)`，由 `core_bridge.gd` 接住走 §5 第 ① 档。
   这条比「宿主目录里别放」更根本 —— 前者是纪律，后者是机制。
4. 备选（更稳、但更复杂）：改用**自定义 `AssemblyLoadContext` + `AssemblyDependencyResolver`**
   的标准插件模式，不受 TPA 约束。本轮没测，若第 1 条在实践中反复出问题再上。

### 实测 4：对拍的三个死结（这一条不属于热更，但同一天测出来，记在一起）

跑了一个询问普查（脚本没进仓库，留在 scratchpad）：

```
players=2 seed=4242 → asks=303  rounds=15
players=4 seed=4242 → asks=155  rounds=6
players=6 seed=4242 → asks=907  rounds=15      ← 最大
平均选项数：setup_place 63~64、action 10~19（占询问总数 90%+）、
            chemo_target 127（全盘每格）、free_move 6~7、revive 3~11
```

**死结一：选项下标不通用。** `action` 占 90%+，选项集合是「这个细胞此刻所有合法动作」，
C# 规则不全 ⇒ 选项数必然不同 ⇒ `CWReplay` 的下标串在两边指向不同动作。实锤，不是推测。

**死结二：RNG 算法不同，且不可调和。**
我们是 Godot 的 `RandomNumberGenerator`（**PCG32**，实测 seed=4242 → state=748695878776107324，
randi_range(0,9) x8 = [8,8,0,9,4,9,7,3]，state 可完整克隆）；
C# 是 `IDeterministicRng.cs:62` 的 **`Xoshiro256StarStar`**。
**同种子必然产生完全不同的序列** —— 只要规则里有掷骰（攻击判定、突变、增生、侵蚀选格、
洗牌、开局癌组织按种子生成），状态就分叉，对齐输入也救不了。
好消息：C# 侧 `IDeterministicRng` 本来就是接口，实现一个「念预生成数组」的很容易；
难点在我们这边——`CWGame.rng` 是 Godot 内置类，不是接口。

**浮点反而不是问题**（两条都实测）：
`pow` 逐位一致（pow(97,0.3)：GDScript `3.944859320862161` / C# `3.9448593208621605`）；
取整口径队友**已经对齐**——`Settlement.cs:83` 用的是
`Math.Round(v, MidpointRounding.AwayFromZero)`，与 GDScript 的 `round()` 同口径。
（我原本怀疑这里有偏离：C# 的 `Math.Round` 默认是银行家舍入，`Math.Round(2.5)=2`
而 GDScript `round(2.5)=3`。查下来他显式写了 `AwayFromZero`，没踩这个坑。）

⇒ 于是 §9 第 4 条「自检夹具的浮点确定性」风险**下降但不清零**：同机同架构下 `pow` 一致，
跨架构（玩家机器 / ARM Mac）仍未验。

### 实测 3：队友的核心测试在本机 **141/141 全过**

```
dotnet test tests/CellWar.Core.Tests/CellWar.Core.Tests.csproj
Passed!  - Failed: 0, Passed: 141, Skipped: 0, Total: 141, Duration: 477 ms
```

交接文档写的是 135/135，现在是 141 —— 他之后又加了。编译 0 警告 0 错误。
**注意这不削弱 §6.3**：141 条测的是它自己的行为契约，而 §6.3 说的是它的规则与 GDScript 不一致。
两边都"绿"，只是绿在不同的标准上 —— 这正是必须对拍的理由。

---

## 九、还需要实测才能定的事

| # | 事项 | 为什么现在定不了 | 定不下来的后果 |
|---|---|---|---|
| 1 | **`CellWar.Core.dll` 的真实字节数** | 本机无 SDK、无 csc、cellwar-next 全仓零 `.dll`；150~300 KB 是按 30~60 B/源码行推的 | 若因为引 NuGet 或 source-gen 变成 MB 级，`NET_TIMEOUT` 与护栏那组不等式全要重算。**配一道硬闸：`core.dll.zst` > 1.5 MB 就 die** |
| 2 | **`LoadFromAssemblyPath` 是否真的顶掉宿主目录/deps.json 那份** | 从没做过实验 | 这正是"每步报成功、一个字节没换"的同构风险位置。阶段 1 的验证项就是它 |
| 3 | **杀软 / SmartScreen / Gatekeeper** | 只能在真机上撞 | 一个国内客户端从裸 IP 明文 HTTP 下包、解出 DLL 写进 `user://`、再 `create_process` 起 .NET 宿主加载——教科书式 loader 特征。360/火绒可能直接删 `live/CellWar.Core.dll`（表现成第 ② 档降级）。**至少三五台真机，且要准备白名单申请与代码签名证书的预算**。macOS 侧宿主必须随游戏一起公证 |
| 4 | **自检夹具哈希的浮点确定性** | `RulePolicies.cs:260` 用 `Math.Pow(ordinary, 0.35/0.3)`，而 `CheckpointCodec.Encode` 把含 `double Energy` 的 WorldState 整个 JSON 序列化后才取 SHA。`Math.Pow` 不保证跨平台/跨运行时逐位一致 | 打包机与玩家机差 1 ULP 且落在 `RoundTenth` 中点 → 哈希对不上 → 静默 quarantine → 攒满永久拉黑。**缓解：夹具只对整数化的量取哈希，或显式避开浮点参与的字段；并在每次全量发版时重新定基线** |
| 5 | **sidecar 冷启动 + 握手能否稳定落进 `PROVE_SEC ≤ 5.0`** | 护栏 `headless_test.gd:6223` 钉死这个上限；自包含 + R2R 控制台冷启动理论上 40~120 ms，但没实测过 | 落不进就要把证明期与握手解耦（另起一个 `CORE_PROVE_SEC`），护栏跟着加 |
| 6 | **Windows 从单 exe 改目录后的玩家失败模式** | 新形态没发过 | "只拖走 exe 就打不开"是新增的支持工单类型 |
| 7 | **Godot 4.7 的 .NET 是否有 Web 导出** | `docs/融合方案_cellwar-next.md` §二① 说没有，但要拿真的 .NET 构建导一次才算数 | 决定网页版单机的归宿：继续跑 GDScript core（= 永久两套实现），还是变成纯联机。**这一条不是热更问题，但它决定路线 A 本身成不成立** |
| 8 | **`MatchObservation` 全量快照的体积** | radius 6 = 127 个 `TissueObservation` + 全部 cells + `DecisionRouter.Available` 逐格枚举的全部 options（己方每细胞 × 127 格，树突【趋化源】再乘 127），单次几十 KB | loopback 无所谓；但任何"内核不在本机"的分支（网页版单机走服务器、联机观战）都会被报文体积卡死，必须先做游标/增量。与热更无关，但在同一条链上 |

---

## 十、四条要写进 CLAUDE.md 的硬纪律

1. **`CellWar.Core` 永远是零 `PackageReference` 的纯 BCL 单程序集**，且 `CellWar.Sidecar` **永不** `PublishTrimmed` / `PublishSingleFile` / `PublishAot`。三者任一开启就把 Core 烧进不可分割的产物，热更载荷从 110 KB 变成几十 MB，整条路线的经济性归零。由 `publish_release.sh` 第⑥闸守。
2. **宿主↔规则接口一动就是全量发版**，由 `HostAbi` 锁住，没有第三条路。宿主要是能跟着热更，载荷就从 110 KB IL 变成 20~70 MB 自包含二进制，"补丁包 Windows/macOS 通用"这条现有性质也一起丢掉。
3. **不做进程内 ALC 卸载式热替换**，理由见 §2 第 1 层。
4. **碰了 `core/CellWar.Core/**` 或 `game/scripts/core/cw_*.gd` 的补丁，必须同时升 `NET_VERSION` 并重新部署服务器**（`build_patch.sh:30-31` 那条纪律的扩展）。做成闸，别靠人记得。

---

## 附：一句话给不想读完的人

**把 C# 内核当成一个 200 KB 的脚本文件，让它坐现在这条已经建好的热更链的同一班车——不新建通道、不新建版本号、不新建信任模型。真正的工作量不在热更机制上（那只有 2 天），在于把 C# 内核的规则先对到和 GDScript 一样准（对拍），以及承认在网页版和安卓上 sidecar 永远不会存在、GDScript core 要一直留着。**