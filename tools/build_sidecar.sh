#!/usr/bin/env bash
# 把 C# sidecar 打进桌面包要的东西放到 game/sidecar/（换内核 P7，docs/内核替换_重启计划.md §五 第 2 条：运行时压进游戏包）：
#   payload/ + payload.json   —— 框架依赖的 sidecar（CellWar.Sidecar.dll + CellWar.Core.dll + CellWar.Ai.dll + runtimeconfig / deps，几百 KB）
#                                与它的 sha256 / 文件表 / core_build。规则一改就变，**随增量补丁走**（build_patch.sh 只带这两样）。
#   runtime-<rid>.zip + runtime-<rid>.json —— 该平台的 .NET 运行时（dotnet 宿主 + host/fxr + shared/Microsoft.NETCore.App，约 31 MB 压缩）
#                                与版本 / sha256。**只随全量发版变**（补丁里没有它，挂了补丁照样用包里那份）。
# 载荷与运行时的 json 分开放，正是为了让补丁只盖 payload.json、不必知道基线包里运行时那一份长什么样；
# 运行时一个平台一份 json，单独重打某个平台不会冲掉别的平台。
# 导出预设：Windows 只带 runtime-win-x64.*、macOS 只带 runtime-osx-arm64.*（见 game/export_presets.cfg）。game/sidecar/ 不入库。
#
# 用法：tools/build_sidecar.sh [rid ...]      缺省 = 本机（Mac 上 osx-arm64）
#   BUILD_ID=<串>    烧进 dll 的 core_build（sidecar `--version` 读得回来）：发版 = 提交号，补丁 = 补丁号；
#                   缺省 = 当前提交号，core/ 有没提交的改动再加 -dirty
#   PAYLOAD_ONLY=1  只出载荷（打补丁用），不碰运行时 zip
#   运行时从哪来：RUNTIME_DIR_<rid 里 - 换成 _>（例 RUNTIME_DIR_win_x64=/path/解开的 dotnet-runtime-10.0.x-win-x64）；
#   没给就用本机 ~/.dotnet（只对本机 rid 有效）。
#
# 发布硬纪律（路线 A §十 第 1 条）—— 这里就是那道闸，每次打包都先过：
#   CellWar.Sidecar / CellWar.Core 的 csproj 不许打开 PublishTrimmed / PublishSingleFile / PublishAot；
#   CellWar.Core / CellWar.Ai 零 PackageReference；载荷里只许有那五个文件（多出一个 dll = 有人加了包引用）。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=game/sidecar
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
PAYLOAD_MAX_KB=2048   # 补丁要带它：超过 2 MB 多半是混进了别的程序集
PAYLOAD_FILES="CellWar.Ai.dll CellWar.Core.dll CellWar.Sidecar.deps.json CellWar.Sidecar.dll CellWar.Sidecar.runtimeconfig.json"
die() { echo "✘ $1" >&2; exit 1; }
host_rid() {
	case "$(uname -s)-$(uname -m)" in
		Darwin-arm64) echo osx-arm64 ;;
		Linux-x86_64) echo linux-x64 ;;
		MINGW*|MSYS*|CYGWIN*) echo win-x64 ;;
		*) echo "unknown" ;;
	esac
}

# ---- 闸：csproj 纪律 ----
for proj in core/CellWar.Sidecar/CellWar.Sidecar.csproj core/CellWar.Core/CellWar.Core.csproj; do
	for prop in PublishTrimmed PublishSingleFile PublishAot; do
		if grep -qiE "<$prop>[[:space:]]*true" "$proj"; then
			die "$proj 打开了 $prop —— 规则 dll 会和宿主烧成一坨，增量补丁就带不了它（路线 A §十 第 1 条）"
		fi
	done
