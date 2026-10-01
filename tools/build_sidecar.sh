#!/usr/bin/env bash
# 把 C# sidecar 打进桌面包要的两样东西放到 game/sidecar/（换内核 P7，docs/内核替换_重启计划.md §五 第 2 条：运行时压进游戏包）：
#   payload/              —— 框架依赖的 sidecar（CellWar.Sidecar.dll + CellWar.Core.dll + runtimeconfig / deps，几百 KB）。
#                            规则一改就变，以后随增量补丁走（P7 后半）。
#   runtime-<rid>.zip     —— 该平台的 .NET 运行时（dotnet 宿主 + host/fxr + shared/Microsoft.NETCore.App），约 31 MB 压缩。
#                            只随全量发版变。
#   manifest.json         —— 载荷的 sha256、运行时版本与 sha256（句柄解包时按它判断「用户目录里那份还是不是这一版」）。
# 导出预设的 include_filter 带 sidecar/*（只有 Windows / macOS 两个桌面预设；网页、安卓排除）。game/sidecar/ 不入库。
#
# 用法：tools/build_sidecar.sh [rid ...]      缺省 = 本机（Mac 上 osx-arm64）
#   运行时从哪来：RUNTIME_DIR_<rid 里 - 换成 _>（例 RUNTIME_DIR_win_x64=/path/解开的 dotnet-runtime-10.0.x-win-x64）；
#   没给就用本机 ~/.dotnet（只对本机 rid 有效）。
#
# 发布硬纪律（路线 A §十 第 1 条）：不 Trim、不 SingleFile、不 Aot —— csproj 里写死了 false，这里也不传。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=game/sidecar
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
host_rid() {
	case "$(uname -s)-$(uname -m)" in
		Darwin-arm64) echo osx-arm64 ;;
		Linux-x86_64) echo linux-x64 ;;
		MINGW*|MSYS*|CYGWIN*) echo win-x64 ;;
		*) echo "unknown" ;;
	esac
}
RIDS=("$@")
[ ${#RIDS[@]} -eq 0 ] && RIDS=("$(host_rid)")

rm -rf "$OUT/payload"
mkdir -p "$OUT/payload"
"$DOTNET" publish core/CellWar.Sidecar -c Release -o "$OUT/payload" -p:UseAppHost=false --no-self-contained --nologo -v q
rm -f "$OUT/payload/"*.pdb
PAYLOAD_SHA=$(cd "$OUT/payload" && ls | sort | xargs cat | shasum -a 256 | cut -d' ' -f1)

RUNTIME_JSON=""
for rid in "${RIDS[@]}"; do
	var="RUNTIME_DIR_${rid//-/_}"
	src="${!var:-}"
	if [ -z "$src" ]; then
		[ "$rid" = "$(host_rid)" ] || { echo "✘ $rid 的运行时要给 $var（解开的 dotnet-runtime 目录）"; exit 1; }
		src="$(dirname "$DOTNET")"
	fi
	ver=$(ls "$src/shared/Microsoft.NETCore.App" | sort -V | tail -1)
	[ -n "$ver" ] || { echo "✘ $src 里没有 shared/Microsoft.NETCore.App"; exit 1; }
	host=dotnet; [ "${rid%%-*}" = "win" ] && host=dotnet.exe
	zip_path="$OUT/runtime-$rid.zip"
	rm -f "$zip_path"
	(cd "$src" && zip -qr -9 -X "$OLDPWD/$zip_path" "$host" host/fxr "shared/Microsoft.NETCore.App/$ver")
	sha=$(shasum -a 256 "$zip_path" | cut -d' ' -f1)
	RUNTIME_JSON="$RUNTIME_JSON${RUNTIME_JSON:+,}\"$rid\":{\"file\":\"runtime-$rid.zip\",\"version\":\"$ver\",\"host\":\"$host\",\"sha256\":\"$sha\"}"
	echo "✔ $rid 运行时 $ver → $zip_path（$(du -h "$zip_path" | cut -f1)）"
done

cat > "$OUT/manifest.json" <<EOF
{"payload":{"dir":"payload","sha256":"$PAYLOAD_SHA","files":[$(cd "$OUT/payload" && ls | sort | sed 's/.*/"&"/' | paste -sd, -)]},"runtimes":{$RUNTIME_JSON}}
EOF
echo "✔ 载荷 $(du -sh "$OUT/payload" | cut -f1)，manifest 在 $OUT/manifest.json"
