#!/bin/bash
# deploy_server.sh —— 发版：把 game/ 打包传到服务器 ~/cellwar/next/，写 DRAIN 让服务器排空后切到新版
#
# 用法（仓库根目录）：tools/deploy_server.sh [ssh 别名，默认 cellwar]
#   · 没有对局在打：服务器几秒内就重启到新版
#   · 有对局在打：维护中（大厅有提示、不能建房/开局），最后一局打完自动重启
# 看状态：ssh cellwar 'systemctl status cellwar --no-pager; journalctl -u cellwar -n 30 --no-pager'
# 第一次装机用 tools/setup_server.sh。别名 cellwar 定义在 ~/.ssh/config（专用钥匙 cellwar_ed25519）。
#
# 换内核 P8 起服务器的对局跑在 C# sidecar 上：规则 dll 随工程走（game/sidecar/payload/），.NET 运行时在服务器上。
# 所以这里多几步：
# ① 运行时：服务器上没有 DOTNET_TGZ 那个版本（缺省 ~/.cellwar/dotnet-runtime-10.0.12-linux-x64.tar.gz —— 10-01 从
#    builds.dotnet.microsoft.com 下的官方包，SHA-512 对过；服务器连不上 GitHub，所以本地下好再传）就传上去，
#    **解到带版本号的新目录 ~/cellwar/dotnet-<版本>/、在那儿先跑一遍 --list-runtimes**，跑不起来就删掉退出。
#    ~/cellwar/dotnet 是指向当前版本的软链，自检全过之后才原子地改指过去；旧版本目录留着（在跑的 sidecar 还开着它的文件）。
# ② 照工作树的 core/ 现编载荷（PAYLOAD_ONLY，要本机 dotnet SDK）；桌面包的运行时 zip（game/sidecar/runtime-*，几十 MB）不上传。
# ③ 新工程连同 server/run.sh 先解到 next.tmp/（**这时还不叫 next/**：run.sh 只认 next/，自检途中服务崩了重启也不会切到没验过的版本），
#    用新运行时真起新载荷：--version 读回的 core_build 要等于这次编的、--selftest 要过 —— 不过就删 next.tmp/、不写 DRAIN。
# ④ 全过了才依次换上：运行时软链 → run.sh → next.tmp/game 改名成 next/ → 写 DRAIN。每一步都是改名（原子），失败当场停、不写 DRAIN。
#
# 观察期要让服务器临时退回 GD 内核：`sudo systemctl edit cellwar`，写 `[Service]` 下一行 `Environment=CW_KERNEL=gd`，
# 再等下一次排空（或 `sudo systemctl restart cellwar`，会断掉在打的局）。**别手改 ~/cellwar/run.sh**：每次部署都会换掉它。
set -e
# macOS 的 tar（bsdtar）会把扩展属性（com.apple.provenance 之类）打成 AppleDouble 的「._文件名」一起塞进包里：
# 2026-10-01 服务器发版因此多出 795 个 ._*.gd 垃圾、`rmdir next.tmp` 撞上 ._game 退出；网页目录也多了 16 个 ._*。
# 关掉它（只对 macOS 生效，别的平台不认这个变量）
export COPYFILE_DISABLE=1
# 服务器的 sshd 被扫描时会随机丢连接（"Connection closed by ... port 22"，2026-09-02 实测），所以每条 ssh/scp 都重试几次。
# 重试意味着远端那段可能跑两遍：下面每一段都写成跑两遍也安全（第二遍要么什么都不做，要么在写 DRAIN 之前失败）
ssh() { for i in 1 2 3 4 5; do command ssh -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; local rc=$?; [ $rc -eq 255 ] || return $rc; sleep 5; done; return 255; }
scp() { for i in 1 2 3 4 5; do command scp -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; local rc=$?; [ $rc -eq 255 ] || return $rc; sleep 5; done; return 255; }
die() { echo "✘ $1"; exit 1; }
HOST=${1:-cellwar}
cd "$(dirname "$0")/.."