done
for proj in core/CellWar.Core/CellWar.Core.csproj core/CellWar.Ai/CellWar.Ai.csproj; do
	if grep -q "<PackageReference" "$proj"; then
		die "$proj 有 PackageReference —— 规则内核与 AI 只许用 BCL（补丁载荷与可替换性都靠它）"
	fi
done

if [ -z "${BUILD_ID:-}" ]; then
	BUILD_ID="$(git rev-parse --short HEAD)"
	[ -n "$(git status --porcelain -- core/CellWar.Core core/CellWar.Sidecar)" ] && BUILD_ID="$BUILD_ID-dirty"
fi

# ---- 载荷 ----
rm -rf "$OUT/payload"
mkdir -p "$OUT/payload"
# Deterministic + ContinuousIntegrationBuild + 不出 pdb：同一份源码、同一个 BUILD_ID 打出来逐字节相同（dll 里不留本机路径）
"$DOTNET" publish core/CellWar.Sidecar -c Release -o "$OUT/payload" -p:UseAppHost=false --no-self-contained --nologo -v q \
	-p:Deterministic=true -p:ContinuousIntegrationBuild=true -p:DebugType=none -p:DebugSymbols=false \
	-p:InformationalVersion="$BUILD_ID" -p:IncludeSourceRevisionInInformationalVersion=false
rm -f "$OUT/payload/"*.pdb
GOT="$(cd "$OUT/payload" && ls | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "$PAYLOAD_FILES" ] || die "载荷文件表不对：$GOT（应为 $PAYLOAD_FILES）—— 多出来的多半是新加的包引用"
KB=$(du -sk "$OUT/payload" | cut -f1)
[ "$KB" -le "$PAYLOAD_MAX_KB" ] || die "载荷 ${KB} KB 超过 ${PAYLOAD_MAX_KB} KB"
PAYLOAD_SHA=$(cd "$OUT/payload" && ls | sort | xargs cat | shasum -a 256 | cut -d' ' -f1)
cat > "$OUT/payload.json" <<EOF
{"dir":"payload","sha256":"$PAYLOAD_SHA","core_build":"$BUILD_ID","files":[$(cd "$OUT/payload" && ls | sort | sed 's/.*/"&"/' | paste -sd, -)]}
EOF
rm -f "$OUT/manifest.json"   # 10-01 拆成 payload.json + runtime-<rid>.json 之前的旧文件
echo "✔ 载荷 ${KB} KB（core_build $BUILD_ID）→ $OUT/payload.json"
[ "${PAYLOAD_ONLY:-0}" = "1" ] && exit 0

# ---- 运行时 ----
RIDS=("$@")
[ ${#RIDS[@]} -eq 0 ] && RIDS=("$(host_rid)")
for rid in "${RIDS[@]}"; do
	var="RUNTIME_DIR_${rid//-/_}"
	src="${!var:-}"
	if [ -z "$src" ]; then
		[ "$rid" = "$(host_rid)" ] || die "$rid 的运行时要给 $var（解开的 dotnet-runtime 目录）"
		src="$(dirname "$DOTNET")"
	fi
	ver=$(ls "$src/shared/Microsoft.NETCore.App" | sort -V | tail -1)
	[ -n "$ver" ] || die "$src 里没有 shared/Microsoft.NETCore.App"
	host=dotnet; [ "${rid%%-*}" = "win" ] && host=dotnet.exe
	zip_path="$OUT/runtime-$rid.zip"
	rm -f "$zip_path"
	(cd "$src" && zip -qr -9 -X "$OLDPWD/$zip_path" "$host" host/fxr "shared/Microsoft.NETCore.App/$ver")
	sha=$(shasum -a 256 "$zip_path" | cut -d' ' -f1)
	echo "{\"file\":\"runtime-$rid.zip\",\"version\":\"$ver\",\"host\":\"$host\",\"sha256\":\"$sha\"}" > "$OUT/runtime-$rid.json"
	echo "✔ $rid 运行时 $ver → $zip_path（$(du -h "$zip_path" | cut -f1)）"
done
