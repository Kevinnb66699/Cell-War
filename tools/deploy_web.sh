#!/usr/bin/env bash
# deploy_web.sh —— 导出网页版并传到服务器
#
# 用法（仓库根目录）：
#   tools/deploy_web.sh              # 导 release 包 → 传到 cellwar:/var/www/cellwar/web/
#   DEBUG=1 tools/deploy_web.sh      # 导 debug 包（报错信息全，排查时用）
#   DRY=1   tools/deploy_web.sh      # 只导不传
#
# ⚠ **三个坑都写死在这个脚本里了，别绕过它**：
#
# ① **Godot 导出失败时退出码仍然是 0**（2026-09-14 亲眼看到：Gradle 构建失败、日志里写着
#    `Project export for preset "Android" failed.`，而进程退出码是 0，**产物还是上一次的旧包**）。
#    所以这里既抓输出里的 ERROR，也核产物的时间戳 —— 光看退出码会「一路绿灯发出去一个旧包」。
#
# ② **nginx 默认不认 .wasm**（这台机器上的 mime.types 原本没有那一行，
#    会当 application/octet-stream 发，浏览器的 instantiateStreaming 用不了）。
#    已经补过一行，备份在 /etc/nginx/mime.types.bak-cellwar；这里传完会再核一遍。
#
# ③ **Godot 网页版必须跑在安全上下文（HTTPS）里**。本地 127.0.0.1 能跑是因为 localhost
#    本身算安全上下文 —— 拿公网 IP 的明文 HTTP 开，引擎直接拒绝启动。
#    所以线上地址必须是 https://，验证那一步照这个来。
set -eu

cd "$(dirname "$0")/.."
GODOT="${GODOT:-/d/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"
HOST="${HOST:-cellwar}"
REMOTE="/var/www/cellwar/web"
OUT="dist/web"
URL="${URL:-https://cellwar.jiling.chat/}"
DRY="${DRY:-0}"
DEBUG="${DEBUG:-0}"

die() { echo "✘ $1" >&2; exit 1; }

[ -x "$GODOT" ] || die "找不到 Godot：$GODOT（用 GODOT=... 指定）"

MODE="--export-release"
[ "$DEBUG" = "1" ] && MODE="--export-debug"

echo "导出网页版（$MODE）…"
rm -rf "$OUT"
mkdir -p "$OUT"
ABS="$(pwd)/$OUT/index.html"
LOG="$(mktemp)"
"$GODOT" --headless --path game "$MODE" "Web" "$ABS" >"$LOG" 2>&1 || true

# ① 退出码靠不住，看输出 + 看产物
if grep -qiE "Project export for preset .* failed|ERROR: Export:" "$LOG"; then
	echo "---- 导出日志尾巴 ----" >&2
	tail -25 "$LOG" >&2
	die "导出失败（退出码可能仍是 0，别信它）"
fi
[ -f "$OUT/index.wasm" ] && [ -f "$OUT/index.pck" ] || { tail -25 "$LOG" >&2; die "产物不全：index.wasm / index.pck 没出来"; }
rm -f "$LOG"

# 注入同源改写（见 tools/web/same_origin_shim.js 的文件头）。
# 游戏里有两处地址写死成 http://124.221.78.13/cellwar/，在 https 页面上会被当混合内容拦掉、
# 并把整页标成「不安全」。改那两个地址要动 boot.gd = 必须全量发版，所以改在**发版这一侧**。
# 必须插在引擎脚本**之前** —— </head> 前面正好。
SHIM="tools/web/same_origin_shim.js"
[ -f "$SHIM" ] || die "找不到 $SHIM"
python - "$OUT/index.html" "$SHIM" <<'PYEOF'
import io, sys
page, shim = sys.argv[1], sys.argv[2]
html = io.open(page, encoding="utf-8", newline="").read()
js = io.open(shim, encoding="utf-8", newline="").read()
assert "same-origin-shim" not in html, "已经注入过了"
tag = "<script id=\"same-origin-shim\">\n" + js + "</script>\n\t</head>"
assert html.count("\t</head>") == 1, "index.html 的 </head> 锚点对不上（Godot 换模板了？）"
io.open(page, "w", encoding="utf-8", newline="").write(html.replace("\t</head>", tag))
print("  已注入同源改写")
PYEOF