# ---- ① .NET 运行时（装在新目录里，在跑的服务一点不碰）----
DOTNET_TGZ=${DOTNET_TGZ:-$HOME/.cellwar/dotnet-runtime-10.0.12-linux-x64.tar.gz}
DOTNET_VER=$(basename "$DOTNET_TGZ" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
[ -n "$DOTNET_VER" ] || die "从 $DOTNET_TGZ 的文件名读不出版本号（要形如 dotnet-runtime-10.0.12-linux-x64.tar.gz）"
RT="dotnet-$DOTNET_VER"
if ssh "$HOST" "~/cellwar/$RT/dotnet --list-runtimes 2>/dev/null | grep -q 'Microsoft.NETCore.App $DOTNET_VER '"; then
	echo ".NET 运行时 $DOTNET_VER 已在服务器上（~/cellwar/$RT/）"
else
	[ -f "$DOTNET_TGZ" ] || die "本地没有 $DOTNET_TGZ（.NET $DOTNET_VER linux-x64 运行时）：下好再跑，或用 DOTNET_TGZ 指给我"
	echo "上传 .NET 运行时 $DOTNET_VER → ~/cellwar/$RT/ …"
	ssh "$HOST" "mkdir -p ~/cellwar"
	scp -q "$DOTNET_TGZ" "$HOST:~/cellwar/$RT.tar.gz"
	ssh "$HOST" "set -e; cd ~/cellwar
		if $RT/dotnet --list-runtimes 2>/dev/null | grep -q 'Microsoft.NETCore.App $DOTNET_VER '; then rm -f $RT.tar.gz; exit 0; fi
		rm -rf $RT.tmp; mkdir $RT.tmp; tar xzf $RT.tar.gz -C $RT.tmp
		$RT.tmp/dotnet --list-runtimes | grep -q 'Microsoft.NETCore.App $DOTNET_VER ' || { rm -rf $RT.tmp $RT.tar.gz; echo '✘ 传上去的运行时在服务器上跑不起来（架构 / glibc 对不上？）—— 已删掉，线上那一版没动'; exit 1; }
		rm -rf $RT; mv $RT.tmp $RT; rm -f $RT.tar.gz; echo '运行时装好（还没启用，自检过了才改软链）'"
fi

# ---- ② 载荷 ----
echo "现编 sidecar 载荷（照工作树的 core/）…"
PAYLOAD_ONLY=1 bash tools/build_sidecar.sh
WANT_BUILD="$(grep -oE '"core_build":"[^"]*"' game/sidecar/payload.json | cut -d'"' -f4)" || true
[ -n "$WANT_BUILD" ] || die "game/sidecar/payload.json 里读不出 core_build"

# ---- ③④ 工程：先解到 next.tmp/、自检，全过才换上 ----
echo "打包 game/ + server/run.sh → $HOST:~/cellwar/next.tmp …"
tar czf - --exclude=.godot --exclude='tests/_tmp_*' --exclude='sidecar/runtime-*' -C . game server/run.sh \
	| ssh "$HOST" "WANT_BUILD='$WANT_BUILD' RT='$RT'"'
	set -e
	mkdir -p ~/cellwar
	cd ~/cellwar
	rm -rf next.tmp
	mkdir next.tmp
	tar xzf - -C next.tmp
	PENDING=""
	[ -f DRAIN ] && PENDING="（注意：DRAIN 本来就在 —— 之前有一次部署还没切过去，那一份 next/ 照旧会切）"
	LOG=$(mktemp)
	abort() { rm -rf next.tmp; rm -f "$LOG"; echo "✘ $1 —— 这次传的已撤掉、没写 DRAIN、线上那一版没动$PENDING"; exit 1; }
	# 自检：新运行时起得来新载荷、读回的 core_build 就是这次编的
	DN="$PWD/$RT/dotnet"
	DLL="$PWD/next.tmp/game/sidecar/payload/CellWar.Sidecar.dll"
	[ -x "$DN" ] || abort "服务器上没有 $RT/dotnet"
	[ -f "$DLL" ] && [ -f next.tmp/server/run.sh ] || abort "传上来的包不全（没有载荷 dll 或 run.sh）"
	GOT=$(timeout 60 "$DN" exec "$DLL" --version 2>&1 | grep -oE "\"core_build\":\"[^\"]*\"" | cut -d\" -f4) || true
	[ -n "$GOT" ] && [ "$GOT" = "$WANT_BUILD" ] || abort "新载荷读回的 core_build 是「$GOT」，应该是「$WANT_BUILD」"
	timeout 120 "$DN" exec "$DLL" --selftest >"$LOG" 2>&1 || { tail -5 "$LOG"; abort "新载荷的 --selftest 没过"; }
	rm -f "$LOG"
	echo "sidecar 自检通过（core_build $GOT，运行时 $RT）"
	# 换上：每一步都是改名，失败当场停（还没写 DRAIN）
	if [ -e dotnet ] && [ ! -L dotnet ]; then abort "~/cellwar/dotnet 是个真目录、不是软链：手动挪开再部署"; fi
	{ ln -sfn "$RT" dotnet.new && mv -Tf dotnet.new dotnet; } || abort "改运行时软链失败"
	{ install -m 755 next.tmp/server/run.sh run.sh.new && mv -f run.sh.new run.sh; } || abort "换 run.sh 失败"
	{ rm -rf next && mv next.tmp/game next; } || abort "next.tmp/game → next 改名失败"
	rm -rf next.tmp
	touch DRAIN
	echo "已上传到 ~/cellwar/next，已写 DRAIN"
	systemctl is-active cellwar >/dev/null 2>&1 && echo "服务在跑：排空后自动切新版" || echo "服务没在跑：sudo systemctl start cellwar"
'
