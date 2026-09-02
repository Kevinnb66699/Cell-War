#!/bin/bash
# run.sh —— Cell War 联机服务器的启动脚本（systemd 的 ExecStart，见 cellwar.service）
#
# 目录 ~/cellwar/：godot（Linux 4.5 二进制）、game/（工程副本）、next/（待切换的新版）、DRAIN（排空标记）。
# 发版流程（docs/联机设计 §八）：tools/deploy_server.sh 把新工程传到 next/ 并写 DRAIN →
# 服务器进入维护中（拒绝建房与开局），最后一局打完自动退出 → systemd Restart 拉起本脚本 →
# 这里把 next/ 换成 game/、重新导入资源、清掉 DRAIN，再起新版。
set -e
cd "$(dirname "$0")"
if [ -d next ]; then
  rm -rf game.prev
  [ -d game ] && mv game game.prev
  mv next game
  ./godot --headless --path game --import >/dev/null 2>&1 || true
fi
rm -f DRAIN
exec ./godot --headless --path game --script res://server/server_main.gd -- port=8611 drain="$PWD/DRAIN"