# 预压：wasm 有 36 MB，不压的话首次加载能拖到几分钟。
# **在这里压而不是让 nginx 现压** —— 现压等于每个请求都 gzip 一遍 36 MB，CPU 白烧。
# 服务器那边 `gzip_static on`，同名的 .gz 存在就直接发它。
echo "预压 …"
for f in "$OUT"/*.wasm "$OUT"/*.js "$OUT"/*.pck "$OUT"/*.html; do
	[ -f "$f" ] || continue
	gzip -9 -k -f "$f"
	echo "  $(basename "$f"):  $(du -h "$f" | cut -f1) -> $(du -h "$f.gz" | cut -f1)"
done

echo "✔ 产物：$(du -sh "$OUT" | cut -f1)"
ls -la "$OUT"

if [ "$DRY" = "1" ]; then
	echo "✔ DRY=1：只导不传，线上没有任何变化"
	exit 0
fi

echo "上传到 $HOST:$REMOTE …"
ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST" "sudo -n mkdir -p $REMOTE && sudo -n chown -R \$USER:\$USER $REMOTE"
# 先解到临时目录再 rsync --delete：直接往目标里解的话，上一版多出来的文件会留着
tar czf - -C "$OUT" . | ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST" "
	set -e
	rm -rf ~/web.tmp && mkdir -p ~/web.tmp
	tar xzf - -C ~/web.tmp
	rsync -a --delete ~/web.tmp/ $REMOTE/
	rm -rf ~/web.tmp
"

# ② 传完核一遍 MIME —— wasm 发错类型时页面照样「能打开」，只是引擎起不来，最难看出来
echo "核对线上的 MIME 与状态码 …"
ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST" '
	# **必须按域名 + HTTPS 核**：同一份文件被两个 server 块同时 alias 着——
	# 老那块是 `server_name 124.221.78.13` 的明文 80（补丁与反馈口在用，没有 gzip_static），
	# 新这块才是带证书、带 gzip_static 的 cellwar.jiling.chat。
	# 打错主机名的话，压缩这一条会永远报「没生效」（第一版就是这么误报的）。
	R="--resolve cellwar.jiling.chat:443:127.0.0.1 -k"
	fail=0
	for f in index.html index.wasm index.js index.pck; do
		line=$(curl -s $R -o /dev/null -w "%{http_code} %{content_type}" "https://cellwar.jiling.chat/$f")
		echo "  $line  $f"
		case "$f:$line" in
			index.wasm:*application/wasm*) ;;
			index.wasm:*) echo "  ✘ wasm 的 MIME 不对（nginx 的 mime.types 缺 application/wasm）"; fail=1 ;;
		esac
		# 预压那一份有没有真被发出去（gzip_static 没开、或 .gz 没传上来的话这里会露馅）
		enc=$(curl -s $R -o /dev/null -H "Accept-Encoding: gzip" -w "%{size_download}" "https://cellwar.jiling.chat/$f")
		raw=$(curl -s $R -o /dev/null -w "%{size_download}" "https://cellwar.jiling.chat/$f")
		if [ "$f" = "index.wasm" ]; then
			if [ "$enc" -ge "$raw" ]; then
				echo "  ✘ wasm 没走预压：压缩 $enc / 原始 $raw"; fail=1
			else
				echo "     预压生效：$raw -> $enc 字节"
			fi
		fi
		case "$line" in 200*) ;; *) echo "  ✘ $f 取不到"; fail=1 ;; esac
	done
	exit $fail
' || die "线上核对没过，见上面"

echo
echo "✔ 已上线：$URL"
echo "  ⚠ 必须用 https 打开 —— 明文 HTTP 下 Godot 会拒绝启动（Secure Context）"
