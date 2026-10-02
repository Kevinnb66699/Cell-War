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
# C# 内核（换内核 P8）：.NET 运行时装在 dotnet/（tools/setup_server.sh 装），规则 dll 随工程走
# （game/sidecar/payload/，tools/deploy_server.sh 打包前现编、传上来先自检再切）。缺一样就不设 ——
# 建局时找不到 sidecar：普通房照旧走 GD 路、网页单机房答 solo_off（与切换前一样），服务本身照常起
if [ -x dotnet/dotnet ] && [ -f game/sidecar/payload/CellWar.Sidecar.dll ]; then
  export CW_DOTNET="$PWD/dotnet/dotnet" CW_SIDECAR_DLL="$PWD/game/sidecar/payload/CellWar.Sidecar.dll"
fi
# feedback_*：「反馈 bug」收件口（issue #19），只绑本机，nginx 把 /cellwar/feedback 反代到 8612（server/nginx-feedback.conf）
mkdir -p feedback
exec ./godot --headless --path game --script res://server/server_main.gd -- port=8611 drain="$PWD/DRAIN" \
  feedback_port=8612 feedback_bind=127.0.0.1 feedback_dir="$PWD/feedback"
