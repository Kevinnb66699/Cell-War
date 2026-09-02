#!/bin/bash
# setup_server.sh —— 第一次在服务器上装联机服务（可重复执行）
#
# 用法（仓库根目录）：tools/setup_server.sh [ssh 别名，默认 cellwar] [本地的 Godot Linux zip 路径]
# 做的事：把 Godot 4.5 Linux 二进制、run.sh、systemd 单元放到 ~/cellwar/，上传当前 game/ 作为首版，
# 然后 enable + start 服务。之后发版只用 tools/deploy_server.sh。
# 服务器连不上 GitHub（2026-09-02 实测），所以 Godot 二进制要本地下载再传：
#   https://github.com/godotengine/godot-builds/releases/download/4.5-stable/Godot_v4.5-stable_linux.x86_64.zip
set -e
# 服务器的 sshd 被扫描时会随机丢连接（"Connection closed by ... port 22"，2026-09-02 实测），所以每条 ssh/scp 都重试几次
ssh() { for i in 1 2 3 4 5; do command ssh -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; local rc=$?; [ $rc -eq 255 ] || return $rc; sleep 5; done; return 255; }
scp() { for i in 1 2 3 4 5; do command scp -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; local rc=$?; [ $rc -eq 255 ] || return $rc; sleep 5; done; return 255; }
HOST=${1:-cellwar}
ZIP=${2:-}
cd "$(dirname "$0")/.."
ssh "$HOST" 'mkdir -p ~/cellwar'
if [ -n "$ZIP" ]; then
  echo "上传 Godot 二进制 …"
  scp -q "$ZIP" "$HOST:~/cellwar/godot_linux.zip"
  ssh "$HOST" 'cd ~/cellwar && unzip -oq godot_linux.zip && chmod +x Godot_v4.5-stable_linux.x86_64 && ln -sf Godot_v4.5-stable_linux.x86_64 godot && rm -f godot_linux.zip && ./godot --version'
else
  ssh "$HOST" 'test -x ~/cellwar/godot' || { echo "服务器上还没有 ~/cellwar/godot，请把 Godot Linux zip 作为第二个参数传入"; exit 1; }
fi
scp -q server/run.sh "$HOST:~/cellwar/run.sh"
scp -q server/cellwar.service "$HOST:/tmp/cellwar.service"
ssh "$HOST" 'chmod +x ~/cellwar/run.sh && sudo -n cp /tmp/cellwar.service /etc/systemd/system/cellwar.service && sudo -n systemctl daemon-reload && sudo -n systemctl enable cellwar >/dev/null 2>&1 && echo "systemd 单元已装好"'
echo "上传首版工程 …"
tar czf - --exclude=.godot --exclude='tests/_tmp_*' -C . game | ssh "$HOST" 'set -e; rm -rf ~/cellwar/next; mkdir -p ~/cellwar/next.tmp; tar xzf - -C ~/cellwar/next.tmp; mv ~/cellwar/next.tmp/game ~/cellwar/next; rmdir ~/cellwar/next.tmp; touch ~/cellwar/DRAIN'
ssh "$HOST" 'sudo -n systemctl restart cellwar && sleep 3 && systemctl status cellwar --no-pager | head -12'
