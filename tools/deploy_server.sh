#!/bin/bash
# deploy_server.sh —— 发版：把 game/ 打包传到服务器 ~/cellwar/next/，写 DRAIN 让服务器排空后切到新版
#
# 用法（仓库根目录）：tools/deploy_server.sh [ssh 别名，默认 cellwar]
#   · 没有对局在打：服务器几秒内就重启到新版
#   · 有对局在打：维护中（大厅有提示、不能建房/开局），最后一局打完自动重启
# 看状态：ssh cellwar 'systemctl status cellwar --no-pager; journalctl -u cellwar -n 30 --no-pager'
# 第一次装机用 tools/setup_server.sh。别名 cellwar 定义在 ~/.ssh/config（专用钥匙 cellwar_ed25519）。
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
echo "打包 game/ → $HOST:~/cellwar/next …"
tar czf - --exclude=.godot --exclude='tests/_tmp_*' -C . game | ssh "$HOST" '
  set -e
  mkdir -p ~/cellwar
  rm -rf ~/cellwar/next.tmp ~/cellwar/next
  mkdir ~/cellwar/next.tmp
  tar xzf - -C ~/cellwar/next.tmp
  mv ~/cellwar/next.tmp/game ~/cellwar/next
  rmdir ~/cellwar/next.tmp
  touch ~/cellwar/DRAIN
  echo "已上传到 ~/cellwar/next，已写 DRAIN"
  systemctl is-active cellwar >/dev/null 2>&1 && echo "服务在跑：排空后自动切新版" || echo "服务没在跑：sudo systemctl start cellwar"
'
