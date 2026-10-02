# 真机验收驱动（tools/acceptance/）

在**导出的发布包**（真正发出去的那个可执行文件）里跑真产品代码，逐项报通过 / 失败。
入口是 `acceptance.gd`，用法与 `tools/export_check_sidecar.gd` 一样：导出包认 `--headless --script <绝对路径>`。

```
<导出的可执行文件> --headless --script <绝对路径>/acceptance.gd -- [steps=a,b,c] [server=ws://HOST:PORT] [out=<结果文件>]
```

- 只用产品代码（`res://scripts`、`res://scenes`、`res://data`）和本目录自己的文件；导出包里没有 `res://tests`，
  要用的测试辅助逻辑已经抄进来了（出处写在各文件头注里）。**整个目录拷走就能用**，不依赖仓库里别的东西。
- 用户目录换到 `CellWar-acceptance`，开跑前清空：不碰真玩家的存档 / 教程进度 / `sidecar` 解包目录。
  Mac：`~/Library/Application Support/CellWar-acceptance`；Windows：`%APPDATA%\CellWar-acceptance`。跑完可以整个删掉。
- 要验的是包里那份 .NET 运行时：跑之前环境里别有 `CW_KERNEL`、`CW_SIDECAR_DLL`、`CW_DOTNET`（有了就验不到包里那份），
  PATH 里最好也别有 dotnet。

## 有哪几项

| 项 | 验什么 |
|---|---|
| `unpack` | 清掉 `user://sidecar` → `CWKernelSidecar.locate()` 从 pck 现解运行时 + 载荷 → 解出来的 dotnet 跑 `--version`（报 core_build，与包里 `payload.json` 对得上）和 `--selftest` |
| `hotseat` | 主菜单开 2 人本地多人（全真人）：换手遮罩点掉、各席轮流作答，句柄必须是 `CWKernelSidecar`，打到第 3 世界回合 |
| `solo_normal` / `solo_intent` / `solo_search` | 4 人局，1 位真人（免疫）+ 3 席 AI，AI 分别是普通 / 意图 / 搜索三档（C# AI 在 sidecar 里），打到第 3 世界回合 |
| `spectate` | 观战：4 席全 AI，打到第 3 世界回合 |
| `save_continue` | 单机打到第 2 世界回合 → 暂停菜单「保存并退出」→ 主菜单「继续对局」→ 回到 sidecar、回合与细胞逐个相同 → 再打一个世界回合 |
| `tutorial` | 主菜单「新手引导」：开场动画 → 七段（c1_l1 … c2_l5、间章、c3_l6）在 C# 内核上一口气打到「全部通关」回主菜单；每段按次序进、句柄每一帧都是 sidecar |
| `online` | 要 `server=`：本进程里两个客户端连服务器，建一间 2 人房对打到第 3 世界回合 |
| `web_solo` | 要 `server=`：网页单机那条路（主菜单开局走服务器的私人房，`create_solo`），界面上打到第 3 世界回合 |

不写 `steps=` 就跑前八项；给了 `server=` 再加联机两项。每项有自己的上限（见 `acceptance.gd` 的 `STEPS`），
一项卡住只判它失败，后面照跑。

## 怎么看结果

每一项一行 `[通过] step …` 或 `[失败] step …: 原因`，最后一行 `ACCEPTANCE: PASS x/y` 或 `ACCEPTANCE: FAIL x/y`，
退出码 0 / 1。给了 `out=` 就把这些行同样写进那个文件（每出一行重写一次）。

**结果文件里没有最后那行 `ACCEPTANCE` = 进程崩了。** 发布包里 GDScript 不做大部分运行时检查：越界、缺键是静默的，
对 null 调方法直接段错误退出（Mac 上退出码 139 / 11）。每项开跑前文件里都先落一行 `# 开始 step …`，
最后一行 `# 开始` 就是崩的那一项。同理，「SCRIPT ERROR」在发布包里多半报不出来；能稳定抓到的是产品代码自己的
`push_error`（那十几处都是真故障，抓到就判失败）和引擎的 ERROR（只记在说明里）。

引擎自己的日志（godot.log）在换用户目录之前就开了，默认还写在真玩家的目录里；不想要就加 `--log-file <路径>`
（放在 `--script` 前面）。

## Mac

导出包要带 sidecar：先 `bash tools/build_sidecar.sh osx-arm64`，再导出 `macOS` 预设
（`$G --headless --path game --export-release macOS ../dist/mac/CellWar.zip`），解开 zip。

```sh
APP="/path/to/Cell War.app/Contents/MacOS/Cell War"
env -i HOME="$HOME" PATH=/usr/bin:/bin TMPDIR="$TMPDIR" \
  "$APP" --headless --script "$PWD/tools/acceptance/acceptance.gd" -- out="$PWD/acceptance_result.txt"
echo "exit=$?"; cat acceptance_result.txt
```

`env -i` 是为了让 PATH 里没有 dotnet、也没有 `CW_*` 变量。只跑几项：`-- steps=unpack,tutorial out=…`。

## Windows 11 ARM（Parallels，x64 包模拟运行）

导出包要带 Windows 的运行时：Mac 上
`RUNTIME_DIR_win_x64=~/.cellwar/dotnet-runtime-10.0.12-win-x64 bash tools/build_sidecar.sh osx-arm64 win-x64`，
再导出 `Windows Desktop` 预设（`../dist/win/CellWar.exe`）。

1. 把 `CellWar.exe` 和整个 `tools/acceptance` 目录拷到虚拟机的本地盘（别从 `\\Mac\…` 共享目录直接跑），例如
   `C:\CellWar\CellWar.exe`、`C:\cellwar-accept\`。路径里别带空格。
2. 发布版 exe 是窗口程序、**没有控制台输出**，结果只看 `out=` 那个文件。PowerShell：

```powershell
$p = Start-Process -FilePath C:\CellWar\CellWar.exe -Wait -PassThru -ArgumentList `
  '--headless', '--script', 'C:/cellwar-accept/acceptance.gd', '--', 'out=C:/cellwar-accept/result.txt'
"exit=$($p.ExitCode)"
Get-Content -Encoding UTF8 C:\cellwar-accept\result.txt
```

`--script` 和 `out=` 用正斜杠写路径。Mac 上整套约 2.5 分钟；x64 模拟跑会慢几倍，各项上限已经按这个放宽了。

## 联机两项要一台服务器

本机起一台（仓库根目录，开发期 sidecar 产物先 `dotnet build core/CellWar.Sidecar`）：

```sh
CW_KERNEL=sidecar $G --headless --path game --script res://server/server_main.gd -- port=18911 bind=127.0.0.1 feedback_port=0
```

Mac 上跑：`-- server=ws://127.0.0.1:18911 out=…`。虚拟机里跑要让服务器听所有网卡（`bind=*`），
`server=` 填 Mac 在 Parallels 共享网络上的地址（虚拟机里 `ipconfig` 看默认网关，一般是 `ws://10.211.55.2:18911`）。
服务器那边这一局跑在哪个内核上客户端看不到，看服务器日志「开局（C# 内核…）」那一行。**别拿线上服务器跑**：会真建房。
