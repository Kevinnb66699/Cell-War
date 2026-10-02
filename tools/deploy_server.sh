#!/bin/bash
# deploy_server.sh —— 发版：把 game/ 打包传到服务器 ~/cellwar/next/，写 DRAIN 让服务器排空后切到新版
#
# 用法（仓库根目录）：tools/deploy_server.sh [ssh 别名，默认 cellwar]
#   · 没有对局在打：服务器几秒内就重启到新版
#   · 有对局在打：维护中（大厅有提示、不能建房/开局），最后一局打完自动重启
# 看状态：ssh cellwar 'systemctl status cellwar --no-pager; journalctl -u cellwar -n 30 --no-pager'
# 第一次装机用 tools/setup_server.sh。别名 cellwar 定义在 ~/.ssh/config（专用钥匙 cellwar_ed25519）。
#
# 换内核 P8 起服务器的对局跑在 C# sidecar 上：规则 dll 随工程走（game/sidecar/payload/），.NET 运行时在服务器的 ~/cellwar/dotnet/
#（这里装：服务器上没有 DOTNET_TGZ 那个版本才传，缺省 ~/.cellwar/dotnet-runtime-10.0.12-linux-x64.tar.gz —— 10-01 从
# builds.dotnet.microsoft.com 下的官方包，SHA-512 对过；服务器连不上 GitHub，所以本地下好再传；只装、不重启服务）。
# 所以这里多三步：① 打包前照工作树的 core/ 现编载荷（PAYLOAD_ONLY，要本机 dotnet SDK）；
# ② 桌面包的运行时 zip（game/sidecar/runtime-*，几十 MB、服务器用不上）不上传；
# ③ 传上去之后、写 DRAIN 之前，用服务器那份运行时真起一次新载荷（--version 读回 core_build 对得上 + --selftest 打一小局）——
#    不过就删掉 next/、不写 DRAIN，线上那一版一点不动。run.sh 也随这次更新（先传 run.sh.new，自检过了才换上）。
set -e
# macOS 的 tar（bsdtar）会把扩展属性（com.apple.provenance 之类）打成 AppleDouble 的「._文件名」一起塞进包里：
# 2026-10-01 服务器发版因此多出 795 个 ._*.gd 垃圾、`rmdir next.tmp` 撞上 ._game 退出；网页目录也多了 16 个 ._*。
# 关掉它（只对 macOS 生效，别的平台不认这个变量）
export COPYFILE_DISABLE=1
# 服务器的 sshd 被扫描时会随机丢连接（"Connection closed by ... port 22"，2026-09-02 实测），所以每条 ssh/scp 都重试几次
ssh() { for i in 1 2 3 4 5; do command ssh -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; local rc=$?; [ $rc -eq 255 ] || return $rc; sleep 5; done; return 255; }
scp() { for i in 1 2 3 4 5; do command scp -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; local rc=$?; [ $rc -eq 255 ] || return $rc; sleep 5; done; return 255; }
HOST=${1:-cellwar}
cd "$(dirname "$0")/.."
echo "现编 sidecar 载荷（照工作树的 core/）…"
PAYLOAD_ONLY=1 bash tools/build_sidecar.sh
WANT_BUILD="$(grep -oE '"core_build":"[^"]*"' game/sidecar/payload.json | cut -d'"' -f4)"
DOTNET_TGZ=${DOTNET_TGZ:-$HOME/.cellwar/dotnet-runtime-10.0.12-linux-x64.tar.gz}
DOTNET_VER=$(basename "$DOTNET_TGZ" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if ssh "$HOST" "~/cellwar/dotnet/dotnet --list-runtimes 2>/dev/null | grep -q 'Microsoft.NETCore.App $DOTNET_VER '"; then
  echo ".NET 运行时 $DOTNET_VER 已装好"
else
  [ -f "$DOTNET_TGZ" ] || { echo "本地没有 $DOTNET_TGZ（.NET $DOTNET_VER linux-x64 运行时）：下好再跑，或用 DOTNET_TGZ 指给我"; exit 1; }
  echo "上传 .NET 运行时 $DOTNET_VER（换上之前在跑的对局不受影响：已起的进程用的是旧文件）…"
  scp -q "$DOTNET_TGZ" "$HOST:~/cellwar/dotnet_runtime.tar.gz"
  ssh "$HOST" "set -e; cd ~/cellwar; rm -rf dotnet.tmp; mkdir dotnet.tmp; tar xzf dotnet_runtime.tar.gz -C dotnet.tmp; rm -f dotnet_runtime.tar.gz; rm -rf dotnet; mv dotnet.tmp dotnet; dotnet/dotnet --list-runtimes"
fi
scp -q server/run.sh "$HOST:~/cellwar/run.sh.new"
echo "打包 game/ → $HOST:~/cellwar/next …"
tar czf - --exclude=.godot --exclude='tests/_tmp_*' --exclude='sidecar/runtime-*' -C . game | ssh "$HOST" "WANT_BUILD='$WANT_BUILD'"'
  set -e
  mkdir -p ~/cellwar
  rm -rf ~/cellwar/next.tmp ~/cellwar/next
  mkdir ~/cellwar/next.tmp
  tar xzf - -C ~/cellwar/next.tmp
  mv ~/cellwar/next.tmp/game ~/cellwar/next
  rmdir ~/cellwar/next.tmp
  # 自检：服务器那份运行时起得来新载荷、读回的 core_build 就是这次编的 —— 不过就撤回，线上不动
  DN=~/cellwar/dotnet/dotnet
  DLL=~/cellwar/next/sidecar/payload/CellWar.Sidecar.dll
  abort() { rm -rf ~/cellwar/next ~/cellwar/run.sh.new; echo "✘ $1 —— 已撤回 next/，没写 DRAIN，线上那一版没动"; exit 1; }
  [ -x "$DN" ] || abort "服务器上没有 .NET 运行时（~/cellwar/dotnet/）"
  GOT=$("$DN" exec "$DLL" --version 2>&1 | grep -oE "\"core_build\":\"[^\"]*\"" | cut -d\" -f4) || true
  [ "$GOT" = "$WANT_BUILD" ] || abort "新载荷读回的 core_build 是「$GOT」，应该是「$WANT_BUILD」"
  "$DN" exec "$DLL" --selftest >/tmp/cellwar_selftest.log 2>&1 || { tail -5 /tmp/cellwar_selftest.log; abort "新载荷的 --selftest 没过"; }
  echo "sidecar 自检通过（core_build $GOT）"
  chmod +x ~/cellwar/run.sh.new && mv ~/cellwar/run.sh.new ~/cellwar/run.sh
  touch ~/cellwar/DRAIN
  echo "已上传到 ~/cellwar/next，已写 DRAIN"
  systemctl is-active cellwar >/dev/null 2>&1 && echo "服务在跑：排空后自动切新版" || echo "服务没在跑：sudo systemctl start cellwar"
'
